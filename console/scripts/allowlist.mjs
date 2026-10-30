import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Contract, JsonRpcProvider, Wallet } from 'ethers';
import { buildSnapshot, validateSnapshot, capacity, checkerScript, tiers } from '../src/allowlist.js';

const args = process.argv.slice(2);
const option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
const mode = args[0];
if (mode === 'build') {
  const source = option('--csv-dir'), output = option('--out'), frozenAt = option('--frozen-at');
  if (!source || !output || !frozenAt) throw new Error('Usage: allowlist.mjs build --csv-dir DIR --out DIR --frozen-at ISO_UTC [--pioneer-limit 4 --operative-limit 10]');
  const sources = Object.fromEntries(await Promise.all(tiers.map(async tier => [`${tier}.csv`, await readFile(resolve(source, `${tier}.csv`))])));
  const { snapshot, duplicateRows } = buildSnapshot(sources, frozenAt, { pioneer: BigInt(option('--pioneer-limit') || 4), operative: BigInt(option('--operative-limit') || 10) });
  await mkdir(output, { recursive: true });
  await writeFile(resolve(output, 'allowlist.json'), JSON.stringify(snapshot, null, 2) + '\n');
  await writeFile(resolve(output, 'check-data.js'), checkerScript(snapshot));
  console.log(JSON.stringify({ root: snapshot.root, snapshotHash: snapshot.snapshotHash, counts: snapshot.counts, duplicateRows }));
} else if (mode === 'load') {
  const file = option('--snapshot'), target = option('--contract'), rpc = option('--rpc');
  if (!file || !target || !rpc) throw new Error('Usage: allowlist.mjs load --snapshot FILE --contract ADDRESS --rpc URL [--apply]');
  const snapshot = validateSnapshot(JSON.parse(await readFile(file, 'utf8')));
  const provider = new JsonRpcProvider(rpc, undefined, { cacheTimeout: -1 });
  try {
    const chain = Number(await provider.send('eth_chainId', []));
    if (![11155111, 31337].includes(chain)) throw new Error('This loader supports Sepolia and local Anvil only.');
    const abi = JSON.parse(await readFile(new URL('../../ryodan-keys/abi/RyodanKeys.json', import.meta.url), 'utf8'));
    let keys = new Contract(target, abi, provider);
    if (await keys.CONTRACT_VERSION() !== 4n) throw new Error('A v4 contract is required.');
    const [pioneer, operative, maxPaid, root, hash, current, deadline, block] = await Promise.all([keys.phases(1), keys.phases(2), keys.MAX_PUBLIC_SUPPLY(), keys.allowlistRoot(), keys.allowlistSnapshotHash(), keys.currentPhase(), keys.mintEndTime(), provider.getBlock('latest')]);
    if (root === snapshot.root && hash === snapshot.snapshotHash) {
      const actual = await Promise.all([1, 2, 3].map(tier => keys.tierMembers(tier)));
      if (actual.some((count, index) => count !== BigInt(snapshot.counts[tiers[index]]))) throw new Error('On-chain counts differ from the snapshot.');
      console.log('Snapshot already matches root, hash and all tier counts. No transaction needed.');
    } else {
      if (current !== 0n) throw new Error('Allowlist is frozen after Pioneer starts.');
      if (BigInt(block.timestamp) > deadline) throw new Error('Sale has expired.');
      const reserved = capacity(snapshot.counts, pioneer.walletLimit, operative.walletLimit, maxPaid);
      console.log(JSON.stringify({ chainId: chain, contract: target, counts: snapshot.counts, root: snapshot.root, snapshotHash: snapshot.snapshotHash, gtdReserved: reserved.total.toString(), apply: args.includes('--apply') }));
      if (args.includes('--apply')) {
        if (!process.env.PRIVATE_KEY) throw new Error('Inject PRIVATE_KEY using hush run --redact.');
        keys = keys.connect(new Wallet(process.env.PRIVATE_KEY, provider));
        const values = [snapshot.root, snapshot.snapshotHash, ...tiers.map(tier => snapshot.counts[tier])];
        await keys.configureAllowlist.staticCall(...values);
        const receipt = await (await keys.configureAllowlist(...values)).wait(chain === 31337 ? 1 : 2);
        if (receipt.status !== 1 || await keys.allowlistRoot() !== snapshot.root || await keys.allowlistSnapshotHash() !== snapshot.snapshotHash) throw new Error('Snapshot receipt or state verification failed.');
        console.log(`Confirmed ${receipt.hash}`);
      }
    }
  } finally { provider.destroy(); }
} else throw new Error('Choose build or load.');
