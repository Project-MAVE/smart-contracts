import { Contract, JsonRpcProvider, ZeroHash } from 'ethers';
import abi from '../../ryodan-keys/abi/RyodanKeys.json';

export { abi };

export function reader(url, chainId) {
  return new JsonRpcProvider(url, chainId, { batchMaxCount: 40, cacheTimeout: -1, pollingInterval: 4000 });
}

export async function snapshot(provider, contractAddress, account, chainId) {
  const actual = Number(await provider.send('eth_chainId', []));
  if (actual !== chainId) throw new Error('RPC network mismatch. Writes have been disabled.');
  const block = await provider.getBlock('latest');
  if (!block) throw new Error('The latest block is unavailable.');
  const options = { blockTag: block.number };
  const keys = new Contract(contractAddress, abi, provider);
  const getters = {
    price: 'mintPrice', deadline: 'mintEndTime', limit: 'MAX_MINT_AMOUNT', maxPaid: 'MAX_PUBLIC_SUPPLY',
    maxTreasury: 'MAX_TREASURY_SUPPLY', maxWhitelist: 'WL_MINT_AMOUNT', paid: 'mintedByUsers',
    treasuryMinted: 'mintedByTreasury', whitelistMinted: 'mintedByWhitelist', supply: 'totalSupply',
    refunded: 'totalRefunded', publicActive: 'isPublicMintActive', whitelistActive: 'isWhitelistMintActive',
    soldOut: 'soldOut', revealed: 'revealed', refundsAvailable: 'refundsAvailable', treasuryRoleId: 'TREASURY_ROLE',
  };
  const values = await Promise.all(Object.entries(getters).map(async ([key, method]) => [key, await keys[method](options)]));
  const state = Object.fromEntries(values);
  state.balance = await provider.getBalance(contractAddress, block.number);
  // Earlier, explicitly listed deployments do not expose a version getter.
  state.version = await keys.CONTRACT_VERSION(options).catch(error => {
    if (error.code === 'CALL_EXCEPTION' || error.code === 'BAD_DATA') return 1n;
    throw error;
  });
  Object.assign(state, { block: block.number, timestamp: BigInt(block.timestamp), walletMinted: 0n, whitelisted: false, admin: false, treasuryRole: false });
  if (account) {
    [state.walletMinted, state.whitelisted, state.admin, state.treasuryRole] = await Promise.all([
      keys.mintedAmount(account, options), keys.whitelisted(account, options),
      keys.hasRole(ZeroHash, account, options), keys.hasRole(state.treasuryRoleId, account, options),
    ]);
  }
  return state;
}
