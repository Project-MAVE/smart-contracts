import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { buildSnapshot, proofFor, checkerScript } from '../src/allowlist.js';
import { Contract, ContractFactory, JsonRpcProvider, Wallet, getCreateAddress, keccak256, ZeroHash } from 'ethers';

const root = fileURLToPath(new URL('../../', import.meta.url));
const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const local = args.includes('--local');
const verifyOnly = args.includes('--verify');
const refund = args.includes('--refund');
const burnTreasury = args.includes('--burn-treasury');
const qa = args.includes('--qa') || refund || burnTreasury;
const sbtBase = option('--sbt-base', local ? 'ipfs://ryodan-sbt-local/' : null);
const nftBase = option('--nft-base', local ? 'ipfs://ryodan-nft-local/' : null);
const chainId = local ? 31337 : 11155111;
const fixedDeadline = option('--deadline', null);
const pioneerWallets = (option('--pioneers', '') || '').split(',').map(value => value.trim()).filter(Boolean);
const rpc = option('--rpc', local ? 'http://127.0.0.1:8547' : 'https://ethereum-sepolia-rpc.publicnode.com');
const provider = new JsonRpcProvider(rpc, chainId, { cacheTimeout: -1, pollingInterval: 1500 });
if (Number(await provider.send('eth_chainId', [])) !== chainId) throw new Error('Wrong chain');
const manifestPath = resolve(root, option('--manifest', local ? 'console/test-results/local-deployment.json' : `ryodan-keys/deployments/sepolia-v6${qa ? '-refund' : ''}.json`));
await mkdir(dirname(manifestPath), { recursive: true });
const artifact = JSON.parse(await readFile(resolve(root, 'ryodan-keys/out/RyodanKeys.sol/RyodanKeys.json'), 'utf8'));
const expectedWallet = '0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc';
let signer;
if (!verifyOnly) {
  if (local) signer = await provider.getSigner(0);
  else {
    if (!process.env.PRIVATE_KEY) throw new Error('Inject PRIVATE_KEY with hush run --redact');
    signer = new Wallet(process.env.PRIVATE_KEY, provider);
    if (signer.address.toLowerCase() !== expectedWallet.toLowerCase()) throw new Error('Unexpected signing wallet');
  }
}
const deployer = local ? (await provider.listAccounts())[0].address : expectedWallet;
let manifest;
try { manifest = JSON.parse(await readFile(manifestPath, 'utf8')); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
manifest ||= { chainId, deployer, version: 6, purpose: qa ? 'refund' : 'management', transactions: {}, checks: [] };
if (manifest.chainId !== chainId || manifest.deployer !== deployer || manifest.version !== 6) throw new Error('Manifest context mismatch');
async function save() {
  await writeFile(`${manifestPath}.tmp`, JSON.stringify(manifest, null, 2) + '\n');
  await rename(`${manifestPath}.tmp`, manifestPath);
}
async function check(label, condition) {
  if (!condition) throw new Error(`Check failed: ${label}`);
  if (!manifest.checks.includes(label)) manifest.checks.push(label);
  await save();
  console.log(`PASS ${label}`);
}
async function confirm(hash) {
  const receipt = await provider.waitForTransaction(hash, local ? 1 : 2, 180000);
  if (!receipt || receipt.status !== 1) throw new Error(`Transaction unconfirmed or reverted: ${hash}`);
  return receipt;
}
if (!manifest.address) {
  if (verifyOnly || refund || burnTreasury) throw new Error('Deploy first');
  const base = /^(ipfs:\/\/[^/\s?#]+\/|https:\/\/[^/\s?#]+\/)([^\s?#]*\/)?$/;
  if (!base.test(sbtBase || '') || !base.test(nftBase || '')) throw new Error('Pass --sbt-base and --nft-base: ipfs:// or https:// folders ending with /');
  const block = await provider.getBlock('latest');
  // v6: the deadline is fixed at deploy. The QA deployment gets a short one so its refund flow can run.
  const deadline = fixedDeadline ? Number(fixedDeadline) : block.timestamp + (qa ? 3600 : 30 * 86400);
  if (!Number.isSafeInteger(deadline) || deadline <= block.timestamp) throw new Error('--deadline must be a future Unix timestamp');
  const factory = new ContractFactory(artifact.abi, artifact.bytecode.object, signer);
  const nonce = await provider.getTransactionCount(deployer, 'pending');
  const transaction = await signer.sendTransaction({ ...await factory.getDeployTransaction(deadline, sbtBase, nftBase, deployer, deployer), nonce });
  manifest.address = getCreateAddress({ from: deployer, nonce });
  manifest.deploymentTransaction = transaction.hash;
  manifest.deadline = deadline;
  manifest.sbtBaseURI = sbtBase;
  manifest.nftBaseURI = nftBase;
  await save();
  console.log(`DEPLOYED ${manifest.address} ${transaction.hash}`);
}
const deployReceipt = await confirm(manifest.deploymentTransaction);
manifest.deploymentBlock = deployReceipt.blockNumber;
const keys = new Contract(manifest.address, artifact.abi, signer || provider);
const runtime = await provider.getCode(manifest.address);
// v6 keeps mintEndTime as an immutable: its value is written into the runtime code, so those bytes are compared apart.
const immutables = Object.values(artifact.deployedBytecode.immutableReferences || {}).flat();
const blank = code => immutables.reduce((hex, { start, length }) => hex.slice(0, 2 + start * 2) + '0'.repeat(length * 2) + hex.slice(2 + (start + length) * 2), code);
await check('Exact runtime bytecode matches current compiler artifact', blank(runtime) === blank(artifact.deployedBytecode.object));
await check('Immutable deadline in the runtime code equals the deploy deadline', immutables.length > 0 && immutables.every(({ start, length }) => BigInt('0x' + runtime.slice(2 + start * 2, 2 + (start + length) * 2)) === BigInt(manifest.deadline)));
manifest.runtimeCodeHash = keccak256(runtime);
await check('Contract version 6', await keys.CONTRACT_VERSION() === 6n);
await check('Deadline and metadata folders are the ones fixed at deploy', await keys.mintEndTime() === BigInt(manifest.deadline) && await keys.sbtBaseURI() === manifest.sbtBaseURI && await keys.nftBaseURI() === manifest.nftBaseURI);
await check('No function can move the deadline', !artifact.abi.some(item => item.name === 'setMintEndTime'));
await check('Test wallet is admin', await keys.hasRole(ZeroHash, deployer));
await check('Test wallet is treasury', await keys.hasRole(await keys.TREASURY_ROLE(), deployer));

async function transact(label, method, values = [], value = 0n) {
  let record = manifest.transactions[label];
  if (!record) {
    const transaction = await keys[method](...values, { value });
    record = manifest.transactions[label] = { hash: transaction.hash };
    await save();
    console.log(`SUBMITTED ${label} ${transaction.hash}`);
  }
  const receipt = await confirm(record.hash);
  Object.assign(record, { blockNumber: receipt.blockNumber, status: receipt.status, gasUsed: receipt.gasUsed.toString() });
  await save();
  console.log(`CONFIRMED ${label}`);
}

async function expectRevert(label, method, values) {
  let reverted = false;
  try { await keys[method].staticCall(...values); } catch (error) { if (error.code !== 'CALL_EXCEPTION') throw error; reverted = true; }
  await check(label, reverted);
}

if (refund) {
  await check('Keep-or-refund window open after the fixed deadline', await keys.refundsAvailable() && await keys.choiceWindowOpen());
  await expectRevert('Treasury keys cannot be burned while minters decide', 'burnTreasuryKeys', [[3]]);
  await transact('Keep key 1 and refund key 2', 'settle', [[1], [2]]);
  await check('Kept key 1 reads the NFT set, its payment is kept', await keys.kept(1) && await keys.tokenURI(1) === `${manifest.nftBaseURI}1.json` && await keys.keptFunds() === 25n * 10n ** 15n);
  await transact('Refund the other paid keys in one batch', 'refundBatch', [[4, 5, 6]]);
  await expectRevert('Repeated refund rejected', 'refund', [2]);
  await expectRevert('Kept key cannot be refunded', 'refund', [1]);
  await check('Refunds burned every refunded key', await keys.totalSupply() === 2n && await keys.totalRefunded() === 4n);
  await check('Only the kept payment stays after refunds', await provider.getBalance(manifest.address) === 25n * 10n ** 15n);
  await transact('Withdraw kept-key payment', 'withdrawKept');
  await check('Contract balance is zero after the kept withdrawal', await provider.getBalance(manifest.address) === 0n);
} else if (burnTreasury) {
  await check('Keep-or-refund window closed', await keys.refundsAvailable() && !await keys.choiceWindowOpen());
  await expectRevert('Paid key cannot be burned as treasury', 'burnTreasuryKeys', [[1]]);
  await transact('Burn treasury key 3', 'burnTreasuryKeys', [[3]]);
  await check('Only the kept key remains', await keys.totalSupply() === 1n && await keys.totalBurned() === 1n && await keys.ownerOf(1) === deployer);
} else if (!verifyOnly) {
  manifest.allowlist ||= buildSnapshot({ 'pioneer.csv': `address\n${[deployer, ...pioneerWallets].join('\n')}\n`, 'operative.csv': 'address\n', 'recruit.csv': 'address\n' }, new Date().toISOString()).snapshot;
  const snapshot = manifest.allowlist;
  await save();
  await transact('Load test-wallet Merkle snapshot', 'configureAllowlist', [snapshot.root, snapshot.snapshotHash, snapshot.counts.pioneer, 0, 0]);
  const eligibility = proofFor(snapshot, deployer);
  await transact('Start Pioneer', 'advancePhase');
  await transact('Resume Pioneer', 'setMintPaused', [false]);
  await transact('Mint Pioneer test pair', 'mintWithProof', [2, 1, 25n * 10n ** 15n, eligibility.tier, eligibility.proof], 5n * 10n ** 16n);
  await transact('Mint treasury test key', 'treasuryMint', [1, deployer]);
  for (const [index, wallet] of [deployer, ...pioneerWallets].entries()) {
    const entry = proofFor(snapshot, wallet);
    await check(`Pioneer proof accepted on-chain for snapshot wallet ${index + 1} of ${pioneerWallets.length + 1}`, entry?.tier === 1 && await keys.verifyEligibility(wallet, 1, entry.proof));
  }
  await check('Token IDs start at 1 and record the original payment', await keys.mintPayment(1) === 25n * 10n ** 15n && await keys.ownerOf(1) === deployer && await keys.tokenURI(1) === `${manifest.sbtBaseURI}1.json`);
  if (qa) {
    for (const [phaseId, name, price] of [[2, 'Operative', 4n * 10n ** 16n], [3, 'Recruit', 45n * 10n ** 15n], [4, 'Civilian', 5n * 10n ** 16n]]) {
      await transact(`Advance to ${name}`, 'advancePhase');
      await transact(`Resume ${name}`, 'setMintPaused', [false]);
      await transact(`Mint ${name} test key`, 'mint', [1, phaseId, price], price);
    }
    await check('Four independent phase counters', (await Promise.all([1, 2, 3, 4].map(id => keys.mintedInPhase(id, deployer)))).every((value, index) => value === (index === 0 ? 2n : 1n)));
    await check('All unused GTD allocations released before Civilian', await keys.totalGtdReserved() === 0n);
    await check('Mixed-price reserve equals 0.185 ETH', await provider.getBalance(manifest.address) === 185n * 10n ** 15n);
    await expectRevert('Cannot reopen previous phase', 'configurePhase', [1, 5n * 10n ** 15n, 4]);
    await expectRevert('Cannot choose another mint phase', 'mint', [1, 1, 5n * 10n ** 15n]);
  }
  await check('Paid and treasury mint counters', await keys.mintedByUsers() === (qa ? 5n : 2n) && await keys.mintedByTreasury() === 1n);
}
for (const [label, record] of Object.entries(manifest.transactions)) {
  const receipt = await confirm(record.hash);
  await check(`Receipt: ${label}`, receipt.status === 1);
}
manifest.currentPhase = Number(await keys.currentPhase());
manifest.deadline = Number(await keys.mintEndTime());
manifest.lastVerifiedBlock = await provider.getBlockNumber();
await save();
if (!local && !qa && !verifyOnly) {
  await writeFile(resolve(root, 'console/src/allowlist.json'), JSON.stringify(manifest.allowlist, null, 2) + '\n');
  await writeFile(resolve(root, 'console/public/testnet-check-data.js'), checkerScript(manifest.allowlist));
  await writeFile(resolve(root, 'console/src/deployment.json'), JSON.stringify({ chainId, address: manifest.address, label: 'v6 / client-aligned management', deploymentBlock: manifest.deploymentBlock, runtimeCodeHash: manifest.runtimeCodeHash }, null, 2) + '\n');
}
console.log(JSON.stringify({ address: manifest.address, chainId, deadline: manifest.deadline, manifest: manifestPath }));
provider.destroy();
