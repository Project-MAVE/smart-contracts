import { spawn } from 'node:child_process';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider } from 'ethers';
import assert from 'node:assert/strict';

const directory = await mkdtemp(join(tmpdir(), 'ryodan-v7-deploy-'));
const root = fileURLToPath(new URL('../../', import.meta.url));
const rpc = 'http://127.0.0.1:28547';
const anvil = spawn(process.env.ANVIL_BIN || `${homedir()}/.foundry/bin/anvil`, ['--host', '127.0.0.1', '--port', '28547', '--silent'], { stdio: 'ignore' });
const provider = new JsonRpcProvider(rpc, 31337, { cacheTimeout: -1 });
async function run(manifest, ...flags) {
  await new Promise((resolve, reject) => {
    const process = spawn(globalThis.process.execPath, ['console/scripts/deploy.mjs', '--local', '--rpc', rpc, '--manifest', manifest, ...flags], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    process.stdout.on('data', data => { output += data; });
    process.stderr.on('data', data => { output += data; });
    process.on('error', reject);
    process.on('exit', code => code === 0 ? resolve() : reject(new Error(output)));
  });
  return JSON.parse(await readFile(manifest, 'utf8'));
}
try {
  for (let attempt = 0; attempt < 60; attempt++) {
    try { await fetch(rpc); break; } catch { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  const activePath = join(directory, 'active.json');
  const qaPath = join(directory, 'qa.json');
  const active = await run(activePath);
  assert.equal(active.version, 7);
  assert.equal(active.currentPhase, 1);
  const resumed = await run(activePath);
  assert.deepEqual(resumed.transactions, active.transactions);
  console.log('PASS v7 management deployment (5-argument constructor) and idempotent resumption');
  const qa = await run(qaPath, '--qa');
  assert.equal(qa.currentPhase, 4);
  assert(qa.checks.includes('Mixed-price reserve equals 0.0555 ETH'));
  console.log('PASS v7 QA deployment mints all four phases with independent counters, IDs from 1');
  await assert.rejects(run(qaPath, '--refund'), /Keep-or-refund window open/);
  await provider.send('evm_increaseTime', [3601]);
  await provider.send('evm_mine', []);
  const refunded = await run(qaPath, '--refund');
  assert(refunded.checks.includes('Contract balance is zero after the kept withdrawal'));
  console.log('PASS keep one key, refund the rest at mixed prices, withdraw the kept payment');
  await assert.rejects(run(qaPath, '--burn-treasury'), /Keep-or-refund window closed/);
  await provider.send('evm_increaseTime', [4 * 86400]);
  await provider.send('evm_mine', []);
  const burned = await run(qaPath, '--burn-treasury');
  assert(burned.checks.includes('Only the kept key remains'));
  await run(qaPath, '--verify');
  console.log('PASS treasury burn after the 4-day window and runtime verification');
} finally {
  anvil.kill();
  provider.destroy();
}
