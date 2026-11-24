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

export function deadlineUTC(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(value)) throw new Error('Enter a valid UTC date and time.');
  const normalized = value.length === 16 ? `${value}:00` : value;
  const time = new Date(`${normalized}Z`);
  if (!Number.isFinite(time.getTime()) || time.toISOString().slice(0, 19) !== normalized) throw new Error('Enter a valid UTC date and time.');
  return BigInt(Math.floor(time.getTime() / 1000));
}

export const SUPPORTED_VERSION = 8n;

export function assertSupported(version) {
  if (version !== SUPPORTED_VERSION) throw Object.assign(new Error(`Unsupported contract ${version === null || version === undefined ? 'without CONTRACT_VERSION (v1)' : `version ${version}`}. This console manages only Ryodan Keys v8.`), { code: 'UNSUPPORTED_CONTRACT' });
}

export const phaseNames = ['Not started', 'Pioneer', 'Operative', 'Recruit', 'Civilian'];

export function remaining(s) {
  const supply = s.maxPaid - s.paid - (s.currentPhase > 2n ? s.reserved : 0n);
  return s.phaseAllowance < supply ? s.phaseAllowance : supply;
}

export function tokenRange(s) {
  const first = s ? s.firstTokenId : 1n;
  const total = s ? s.maxPaid + s.maxTreasury : 6666n;
  return [first, first + total - 1n];
}

export function phase(s) {
  if (s.soldOut) return 'SOLD OUT';
  if (s.timestamp > s.deadline && s.choiceWindowOpen) return 'KEEP OR REFUND';
  if (s.timestamp > s.deadline) return 'EXPIRED';
  if (s.paid === s.maxPaid) return 'PAID CAP';
  return s.currentPhase === 0n ? 'NOT STARTED' : s.paused ? 'PAUSED' : phaseNames[Number(s.currentPhase)].toUpperCase();
}

const adminKinds = ['admin', 'phaseAdmin', 'allowlist', 'advance', 'pause'];
const treasuryKinds = ['treasuryMint', 'withdraw', 'withdrawKept', 'burnTreasury'];

/** True when the role for this action belongs to a Safe: the console prepares the call, the Safe owners sign it. */
export function viaSafe(kind, s, account) {
  if (!s?.safe || account?.toLowerCase() === s.safe.address.toLowerCase()) return false;
  if (kind === 'acceptAdmin') return Boolean(s.safe.incoming);
  if (adminKinds.includes(kind)) return !s.admin && !s.safe.incoming;
  return treasuryKinds.includes(kind) && s.safe.treasury && !s.treasuryRole;
}

export function gate(kind, s, context) {
  if (context.busy) return 'Another transaction is being reviewed or submitted.';
  if (context.pending) return 'Reconcile the pending transaction before submitting another.';
  if (!s || context.stale) return 'Refresh contract state before submitting.';
  const safe = viaSafe(kind, s, context.account);
  if (adminKinds.includes(kind) && s.safe?.incoming && !s.admin) return 'The Safe accepts the administrator role first.';
  if (!safe && !context.account) return 'Connect a wallet to continue.';
  if (!safe && !context.correctChain) return 'Switch your wallet to the displayed network.';
  if (s.version !== SUPPORTED_VERSION) return 'This console manages only Ryodan Keys v8.';
  if (kind === 'acceptAdmin' && safe && s.timestamp <= s.safe.incoming.schedule) return 'The transfer can be accepted from the next block.';
  if (!safe && adminKinds.includes(kind) && !s.admin) return 'The connected wallet needs the administrator role.';
  if (!safe && treasuryKinds.includes(kind) && !s.treasuryRole) return 'The connected wallet needs the treasury role.';
  if (['phaseAdmin', 'allowlist', 'advance', 'pause'].includes(kind)) {
    if (s.timestamp > s.deadline || s.soldOut) return 'Sale configuration is closed after expiry or sellout.';
    if (kind === 'allowlist' && s.currentPhase !== 0n) return 'The snapshot is frozen: Pioneer has already started.';
    if (kind === 'phaseAdmin' && s.currentPhase !== 0n) return 'Prices and limits are locked: Pioneer has already started.';
    if (kind === 'advance' && !s.allowlistConfigured) return 'Load the allowlist snapshot before starting Pioneer.';
    if (kind === 'advance' && s.currentPhase === 4n) return 'Civilian is the final phase.';
    if (kind === 'pause' && s.currentPhase === 0n) return 'Start Pioneer before resuming minting.';
  }
  if (['mint', 'treasuryMint'].includes(kind) && s.timestamp > s.deadline) return 'The sale has expired. Minting is closed.';
  if (kind === 'mint') {
    if (!s.publicActive && !s.whitelistActive) return 'Minting is paused.';
    if (s.whitelistActive && !s.whitelisted) return 'This wallet is not on the active phase allowlist.';
    if (remaining(s) <= 0n) return 'The remaining supply or your wallet allowance is exhausted.';
  }
  if (kind === 'treasuryMint' && s.treasuryMinted === s.maxTreasury) return 'All treasury keys have been minted.';
  if (kind === 'withdraw' && !s.soldOut) return `All ${(s.maxPaid + s.maxTreasury).toLocaleString('en-US')} keys must mint before this operation unlocks.`;
  if (kind === 'withdraw' && s.timestamp <= s.deadline) return 'Sellout proceeds can be withdrawn only after the mint deadline.';
  if (kind === 'withdraw' && s.balance === 0n) return 'There is no balance to withdraw.';
  if (['refund', 'settle', 'withdrawKept', 'burnTreasury'].includes(kind) && !s.refundsAvailable) return 'This opens only after an unsuccessful expiry.';
  if (kind === 'settle' && !s.choiceWindowOpen) return `The ${s.choiceWindow / 3600n}-hour keep-or-refund window has closed. Remaining paid keys can only be refunded.`;
  if (kind === 'burnTreasury' && s.choiceWindowOpen) return 'Treasury keys can be burned only after the keep-or-refund window closes.';
  if (kind === 'withdrawKept' && s.keptFunds === s.keptWithdrawn) return 'No payments from kept keys are waiting to be withdrawn.';
  if (kind === 'claimPending' && !s.pendingRefund) return 'This wallet has no pending refund.';
  return '';
}

export function friendlyError(error) {
  if (error?.code === 'ACTION_REJECTED' || error?.code === 4001) return 'Signature rejected. No transaction was submitted.';
  if (error?.code === 'INSUFFICIENT_FUNDS') return 'Insufficient ETH for the payment and network fees.';
  return error?.revert?.args?.[0] || error?.reason || error?.shortMessage || error?.message || 'The request failed. Refresh and try again.';
}

export function refundIds(value, maximum = 6666n, minimum = 1n) {
  const ids = String(value).trim().split(/[\s,;]+/).map(value => unsigned(value, maximum, minimum));
  if (!ids.length || ids.length > 50 || new Set(ids.map(String)).size !== ids.length) throw new Error('Enter 1–50 unique token IDs.');
  return ids;
}

export function settleIds(keepValue, refundValue, maximum = 6666n, minimum = 1n) {
  const parse = value => String(value).trim() ? String(value).trim().split(/[\s,;]+/).map(value => unsigned(value, maximum, minimum)) : [];
  const keep = parse(keepValue);
  const refund = parse(refundValue);
  const count = keep.length + refund.length;
  if (!count || count > 50) throw new Error('Enter 1–50 token IDs in total to keep or refund.');
  if (new Set([...keep, ...refund].map(String)).size !== count) throw new Error('Each token ID can appear only once, in one list.');
  return [keep, refund];
}
