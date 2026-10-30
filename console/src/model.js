import { getAddress, ZeroAddress } from 'ethers';

export function unsigned(value, maximum = 6666n, minimum = 0n) {
  const text = String(value).trim();
  if (!/^\d+$/.test(text)) throw new Error('Enter a whole, non-negative number.');
  const amount = BigInt(text);
  if (amount < minimum || amount > maximum) throw new Error(`Enter a number from ${minimum} to ${maximum}.`);
  return amount;
}

export function address(value) {
  let account;
  try { account = getAddress(value.trim()); } catch { throw new Error('Enter a valid Ethereum address (0x + 40 hex characters).'); }
  if (account === ZeroAddress) throw new Error('The zero address cannot receive tokens, refunds or roles.');
  return account;
}

export function addresses(value) {
  const list = [...new Set(value.trim().split(/[\s,;]+/).map(address))];
  if (!list.length || list.length > 100) throw new Error('Enter between 1 and 100 addresses.');
  return list;
}

export function deadlineUTC(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(value)) throw new Error('Enter a valid UTC date and time.');
  const normalized = value.length === 16 ? `${value}:00` : value;
  const time = new Date(`${normalized}Z`);
  if (!Number.isFinite(time.getTime()) || time.toISOString().slice(0, 19) !== normalized) throw new Error('Enter a valid UTC date and time.');
  return BigInt(Math.floor(time.getTime() / 1000));
}

export function metadataBase(value) {
  const uri = value.trim();
  if (!uri.endsWith('/') || /[\s?#]/.test(uri) || !/^(ipfs:\/\/[^/]+\/|https:\/\/[^/]+\/)/.test(uri)) {
    throw new Error('Use an ipfs:// or https:// directory URI ending with /, without spaces, query or fragment.');
  }
  return uri;
}

export const phaseNames = ['Not started', 'Pioneer', 'Operative', 'Recruit', 'Civilian'];

export function remaining(s) {
  if (s.version >= 3n) {
    const supply = s.maxPaid - s.paid - (s.currentPhase > 2n ? s.reserved : 0n);
    return s.phaseAllowance < supply ? s.phaseAllowance : supply;
  }
  const wallet = s.limit > s.walletMinted ? s.limit - s.walletMinted : 0n;
  return [s.maxPaid - s.paid, wallet, s.whitelistActive ? s.maxWhitelist - s.whitelistMinted : s.maxPaid]
    .reduce((a, b) => a < b ? a : b);
}

export function phase(s) {
  if (s.soldOut) return 'SOLD OUT';
  if (s.timestamp > s.deadline) return 'EXPIRED';
  if (s.paid === s.maxPaid) return 'PAID CAP';
  if (s.version >= 3n) return s.currentPhase === 0n ? 'NOT STARTED' : s.paused ? 'PAUSED' : phaseNames[Number(s.currentPhase)].toUpperCase();
  if (s.publicActive) return 'PUBLIC';
  if (s.whitelistActive) return 'WHITELIST';
  return 'PAUSED';
}

export function gate(kind, s, context) {
  if (context.busy) return 'Another transaction is being reviewed or submitted.';
  if (context.pending) return 'Reconcile the pending transaction before submitting another.';
  if (!s || context.stale) return 'Refresh contract state before submitting.';
  if (!context.account) return 'Connect a wallet to continue.';
  if (!context.correctChain) return 'Switch your wallet to the displayed network.';
  if (['admin', 'phaseAdmin', 'allowlist', 'advance', 'pause', 'deadline', 'reveal'].includes(kind) && !s.admin) return 'The connected wallet needs the administrator role.';
  if (['treasuryMint', 'withdraw'].includes(kind) && !s.treasuryRole) return 'The connected wallet needs the treasury role.';
  if (['phaseAdmin', 'allowlist', 'advance', 'pause'].includes(kind)) {
    if (s.version < 3n) return 'Four-phase controls require a v3 deployment.';
    if (s.timestamp > s.deadline || s.soldOut) return 'Sale configuration is closed after expiry or sellout.';
    if (kind === 'allowlist' && s.version >= 4n && s.currentPhase !== 0n) return 'The snapshot is frozen: Pioneer has already started.';
    if (kind === 'advance' && s.version >= 4n && !s.allowlistConfigured) return 'Load the allowlist snapshot before starting Pioneer.';
    if (kind === 'allowlist' && s.currentPhase === 4n) return 'All allowlist phases are closed. Civilian is public.';
    if (kind === 'advance' && s.currentPhase === 4n) return 'Civilian is the final phase.';
    if (kind === 'pause' && s.currentPhase === 0n) return 'Start Pioneer before resuming minting.';
  }
  if (kind === 'deadline' && s.version < 2n) return 'This earlier deployment has an immutable deadline. Select the v2 contract.';
  if (['mint', 'treasuryMint', 'deadline'].includes(kind) && s.timestamp > s.deadline) return 'The sale has expired. Minting and deadline changes are closed.';
  if (kind === 'deadline' && s.soldOut) return 'The deadline is locked after sellout.';
  if (kind === 'mint') {
    if (!s.publicActive && !s.whitelistActive) return 'Minting is paused.';
    if (s.whitelistActive && !s.whitelisted) return 'This wallet is not on the active phase allowlist.';
    if (remaining(s) <= 0n) return 'The remaining supply or your wallet allowance is exhausted.';
  }
  if (kind === 'treasuryMint' && s.treasuryMinted === s.maxTreasury) return 'All treasury keys have been minted.';
  if (['withdraw', 'reveal'].includes(kind) && !s.soldOut) return `All ${(s.maxPaid + s.maxTreasury).toLocaleString('en-US')} keys must mint before this operation unlocks.`;
  if (kind === 'withdraw' && s.balance === 0n) return 'There is no balance to withdraw.';
  if (kind === 'reveal' && s.revealed) return 'The collection has already been permanently revealed.';
  if (kind === 'refund' && !s.refundsAvailable) return 'Refunds open only after unsuccessful expiry.';
  return '';
}

export function friendlyError(error) {
  if (error?.code === 'ACTION_REJECTED' || error?.code === 4001) return 'Signature rejected. No transaction was submitted.';
  if (error?.code === 'INSUFFICIENT_FUNDS') return 'Insufficient ETH for the payment and network fees.';
  return error?.revert?.args?.[0] || error?.reason || error?.shortMessage || error?.message || 'The request failed. Refresh and try again.';
}

export function refundIds(value, maximum = 6665n) {
  const ids = String(value).trim().split(/[\s,;]+/).map(value => unsigned(value, maximum));
  if (!ids.length || ids.length > 50 || new Set(ids.map(String)).size !== ids.length) throw new Error('Enter 1–50 unique token IDs.');
  return ids;
}
