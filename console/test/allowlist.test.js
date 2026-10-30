import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import { ZeroHash } from 'ethers';
import { buildSnapshot, capacity, checkerScript, csvTemplate, leafFor, lookupKey, pairHash, parseCSV, proofFor, validateSnapshot } from '../src/allowlist.js';
const accounts = Array.from({ length: 17 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}`);
const frozen = '2026-10-30T12:00:00.000Z';
const csv = list => `address\n${list.join('\n')}\n`;
const sources = (p = [], o = [], r = []) => ({ 'pioneer.csv': csv(p), 'operative.csv': csv(o), 'recruit.csv': csv(r) });

test('downloadable templates are empty valid CSVs, not real allowlist members', async () => {
  for (const tier of ['pioneer', 'operative', 'recruit']) {
    const content = await readFile(new URL(`../public/templates/${tier}.csv`, import.meta.url), 'utf8');
    assert.equal(content, csvTemplate); assert.deepEqual(parseCSV(content), []);
  }
});
test('CSV parser handles BOM, quotes, CRLF and extra columns without admitting malformed rows', () => {
  assert.deepEqual(parseCSV(`\ufeffaddress,note\r\n"${accounts[0]}","a, b\nquoted"\r\n`), [accounts[0]]);
  for (const text of ['wallet\n', 'address\n0x123\n', 'address\n0x0000000000000000000000000000000000000000\n', 'address\n"unclosed', `address\n"${accounts[0]}"x\n`, 'address\n,missing']) assert.throws(() => parseCSV(text));
});
test('highest tier wins and checker uses the identical exclusive snapshot', () => {
  const { snapshot, duplicateRows } = buildSnapshot(sources([accounts[0], accounts[0]], [accounts[0], accounts[1]], [accounts[0], accounts[1], accounts[2]]), frozen);
  assert.equal(duplicateRows, 4); assert.deepEqual(snapshot.counts, { pioneer: 1, operative: 1, recruit: 1 });
  assert.equal(proofFor(snapshot, accounts[0]).tier, 1); assert.equal(proofFor(snapshot, accounts[1]).tier, 2);
  assert.equal(proofFor(snapshot, accounts[3]), null);
  const context = { window: {} }; context.window = context; vm.runInNewContext(checkerScript(snapshot), context);
  assert.equal(context.NM.checkData.pioneer[0], lookupKey(accounts[0]).slice(2));
  assert.equal(context.NM.checkData.operative.length, 1);
  assert(!JSON.stringify(snapshot).includes(accounts[0]));
});
test('every odd and even tree size yields verifiable deterministic proofs', () => {
  for (let count = 0; count <= accounts.length; count++) {
    const input = sources(accounts.slice(0, count));
    const { snapshot } = buildSnapshot(input, frozen);
    assert.equal(validateSnapshot(snapshot), snapshot);
    if (!count) assert.equal(snapshot.root, ZeroHash);
    for (const account of accounts.slice(0, count)) {
      const entry = proofFor(snapshot, account);
      assert.equal(entry.proof.reduce(pairHash, leafFor(account, 1)), snapshot.root);
    }
    assert.deepEqual(buildSnapshot(input, frozen).snapshot, snapshot);
  }
});
test('snapshot detects modified counts, source digests, proof nodes, leaves and timestamps', () => {
  const { snapshot } = buildSnapshot(sources([accounts[0]], [accounts[1]], [accounts[2]]), frozen);
  for (const mutate of [s => s.counts.pioneer++, s => s.sourceHashes['pioneer.csv'] = ZeroHash, s => s.frozenAt = 'bad', s => s.proofs[lookupKey(accounts[0])].proof[0] = ZeroHash, s => s.proofs[lookupKey(accounts[0])].leaf = ZeroHash, s => delete s.proofs[lookupKey(accounts[0])]]) {
    const copy = structuredClone(snapshot); mutate(copy); assert.throws(() => validateSnapshot(copy));
  }
});
test('GTD includes both inherited allocations and rejects overbooking and odd caps', () => {
  assert.equal(capacity({ pioneer: 440, operative: 0 }).total, 6160n);
  assert.throws(() => capacity({ pioneer: 441, operative: 0 }), /6166/);
  assert.equal(capacity({ pioneer: 1, operative: 1 }, 2000n, 2083n).total, 6166n);
  assert.throws(() => capacity({ pioneer: 1, operative: 0 }, 3n, 10n));
  assert.throws(() => buildSnapshot({ 'pioneer.csv': csvTemplate }, frozen), /Missing operative/);
  assert.throws(() => buildSnapshot(sources(), '2026-10-30'), /UTC/);
});
