import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { AbiCoder, JsonRpcProvider, keccak256 } from 'ethers';

if (!process.env.ETHERSCAN_API_KEY) throw new Error('Inject ETHERSCAN_API_KEY via hush run --redact.');
const qa = process.argv.includes('--qa');
const suffix = qa ? '-refund' : '';
const root = fileURLToPath(new URL('../../ryodan-keys/', import.meta.url));
const manifest = JSON.parse(await readFile(`${root}deployments/sepolia-v4${suffix}.json`, 'utf8'));
if (manifest.version !== 4 || manifest.chainId !== 11155111) throw new Error('Expected the v4 Sepolia deployment.');
const forge = process.env.FORGE_BIN || `${homedir()}/.foundry/bin/forge`;
const contract = 'src/RyodanKeys.sol:RyodanKeys';
const compiler = 'v0.8.37+commit.f401782d';
const constructor = AbiCoder.defaultAbiCoder().encode(['uint256', 'string', 'address', 'address'], [manifest.initialDeadline, manifest.hiddenMetadataURI, manifest.deployer, manifest.deployer]).slice(2);
const expected = JSON.parse(execFileSync(forge, ['verify-contract', manifest.address, contract, '--chain', '11155111', '--compiler-version', compiler.slice(1), '--show-standard-json-input'], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
const artifact = JSON.parse(await readFile(`${root}out/RyodanKeys.sol/RyodanKeys.json`, 'utf8'));
const provider = new JsonRpcProvider('https://rpc.sepolia.ethpandaops.io');
try {
  const transaction = await provider.getTransaction(manifest.deploymentTransaction);
  if (!transaction || transaction.data !== artifact.bytecode.object + constructor) throw new Error('Creation bytecode/constructor mismatch.');
  if (await provider.getCode(manifest.address) !== artifact.deployedBytecode.object) throw new Error('Runtime bytecode mismatch.');
} finally { provider.destroy(); }
if (!process.argv.includes('--check')) {
  execFileSync(forge, ['verify-contract', manifest.address, contract, '--chain', '11155111', '--verifier', 'etherscan', '--compiler-version', compiler.slice(1), '--constructor-args', constructor, '--skip-is-verified-check', '--watch', '--retries', '12', '--delay', '5'], { cwd: root, stdio: 'inherit' });
}
const url = new URL('https://api.etherscan.io/v2/api');
url.search = new URLSearchParams({ chainid: '11155111', module: 'contract', action: 'getsourcecode', address: manifest.address, apikey: process.env.ETHERSCAN_API_KEY });
let response;
try { response = await fetch(url, { signal: AbortSignal.timeout(25000) }); } catch { throw new Error('Etherscan metadata request failed.'); }
if (!response.ok) throw new Error(`Etherscan returned HTTP ${response.status}`);
const data = await response.json();
if (data.status !== '1' || !Array.isArray(data.result)) throw new Error('Etherscan verification metadata unavailable.');
const result = data.result[0];
if (!result.SourceCode || result.ABI === 'Contract source code not verified') throw new Error('Not verified yet.');
const published = JSON.parse(result.SourceCode.startsWith('{{') ? result.SourceCode.slice(1, -1) : result.SourceCode);
for (const [name, file] of Object.entries(expected.sources)) if (published.sources?.[name]?.content !== file.content) throw new Error(`Published source differs: ${name}`);
if (result.ContractName !== 'RyodanKeys' || result.CompilerVersion !== compiler || result.OptimizationUsed !== '1' || result.Runs !== '200' || result.EVMVersion.toLowerCase() !== 'cancun') throw new Error('Exact compiler/source verification mismatch.');
const constructorArgumentsMatch = result.ConstructorArguments.replace(/^0x/, '').toLowerCase() === constructor.toLowerCase();
if (!result.SimilarMatch && !constructorArgumentsMatch) throw new Error('Published constructor arguments mismatch.');
const report = { checkedAt: new Date().toISOString(), address: manifest.address, chainId: 11155111, etherscanStatus: result.SimilarMatch ? 'VERIFIED_SIMILAR_MATCH' : 'VERIFIED_EXACT_MATCH', similarMatch: result.SimilarMatch || null, compiler, optimizerRuns: 200, evmVersion: 'cancun', sourcesCompared: Object.keys(expected.sources).length, constructorArgumentsMatch, creationBytecodeAndArgumentsMatch: true, runtimeMatches: true, runtimeCodeHash: keccak256(artifact.deployedBytecode.object), abiEntries: JSON.parse(result.ABI).length, codeUrl: `https://sepolia.etherscan.io/address/${manifest.address}#code` };
await mkdir(`${root}deployments/`, { recursive: true });
await writeFile(`${root}deployments/sepolia-v4${suffix}-etherscan.json`, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
