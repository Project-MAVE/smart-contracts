// The handover, end to end: our key deploys and prepares the contract, starts the administrator transfer,
// and two owners of a real Safe accept it from the console on a fork.
// Needs SAFE_FORK_URL (an Ethereum Sepolia RPC, optionally pinned with SAFE_FORK_BLOCK); without it the journey is skipped.
import { chromium } from 'playwright';
import { ContractFactory, JsonRpcProvider, Contract, Interface, ZeroAddress, ZeroHash } from 'ethers';
import { spawn } from 'node:child_process';
import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import assert from 'node:assert/strict';
import { batchCalldata } from '../src/safe.js';

if (!process.env.SAFE_FORK_URL) { console.log('SKIP handover journey: set SAFE_FORK_URL to an Ethereum Sepolia RPC'); process.exit(0); }
const root = fileURLToPath(new URL('../', import.meta.url));
const rpc = 'http://127.0.0.1:18549';
const url = 'http://127.0.0.1:14175';
const output = new URL('../test-results/', import.meta.url);
await mkdir(output, { recursive: true });
const safeAddress = process.env.SAFE_ADDRESS || '0x31Cd849c982ED10a94A66b4FD7867e97656952Eb';
const report = name => console.log(`PASS ${name}`);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const anvil = spawn(process.env.ANVIL_BIN || `${homedir()}/.foundry/bin/anvil`, ['--fork-url', process.env.SAFE_FORK_URL, ...(process.env.SAFE_FORK_BLOCK ? ['--fork-block-number', process.env.SAFE_FORK_BLOCK] : []), '--chain-id', '31337', '--port', '18549', '--host', '127.0.0.1', '--silent'], { stdio: ['ignore', 'ignore', 'pipe'] });
let server, browser, page;
const provider = new JsonRpcProvider(rpc, 31337, { staticNetwork: true, cacheTimeout: -1, pollingInterval: 100 });
try {
  for (let attempt = 0; attempt < 300; attempt++) { try { await provider.send('eth_chainId', []); break; } catch { await delay(100); } }
  const artifact = JSON.parse(await readFile(new URL('../../ryodan-keys/out/RyodanKeys.sol/RyodanKeys.json', import.meta.url), 'utf8'));
  const snapshot = JSON.parse(await readFile(new URL('../src/allowlist.json', import.meta.url), 'utf8'));
  const iface = new Interface(artifact.abi);
  const safe = new Contract(safeAddress, ['function getOwners() view returns (address[])', 'function getThreshold() view returns (uint256)'], provider);
  const owners = [...await safe.getOwners()];
  assert.equal(await safe.getThreshold(), 2n);
  for (const account of owners) {
    await provider.send('anvil_impersonateAccount', [account]);
    await provider.send('anvil_setBalance', [account, '0x56bc75e2d63100000']);
  }
  const [first, second] = owners;
  const deployer = await provider.getSigner(0);
  const deadline = (await provider.getBlock('latest')).timestamp + 2 * 86400;

  // What our deployment does with its own key before the Safe signs anything.
  const keys = await new ContractFactory(artifact.abi, artifact.bytecode.object, deployer).deploy(deadline, 'ipfs://ryodan-sbt-local/', 'ipfs://ryodan-nft-local/', deployer.address, deployer.address);
  await keys.waitForDeployment();
  const target = await keys.getAddress();
  const treasuryRole = await keys.TREASURY_ROLE();
  await (await keys.configureAllowlist(snapshot.root, snapshot.snapshotHash, snapshot.counts.pioneer, snapshot.counts.operative, snapshot.counts.recruit)).wait();
  for (let left = 666; left > 0; left -= 100) await (await keys.treasuryMint(Math.min(100, left), safeAddress)).wait();
  await (await keys.grantRole(treasuryRole, safeAddress)).wait();
  await (await keys.revokeRole(treasuryRole, deployer.address)).wait();
  await (await keys.beginDefaultAdminTransfer(safeAddress)).wait();
  assert.deepEqual([await keys.defaultAdmin(), (await keys.pendingDefaultAdmin())[0], await keys.balanceOf(safeAddress)], [deployer.address, safeAddress, 666n]);
  report('Our key deploys, loads the list, mints the 666 treasury keys to the Safe, hands it the treasury role and starts the administrator transfer');

  server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '14175', '--strictPort'], { cwd: root, env: { ...process.env, VITE_CHAIN_ID: '31337', VITE_RPC_URL: rpc, VITE_CONTRACT_ADDRESS: target }, stdio: ['ignore', 'ignore', 'pipe'] });
  for (let attempt = 0; attempt < 100; attempt++) { try { const response = await fetch(url); if (response.ok) break; } catch {} await delay(100); }
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, acceptDownloads: true });
  await context.addInitScript(rpc => {
    const events = new Map();
    const wallet = { account: null };
    window.testWallet = { use(account) { wallet.account = account; events.get('accountsChanged')?.([account]); } };
    window.ethereum = {
      on(event, listener) { events.set(event, listener); },
      async request({ method, params = [] }) {
        if (method === 'eth_requestAccounts' || method === 'eth_accounts') return wallet.account ? [wallet.account] : [];
        if (method === 'eth_chainId') return '0x7a69';
        const response = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }) });
        const data = await response.json();
        if (data.error) throw Object.assign(new Error(data.error.message), data.error);
        return data.result;
      },
    };
  }, rpc);
  page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('requestfailed', request => errors.push(`request failed: ${request.url()}`));
  const synced = () => page.waitForFunction(() => document.querySelector('#sync-status').textContent.includes('SYNCHRONIZED'));
  const refresh = async () => { await page.click('#refresh'); await synced(); };
  const steps = () => page.locator('#safe-steps .safe-step').evaluateAll(nodes => nodes.map(node => `${node.querySelector('.phase-state').textContent} ${node.querySelector('strong').textContent}`));
  const shot = name => page.screenshot({ path: fileURLToPath(new URL(`handover-${name}.png`, output)), fullPage: true, animations: 'disabled' });
  async function review(trigger, title) {
    await page.click(trigger);
    await page.locator('#review-dialog[open]').waitFor();
    assert.equal(await page.textContent('#review-title'), title);
    assert.match(await page.textContent('#review-details'), new RegExp(`EXECUTED BYSafe ${safeAddress}\\s*2 of 3 owners sign`));
  }
  async function sign(trigger, title, label, done) {
    await review(trigger, title);
    assert.equal(await page.textContent('#confirm-transaction'), label);
    await page.click('#confirm-transaction');
    await page.waitForFunction(text => document.querySelector('#notice').textContent.startsWith(text), done, { timeout: 60000 });
    await synced();
  }
  const use = async account => { await page.evaluate(value => window.testWallet.use(value), account); await synced(); await page.waitForFunction(value => document.querySelector('#identity-address').textContent === value, account); };
  const stepButton = id => page.textContent(`[data-safe-step=${id}]`);
  const hint = id => page.textContent(`[data-safe-step=${id}] + .action-hint`);

  await page.goto(url);
  await synced();
  await page.locator('#safe-section').waitFor();
  assert.equal(await page.textContent('#safe-kicker'), 'THIS CONTRACT IS BEING HANDED TO A SAFE');
  assert.equal(await page.textContent('#safe-address'), safeAddress);
  assert.match(await page.textContent('#safe-roles'), /^Administrator once it accepts · Treasury · holds 666 keys · Safe 1\.5\.0$/);
  assert.deepEqual(await steps(), ['01 / NEXT Accept the administrator role', '02 / DONE Load the allowlist', '03 / DONE Mint the 666 treasury keys', '04 / WAITING Open Pioneer']);
  assert.ok((await page.textContent('#safe-steps')).includes(`${deployer.address} deployed this contract and hands it over.`));
  assert.equal(await page.locator('[data-safe-step=accept]').isDisabled(), true);
  assert.equal(await hint('accept'), 'The transfer can be accepted from the next block.');
  await provider.send('evm_mine', []);
  await refresh();
  assert.equal(await page.locator('[data-safe-step=accept]').isDisabled(), false);
  assert.equal(await stepButton('accept'), 'Prepare for the Safe ↗');
  assert.equal(await page.locator('[data-safe-step=open]').isDisabled(), true);
  assert.equal(await hint('open'), 'The Safe accepts the administrator role first.');
  await shot('01-pending');
  report('A transfer waiting for a Safe is shown as its first step, from the block after it was started; the launch steps wait behind it');

  await review('[data-safe-step=accept]', 'Accept administrator role');
  const [download] = await Promise.all([page.waitForEvent('download'), page.click('#confirm-transaction')]);
  const file = JSON.parse(await readFile(await download.path(), 'utf8'));
  assert.deepEqual([file.meta.createdFromSafeAddress, file.transactions.length, file.transactions[0].to, batchCalldata(file.transactions[0])], [safeAddress, 1, target, iface.encodeFunctionData('acceptDefaultAdminTransfer')]);
  report('Without an owner wallet the acceptance is a one-call batch for the Safe app');

  await page.evaluate(owner => window.testWallet.use(owner), first);
  await page.click('#connect');
  await synced();
  await page.waitForFunction(() => document.querySelector('#safe-owners').textContent.includes('The connected wallet is one of the owners.'));
  assert.equal(await stepButton('accept'), 'Approve as owner ↗');
  await sign('[data-safe-step=accept]', 'Accept administrator role', 'Approve as owner (1 of 2) ↗', 'Owner approval 1 of 2: Accept administrator role confirmed');
  assert.deepEqual([await keys.defaultAdmin(), await keys.hasRole(ZeroHash, safeAddress)], [deployer.address, false], 'one approval moves nothing');
  await page.waitForFunction(() => document.querySelector('[data-safe-step=accept]').textContent.startsWith('Approved · waiting'));
  await shot('02-approved');
  report('First owner approves the acceptance with its own wallet: recorded on chain, the role has not moved');

  await use(second);
  assert.equal(await stepButton('accept'), 'Execute as owner ↗');
  await sign('[data-safe-step=accept]', 'Accept administrator role', 'Execute from the Safe ↗', 'Safe execution: Accept administrator role confirmed');
  assert.deepEqual([await keys.defaultAdmin(), (await keys.pendingDefaultAdmin())[0]], [safeAddress, ZeroAddress]);
  assert.deepEqual([await keys.hasRole(ZeroHash, safeAddress), await keys.hasRole(treasuryRole, safeAddress), await keys.hasRole(ZeroHash, deployer.address), await keys.hasRole(treasuryRole, deployer.address)], [true, true, false, false]);
  await assert.rejects(keys.setMintPaused(false), 'our key administers nothing any more');
  assert.equal(await page.textContent('#safe-kicker'), 'THIS CONTRACT IS RUN BY A SAFE');
  assert.match(await page.textContent('#safe-roles'), /^Administrator · Treasury · holds 666 keys · Safe 1\.5\.0$/);
  assert.deepEqual(await steps(), ['01 / DONE Load the allowlist', '02 / DONE Mint the 666 treasury keys', '03 / NEXT Open Pioneer']);
  await shot('03-accepted');
  report('Second owner executes: the Safe is the only administrator and treasurer, our key holds no role');

  await sign('[data-safe-step=open]', 'Open Pioneer', 'Approve as owner (1 of 2) ↗', 'Owner approval 1 of 2: Open Pioneer confirmed');
  await use(first);
  await sign('[data-safe-step=open]', 'Open Pioneer', 'Execute from the Safe ↗', 'Safe execution: Open Pioneer confirmed');
  assert.deepEqual([await keys.currentPhase(), await keys.mintPaused()], [1n, false]);
  report('After the acceptance the same two owners open Pioneer from the console');

  await page.setViewportSize({ width: 390, height: 844 });
  await refresh();
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), 0);
  await shot('04-mobile');
  assert.deepEqual(errors, []);
  report('No horizontal overflow at 390 px; no console errors, page errors or failed requests');
} catch (error) {
  if (page) {
    console.error('UI notice:', await page.locator('#notice').textContent().catch(() => 'unavailable'));
    await page.screenshot({ path: fileURLToPath(new URL('handover-failure.png', output)), fullPage: true }).catch(() => {});
  }
  throw error;
} finally {
  await browser?.close();
  server?.kill();
  anvil.kill();
  provider.destroy();
}
