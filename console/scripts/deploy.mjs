import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { Contract, ContractFactory, JsonRpcProvider, Wallet, getCreateAddress, keccak256, ZeroHash } from 'ethers';

const root = fileURLToPath(new URL('../../', import.meta.url));
const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const local = args.includes('--local');
const verifyOnly = args.includes('--verify');
const refund = args.includes('--refund');
const qa = args.includes('--qa') || refund;
const chainId = local ? 31337 : 11155111;
const rpc = option('--rpc', local ? 'http://127.0.0.1:8547' : 'https://ethereum-sepolia-rpc.publicnode.com');
const provider = new JsonRpcProvider(rpc, chainId, { cacheTimeout: -1, pollingInterval: 1500 });
if (Number(await provider.send('eth_chainId', [])) !== chainId) throw new Error('Wrong chain');
const manifestPath = resolve(root, option('--manifest', local ? 'console/test-results/local-deployment.json' : `ryodan-keys/deployments/sepolia-v2${qa ? '-refund' : ''}.json`));
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
manifest ||= { chainId, deployer, version: 2, purpose: qa ? 'refund' : 'management', transactions: {}, checks: [] };
if (manifest.chainId !== chainId || manifest.deployer !== deployer || manifest.version !== 2) throw new Error('Manifest context mismatch');
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
  if (verifyOnly || refund) throw new Error('Deploy first');
  const block = await provider.getBlock('latest');
  const deadline = block.timestamp + (qa ? 1200 : 30 * 86400);
  const hidden = 'data:application/json;base64,' + Buffer.from(JSON.stringify({ name: 'Ryodan Key / sealed', description: 'Sepolia v2 test collection. Final metadata is not revealed.', attributes: [{ trait_type: 'State', value: 'Unrevealed' }] })).toString('base64');
  const factory = new ContractFactory(artifact.abi, artifact.bytecode.object, signer);
  const nonce = await provider.getTransactionCount(deployer, 'pending');
  const transaction = await signer.sendTransaction({ ...await factory.getDeployTransaction(deadline, hidden, deployer, deployer), nonce });
  manifest.address = getCreateAddress({ from: deployer, nonce });
  manifest.deploymentTransaction = transaction.hash;
  manifest.initialDeadline = deadline;
  manifest.hiddenMetadataURI = hidden;
  await save();
  console.log(`DEPLOYED ${manifest.address} ${transaction.hash}`);
}
const deployReceipt = await confirm(manifest.deploymentTransaction);
manifest.deploymentBlock = deployReceipt.blockNumber;
const keys = new Contract(manifest.address, artifact.abi, signer || provider);
const runtime = await provider.getCode(manifest.address);
await check('Exact runtime bytecode matches current compiler artifact', runtime === artifact.deployedBytecode.object);
manifest.runtimeCodeHash = keccak256(runtime);
await check('Contract version 2', await keys.CONTRACT_VERSION() === 2n);
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
  await check('Refunds available after shortened deadline', await keys.refundsAvailable());
  const block = await provider.getBlock('latest');
  await expectRevert('Expired sale cannot be reopened even before first refund', 'setMintEndTime', [block.timestamp + 86400]);
  await transact('Refund paid token 0', 'refund', [0]);
  await expectRevert('Repeated refund rejected', 'refund', [0]);
  await expectRevert('Expired sale cannot be reopened after refund', 'setMintEndTime', [block.timestamp + 86400]);
  await check('Refund burned paid key', await keys.totalSupply() === 1n && await keys.totalRefunded() === 1n);
  await check('Refund returned all paid reserves', await provider.getBalance(manifest.address) === 0n);
} else if (!verifyOnly) {
  await transact('Extend deadline by one day', 'setMintEndTime', [manifest.initialDeadline + 86400]);
  await transact('Restore original deadline', 'setMintEndTime', [manifest.initialDeadline]);
  await transact('Enable public mint', 'setPublicMintActive', [true, 3]);
  await transact('Mint paid test key', 'mint', [1], 10n ** 16n);
  await transact('Mint treasury test key', 'treasuryMint', [1, deployer]);
  await check('Paid and treasury mint counters', await keys.mintedByUsers() === 1n && await keys.mintedByTreasury() === 1n);
  if (qa) {
    if (!manifest.shortenedDeadline) {
      manifest.shortenedDeadline = (await provider.getBlock('latest')).timestamp + 90;
      await save();
    }
    await transact('Shorten deadline for refund QA', 'setMintEndTime', [manifest.shortenedDeadline]);
  }
}
for (const [label, record] of Object.entries(manifest.transactions)) {
  const receipt = await confirm(record.hash);
  await check(`Receipt: ${label}`, receipt.status === 1);
}
manifest.currentDeadline = Number(await keys.mintEndTime());
manifest.lastVerifiedBlock = await provider.getBlockNumber();
await save();
if (!local && !qa && !verifyOnly) {
  await writeFile(resolve(root, 'console/src/deployment.json'), JSON.stringify({ chainId, address: manifest.address, label: 'v2 / active management', deploymentBlock: manifest.deploymentBlock, runtimeCodeHash: manifest.runtimeCodeHash }, null, 2) + '\n');
}
console.log(JSON.stringify({ address: manifest.address, chainId, currentDeadline: manifest.currentDeadline, manifest: manifestPath }));
provider.destroy();
