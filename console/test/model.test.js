import test from 'node:test';
import assert from 'node:assert/strict';
import { address, assertSupported, deadlineUTC, gate, phase, remaining, refundIds, settleIds, tokenRange, unsigned } from '../src/model.js';

const account = '0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc';
const context = { account, correctChain: true, busy: false, pending: null, stale: false };
const v6 = {
  version: 7n, deadline: 200n, timestamp: 100n, maxPaid: 6166n, maxTreasury: 500n, firstTokenId: 1n, choiceWindow: 345600n,
  paid: 1n, treasuryMinted: 0n, walletMinted: 10n, limit: 4n, balance: 10n ** 16n, admin: true, treasuryRole: true,
  currentPhase: 1n, paused: false, reserved: 16n, phaseAllowance: 4n, phaseWalletMinted: 0n, allowlistConfigured: true,
  publicActive: false, whitelistActive: true, whitelisted: true, soldOut: false, refundsAvailable: false,
  choiceWindowOpen: false, totalKept: 0n, keptFunds: 0n, keptWithdrawn: 0n, pendingRefund: 0n,
};
const expired = { ...v6, timestamp: 201n, refundsAvailable: true, choiceWindowOpen: true };
const writes = ['mint', 'treasuryMint', 'withdraw', 'admin', 'phaseAdmin', 'allowlist', 'advance', 'pause', 'refund', 'settle', 'claimPending', 'withdrawKept', 'burnTreasury'];

