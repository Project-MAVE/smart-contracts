import { Contract, Interface, ZeroAddress, ZeroHash, concat, dataLength, getAddress, keccak256, solidityPacked, toUtf8Bytes, zeroPadValue } from 'ethers';

const safeAbi = [
  'function getOwners() view returns (address[])', 'function getThreshold() view returns (uint256)',
  'function nonce() view returns (uint256)', 'function VERSION() view returns (string)',
  'function approvedHashes(address owner, bytes32 hash) view returns (uint256)',
  'function getTransactionHash(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 nonce) view returns (bytes32)',
  'function approveHash(bytes32 hashToApprove)',
  'function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) payable returns (bool)',
];
export const safeInterface = new Interface(safeAbi);
// MultiSendCallOnly per Safe version (safe-deployments, canonical addresses): the contract a Safe delegates to for several calls at once.
const multiSendCallOnly = {
  '1.5.0': ['0xA83c336B20401Af773B6219BA5027174338D1836', '0xcdbdcec38d2f1c7d961b0029ff8416b7e86e9974d6f0e9c9580c7d17fcfb6663'],
  '1.4.1': ['0x9641d764fc13c8B624c04430C7356C1C7C8102e2', '0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939'],
};
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

/** The Safe transaction for one or more batch entries: a single call goes straight to its target, several run through MultiSendCallOnly. */
export function safeTransaction(safe, calls) {
  const list = calls.map(call => ({ to: getAddress(call.to), value: BigInt(call.value), data: batchCalldata(call) }));
  if (list.length === 1) return { ...list[0], operation: 0 };
  const known = multiSendCallOnly[safe.version.split('+')[0]];
  if (!known) throw new Error(`Several calls in one transaction are not prepared here for Safe ${safe.version}. Download the batch for the Safe app.`);
  const packed = concat(list.map(call => solidityPacked(['uint8', 'address', 'uint256', 'uint256', 'bytes'], [0, call.to, call.value, dataLength(call.data), call.data])));
  return { to: known[0], value: 0n, data: new Interface(['function multiSend(bytes transactions)']).encodeFunctionData('multiSend', [packed]), operation: 1, codeHash: known[1] };
}

const safeTxArguments = (tx, last) => [tx.to, tx.value, tx.data, tx.operation, 0, 0, 0, ZeroAddress, ZeroAddress, last];

/** Reads from the Safe the hash of this transaction at its current nonce and which owners approved it on chain. */
export async function confirmations(provider, safe, tx, options = {}) {
  if (tx.operation === 1 && keccak256(await provider.getCode(tx.to, options.blockTag)) !== tx.codeHash) throw new Error('The Safe batch contract on this network is not the published one. Download the batch for the Safe app.');
  const contract = new Contract(safe.address, safeAbi, provider);
  const nonce = await contract.nonce(options);
  const hash = await contract.getTransactionHash(...safeTxArguments(tx, nonce), options);
  const flags = await Promise.all(safe.owners.map(owner => contract.approvedHashes(owner, hash, options)));
  return { hash, nonce, approved: safe.owners.filter((_, index) => flags[index] !== 0n) };
}

const includes = (list, account) => Boolean(account) && list.some(item => item.toLowerCase() === account.toLowerCase());

/** What the connected account can do with a Safe transaction: approve it, execute it, wait for another owner, or nothing. */
export function ownerStep(safe, approved, account) {
  const needed = Number(safe.threshold);
  if (!account) return 'connect';
  if (approved.length >= needed) return 'execute';
  if (!isOwner(safe, account)) return 'observe';
  if (includes(approved, account)) return 'wait';
  return approved.length + 1 >= needed ? 'execute' : 'approve';
}

/** Signatures for execTransaction made of on-chain approvals: the sender counts as approving when it is an owner. */
export function executionSignatures(safe, approved, sender) {
  const signers = [...new Set([...(isOwner(safe, sender) ? [getAddress(sender)] : []), ...approved.map(owner => getAddress(owner))])].slice(0, Number(safe.threshold));
  if (signers.length < Number(safe.threshold)) throw new Error('This Safe transaction does not have enough owner approvals yet.');
  return concat(signers.sort((a, b) => BigInt(a) < BigInt(b) ? -1 : 1).map(owner => concat([zeroPadValue(owner, 32), ZeroHash, '0x01'])));
}

export const approveCall = (safe, hash) => ({ to: safe.address, data: safeInterface.encodeFunctionData('approveHash', [hash]) });
export const executeCall = (safe, tx, signatures) => ({ to: safe.address, data: safeInterface.encodeFunctionData('execTransaction', [...safeTxArguments(tx, signatures)]) });
