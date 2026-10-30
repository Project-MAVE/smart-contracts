import { readFile, writeFile } from 'node:fs/promises';
import { Contract, JsonRpcProvider, formatEther, keccak256 } from 'ethers';
const root = new URL('../../ryodan-keys/', import.meta.url);
const provider = new JsonRpcProvider('https://rpc.sepolia.ethpandaops.io', 11155111, { cacheTimeout: -1 });
const artifact = JSON.parse(await readFile(new URL('out/RyodanKeys.sol/RyodanKeys.json', root), 'utf8'));
const check = (condition, message) => { if (!condition) throw new Error(message); };
const records = [];
try {
  check(Number(await provider.send('eth_chainId', [])) === 11155111, 'Wrong chain');
  for (const purpose of ['management', 'refund']) {
    const suffix = purpose === 'refund' ? '-refund' : '';
    const manifest = JSON.parse(await readFile(new URL(`deployments/sepolia-v4${suffix}.json`, root), 'utf8'));
    const block = await provider.getBlock('latest');
    const options = { blockTag: block.number };
    const keys = new Contract(manifest.address, artifact.abi, provider);
    const runtime = await provider.getCode(manifest.address, block.number);
    check(runtime === artifact.deployedBytecode.object, 'Runtime differs from optimized compiler output');
    const [paid, treasury, live, refunded, phase, balance, deadline, reserve] = await Promise.all([keys.mintedByUsers(options), keys.mintedByTreasury(options), keys.totalSupply(options), keys.totalRefunded(options), keys.currentPhase(options), provider.getBalance(manifest.address, block.number), keys.mintEndTime(options), keys.totalGtdReserved(options)]);
    const record = { purpose, address: manifest.address, block: block.number, timestamp: block.timestamp, runtimeCodeHash: keccak256(runtime), paid: Number(paid), treasury: Number(treasury), live: Number(live), refunded: Number(refunded), phase: Number(phase), balanceETH: formatEther(balance), deadline: Number(deadline), gtdReserved: Number(reserve) };
    if (purpose === 'management') {
      check(paid === 2n && treasury === 1n && live === 3n && refunded === 0n && phase === 1n && balance === 5n * 10n ** 16n && reserve === 12n, 'Unexpected management smoke state');
    } else {
      check(paid === 5n && treasury === 1n && live === 1n && refunded === 5n && balance === 0n && reserve === 0n, 'Unexpected refund final state');
      const receipt = await provider.getTransactionReceipt(manifest.transactions['Refund all paid keys in one batch'].hash);
      check(receipt?.status === 1, 'Refund receipt failed');
      const events = receipt.logs.filter(log => log.address.toLowerCase() === manifest.address.toLowerCase()).map(log => keys.interface.parseLog(log)).filter(event => event?.name === 'Refunded');
      const amount = events.reduce((sum, event) => sum + event.args.amount, 0n);
      check(events.length === 5 && amount === 185n * 10n ** 15n && events.every(event => event.args.recipient === manifest.deployer && event.args.minter === manifest.deployer), 'Incorrect refund events/recipients');
      const before = await provider.getBalance(manifest.deployer, receipt.blockNumber - 1);
      const after = await provider.getBalance(manifest.deployer, receipt.blockNumber);
      check(after - before + receipt.gasUsed * receipt.gasPrice === amount, 'Refund recipient balance plus gas does not match payout');
      let duplicateRejected = false, reopenRejected = false;
      try { await keys.refund.staticCall(0); } catch (error) { if (error.code !== 'CALL_EXCEPTION') throw error; duplicateRejected = true; }
      try { await keys.setMintEndTime.staticCall(block.timestamp + 86400, { from: manifest.deployer }); } catch (error) { if (error.code !== 'CALL_EXCEPTION') throw error; reopenRejected = true; }
      check(duplicateRejected && reopenRejected, 'Repeated refund or expired reopen was accepted');
      Object.assign(record, { refundTransaction: receipt.hash, refundIds: events.map(event => Number(event.args.tokenId)), refundETH: formatEther(amount), recipientBalancePlusGasMatches: true, duplicateRejected, expiredReopenRejected: reopenRejected });
    }
    records.push(record);
  }
  const result = { checkedAt: new Date().toISOString(), chainId: 11155111, rpc: 'https://rpc.sepolia.ethpandaops.io', records };
  await writeFile(new URL('deployments/sepolia-v4-verification.json', root), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
} finally { provider.destroy(); }
