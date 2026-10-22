import { chromium } from 'playwright';
import { ContractFactory, JsonRpcProvider, Contract, ZeroHash } from 'ethers';
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('../', import.meta.url));
const rpc = 'http://127.0.0.1:18547';
const url = 'http://127.0.0.1:14173';
const output = new URL('../test-results/', import.meta.url);
await mkdir(output, { recursive: true });
const checks = [];
const report = name => { checks.push(name); console.log(`PASS ${name}`); };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const anvil = spawn(process.env.ANVIL_BIN || `${homedir()}/.foundry/bin/anvil`, ['--port', '18547', '--host', '127.0.0.1', '--silent'], { stdio: ['ignore', 'ignore', 'pipe'] });
let server, browser, page;
const provider = new JsonRpcProvider(rpc, 31337, { cacheTimeout: -1, pollingInterval: 100 });
try {
  for (let attempt = 0; attempt < 60; attempt++) {
    try { await fetch(rpc); break; } catch { await delay(100); }
  }
  const accounts = (await provider.listAccounts()).map(signer => signer.address);
  const signer = await provider.getSigner(0);
  const artifact = JSON.parse(await readFile(new URL('../../ryodan-keys/out/RyodanKeys.sol/RyodanKeys.json', import.meta.url), 'utf8'));
  const factory = new ContractFactory(artifact.abi, artifact.bytecode.object, signer);
  const initialDeadline = (await provider.getBlock('latest')).timestamp + 30 * 86400;
  const keys = await factory.deploy(initialDeadline, 'ipfs://hidden/hidden.json', accounts[0], accounts[0]);
  await keys.waitForDeployment();
  const target = await keys.getAddress();
  await (await keys.setPublicMintActive(true, 5)).wait();
  server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '14173', '--strictPort'], { cwd: root, env: { ...process.env, VITE_CHAIN_ID: '31337', VITE_RPC_URL: rpc, VITE_CONTRACT_ADDRESS: target }, stdio: ['ignore', 'ignore', 'pipe'] });
  for (let attempt = 0; attempt < 60; attempt++) { try { const response = await fetch(url); if (response.ok) break; } catch {} await delay(100); }
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  browser = await chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  await context.addInitScript(({ rpc, accounts }) => {
    const events = new Map();
    const wallet = { account: accounts[0], chain: '0x7a69', reject: false };
    window.testWallet = {
      changeAccount(account) { wallet.account = account; events.get('accountsChanged')?.([account]); },
      changeChain(chain) { wallet.chain = chain; events.get('chainChanged')?.(chain); },
      rejectNext() { wallet.reject = true; },
    };
    window.ethereum = {
      on(event, listener) { events.set(event, listener); },
      async request({ method, params = [] }) {
        if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [wallet.account];
        if (method === 'eth_chainId') return wallet.chain;
        if (method === 'wallet_switchEthereumChain') { wallet.chain = params[0].chainId; events.get('chainChanged')?.(wallet.chain); return null; }
        if (method === 'eth_sendTransaction' && wallet.reject) { wallet.reject = false; throw Object.assign(new Error('User rejected request'), { code: 4001 }); }
        const response = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }) });
        const data = await response.json();
        if (data.error) throw Object.assign(new Error(data.error.message), data.error);
        return data.result;
      },
    };
  }, { rpc, accounts });
  page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('requestfailed', request => errors.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText}`));
  page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
  await page.goto(url);
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'PUBLIC');
  assert.equal(await page.locator('[data-action="mint"]').isDisabled(), true);
  report('Disconnected read-only state reflects actual local contract');
  await page.locator('#connect').click();
  await page.waitForFunction(() => !document.querySelector('[data-action="mint"]').disabled);
  assert.match(await page.locator('#identity-roles').textContent(), /Administrator/);
  report('Wallet connection and on-chain operator role detection');
  await page.screenshot({ path: fileURLToPath(new URL('desktop.png', output)), fullPage: true, animations: 'disabled' });

  async function transact(form, predicate) {
    const confirmed = await page.locator('#activity-log .log-kind').evaluateAll(nodes => nodes.filter(node => node.textContent === 'CONFIRMED').length);
    await page.locator(`${form} button[type="submit"]`).click();
    await page.locator('#review-dialog').waitFor({ state: 'visible' });
    assert.match(await page.locator('#review-details').textContent(), new RegExp(target));
    await page.locator('#confirm-transaction').click();
    await page.waitForFunction(previous => [...document.querySelectorAll('#activity-log .log-kind')].filter(node => node.textContent === 'CONFIRMED').length > previous, confirmed, { timeout: 20000 });
    if (predicate) assert.equal(await predicate(), true);
  }
  await page.locator('#mint-amount').fill('2');
  await transact('#mint-form', async () => await keys.mintedByUsers() === 2n);
  assert.match(await page.locator('#notice').textContent(), /Token IDs: 0, 1/);
  report('UI exact-value mint, review, real receipt and minted token IDs');

  await page.locator('a[data-page="sale"]').click();
  const nextDeadline = initialDeadline + 86400;
  await page.locator('#new-deadline').fill(new Date(nextDeadline * 1000).toISOString().slice(0, 19));
  await transact('#deadline-form', async () => await keys.mintEndTime() === BigInt(nextDeadline));
  report('UI deadline update sends exact UTC timestamp');
  await page.locator('#phase').selectOption('whitelist');
  await transact('#phase-form', async () => await keys.isWhitelistMintActive() && !await keys.isPublicMintActive());
  await page.locator('#whitelist-addresses').fill(accounts[0]);
  await transact('#whitelist-form', () => keys.whitelisted(accounts[0]));
  report('UI exclusive phase transition and whitelist management');
  await page.locator('a[data-page="treasury"]').click();
  await page.locator('#treasury-amount').fill('1');
  await page.locator('#treasury-recipient').fill(accounts[0]);
  await transact('#treasury-form', async () => await keys.mintedByTreasury() === 1n);
  assert.equal(await page.locator('[data-action="withdraw"]').isDisabled(), true);
  report('UI treasury mint and withdrawal blocked before sellout');
  await page.locator('a[data-page="reveal"]').click();
  assert.equal(await page.locator('[data-action="reveal"]').isDisabled(), true);
  await page.locator('#inspect-form button').click();
  await page.waitForFunction(() => document.querySelector('#token-result').textContent.includes('ipfs://hidden/hidden.json'));
  report('UI token metadata inspection and premature reveal guard');
  await page.locator('a[data-page="access"]').click();
  await page.locator('#role-account').fill(accounts[1]);
  await transact('#role-form', () => keys.hasRole(ZeroHash, accounts[1]));
  await page.locator('#role-operation').selectOption('revoke');
  await transact('#role-form', async () => !await keys.hasRole(ZeroHash, accounts[1]));
  report('UI grant and revoke administrator role');
  await page.locator('#role-account').fill(accounts[0]);
  await page.locator('#role-form button').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('Self-revocation'));
  assert.equal(await page.locator('#review-dialog').isVisible(), false);
  report('UI prevents accidental administrator self-revocation');

  await page.evaluate(account => window.testWallet.changeAccount(account), accounts[2]);
  await page.waitForFunction(() => document.querySelector('#identity-address').textContent !== 'Not connected' && !document.querySelector('#identity-roles').textContent.includes('Administrator'));
  assert.equal(await page.locator('#role-form button').isDisabled(), true);
  report('Account switching clears old privileges');
  await page.evaluate(account => window.testWallet.changeAccount(account), accounts[0]);
  await page.waitForFunction(() => document.querySelector('#identity-roles').textContent.includes('Administrator'));
  await page.evaluate(() => window.testWallet.changeChain('0x1'));
  await page.waitForFunction(() => document.querySelector('#role-form button').disabled);
  await page.locator('#connect').click();
  await page.waitForFunction(() => !document.querySelector('#role-form button').disabled);
  report('Wrong network blocks writes and network switch recovers');
  await page.locator('a[data-page="mint"]').click();
  await page.locator('#mint-amount').fill('1');
  await page.evaluate(() => window.testWallet.rejectNext());
  await page.locator('#mint-form button[type="submit"]').click();
  await page.locator('#review-dialog').waitFor({ state: 'visible' });
  await page.locator('#confirm-transaction').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('Signature rejected'));
  assert.equal(await keys.mintedByUsers(), 2n);
  report('Wallet rejection sends no transaction and resets controls');

  await provider.send('evm_setAutomine', [false]);
  await page.locator('#mint-form button[type="submit"]').click();
  await page.locator('#review-dialog').waitFor({ state: 'visible' });
  await page.locator('#confirm-transaction').click();
  await page.locator('#pending-box').waitFor({ state: 'visible' });
  await page.reload();
  await page.locator('#pending-box').waitFor({ state: 'visible' });
  assert.equal(await page.locator('[data-action="mint"]').isDisabled(), true);
  await provider.send('evm_mine', []);
  await provider.send('evm_setAutomine', [true]);
  await page.locator('#reconcile').click();
  await page.waitForFunction(() => document.querySelector('#pending-box').hidden);
  assert.equal(await keys.mintedByUsers(), 3n);
  report('Pending transaction survives reload, prevents duplicate sends and reconciles');
  await page.locator('#connect').click();
  await page.waitForFunction(() => document.querySelector('#identity-roles').textContent.includes('Administrator'));

  const snapshotId = await provider.send('evm_snapshot', []);
  const block = await provider.getBlock('latest');
  await (await keys.setMintEndTime(block.timestamp + 10)).wait();
  await provider.send('evm_increaseTime', [11]);
  await provider.send('evm_mine', []);
  await page.locator('#refresh').click();
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'EXPIRED');
  await page.locator('a[data-page="sale"]').click();
  assert.equal(await page.locator('[data-action="deadline"]').isDisabled(), true);
  await page.locator('a[data-page="refund"]').click();
  await page.locator('#refund-id').fill('0');
  await transact('#refund-form', () => keys.refunded(0));
  await page.locator('#refund-form button').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('Already refunded'));
  report('Expired-sale UI locks deadline, refunds once and rejects duplicate claim');
  await provider.send('evm_revert', [snapshotId]);
  await (await keys.setPublicMintActive(true, 5900)).wait();
  for (let left = 5897; left > 0; left -= 100) await (await keys.mint(Math.min(left, 100), { value: BigInt(Math.min(left, 100)) * 10n ** 16n })).wait();
  for (let left = 499; left > 0; left -= 50) await (await keys.treasuryMint(Math.min(left, 50), accounts[0])).wait();
  await page.locator('#refresh').click();
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'SOLD OUT');
  await page.locator('a[data-page="reveal"]').click();
  await page.locator('#base-uri').fill('ipfs://bafy-local-test/');
  await page.locator('input[name="acknowledge"]').check();
  await transact('#reveal-form', () => keys.revealed());
  assert.equal(await keys.tokenURI(0), 'ipfs://bafy-local-test/0.json');
  assert.equal(await page.locator('[data-action="reveal"]').isDisabled(), true);
  await page.locator('a[data-page="treasury"]').click();
  await transact('#withdraw-form', async () => await provider.getBalance(target) === 0n);
  report('Full 6,400-key sale: UI permanent reveal and 59 ETH withdrawal');
  await page.setViewportSize({ width: 390, height: 844 });
  for (const name of ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund']) {
    await page.locator(`a[data-page="${name}"]`).click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `Mobile overflow in ${name}`);
  }
  await page.locator('a[data-page="sale"]').click();
  await page.screenshot({ path: fileURLToPath(new URL('mobile.png', output)), fullPage: true, animations: 'disabled' });
  report('All six views fit a 390px mobile viewport');
  assert.deepEqual(errors, []);
  report('No uncaught browser errors');
  await writeFile(new URL('browser-verification.json', output), JSON.stringify({ checks, contract: target, chainId: 31337 }, null, 2) + '\n');
} catch (error) {
  if (page) {
    console.error('UI notice:', await page.locator('#notice').textContent().catch(() => 'unavailable'));
    await page.screenshot({ path: fileURLToPath(new URL('failure.png', output)), fullPage: true }).catch(() => {});
  }
  throw error;
} finally {
  await browser?.close(); server?.kill(); anvil.kill(); provider.destroy();
}
