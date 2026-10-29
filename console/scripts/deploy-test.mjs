import { spawn } from 'node:child_process';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider } from 'ethers';
import assert from 'node:assert/strict';

const directory = await mkdtemp(join(tmpdir(), 'ryodan-v3-deploy-'));
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
  assert.equal(active.version, 3);
  assert.equal(active.currentPhase, 1);
  const resumed = await run(activePath);
  assert.deepEqual(resumed.transactions, active.transactions);
  console.log('PASS v3 management deployment and idempotent resumption');
  const qa = await run(qaPath, '--qa');
  assert.equal(qa.currentPhase, 4);
  assert(qa.checks.includes('Mixed-price reserve equals 0.018 ETH'));
  console.log('PASS v3 QA deployment mints all four phases with independent counters');
  await provider.send('evm_increaseTime', [100]);
  await provider.send('evm_mine', []);
  const refunded = await run(qaPath, '--refund');
  assert(refunded.checks.includes('Refund returned all paid reserves'));
  await run(qaPath, '--verify');
  console.log('PASS exact mixed-price refunds, duplicate rejection and runtime verification');
} finally {
  anvil.kill();
  provider.destroy();
}
