import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Interface } from 'ethers';
import { batchCall, batchCalldata, batchChecksum, batchFile, isOwner, launchSteps, safeGasNeeded, safeLinks, TRANSACTION_GAS_CAP } from '../src/safe.js';
import { gate, viaSafe } from '../src/model.js';

const abi = JSON.parse(await readFile(new URL('../../ryodan-keys/abi/RyodanKeys.json', import.meta.url), 'utf8'));
const keys = '0x28097DF55dA295bB969b8B187c26978D63D099B8';
const safeAddress = '0x31Cd849c982ED10a94A66b4FD7867e97656952Eb';
const owners = ['0x64Edd77035E6d19d4d28CCEf71ae0487B9d770Ec', '0x07a7a4993c2bA83f87738991Db4B34162ba84Bf9', '0x69012B90cCB872Fb5b650922CaA71193255E9d74'];
const root = '0x684eef196d6778d493101719a1baa468b9bad7e8cfb647aec304c535626c0273';
const snapshotHash = '0x4340544089b569df44f052e55b46721daaa5c1c717169631e82803d98698ae1d';
const iface = new Interface(abi);
const safe = { address: safeAddress, owners, threshold: 2n, nonce: 0n, version: '1.5.0', treasury: true, keys: 0n, owner: false };
const fresh = {
  version: 7n, deadline: 200n, timestamp: 100n, maxPaid: 6166n, maxTreasury: 500n, firstTokenId: 1n, paid: 0n, treasuryMinted: 0n, balance: 0n,
  admin: false, treasuryRole: false, currentPhase: 0n, paused: true, allowlistConfigured: false, snapshotMatches: false, allowlistRoot: `0x${'0'.repeat(64)}`,
  tierCounts: [0n, 0n, 0n], soldOut: false, refundsAvailable: false, choiceWindowOpen: false, keptFunds: 0n, keptWithdrawn: 0n, safe,
};
const snapshot = { counts: { pioneer: 105, operative: 1403, recruit: 5705 } };
const nobody = { account: null, correctChain: false, busy: false, pending: null, stale: false };

test('every launch call is exported as method plus string inputs and decodes to the exact calldata', () => {
  for (const [method, args] of [
    ['configureAllowlist', [root, snapshotHash, 105n, 1403n, 5705n]], ['treasuryMint', [100n, safeAddress]], ['advancePhase', []], ['setMintPaused', [false]], ['setMintPaused', [true]],
    ['configurePhase', [1n, 7500000000000000n, 4n]], ['withdraw', []], ['withdrawKept', []], ['burnTreasuryKeys', [[1n, 2n, 500n]]], ['beginDefaultAdminTransfer', [owners[0]]],
  ]) {
    const call = batchCall(abi, keys, method, args);
    assert.equal(call.to, keys);
    assert.equal(call.value, '0');
    assert.equal(call.contractMethod.name, method);
    assert.ok(Object.values(call.contractInputsValues).every(value => typeof value === 'string'), 'the Transaction Builder refuses numbers');
    assert.equal(batchCalldata(call), iface.encodeFunctionData(method, args));
  }
  assert.throws(() => batchCall(abi, keys, 'treasuryMint', [100n]), /Unknown call/);
});

test('a batch file carries the Transaction Builder checksum and any later edit breaks it', () => {
  const file = batchFile({ chainId: 11155111, safe: safeAddress, name: 'Open Pioneer', description: 'two calls', createdAt: 1795440000000,
    transactions: [batchCall(abi, keys, 'advancePhase', []), batchCall(abi, keys, 'setMintPaused', [false])] });
  assert.deepEqual([file.version, file.chainId, file.meta.createdFromSafeAddress, file.transactions.length], ['1.0', '11155111', safeAddress, 2]);
  const { checksum, ...meta } = file.meta;
  assert.match(checksum, /^0x[0-9a-f]{64}$/);
  assert.equal(batchChecksum({ ...file, meta }), checksum);
  assert.equal(batchChecksum({ ...file, meta: { ...meta, name: 'Renamed in the Safe' } }), checksum, 'the name is not part of the checksum');
  const tampered = structuredClone({ ...file, meta });
  tampered.transactions[1].contractInputsValues.paused = 'true';
  assert.notEqual(batchChecksum(tampered), checksum);
  assert.throws(() => batchFile({ chainId: 1, safe: safeAddress, name: 'x', description: 'x', transactions: [] }), /at least one call/);
});

test('a Safe transaction must fit the per-transaction gas cap', () => {
  assert.equal(TRANSACTION_GAS_CAP, 2n ** 24n);
  assert.ok(safeGasNeeded(12_324_824n) < TRANSACTION_GAS_CAP, '100 treasury keys measured on Sepolia fit');
  assert.ok(safeGasNeeded(15_910_333n) < TRANSACTION_GAS_CAP, '130 measured on Sepolia still fit, with little room');
  assert.ok(safeGasNeeded(16_400_000n) > TRANSACTION_GAS_CAP, 'a call estimated at 16.4M gas does not');
});