test('only contract version 7 is accepted; v1 (no CONTRACT_VERSION) through v6 and later versions are refused', () => {
  assert.doesNotThrow(() => assertSupported(7n));
  assert.throws(() => assertSupported(null), /without CONTRACT_VERSION \(v1\)\. This console manages only Ryodan Keys v7/);
  for (const version of [2n, 3n, 4n, 5n, 6n, 8n]) assert.throws(() => assertSupported(version), new RegExp(`version ${version}\\. This console manages only Ryodan Keys v7`));
  assert.throws(() => assertSupported(4n), error => error.code === 'UNSUPPORTED_CONTRACT');
});
test('every write is blocked when the loaded state is not v7', () => {
  for (const version of [1n, 2n, 3n, 4n, 5n, 6n, 8n]) {
    for (const kind of writes) assert.equal(gate(kind, { ...expired, version, soldOut: false }, context), 'This console manages only Ryodan Keys v7.');
  }
});
test('exact integer validation rejects unsafe amount syntax and bounds', () => {
  for (const value of ['1e3', '-1', '1.1', '', '0x10', 'Infinity', '6001']) assert.throws(() => unsigned(value, 6000n, 1n));
  assert.equal(unsigned('6000', 6000n, 1n), 6000n);
});
test('UTC snapshot time parsing is timezone-independent and rejects calendar rollover', () => {
  assert.equal(deadlineUTC('2026-10-19T20:30'), 1792441800n);
  for (const value of ['2026-02-30T20:30', '2026-10-19', '2026-10-19T20:30Z']) assert.throws(() => deadlineUTC(value));
});
test('address input checksums and rejects zero', () => {
  assert.equal(address(account.toLowerCase()), account);
  assert.throws(() => address('0x0000000000000000000000000000000000000000'));
  assert.throws(() => address('0x123'));
});
test('all writes stop on stale data, wrong chain, pending transaction or disconnected wallet', () => {
  for (const kind of writes) {
    for (const patch of [{ stale: true }, { correctChain: false }, { account: null }, { pending: { hash: '0x123' } }, { busy: true }]) {
      assert.notEqual(gate(kind, v6, { ...context, ...patch }), '');
    }
  }
});
test('allowances are per phase, independent of lifetime purchases', () => {
  assert.equal(remaining(v6), 4n);
  assert.equal(remaining({ ...v6, phaseAllowance: 0n }), 0n);
  assert.equal(remaining({ ...v6, currentPhase: 3n, paid: 6156n, reserved: 8n }), 2n);
  assert.equal(phase(v6), 'PIONEER');
  assert.equal(phase({ ...v6, currentPhase: 2n }), 'OPERATIVE');
  assert.equal(phase({ ...v6, currentPhase: 3n }), 'RECRUIT');
  assert.equal(phase({ ...v6, currentPhase: 4n }), 'CIVILIAN');
  assert.equal(phase({ ...v6, paused: true }), 'PAUSED');
  assert.equal(phase({ ...v6, currentPhase: 0n }), 'NOT STARTED');
  assert.equal(phase({ ...v6, paid: 6166n }), 'PAID CAP');
  assert.equal(phase({ ...v6, timestamp: 201n }), 'EXPIRED');
});
test('mint requires an allowlisted wallet in allowlist phases and an open sale', () => {
  assert.equal(gate('mint', v6, context), '');
  assert.match(gate('mint', { ...v6, whitelisted: false }, context), /allowlist/);
  assert.match(gate('mint', { ...v6, whitelistActive: false }, context), /paused/);
  assert.match(gate('mint', { ...v6, timestamp: 201n }, context), /expired/);
});
test('phase controls require admin, open sale and a sequential transition', () => {
  for (const kind of ['phaseAdmin', 'advance', 'pause']) {
    const base = kind === 'phaseAdmin' ? { ...v6, currentPhase: 0n } : v6;
    assert.equal(gate(kind, base, context), '');
    for (const patch of [{ admin: false }, { timestamp: 201n }, { soldOut: true }]) assert.notEqual(gate(kind, { ...base, ...patch }, context), '');
  }
  assert.notEqual(gate('advance', { ...v6, currentPhase: 4n }, context), '');
  assert.notEqual(gate('pause', { ...v6, currentPhase: 0n }, context), '');
});
test('prices and limits lock when Pioneer opens', () => {
  for (const currentPhase of [1n, 2n, 3n, 4n]) assert.match(gate('phaseAdmin', { ...v6, currentPhase }, context), /locked/);
});
test('the snapshot must load before Pioneer and freezes at the first phase', () => {
  const fresh = { ...v6, currentPhase: 0n, allowlistConfigured: false };
  assert.match(gate('advance', fresh, context), /snapshot/);
  assert.equal(gate('allowlist', fresh, context), '');
  assert.match(gate('allowlist', { ...fresh, currentPhase: 1n }, context), /frozen/);
  assert.equal(gate('advance', { ...fresh, allowlistConfigured: true }, context), '');
});
test('treasury withdrawal requires sellout, treasury role and a balance', () => {
  const after = { ...v6, soldOut: true, timestamp: 201n };
  assert.match(gate('withdraw', v6, context), /6,666/);
  assert.match(gate('withdraw', { ...v6, soldOut: true }, context), /after the mint deadline/);
  assert.equal(gate('withdraw', after, context), '');
  assert.notEqual(gate('withdraw', { ...after, treasuryRole: false }, context), '');
  assert.notEqual(gate('withdraw', { ...after, balance: 0n }, context), '');
});
test('token IDs run from 1 to 6666 in every ID input', () => {
  assert.deepEqual(tokenRange(v6), [1n, 6666n]);
  assert.deepEqual(tokenRange(null), [1n, 6666n]);
  assert.deepEqual(refundIds('1, 2\n6666'), [1n, 2n, 6666n]);
  for (const value of ['', '1,1', '1e2', '-1', '0', '6667', Array.from({ length: 51 }, (_, i) => i + 1).join(',')]) assert.throws(() => refundIds(value));
});
test('keep-or-refund lists are unique across both lists and capped at 50', () => {
  assert.deepEqual(settleIds('1, 2', '3'), [[1n, 2n], [3n]]);
  assert.deepEqual(settleIds('', '4'), [[], [4n]]);
  for (const [keep, refund] of [['', ''], ['1', '1'], ['0', ''], [Array.from({ length: 51 }, (_, i) => i + 1).join(','), '']]) assert.throws(() => settleIds(keep, refund));
});
test('refund and keep-or-refund open only after an unsuccessful expiry, within the 96 h window', () => {
  assert.match(gate('refund', v6, context), /unsuccessful expiry/);
  assert.equal(gate('refund', expired, context), '');
  assert.match(gate('settle', v6, context), /unsuccessful expiry/);
  assert.equal(gate('settle', expired, context), '');
  assert.match(gate('settle', { ...expired, choiceWindowOpen: false }, context), /96-hour/);
  assert.equal(phase(expired), 'KEEP OR REFUND');
  assert.equal(phase({ ...expired, choiceWindowOpen: false }), 'EXPIRED');
});
test('treasury withdraws kept payments and burns treasury keys only after the window', () => {
  assert.match(gate('withdrawKept', expired, context), /No payments/);
  assert.equal(gate('withdrawKept', { ...expired, keptFunds: 10n }, context), '');
  assert.match(gate('withdrawKept', { ...expired, keptFunds: 10n, treasuryRole: false }, context), /treasury role/);
  assert.match(gate('burnTreasury', expired, context), /window closes/);
  assert.equal(gate('burnTreasury', { ...expired, choiceWindowOpen: false }, context), '');
  assert.match(gate('burnTreasury', v6, context), /unsuccessful expiry/);
});
test('pending refund claim needs a pending amount', () => {
  assert.match(gate('claimPending', expired, context), /no pending refund/);
  assert.equal(gate('claimPending', { ...expired, pendingRefund: 1n }, context), '');
});
