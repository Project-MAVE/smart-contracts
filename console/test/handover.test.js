import test from 'node:test';
import assert from 'node:assert/strict';
import { launchSteps } from '../src/safe.js';
import { gate, viaSafe } from '../src/model.js';

const deployer = '0x51c8000000000000000000000000000000000001';
const owners = ['0x3F682372EE60FEd6cc5Bb8638D5cb56FFB9856dD', '0xD7999E4bdD76e42BA29dDf8Cd83b6CE1C8226296', '0x3B0D109448E0Ec7268326A7FB4eed19207867F3F'];
const safe = { address: '0xF4d2Eb533725A9DCb334e8F2a5b58ffC8aeA2EfB', owners, threshold: 2n, nonce: 15n, version: '1.5.0', treasury: true, keys: 666n, owner: false, incoming: { from: deployer, schedule: 100n } };
// The state our deployment leaves behind: list loaded, treasury minted to the Safe, administrator transfer started.
const handed = {
  version: 8n, deadline: 900n, timestamp: 112n, maxPaid: 6000n, maxTreasury: 666n, firstTokenId: 1n, paid: 0n, treasuryMinted: 666n, balance: 0n,
  admin: false, treasuryRole: false, currentPhase: 0n, paused: true, allowlistConfigured: true, snapshotMatches: true, allowlistRoot: `0x2a19${'0'.repeat(56)}51b4`,
  tierCounts: [105n, 1455n, 5699n], soldOut: false, refundsAvailable: false, choiceWindowOpen: false, keptFunds: 0n, keptWithdrawn: 0n, safe,
};
const snapshot = { counts: { pioneer: 105, operative: 1455, recruit: 5699 } };
const as = account => ({ account, correctChain: true, busy: false, pending: null, stale: false });

test('a transfer waiting for a Safe puts its acceptance first; the Safe administers nothing before it', () => {
  const steps = launchSteps(handed, snapshot);
  assert.deepEqual(steps.map(step => `${step.id} ${step.status}`), ['accept NEXT', 'allowlist DONE', 'treasury DONE', 'open WAITING']);
  assert.match(steps[0].detail, new RegExp(`^${deployer} deployed this contract and hands it over\\.`));
  for (const account of [null, owners[0], deployer]) assert.equal(viaSafe('acceptAdmin', handed, account), true);
  assert.equal(viaSafe('acceptAdmin', handed, safe.address.toLowerCase()), false, 'a wallet that presents the Safe signs for itself');
  assert.equal(gate('acceptAdmin', handed, as(owners[0])), '');
  assert.equal(gate('acceptAdmin', handed, as(null)), '', 'the batch can be prepared without a wallet');
  for (const kind of ['advance', 'pause', 'allowlist', 'admin']) {
    assert.equal(viaSafe(kind, handed, owners[0]), false);
    assert.equal(gate(kind, handed, as(owners[0])), 'The Safe accepts the administrator role first.');
  }
  assert.equal(viaSafe('treasuryMint', handed, owners[0]), true, 'the treasury role is granted directly and works at once');
});

test('the acceptance waits for the block after the transfer was started', () => {
  assert.equal(gate('acceptAdmin', { ...handed, timestamp: 100n }, as(owners[0])), 'The transfer can be accepted from the next block.');
  assert.equal(gate('acceptAdmin', { ...handed, timestamp: 101n }, as(owners[0])), '');
});

test('the outgoing administrator keeps its forms until the Safe accepts, and the step disappears afterwards', () => {
  const outgoing = { ...handed, admin: true };
  assert.equal(viaSafe('advance', outgoing, deployer), false);
  assert.equal(gate('admin', outgoing, as(deployer)), '');
  const accepted = { ...handed, safe: { ...safe, incoming: undefined } };
  assert.deepEqual(launchSteps(accepted, snapshot).map(step => `${step.id} ${step.status}`), ['allowlist DONE', 'treasury DONE', 'open NEXT']);
  assert.equal(viaSafe('advance', accepted, owners[0]), true);
  assert.equal(viaSafe('acceptAdmin', accepted, owners[0]), false);
});
