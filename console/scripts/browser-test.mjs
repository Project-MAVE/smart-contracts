import { chromium } from 'playwright';
import { ContractFactory, JsonRpcProvider, Contract, ZeroHash } from 'ethers';
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import assert from 'node:assert/strict';
import { validateSnapshot, proofFor } from '../src/allowlist.js';

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
  const sbtBase = 'ipfs://ryodan-sbt-local/';
  const nftBase = 'ipfs://ryodan-nft-local/';
  const keys = await factory.deploy(initialDeadline, sbtBase, nftBase, accounts[0], accounts[0]);
  await keys.waitForDeployment();
  const target = await keys.getAddress();
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
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'NOT STARTED');
  assert.equal(await page.locator('[data-action="mint"]').isDisabled(), true);
  report('Disconnected read-only state reflects actual local contract');
  await page.locator('#connect').click();
  await page.waitForFunction(() => document.querySelector('#identity-roles').textContent.includes('Administrator'));
  assert.match(await page.locator('#identity-roles').textContent(), /Administrator/);
  report('Wallet connection and on-chain operator role detection');
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('desktop.png', output)), fullPage: true, animations: 'disabled' });

  async function transact(form, predicate) {
    const confirmed = await page.locator('#activity-log .log-kind').evaluateAll(nodes => nodes.filter(node => node.textContent === 'CONFIRMED').length);
    await page.locator(`${form} button[type="submit"]`).click();
    await page.locator('#review-dialog').waitFor({ state: 'visible' });
    assert.match(await page.locator('#review-details').textContent(), new RegExp(target));
    await page.locator('#confirm-transaction').click();
    await page.waitForFunction(previous => [...document.querySelectorAll('#activity-log .log-kind')].filter(node => node.textContent === 'CONFIRMED').length > previous, confirmed, { timeout: 20000 });
    await page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED') && ![...document.querySelectorAll('[data-hint]')].some(node => node.textContent.includes('Another transaction')));
    if (predicate) assert.equal(await predicate(), true);
  }
  await page.locator('a[data-page="sale"]').click();
  const templateDownload = page.waitForEvent('download');
  await page.locator('a[href="/templates/pioneer.csv"]').click();
  const downloaded = await templateDownload;
  assert.equal(await readFile(await downloaded.path(), 'utf8'), 'address\n');
  const zip = await fetch(`${url}/templates/ryodan-allowlist-templates.zip`);
  assert.equal(zip.status, 200); assert((await zip.arrayBuffer()).byteLength > 500);
  report('Admin page downloads empty CSV templates and the complete template ZIP');
  await page.locator('#csv-files').setInputFiles(['pioneer', 'operative', 'recruit'].map((tier, i) => ({ name: `${tier}.csv`, mimeType: 'text/csv', buffer: Buffer.from(`address\n${accounts[i]}\n`) })));
  await page.locator('#csv-form button').click();
  await page.waitForFunction(() => document.querySelector('#snapshot-summary').textContent.includes('24 guaranteed keys'));
  const snapshotDownload = page.waitForEvent('download');
  await page.locator('#download-snapshot').click();
  const snapshotFile = await snapshotDownload;
  const built = validateSnapshot(JSON.parse(await readFile(await snapshotFile.path(), 'utf8')));
  await transact('#snapshot-form', async () => await keys.allowlistRoot() === built.root);
  for (let i = 0; i < 3; i++) { const entry = proofFor(built, accounts[i]); assert(await keys.verifyEligibility(accounts[i], entry.tier, entry.proof)); }
  assert.equal(await keys.totalGtdReserved(), 24n);
  report('UI builds CSV snapshot, downloads valid proofs and loads matching root and GTD counts on chain');
  await transact('#advance-form', async () => await keys.currentPhase() === 1n);
  assert.equal(await page.locator('#snapshot-form button').isDisabled(), true);
  await transact('#pause-form', async () => !await keys.mintPaused());
  await page.locator('a[data-page="mint"]').click();
  assert.equal(await page.locator('#mint-amount').getAttribute('step'), '2');
  assert.match(await page.locator('#mint-unit-note').textContent(), /0.05 ETH per pair/);
  await page.locator('#mint-amount').fill('2');
  await transact('#mint-form', async () => await keys.mintedByUsers() === 2n);
  assert.match(await page.locator('#notice').textContent(), /Token IDs: 1, 2/);
  report('UI exact-value mint, review, real receipt and minted token IDs');

  await page.locator('a[data-page="sale"]').click();
  assert.equal(await page.locator('#deadline-form').isVisible(), false);
  assert.equal(await keys.mintEndTime(), BigInt(initialDeadline));
  report('v6 deadline is fixed at deploy: the console shows no deadline form');
  await page.locator('#phase').selectOption('1');
  await page.locator('#phase-price').fill('0.030');
  await page.locator('#wallet-limit').fill('6');
  await transact('#phase-form', async () => (await keys.phases(1)).walletLimit === 6n && (await keys.phases(1)).price === 30000000000000000n);
  assert.equal(await keys.totalGtdReserved(), 24n);
  report('UI configures exact ETH price and independent per-wallet phase limit');
  await transact('#advance-form', async () => await keys.currentPhase() === 2n && await keys.mintPaused());
  assert(await keys.allowlisted(2, accounts[0]));
  await transact('#pause-form', async () => !await keys.mintPaused());
  assert.equal(await keys.remainingAllowance(2, accounts[0]), 10n);
  assert.equal(await keys.totalGtdReserved(), 20n);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('sale-desktop.png', output)), fullPage: true, animations: 'disabled' });
  report('UI sequential phase closure, guaranteed allowlist, resume and independent allowance');
  await page.locator('a[data-page="treasury"]').click();
  await page.locator('#treasury-amount').fill('1');
  await page.locator('#treasury-recipient').fill(accounts[0]);
  await transact('#treasury-form', async () => await keys.mintedByTreasury() === 1n);
  assert.equal(await page.locator('[data-action="withdraw"]').isDisabled(), true);
  report('UI treasury mint and withdrawal blocked before sellout');
  await page.locator('a[data-page="reveal"]').click();
  assert.equal(await page.locator('#reveal-form').isVisible(), false);
  assert.equal(await page.locator('#sbt-base').textContent(), sbtBase);
  assert.equal(await page.locator('#nft-base').textContent(), nftBase);
  assert.equal(await page.locator('#inspect-id').getAttribute('min'), '1');
  assert.equal(await page.locator('#inspect-id').getAttribute('max'), '6666');
  await page.locator('#inspect-id').fill('1');
  await page.locator('#inspect-form button').click();
  await page.waitForFunction(sbt => document.querySelector('#token-result').textContent.includes(`${sbt}1.json`) && document.querySelector('#token-result').textContent.includes('Locked: soulbound'), sbtBase);
  await page.locator('#inspect-id').fill('3');
  await page.locator('#inspect-form button').click();
  await page.waitForFunction(() => document.querySelector('#token-result').textContent.includes('None: treasury key'));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('metadata-desktop.png', output)), fullPage: true, animations: 'disabled' });
  report('v6 read-only metadata page: SBT and NFT folders from chain, locked key reads the SBT set, no reveal form');
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
  await page.locator('#mint-form button[type="submit"]').click();
  await page.locator('#review-dialog').waitFor({ state: 'visible' });
  await (await keys.configurePhase(2, 41000000000000000n, 10)).wait();
  await page.locator('#confirm-transaction').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('Mint phase or price changed'));
  assert.equal(await keys.mintedByUsers(), 2n);
  await (await keys.configurePhase(2, 40000000000000000n, 10)).wait();
  await page.locator('#refresh').click();
  await page.waitForFunction(() => document.querySelector('#mint-price').textContent === '0.04');
  report('Changed on-chain price invalidates the reviewed quote and recovery uses a fresh quote');
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

  for (const [phaseId, expectedPaid] of [[3, 4n], [4, 5n]]) {
    await page.locator('a[data-page="sale"]').click();
    await transact('#advance-form', async () => await keys.currentPhase() === BigInt(phaseId));
    await transact('#pause-form', async () => !await keys.mintPaused());
    await page.locator('a[data-page="mint"]').click();
    await page.locator('#mint-amount').fill('1');
    await transact('#mint-form', async () => await keys.mintedByUsers() === expectedPaid);
  }
  assert.equal(await keys.mintPayment(1), 25000000000000000n);
  assert.equal(await keys.mintedInPhase(1, accounts[0]), 2n);
  assert.equal(await keys.mintedInPhase(2, accounts[0]), 1n);
  assert.equal(await keys.mintedInPhase(3, accounts[0]), 1n);
  assert.equal(await keys.mintedInPhase(4, accounts[0]), 1n);
  report('All four phases mint in sequence, retain separate counters and release unused guarantees');

  const snapshotId = await provider.send('evm_snapshot', []);
  await (await keys.configurePhase(4, 5n * 10n ** 16n, 6000)).wait();
  for (let left = 5995; left > 0; left -= 100) await (await keys.mint(Math.min(left, 100), 4, 5n * 10n ** 16n, { value: BigInt(Math.min(left, 100)) * 5n * 10n ** 16n })).wait();
  for (let left = 665; left > 0; left -= 50) await (await keys.treasuryMint(Math.min(left, 50), accounts[0])).wait();
  await page.locator('#refresh').click();
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'SOLD OUT');
  assert.equal(await page.locator('#metric-metadata').textContent(), 'NFT SET');
  await page.locator('a[data-page="reveal"]').click();
  await page.locator('#inspect-id').fill('6666');
  await page.locator('#inspect-form button').click();
  await page.waitForFunction(nft => document.querySelector('#token-result').textContent.includes(`${nft}6666.json`) && document.querySelector('#token-result').textContent.includes('Unlocked: sold out'), nftBase);
  assert.equal(await keys.tokenURI(1), `${nftBase}1.json`);
  await page.locator('a[data-page="treasury"]').click();
  assert.equal(await provider.getBalance(target), 299935000000000000000n);
  await transact('#withdraw-form', async () => await provider.getBalance(target) === 0n);
  report('Full 6,666-key sale: every key reads the NFT set by itself (key 6666 included) and 299.935 ETH withdrawal at mixed phase prices');
  await provider.send('evm_revert', [snapshotId]);

  await provider.send('evm_increaseTime', [31 * 86400]);
  await provider.send('evm_mine', []);
  await page.locator('#refresh').click();
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'KEEP OR REFUND');
  await page.locator('a[data-page="treasury"]').click();
  assert.equal(await page.locator('[data-action="burnTreasury"]').isDisabled(), true);
  assert.match(await page.locator('[data-hint="burnTreasury"]').textContent(), /window closes/);
  await page.locator('a[data-page="refund"]').click();
  assert.equal(await page.locator('[data-action="claimPending"]').isDisabled(), true);
  const reserveBeforeRefund = await provider.getBalance(target);
  assert.equal(reserveBeforeRefund, 185000000000000000n);
  await page.evaluate(account => window.testWallet.changeAccount(account), accounts[3]);
  await page.waitForFunction(() => !document.querySelector('#identity-roles').textContent.includes('Administrator'));
  await page.locator('#refund-ids').fill('1, 2, 4, 5, 6');
  await page.locator('#batch-refund-form button').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('only the original minter'));
  assert.equal(await keys.totalRefunded(), 0n);
  report('During the 72 h window a third party cannot refund someone else\'s keys');
  await page.evaluate(account => window.testWallet.changeAccount(account), accounts[0]);
  await page.waitForFunction(() => document.querySelector('#identity-roles').textContent.includes('Administrator'));
  await page.locator('#keep-ids').fill('1');
  await page.locator('#settle-refund-ids').fill('2');
  await transact('#settle-form', async () => await keys.kept(1) && await keys.refunded(2));
  assert.equal(await keys.tokenURI(1), `${nftBase}1.json`);
  await page.locator('#refund-ids').fill('4, 5, 6');
  await transact('#batch-refund-form', async () => await keys.totalRefunded() === 4n);
  assert.equal(await page.locator('#kept-count').textContent(), '1');
  assert.equal(await provider.getBalance(target), 25000000000000000n);
  await page.locator('#refund-ids').fill('1');
  await page.locator('#batch-refund-form button').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('Key kept'));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('refund-desktop.png', output)), fullPage: true, animations: 'disabled' });
  report('Minter keeps key 1 (NFT set) and refunds the rest at mixed prices; a kept key is never refunded');
  await page.locator('a[data-page="treasury"]').click();
  assert.equal(await page.locator('#kept-balance').textContent(), '0.025');
  await transact('#withdraw-kept-form', async () => await provider.getBalance(target) === 0n);
  assert.equal(await page.locator('[data-action="withdrawKept"]').isDisabled(), true);
  report('Treasury withdraws only the kept-key payment without a sellout');
  await provider.send('evm_increaseTime', [72 * 3600]);
  await provider.send('evm_mine', []);
  await page.locator('#refresh').click();
  await page.waitForFunction(() => document.querySelector('#metric-phase').textContent === 'EXPIRED');
  assert.equal(await page.locator('[data-action="settle"]').isDisabled(), true);
  await page.locator('#burn-ids').fill('1');
  await page.locator('#burn-treasury-form button').click();
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('Only free treasury keys'));
  await page.locator('#burn-ids').fill('3');
  await transact('#burn-treasury-form', async () => await keys.totalBurned() === 1n);
  assert.equal(await keys.totalSupply(), 1n);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('treasury-desktop.png', output)), fullPage: true, animations: 'disabled' });
  report('After the window: keep-or-refund closes, paid keys are refused and treasury key 3 is burned');
  await page.setViewportSize({ width: 390, height: 844 });
  for (const name of ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund']) {
    await page.locator(`a[data-page="${name}"]`).click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `Mobile overflow in ${name}`);
  }
  await page.locator('a[data-page="sale"]').click();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('mobile.png', output)), fullPage: true, animations: 'disabled' });
  report('All six views fit a 390px mobile viewport');
  assert(!artifact.abi.some(item => ['setPublicMintActive', 'setMintEndTime', 'reveal'].includes(item.name)));
  assert.deepEqual(errors, []);
  report('No uncaught browser errors');
  const startConsole = async contract => {
    if (server) { const exited = new Promise(resolve => server.once('exit', resolve)); server.kill(); await exited; }
    server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '14173', '--strictPort'], { cwd: root, env: { ...process.env, VITE_CHAIN_ID: '31337', VITE_RPC_URL: rpc, VITE_CONTRACT_ADDRESS: contract }, stdio: ['ignore', 'ignore', 'pipe'] });
    for (let attempt = 0; attempt < 100; attempt++) { try { const response = await fetch(url); if (response.ok) return; } catch {} await delay(100); }
    throw new Error('Console server did not restart');
  };
  const mocks = {
    v1: { initcode: '0x6460006000fd6000526005601bf3', message: /without CONTRACT_VERSION \(v1\)\. This console manages only Ryodan Keys v6/ },
    v4: { initcode: '0x69600460005260206000f3600052600a6016f3', message: /version 4\. This console manages only Ryodan Keys v6/ },
    v5: { initcode: '0x69600560005260206000f3600052600a6016f3', message: /version 5\. This console manages only Ryodan Keys v6/ },
  };
  await page.setViewportSize({ width: 1440, height: 1100 });
  for (const [name, mock] of Object.entries(mocks)) {
    const receipt = await (await signer.sendTransaction({ data: mock.initcode })).wait();
    await startConsole(receipt.contractAddress);
    await page.goto(url);
    await page.waitForFunction(() => document.querySelector('#sync-status')?.textContent.includes('UNSUPPORTED CONTRACT'), null, { timeout: 20000 });
    assert.match(await page.locator('#notice').textContent(), mock.message);
    assert.match(await page.locator('#notice').textContent(), /Every action is disabled/);
    assert.deepEqual(await page.locator('[data-action]').evaluateAll(buttons => buttons.filter(button => !button.disabled).map(button => button.dataset.action)), []);
    if (name === 'v4') await page.screenshot({ path: fileURLToPath(new URL('unsupported-v4.png', output)), animations: 'disabled' });
  }
  assert.deepEqual(errors, []);
  report('A v1, v4 or v5 contract is refused: UNSUPPORTED CONTRACT, explicit message, every action disabled');
  await writeFile(new URL('browser-verification.json', output), JSON.stringify({ checks, contract: target, chainId: 31337 }, null, 2) + '\n');
} catch (error) {
  if (page) {
    console.error('UI notice:', await page.locator('#notice').textContent().catch(() => 'unavailable'));
    console.error('Visible hints:', await page.locator('[data-hint]').evaluateAll(nodes => nodes.filter(node => node.offsetParent).map(node => `${node.dataset.hint}: ${node.textContent}`)).catch(() => []));
    await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: fileURLToPath(new URL('failure.png', output)), fullPage: true }).catch(() => {});
  }
  throw error;
} finally {
  await browser?.close(); server?.kill(); anvil.kill(); provider.destroy();
}
