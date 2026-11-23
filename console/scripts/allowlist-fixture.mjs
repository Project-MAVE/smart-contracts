import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { AbiCoder, getAddress, getBytes } from 'ethers';
import { validateSnapshot, parseCSV, lookupKey, tiers } from '../src/allowlist.js';

const args = process.argv.slice(2);
const option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
const source = option('--csv-dir'), file = option('--snapshot'), output = option('--out');
if (!source || !file || !output) throw new Error('Usage: allowlist-fixture.mjs --csv-dir DIR --snapshot allowlist.json --out FILE');
const snapshot = validateSnapshot(JSON.parse(await readFile(file, 'utf8')));
const accounts = [], proofs = [], seen = new Set(), counts = [0, 0, 0];
for (const [index, tier] of tiers.entries()) {
  for (const address of parseCSV(await readFile(resolve(source, `${tier}.csv`)), `${tier}.csv`)) {
    if (seen.has(address)) continue;
    seen.add(address);
    const entry = snapshot.proofs[lookupKey(address)];
    if (!entry || entry.tier !== index + 1) throw new Error(`${tier}.csv: ${address} is not in the snapshot with tier ${index + 1}.`);
    accounts.push(getAddress(address));
    proofs.push(entry.proof);
    counts[index]++;
  }
}
if (accounts.length !== Object.keys(snapshot.proofs).length || tiers.some((tier, index) => counts[index] !== snapshot.counts[tier])) throw new Error('The CSVs and the snapshot list different wallets.');
const fixture = AbiCoder.defaultAbiCoder().encode(
  ['tuple(bytes32 root, bytes32 snapshotHash, uint256 pioneers, uint256 operatives, uint256 recruits, address[] accounts, bytes32[][] proofs)'],
  [[snapshot.root, snapshot.snapshotHash, ...counts, accounts, proofs]]
);
await mkdir(dirname(resolve(output)), { recursive: true });
await writeFile(resolve(output), getBytes(fixture));
console.log(JSON.stringify({ root: snapshot.root, snapshotHash: snapshot.snapshotHash, counts: snapshot.counts, wallets: accounts.length, bytes: (fixture.length - 2) / 2 }));
