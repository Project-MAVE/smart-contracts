import { Contract, Interface, getAddress, keccak256, toUtf8Bytes } from 'ethers';

const safeAbi = [
  'function getOwners() view returns (address[])', 'function getThreshold() view returns (uint256)',
  'function nonce() view returns (uint256)', 'function VERSION() view returns (string)',
];
// EIP-7825: no single transaction may use more gas than this, whatever the block limit is.
export const TRANSACTION_GAS_CAP = 16_777_216n;
// A Safe forwards 63/64 of its gas to the call and adds its own signature checks and bookkeeping.
export const safeGasNeeded = gas => gas * 64n / 63n + 150_000n;
export const TREASURY_BLOCK = 100n;

export async function readSafe(provider, address, options = {}) {
  if (await provider.getCode(address, options.blockTag) === '0x') return null;
  const safe = new Contract(address, safeAbi, provider);
  try {
    const [owners, threshold, nonce, version] = await Promise.all([safe.getOwners(options), safe.getThreshold(options), safe.nonce(options), safe.VERSION(options)]);
    if (!owners.length || threshold < 1n || threshold > BigInt(owners.length)) return null;
    return { address: getAddress(address), owners: [...owners], threshold, nonce, version };
  } catch (error) {
    if (error.code === 'CALL_EXCEPTION' || error.code === 'BAD_DATA') return null;
    throw error;
  }
}

export const isOwner = (safe, account) => Boolean(safe && account && safe.owners.some(owner => owner.toLowerCase() === account.toLowerCase()));

const inputValue = value => Array.isArray(value) ? `[${value.map(inputValue).join(', ')}]` : String(value);

/** One call in the shape the Safe Transaction Builder exports: the method and its inputs, values as strings. */
export function batchCall(abi, to, method, args) {
  const fragment = new Interface(abi).getFunction(method);
  if (!fragment || fragment.inputs.length !== args.length) throw new Error(`Unknown call ${method} with ${args.length} argument(s).`);
  return {
    to: getAddress(to), value: '0', data: null,
    contractMethod: { inputs: fragment.inputs.map(({ type, name }) => ({ internalType: type, name, type })), name: fragment.name, payable: fragment.payable },
    contractInputsValues: Object.fromEntries(fragment.inputs.map((input, index) => [input.name, inputValue(args[index])])),
  };
}

// The Transaction Builder checksum (apps/tx-builder/src/lib/checksum.ts): a file that fails it loads with a warning.
function serialize(json) {
  if (Array.isArray(json)) return `[${json.map(serialize).join(',')}]`;
  if (typeof json === 'object' && json !== null) {
    const keys = Object.keys(json).sort();
    return `{${JSON.stringify(keys)}${keys.map(key => `${serialize(json[key])},`).join('')}}`;
  }
  return JSON.stringify(json === undefined ? null : json);
}
export const batchChecksum = file => keccak256(toUtf8Bytes(serialize({ ...file, meta: { ...file.meta, name: null } })));

export function batchFile({ chainId, safe, name, description, transactions, createdAt = Date.now() }) {
  if (!transactions.length) throw new Error('A Safe batch needs at least one call.');
  const file = { version: '1.0', chainId: String(chainId), createdAt, meta: { name, description, createdFromSafeAddress: getAddress(safe), createdFromOwnerAddress: '' }, transactions };
  return { ...file, meta: { ...file.meta, checksum: batchChecksum(file) } };
}

/** The calldata the Transaction Builder derives from a batch entry; it must equal what the console simulated. */
export function batchCalldata(transaction) {
  if (transaction.data) return transaction.data;
  const { name, inputs } = transaction.contractMethod;
  const parse = (type, text) => type === 'bool' ? text === 'true' : type.endsWith(']') ? JSON.parse(text.replace(/0x[0-9a-fA-F]+/g, '"$&"')).map(String) : text;
  return new Interface([{ type: 'function', name, inputs, stateMutability: transaction.contractMethod.payable ? 'payable' : 'nonpayable' }])
    .encodeFunctionData(name, inputs.map(input => parse(input.type, transaction.contractInputsValues[input.name])));
}

const prefix = chainId => ({ 1: 'eth', 11155111: 'sep' })[chainId];
export function safeLinks(chainId, safe) {
  const short = prefix(chainId);
  if (!short) return null;
  const id = `${short}:${getAddress(safe)}`;
  return { home: `https://app.safe.global/home?safe=${id}`, queue: `https://app.safe.global/transactions/queue?safe=${id}`, builder: `https://app.safe.global/apps/open?safe=${id}&appUrl=${encodeURIComponent('https://apps-portal.safe.global/tx-builder')}` };
}

/** The ordered launch steps a Safe performs, derived from chain state only. */
export function launchSteps(s, snapshot) {
  const listed = s.allowlistConfigured && s.snapshotMatches;
  const treasuryLeft = s.maxTreasury - s.treasuryMinted;
  const closed = s.timestamp > s.deadline || s.soldOut;
  const current = Number(s.currentPhase);
  const names = ['Pioneer', 'Operative', 'Recruit', 'Civilian'];
  const opened = current === 4 && !s.paused;
  const steps = [
    { id: 'allowlist', title: 'Load the allowlist', done: listed || (s.allowlistConfigured && current > 0),
      detail: listed ? `On chain: ${s.tierCounts.join(' / ')} wallets, root ${s.allowlistRoot.slice(0, 10)}…${s.allowlistRoot.slice(-4)}.`
        : s.allowlistConfigured ? current > 0 ? 'A snapshot is frozen on chain, but it is not the one loaded in this console.' : 'A different snapshot is on chain. Loading replaces it until Pioneer starts.'
        : snapshot ? `Snapshot ready: ${snapshot.counts.pioneer} Pioneer / ${snapshot.counts.operative} Operative / ${snapshot.counts.recruit} Recruit.` : 'Import the snapshot in Sale controls first.' },
    { id: 'treasury', title: `Mint the ${s.maxTreasury} treasury keys`, done: treasuryLeft === 0n,
      detail: treasuryLeft === 0n ? `${s.maxTreasury} / ${s.maxTreasury} minted.` : `${s.treasuryMinted} / ${s.maxTreasury} minted. ${(treasuryLeft + TREASURY_BLOCK - 1n) / TREASURY_BLOCK} Safe transaction(s) of up to ${TREASURY_BLOCK} keys left: one transaction cannot carry more gas.` },
    { id: 'open', title: opened || closed ? 'Open the phases' : current && s.paused ? `Resume ${names[current - 1]}` : `Open ${names[current]}`, done: opened || closed,
      detail: opened ? 'All four phases have been opened.' : closed ? 'The sale is closed.' : current && s.paused ? `${names[current - 1]} is active but paused: one call resumes minting.`
        : `${current ? `${names[current - 1]} is open and minting. Next: one` : 'One'} Safe transaction with two calls, advance to ${names[current]} then resume minting.${current ? ` ${names[current - 1]} closes for good.` : ' The allowlist freezes for good.'}` },
  ];
  const next = steps.findIndex(step => !step.done);
  return steps.map((step, index) => ({ ...step, status: step.done ? 'DONE' : index === next ? 'NEXT' : 'WAITING' }));
}
