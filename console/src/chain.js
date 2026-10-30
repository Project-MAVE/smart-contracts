import { Contract, FetchRequest, JsonRpcProvider, ZeroHash } from 'ethers';
import abi from '../../ryodan-keys/abi/RyodanKeys.json';
import v3Abi from '../../ryodan-keys/abi/RyodanKeys.v3.json';
import { proofFor } from './allowlist.js';
import legacyAbi from '../../ryodan-keys/abi/RyodanKeys.v2.json';

export { abi };
export const abiForVersion = version => version >= 4n ? abi : version === 3n ? v3Abi : legacyAbi;

// snapshot explicitly verifies eth_chainId; static setup avoids an endless startup retry on a failed RPC.
export function reader(url, chainId) {
  const request = new FetchRequest(url);
  request.timeout = 12000;
  request.setThrottleParams({ maxAttempts: 2, slotInterval: 250 });
  return new JsonRpcProvider(request, chainId, { staticNetwork: true, batchMaxCount: 40, cacheTimeout: -1, pollingInterval: 4000 });
}

export async function snapshot(provider, contractAddress, account, chainId, allowlist) {
  const actual = Number(await provider.send('eth_chainId', []));
  if (actual !== chainId) throw new Error('RPC network mismatch. Writes have been disabled.');
  const block = await provider.getBlock('latest');
  if (!block) throw new Error('The latest block is unavailable.');
  const options = { blockTag: block.number };
  const version = await new Contract(contractAddress, abi, provider).CONTRACT_VERSION(options).catch(error => {
    if (error.code === 'CALL_EXCEPTION' || error.code === 'BAD_DATA') return 1n;
    throw error;
  });
  if (version > 4n) throw new Error('Unsupported contract version. Update this console before signing.');
  const keys = new Contract(contractAddress, abiForVersion(version), provider);
  const getters = {
    price: 'mintPrice', deadline: 'mintEndTime', maxPaid: 'MAX_PUBLIC_SUPPLY', maxTreasury: 'MAX_TREASURY_SUPPLY',
    paid: 'mintedByUsers', treasuryMinted: 'mintedByTreasury', supply: 'totalSupply', refunded: 'totalRefunded',
    soldOut: 'soldOut', revealed: 'revealed', refundsAvailable: 'refundsAvailable', treasuryRoleId: 'TREASURY_ROLE',
    ...(version >= 4n ? { allowlistRoot: 'allowlistRoot', allowlistSnapshotHash: 'allowlistSnapshotHash', allowlistConfigured: 'allowlistConfigured' } : {}),
    ...(version >= 3n ? { currentPhase: 'currentPhase', paused: 'mintPaused', reserved: 'totalGtdReserved' } : {
      limit: 'MAX_MINT_AMOUNT', maxWhitelist: 'WL_MINT_AMOUNT', whitelistMinted: 'mintedByWhitelist',
      publicActive: 'isPublicMintActive', whitelistActive: 'isWhitelistMintActive',
    }),
  };
  const values = await Promise.all(Object.entries(getters).map(async ([key, method]) => [key, await keys[method](options)]));
  const state = Object.fromEntries(values);
  Object.assign(state, { version, block: block.number, timestamp: BigInt(block.timestamp), walletMinted: 0n, whitelisted: false, admin: false, treasuryRole: false });
  state.balance = await provider.getBalance(contractAddress, block.number);
  if (version >= 4n) {
    state.tierCounts = await Promise.all([1, 2, 3].map(id => keys.tierMembers(id, options)));
    state.snapshotMatches = Boolean(allowlist && allowlist.root === state.allowlistRoot && allowlist.snapshotHash === state.allowlistSnapshotHash && state.tierCounts.every((count, index) => count === BigInt(allowlist.counts[['pioneer', 'operative', 'recruit'][index]])));
    state.proof = account && state.snapshotMatches ? proofFor(allowlist, account) : null;
  }
  if (version >= 3n) {
    state.phases = await Promise.all([1, 2, 3, 4].map(async id => {
      const config = await keys.phases(id, options);
      const [walletMinted, allowance, allowed] = account ? await Promise.all([
        keys.mintedInPhase(id, account, options), state.proof ? keys.remainingAllowanceWithProof(id, account, state.proof.tier, state.proof.proof, options) : keys.remainingAllowance(id, account, options),
        id === 4 ? true : state.proof ? state.proof.tier <= id : keys.allowlisted(id, account, options),
      ]) : [0n, 0n, false];
      return { id, price: config.price, limit: config.walletLimit, minted: config.minted, members: config.members, reserved: config.reserved, walletMinted, allowance, allowed };
    }));
    const active = state.phases[Number(state.currentPhase) - 1];
    state.limit = active?.limit || 0n;
    state.phaseAllowance = active?.allowance || 0n;
    state.phaseWalletMinted = active?.walletMinted || 0n;
    state.whitelisted = active?.allowed || false;
    state.publicActive = state.currentPhase === 4n && !state.paused;
    state.whitelistActive = state.currentPhase > 0n && state.currentPhase < 4n && !state.paused;
  }
  if (account) {
    [state.walletMinted, state.admin, state.treasuryRole] = await Promise.all([
      keys.mintedAmount(account, options), keys.hasRole(ZeroHash, account, options), keys.hasRole(state.treasuryRoleId, account, options),
    ]);
    if (version < 3n) state.whitelisted = await keys.whitelisted(account, options);
  }
  return state;
}