test('with a Safe as administrator the privileged calls are prepared without a wallet, everything else is unchanged', () => {
  for (const kind of ['allowlist', 'phaseAdmin', 'admin', 'treasuryMint']) {
    assert.equal(viaSafe(kind, fresh, null), true);
    assert.equal(gate(kind, fresh, nobody), '');
  }
  assert.equal(gate('advance', fresh, nobody), 'Load the allowlist snapshot before starting Pioneer.');
  assert.equal(gate('pause', fresh, nobody), 'Start Pioneer before resuming minting.');
  assert.equal(gate('mint', fresh, nobody), 'Connect a wallet to continue.');
  assert.equal(gate('withdraw', fresh, nobody), 'All 6,666 keys must mint before this operation unlocks.');
  assert.equal(viaSafe('mint', fresh, null), false);
  assert.equal(gate('allowlist', { ...fresh, version: 6n }, nobody), 'This console manages only Ryodan Keys v7.');
  assert.equal(gate('allowlist', fresh, { ...nobody, stale: true }), 'Refresh contract state before submitting.');
  const withoutTreasury = { ...fresh, safe: { ...safe, treasury: false } };
  assert.equal(viaSafe('treasuryMint', withoutTreasury, null), false);
  assert.equal(gate('treasuryMint', withoutTreasury, { ...nobody, account: owners[0], correctChain: true }), 'The connected wallet needs the treasury role.');
  const direct = { ...fresh, safe: null };
  assert.equal(gate('allowlist', direct, nobody), 'Connect a wallet to continue.');
  assert.equal(gate('allowlist', direct, { ...nobody, account: owners[0], correctChain: true }), 'The connected wallet needs the administrator role.');
});

test('a wallet connected as the Safe itself signs in the wallet, an owner prepares for the Safe', () => {
  const asSafe = { ...fresh, admin: true, treasuryRole: true };
  assert.equal(viaSafe('allowlist', asSafe, safeAddress.toLowerCase()), false);
  assert.equal(gate('allowlist', asSafe, { ...nobody, account: safeAddress, correctChain: true }), '');
  assert.equal(gate('allowlist', asSafe, { ...nobody, account: safeAddress, correctChain: false }), 'Switch your wallet to the displayed network.');
  assert.equal(viaSafe('allowlist', fresh, owners[1]), true);
  assert.equal(isOwner(safe, owners[1].toLowerCase()), true);
  assert.equal(isOwner(safe, keys), false);
  assert.equal(isOwner(null, owners[1]), false);
});

test('the launch sequence follows chain state: list, treasury in blocks of 100, then each opening', () => {
  const status = s => launchSteps(s, snapshot).map(step => step.status).join(' ');
  const steps = launchSteps(fresh, snapshot);
  assert.deepEqual(steps.map(step => step.id), ['allowlist', 'treasury', 'open']);
  assert.equal(status(fresh), 'NEXT WAITING WAITING');
  assert.match(steps[0].detail, /105 Pioneer \/ 1403 Operative \/ 5705 Recruit/);
  assert.match(steps[1].detail, /^0 \/ 500 minted\. 5 Safe transaction\(s\) of up to 100 keys left/);
  assert.equal(steps[2].title, 'Open Pioneer');
  const listed = { ...fresh, allowlistConfigured: true, snapshotMatches: true, allowlistRoot: root, tierCounts: [105n, 1403n, 5705n] };
  assert.equal(status(listed), 'DONE NEXT WAITING');
  assert.match(launchSteps({ ...listed, treasuryMinted: 250n }, snapshot)[1].detail, /^250 \/ 500 minted\. 3 Safe transaction/);
  assert.match(launchSteps({ ...fresh, allowlistConfigured: true }, snapshot)[0].detail, /A different snapshot is on chain/);
  const minted = { ...listed, treasuryMinted: 500n };
  assert.equal(status(minted), 'DONE DONE NEXT');
  const pioneer = launchSteps({ ...minted, currentPhase: 1n, paused: false }, snapshot)[2];
  assert.deepEqual([pioneer.title, pioneer.status], ['Open Operative', 'NEXT']);
  assert.match(pioneer.detail, /^Pioneer is open and minting\. Next: one Safe transaction with two calls, advance to Operative then resume minting\. Pioneer closes for good\./);
  assert.equal(launchSteps({ ...minted, currentPhase: 1n, paused: true }, snapshot)[2].title, 'Resume Pioneer');
  assert.equal(launchSteps({ ...minted, currentPhase: 4n, paused: true }, snapshot)[2].title, 'Resume Civilian');
  assert.equal(status({ ...minted, currentPhase: 4n, paused: false }), 'DONE DONE DONE');
  assert.equal(status({ ...minted, currentPhase: 2n, paused: false, timestamp: 201n }), 'DONE DONE DONE');
});

test('Safe links exist only for the networks the Safe app serves', () => {
  const links = safeLinks(11155111, safeAddress);
  assert.equal(links.home, `https://app.safe.global/home?safe=sep:${safeAddress}`);
  assert.equal(links.builder, `https://app.safe.global/apps/open?safe=sep:${safeAddress}&appUrl=https%3A%2F%2Fapps-portal.safe.global%2Ftx-builder`);
  assert.equal(safeLinks(1, safeAddress).queue, `https://app.safe.global/transactions/queue?safe=eth:${safeAddress}`);
  assert.equal(safeLinks(31337, safeAddress), null);
});
