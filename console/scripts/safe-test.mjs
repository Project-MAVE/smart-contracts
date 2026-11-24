// The Safe launch sequence, end to end: the console prepares each batch, the real client Safe executes it on a fork.
// Needs SAFE_FORK_URL (an Ethereum Sepolia RPC); without it the journey is skipped.
import { chromium } from 'playwright';
import { ContractFactory, JsonRpcProvider, Contract, Interface, ZeroAddress, ZeroHash, concat, dataLength, solidityPacked, zeroPadValue } from 'ethers';
import { spawn } from 'node:child_process';
import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import assert from 'node:assert/strict';
import { batchCalldata, batchChecksum } from '../src/safe.js';

if (!process.env.SAFE_FORK_URL) { console.log('SKIP Safe journey: set SAFE_FORK_URL to an Ethereum Sepolia RPC'); process.exit(0); }
const root = fileURLToPath(new URL('../', import.meta.url));
const rpc = 'http://127.0.0.1:18548';
const url = 'http://127.0.0.1:14174';
const output = new URL('../test-results/', import.meta.url);
await mkdir(output, { recursive: true });
const safeAddress = process.env.SAFE_ADDRESS || '0x31Cd849c982ED10a94A66b4FD7867e97656952Eb';
// Safe 1.5.0 MultiSendCallOnly, the contract a Safe delegates to when a batch holds several calls.
const multiSendCallOnly = '0xA83c336B20401Af773B6219BA5027174338D1836';
const report = name => console.log(`PASS ${name}`);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const anvil = spawn(process.env.ANVIL_BIN || `${homedir()}/.foundry/bin/anvil`, ['--fork-url', process.env.SAFE_FORK_URL, '--chain-id', '31337', '--port', '18548', '--host', '127.0.0.1', '--silent'], { stdio: ['ignore', 'ignore', 'pipe'] });
let server, browser, page;
const provider = new JsonRpcProvider(rpc, 31337, { staticNetwork: true, cacheTimeout: -1, pollingInterval: 100 });
try {
  for (let attempt = 0; attempt < 300; attempt++) { try { await provider.send('eth_chainId', []); break; } catch { await delay(100); } }
  const artifact = JSON.parse(await readFile(new URL('../../ryodan-keys/out/RyodanKeys.sol/RyodanKeys.json', import.meta.url), 'utf8'));
  const snapshot = JSON.parse(await readFile(new URL('../src/allowlist.json', import.meta.url), 'utf8'));
  const iface = new Interface(artifact.abi);
  const safe = new Contract(safeAddress, [
    'function getOwners() view returns (address[])', 'function getThreshold() view returns (uint256)', 'function nonce() view returns (uint256)',
    'function getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256) view returns (bytes32)',
    'function approveHash(bytes32)', 'function execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes) payable returns (bool)',
    'function approvedHashes(address,bytes32) view returns (uint256)',
    'event ExecutionSuccess(bytes32 indexed txHash, uint256 payment)',
  ], provider);
  const owners = [...await safe.getOwners()];
  assert.equal(await safe.getThreshold(), 2n);
  assert.notEqual(await provider.getCode(multiSendCallOnly), '0x');
  for (const account of [...owners, safeAddress]) {
    await provider.send('anvil_impersonateAccount', [account]);
    await provider.send('anvil_setBalance', [account, '0x56bc75e2d63100000']);
  }
  const [first, second] = [owners[0], owners[1]];
  const deployer = await provider.getSigner(0);
  const deadline = (await provider.getBlock('latest')).timestamp + 2 * 86400;
  const keys = await new ContractFactory(artifact.abi, artifact.bytecode.object, deployer).deploy(deadline, 'ipfs://ryodan-sbt-local/', 'ipfs://ryodan-nft-local/', safeAddress, safeAddress);
  await keys.waitForDeployment();
  const target = await keys.getAddress();
  assert.equal(await keys.defaultAdmin(), safeAddress);
  assert.equal(await keys.hasRole(ZeroHash, deployer.address), false);

  // What the Safe app does with a Transaction Builder batch: one call goes straight to its target, several are
  // packed for MultiSendCallOnly and run by delegatecall. Two owners approve: one on chain, one as the sender.
  async function executeFromSafe(file) {
    const calls = file.transactions.map(entry => ({ to: entry.to, value: BigInt(entry.value), data: batchCalldata(entry) }));
    const single = calls.length === 1;
    const to = single ? calls[0].to : multiSendCallOnly;
    const data = single ? calls[0].data : new Interface(['function multiSend(bytes)']).encodeFunctionData('multiSend', [concat(calls.map(call => solidityPacked(['uint8', 'address', 'uint256', 'uint256', 'bytes'], [0, call.to, call.value, dataLength(call.data), call.data])))]);
    const operation = single ? 0 : 1;
    const hash = await safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, ZeroAddress, ZeroAddress, await safe.nonce());
    await (await safe.connect(await provider.getSigner(second)).approveHash(hash)).wait();
    const signatures = concat([first, second].sort((a, b) => BigInt(a) < BigInt(b) ? -1 : 1).map(owner => concat([zeroPadValue(owner, 32), ZeroHash, '0x01'])));
    const receipt = await (await safe.connect(await provider.getSigner(first)).execTransaction(to, 0, data, operation, 0, 0, 0, ZeroAddress, ZeroAddress, signatures)).wait();
    assert.equal(receipt.status, 1);
    assert.ok(receipt.logs.some(log => log.address === safeAddress && log.topics[0] === safe.interface.getEvent('ExecutionSuccess').topicHash && log.topics[1] === hash), 'the Safe reports the execution');
    return receipt;
  }

  server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '14174', '--strictPort'], { cwd: root, env: { ...process.env, VITE_CHAIN_ID: '31337', VITE_RPC_URL: rpc, VITE_CONTRACT_ADDRESS: target }, stdio: ['ignore', 'ignore', 'pipe'] });
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
  const shot = name => page.screenshot({ path: fileURLToPath(new URL(`safe-${name}.png`, output)), fullPage: true, animations: 'disabled' });
  // Reviews the step, checks the dialog, downloads the batch and returns it parsed; nothing is sent to the chain.
  async function review(trigger, title) {
    await page.click(trigger);
    await page.locator('#review-dialog[open]').waitFor();
    assert.equal(await page.textContent('#review-title'), title);
    assert.match(await page.textContent('#review-details'), new RegExp(`EXECUTED BYSafe ${safeAddress}\\s*2 of 3 owners sign`));
  }
  async function prepare(trigger, title, button = '#confirm-transaction') {
    await review(trigger, title);
    assert.equal(await page.textContent(button), button === '#confirm-transaction' ? 'Download Safe batch ↓' : 'Download batch file ↓');
    const [download] = await Promise.all([page.waitForEvent('download'), page.click(button)]);
    const file = JSON.parse(await readFile(await download.path(), 'utf8'));
    const { checksum, ...meta } = file.meta;
    assert.equal(batchChecksum({ ...file, meta }), checksum);
    assert.deepEqual([file.version, file.chainId, meta.createdFromSafeAddress, meta.name], ['1.0', '31337', safeAddress, title]);
    assert.ok(file.transactions.every(entry => entry.to === target && entry.value === '0'));
    await page.waitForFunction(() => document.querySelector('#notice').textContent.startsWith('Batch downloaded'));
    return file;
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

  await page.goto(url);
  await synced();
  await page.locator('#safe-section').waitFor();
  assert.equal(await page.textContent('#safe-tag'), '2 OF 3 OWNERS SIGN');
  assert.equal(await page.textContent('#safe-address'), safeAddress);
  for (const owner of owners) assert.ok((await page.textContent('#safe-owners')).includes(owner));
  assert.match(await page.textContent('#safe-roles'), /^Administrator · Treasury · holds 0 keys · Safe 1\.5\.0$/);
  assert.deepEqual(await steps(), ['01 / NEXT Load the allowlist', '02 / WAITING Mint the 666 treasury keys', '03 / WAITING Open Pioneer']);
  assert.equal(await page.locator('[data-safe-step=open]').isDisabled(), true);
  assert.equal(await page.textContent('[data-safe-step=open] + .action-hint'), 'Load the allowlist snapshot before starting Pioneer.');
  assert.equal(await page.textContent('[data-hint=mint]'), 'Connect a wallet to continue.');
  assert.equal(await stepButton('allowlist'), 'Prepare for the Safe ↗');
  assert.equal(await page.locator('#safe-builder').isHidden(), true, 'no Safe app link on a local chain');
  await shot('01-start');
  report('A Safe administrator is detected with its owners, threshold and roles; no wallet is needed to prepare a call');

  const list = await prepare('[data-safe-step=allowlist]', 'Load frozen allowlist snapshot');
  assert.equal(batchCalldata(list.transactions[0]), iface.encodeFunctionData('configureAllowlist', [snapshot.root, snapshot.snapshotHash, snapshot.counts.pioneer, snapshot.counts.operative, snapshot.counts.recruit]));
  assert.equal(await keys.allowlistConfigured(), false, 'downloading a batch changes nothing on chain');
  await executeFromSafe(list);
  await refresh();
  assert.deepEqual(await steps(), ['01 / DONE Load the allowlist', '02 / NEXT Mint the 666 treasury keys', '03 / WAITING Open Pioneer']);
  assert.equal(await keys.totalGtdReserved(), BigInt(snapshot.counts.pioneer * 4 + snapshot.counts.operative * 4));
  report('Allowlist batch: exact calldata, executed by the Safe with two owners, step marked done');

  // Owners act in the console with their own wallets: the first approves, the second executes.
  assert.equal(await stepButton('treasury'), 'Prepare for the Safe · next 100 keys ↗');
  await page.evaluate(owner => window.testWallet.use(owner), first);
  await page.click('#connect');
  await synced();
  await page.waitForFunction(() => document.querySelector('#safe-owners').textContent.includes('The connected wallet is one of the owners.'));
  assert.equal(await stepButton('treasury'), 'Approve as owner · next 100 keys ↗');
  await sign('[data-safe-step=treasury]', 'Mint treasury keys 1-100', 'Approve as owner (1 of 2) ↗', 'Owner approval 1 of 2: Mint treasury keys 1-100 confirmed');
  assert.equal(await keys.mintedByTreasury(), 0n, 'one approval mints nothing');
  await page.waitForFunction(() => document.querySelector('[data-safe-step=treasury]').textContent.startsWith('Approved · waiting'));
  assert.match(await page.textContent('#safe-steps'), new RegExp(`Approved by ${first.slice(0, 6)}…${first.slice(-4)}: 1 of 2\\.`));
  await review('[data-safe-step=treasury]', 'Mint treasury keys 1-100');
  assert.equal(await page.textContent('#confirm-transaction'), 'Waiting for another owner');
  assert.equal(await page.locator('#confirm-transaction').isDisabled(), true);
  assert.match(await page.textContent('#review-details'), new RegExp(`OWNER APPROVALS1 of 2 on chain\\s*${first}`));
  await page.click('#review-dialog button[value=cancel].button');
  report('First owner approves in the console with its own wallet: recorded on chain, nothing minted, a second approval by the same owner is refused');

  await use(second);
  assert.equal(await stepButton('treasury'), 'Execute as owner · next 100 keys ↗');
  await sign('[data-safe-step=treasury]', 'Mint treasury keys 1-100', 'Execute from the Safe ↗', 'Safe execution: Mint treasury keys 1-100 confirmed');
  assert.deepEqual([await keys.mintedByTreasury(), await keys.balanceOf(safeAddress)], [100n, 100n]);
  assert.equal(await page.textContent('#treasury-count'), '100 / 666');
  assert.equal(await stepButton('treasury'), 'Approve as owner · next 100 keys ↗');
  report('Second owner executes the approved step from the console: 100 keys minted to the Safe');

  await sign('[data-safe-step=treasury]', 'Mint treasury keys 101-200', 'Approve as owner (1 of 2) ↗', 'Owner approval 1 of 2: Mint treasury keys 101-200 confirmed');
  await use(first);
  await sign('[data-safe-step=treasury]', 'Mint treasury keys 101-200', 'Execute from the Safe ↗', 'Safe execution: Mint treasury keys 101-200 confirmed');
  assert.equal(await keys.mintedByTreasury(), 200n);
  report('The roles swap: any two owners complete a step');

  for (let block = 2; block < 7; block++) {
    const size = Math.min(100, 666 - block * 100);
    const file = await prepare('[data-safe-step=treasury]', `Mint treasury keys ${block * 100 + 1}-${block * 100 + size}`, '#download-batch');
    assert.equal(batchCalldata(file.transactions[0]), iface.encodeFunctionData('treasuryMint', [size, safeAddress]));
    await executeFromSafe(file);
    await refresh();
    assert.equal(await page.textContent('#treasury-count'), `${block * 100 + size} / 666`);
  }
  assert.deepEqual([await keys.mintedByTreasury(), await keys.balanceOf(safeAddress), await keys.ownerOf(1), await keys.ownerOf(666)], [666n, 666n, safeAddress, safeAddress]);
  assert.deepEqual(await steps(), ['01 / DONE Load the allowlist', '02 / DONE Mint the 666 treasury keys', '03 / NEXT Open Pioneer']);
  assert.match(await page.textContent('#safe-roles'), /holds 666 keys/);
  await shot('02-treasury-minted');
  report('Treasury: the batch file stays available to a connected owner; all 666 keys are owned by the Safe');

  const open = await prepare('[data-safe-step=open]', 'Open Pioneer', '#download-batch');
  assert.deepEqual(open.transactions.map(batchCalldata), [iface.encodeFunctionData('advancePhase'), iface.encodeFunctionData('setMintPaused', [false])]);
  assert.match(await page.textContent('#activity-log'), /PREPARED.*Open Pioneer · batch for Safe/);
  await sign('[data-safe-step=open]', 'Open Pioneer', 'Approve as owner (1 of 2) ↗', 'Owner approval 1 of 2: Open Pioneer confirmed');
  assert.deepEqual([await keys.currentPhase(), await keys.mintPaused()], [0n, true]);
  await use(second);
  await sign('[data-safe-step=open]', 'Open Pioneer', 'Execute from the Safe ↗', 'Safe execution: Open Pioneer confirmed');
  assert.deepEqual([await keys.currentPhase(), await keys.mintPaused()], [1n, false]);
  assert.equal(await page.textContent('#metric-phase'), 'PIONEER');
  assert.deepEqual(await steps(), ['01 / DONE Load the allowlist', '02 / DONE Mint the 666 treasury keys', '03 / NEXT Open Operative']);
  assert.match(await page.textContent('#safe-steps'), /Pioneer is open and minting\./);
  await shot('03-pioneer-open');
  report('Opening: two owners approve and execute advancePhase then setMintPaused(false) as one Safe transaction; Pioneer is minting');

  await page.goto(`${url}/#access`);
  await page.waitForFunction(() => document.querySelector('#identity-roles').textContent.includes('Safe owner'));
  assert.equal(await page.textContent('#identity-roles'), 'Safe owner · Holder / minter');
  await page.goto(`${url}/#sale`);
  await synced();
  await sign('#pause-form button', 'Pause active phase', 'Approve as owner (1 of 2) ↗', 'Owner approval 1 of 2: Pause active phase confirmed');
  assert.equal(await keys.mintPaused(), false, 'an owner key alone cannot administer the contract');
  await use((await provider.listAccounts())[3].address);
  const pause = await prepare('#pause-form button', 'Pause active phase');
  assert.equal(batchCalldata(pause.transactions[0]), iface.encodeFunctionData('setMintPaused', [true]));
  assert.match(await page.textContent('#safe-owners'), /The connected wallet is not an owner\./);
  report('Every administrator form follows the same two-owner route; a wallet that is not an owner can only download the batch');

  await use(safeAddress);
  await page.waitForFunction(() => document.querySelector('[data-hint=pause]').textContent === 'Ready. Review the transaction before signing.');
  await page.click('#pause-form button');
  await page.locator('#review-dialog[open]').waitFor();
  assert.equal(await page.textContent('#confirm-transaction'), 'Sign in wallet ↗');
  assert.match(await page.textContent('#review-details'), new RegExp(`SIGNER${safeAddress}`));
  await page.click('#confirm-transaction');
  await page.waitForFunction(() => document.querySelector('#notice').textContent.includes('confirmed'));
  assert.equal(await keys.mintPaused(), true);
  await page.goto(`${url}/#mint`);
  await synced();
  assert.deepEqual(await steps(), ['01 / DONE Load the allowlist', '02 / DONE Mint the 666 treasury keys', '03 / NEXT Resume Pioneer']);
  report('A wallet that connects as the Safe itself signs in the wallet, as any administrator');

  await page.setViewportSize({ width: 390, height: 844 });
  await refresh();
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), 0);
  await shot('04-mobile');
  report('No horizontal overflow at 390 px');
  assert.deepEqual(errors, []);
  report('No console errors, page errors or failed requests');
} catch (error) {
  if (page) {
    console.error('UI notice:', await page.locator('#notice').textContent().catch(() => 'unavailable'));
    await page.screenshot({ path: fileURLToPath(new URL('safe-failure.png', output)), fullPage: true }).catch(() => {});
  }
  throw error;
} finally {
  await browser?.close();
  server?.kill();
  anvil.kill();
  provider.destroy();
}
