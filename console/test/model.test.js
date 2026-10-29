import test from 'node:test';
import assert from 'node:assert/strict';
import { addresses, deadlineUTC, gate, metadataBase, phase, remaining, unsigned } from '../src/model.js';

const account = '0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc';
const context = { account, correctChain: true, busy: false, pending: null, stale: false };
const sale = { version: 2n, deadline: 200n, timestamp: 100n, maxPaid: 5900n, maxTreasury: 500n, maxWhitelist: 1000n,
  paid: 1n, treasuryMinted: 0n, whitelistMinted: 1n, limit: 3n, walletMinted: 1n,
  publicActive: true, whitelistActive: false, whitelisted: false, admin: true, treasuryRole: true,
  soldOut: false, revealed: false, refundsAvailable: false, balance: 10n ** 16n };

test('exact integer validation rejects unsafe amount syntax and bounds', () => {
  for (const value of ['1e3', '-1', '1.1', '', '0x10', 'Infinity', '5901']) assert.throws(() => unsigned(value, 5900n, 1n));
  assert.equal(unsigned('5900', 5900n, 1n), 5900n);
});
test('UTC deadline parsing is timezone-independent and rejects calendar rollover', () => {
  assert.equal(deadlineUTC('2026-10-19T20:30'), 1792441800n);
  for (const value of ['2026-02-30T20:30', '2026-10-19', '2026-10-19T20:30Z']) assert.throws(() => deadlineUTC(value));
});
test('whitelist input checks addresses, deduplicates and rejects zero', () => {
  assert.deepEqual(addresses(`${account},\n${account.toLowerCase()}`), [account]);
  assert.throws(() => addresses('0x0000000000000000000000000000000000000000'));
  assert.throws(() => addresses(''));
});
test('reveal URLs prohibit script schemes and path suffix traps', () => {
  assert.equal(metadataBase('ipfs://bafyexample/'), 'ipfs://bafyexample/');
  for (const value of ['javascript:alert(1)/', 'https://a.invalid/path?x=/', 'ipfs://x', 'ipfs:///']) assert.throws(() => metadataBase(value));
});
test('remaining allowance clamps a reduced cap and shares phase limits', () => {
  assert.equal(remaining({ ...sale, limit: 0n }), 0n);
  assert.equal(remaining({ ...sale, whitelistActive: true, whitelistMinted: 999n }), 1n);
});
test('deadline gate supports v2 open sales and locks legacy, expired, sold-out sales', () => {
  assert.equal(gate('deadline', sale, context), '');
  for (const patch of [{ version: 1n }, { timestamp: 201n }, { soldOut: true }, { admin: false }]) assert.notEqual(gate('deadline', { ...sale, ...patch }, context), '');
  assert.equal(gate('deadline', { ...sale, timestamp: 200n }, context), '');
});
test('all writes stop on stale data, wrong chain, pending transaction or disconnected wallet', () => {
  for (const kind of ['mint', 'deadline', 'admin', 'reveal', 'withdraw', 'treasuryMint', 'refund']) {
    for (const patch of [{ stale: true }, { correctChain: false }, { account: null }, { pending: { hash: '0x123' } }, { busy: true }]) {
      assert.notEqual(gate(kind, sale, { ...context, ...patch }), '');
    }
  }
});
test('mint and refund distinguish failed expiry, whitelist and paid sellout', () => {
  assert.equal(phase({ ...sale, paid: 5900n }), 'PAID CAP');
  assert.equal(phase({ ...sale, timestamp: 201n }), 'EXPIRED');
  assert.notEqual(gate('mint', { ...sale, whitelistActive: true, publicActive: false }, context), '');
  assert.notEqual(gate('refund', sale, context), '');
  assert.equal(gate('refund', { ...sale, refundsAvailable: true }, context), '');
});
test('reveal and treasury withdrawal require soldout and appropriate roles', () => {
  assert.notEqual(gate('reveal', sale, context), '');
  assert.equal(gate('reveal', { ...sale, soldOut: true }, context), '');
  assert.notEqual(gate('reveal', { ...sale, soldOut: true, revealed: true }, context), '');
  assert.notEqual(gate('withdraw', { ...sale, soldOut: true, treasuryRole: false }, context), '');
  assert.notEqual(gate('withdraw', { ...sale, soldOut: true, balance: 0n }, context), '');
});

const modern = { ...sale, version: 3n, currentPhase: 1n, paused: false, reserved: 16n, phaseAllowance: 4n, phaseWalletMinted: 0n, walletMinted: 10n, publicActive: false, whitelistActive: true, whitelisted: true };
test('v3 allowances are per phase, independent of lifetime purchases', () => {
  assert.equal(remaining(modern), 4n);
  assert.equal(remaining({ ...modern, phaseAllowance: 0n }), 0n);
  assert.equal(remaining({ ...modern, currentPhase: 3n, paid: 5890n, reserved: 8n }), 2n);
  assert.equal(phase(modern), 'PIONEER');
  assert.equal(phase({ ...modern, currentPhase: 2n }), 'OPERATIVE');
  assert.equal(phase({ ...modern, currentPhase: 3n }), 'RECRUIT');
  assert.equal(phase({ ...modern, currentPhase: 4n }), 'CIVILIAN');
  assert.equal(phase({ ...modern, paused: true }), 'PAUSED');
  assert.equal(phase({ ...modern, currentPhase: 0n }), 'NOT STARTED');
});
test('v3 phase controls require admin, open sale and a sequential transition', () => {
  for (const kind of ['phaseAdmin', 'advance', 'pause']) {
    assert.equal(gate(kind, modern, context), '');
    for (const patch of [{ version: 2n }, { admin: false }, { timestamp: 201n }, { soldOut: true }]) assert.notEqual(gate(kind, { ...modern, ...patch }, context), '');
  }
  assert.notEqual(gate('advance', { ...modern, currentPhase: 4n }, context), '');
  assert.notEqual(gate('pause', { ...modern, currentPhase: 0n }, context), '');
});
