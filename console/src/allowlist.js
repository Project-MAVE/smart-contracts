import { AbiCoder, ZeroAddress, ZeroHash, concat, getAddress, keccak256, sha256, toUtf8Bytes } from 'ethers';

export const tiers = ['pioneer', 'operative', 'recruit'];
export const csvTemplate = 'address\n';
const hashPattern = /^0x[0-9a-f]{64}$/;
const coder = AbiCoder.defaultAbiCoder();
const bytes = value => typeof value === 'string' ? toUtf8Bytes(value) : value;
const requireValid = (condition, message) => { if (!condition) throw new Error(message); };
export const lookupKey = address => sha256(toUtf8Bytes(getAddress(address.toLowerCase()).toLowerCase()));
export const leafFor = (address, tier) => keccak256(keccak256(coder.encode(['address', 'uint8'], [address, tier])));
export const pairHash = (a, b) => keccak256(concat(a < b ? [a, b] : [b, a]));

function treeFor(leaves) {
  const levels = [[...leaves].sort()];
  while (levels.at(-1).length > 1) {
    const last = levels.at(-1), next = [];
    for (let i = 0; i < last.length; i += 2) next.push(i + 1 < last.length ? pairHash(last[i], last[i + 1]) : last[i]);
    levels.push(next);
  }
  return { levels, root: levels.at(-1)[0] || ZeroHash };
}

export function parseCSV(value, filename = 'CSV') {
  const input = new TextDecoder('utf-8', { fatal: true }).decode(bytes(value)).replace(/^\uFEFF/, '');
  const rows = []; let row = [], field = '', quoted = false, closed = false;
  const endField = () => { row.push(field.trim()); field = ''; closed = false; };
  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (quoted) {
      if (c === '"' && input[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') { quoted = false; closed = true; }
      else field += c;
    } else if (c === ',') endField();
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && input[i + 1] === '\n') i++;
      endField(); rows.push(row); row = [];
    } else if (c === '"' && !field && !closed) quoted = true;
    else { requireValid(!closed && c !== '"', `${filename}: malformed quoted field.`); field += c; }
  }
  requireValid(!quoted, `${filename}: unclosed quoted field.`);
  if (field || row.length || closed) { endField(); rows.push(row); }
  const entries = rows.filter(row => row.some(Boolean));
  requireValid(entries.length > 0 && entries[0][0].toLowerCase() === 'address', `${filename}: the first column must be headed address.`);
  const addresses = entries.slice(1).map((row, index) => {
    requireValid(/^0x[0-9a-fA-F]{40}$/.test(row[0]), `${filename}: invalid address at data row ${index + 1}.`);
    const address = getAddress(row[0].toLowerCase());
    requireValid(address !== ZeroAddress, `${filename}: zero address at data row ${index + 1}.`);
    return address.toLowerCase();
  });
  return addresses;
}

function manifest(snapshot) {
  return { schemaVersion: 1, frozenAt: snapshot.frozenAt,
    sourceHashes: Object.fromEntries(tiers.map(tier => [`${tier}.csv`, snapshot.sourceHashes[`${tier}.csv`]])),
    root: snapshot.root, counts: Object.fromEntries(tiers.map(tier => [tier, snapshot.counts[tier]])) };
}
export const snapshotDigest = snapshot => keccak256(toUtf8Bytes(JSON.stringify(manifest(snapshot))));

export function capacity(counts, pioneerLimit = 4n, operativeLimit = 10n, paidSupply = 6166n) {
  requireValid(pioneerLimit > 0n && pioneerLimit % 2n === 0n && operativeLimit > 0n, 'Pioneer requires a positive even cap; Operative requires a positive cap.');
  const pioneer = BigInt(counts.pioneer) * pioneerLimit;
  const operative = BigInt(counts.pioneer + counts.operative) * operativeLimit;
  const total = pioneer + operative;
  requireValid(total <= paidSupply, `GTD allocations need ${total} keys; only ${paidSupply} paid keys are available.`);
  return { pioneer, operative, total, unreserved: paidSupply - total };
}

export function buildSnapshot(sources, frozenAt, limits = {}) {
  requireValid(typeof frozenAt === 'string' && Number.isFinite(Date.parse(frozenAt)) && new Date(frozenAt).toISOString() === frozenAt, 'Use an explicit ISO UTC freeze timestamp.');
  const assigned = new Map(), sourceHashes = {}, counts = { pioneer: 0, operative: 0, recruit: 0 };
  let duplicateRows = 0;
  tiers.forEach((tier, index) => {
    const name = `${tier}.csv`;
    requireValid(sources[name] !== undefined, `Missing ${name}. Provide all three CSVs, including empty lists.`);
    sourceHashes[name] = sha256(bytes(sources[name]));
    for (const address of parseCSV(sources[name], name)) {
      if (assigned.has(address)) duplicateRows++;
      else { assigned.set(address, index + 1); counts[tier]++; }
    }
  });
  requireValid(assigned.size <= 20000, 'Split out invalid data: snapshots support at most 20,000 unique wallets.');
  capacity(counts, limits.pioneer, limits.operative, limits.paidSupply);
  const entries = [...assigned].map(([address, tier]) => ({ key: lookupKey(address), tier, leaf: leafFor(address, tier) }));
  const { root, levels } = treeFor(entries.map(entry => entry.leaf));
  const indices = new Map(levels[0].map((leaf, i) => [leaf, i]));
  const proofs = {};
  for (const entry of entries.sort((a, b) => a.key.localeCompare(b.key))) {
    let index = indices.get(entry.leaf); const proof = [];
    for (const level of levels.slice(0, -1)) {
      if ((index ^ 1) < level.length) proof.push(level[index ^ 1]);
      index = Math.floor(index / 2);
    }
    proofs[entry.key] = { tier: entry.tier, leaf: entry.leaf, proof };
  }
  const snapshot = { schemaVersion: 1, frozenAt, sourceHashes, root, counts, proofs };
  snapshot.snapshotHash = snapshotDigest(snapshot);
  validateSnapshot(snapshot);
  return { snapshot, duplicateRows };
}

export function validateSnapshot(snapshot) {
  requireValid(snapshot?.schemaVersion === 1 && hashPattern.test(snapshot.root), 'Unsupported or malformed allowlist snapshot.');
  requireValid(typeof snapshot.frozenAt === 'string' && Number.isFinite(Date.parse(snapshot.frozenAt)) && new Date(snapshot.frozenAt).toISOString() === snapshot.frozenAt, 'Invalid snapshot freeze timestamp.');
  requireValid(tiers.every(tier => hashPattern.test(snapshot.sourceHashes?.[`${tier}.csv`]) && Number.isSafeInteger(snapshot.counts?.[tier]) && snapshot.counts[tier] >= 0), 'Invalid CSV hashes or tier counts.');
  const entries = Object.entries(snapshot.proofs || {});
  requireValid(entries.length <= 20000, 'Snapshot exceeds 20,000 wallets.');
  const counts = [0, 0, 0], leaves = new Set();
  for (const [key, entry] of entries) {
    requireValid(hashPattern.test(key) && [1, 2, 3].includes(entry.tier) && hashPattern.test(entry.leaf) && Array.isArray(entry.proof) && entry.proof.length <= 32 && entry.proof.every(item => hashPattern.test(item)), 'Malformed proof entry.');
    requireValid(!leaves.has(entry.leaf), 'Duplicate Merkle leaf.'); leaves.add(entry.leaf);
    requireValid(entry.proof.reduce(pairHash, entry.leaf) === snapshot.root, 'A proof does not match the snapshot root.');
    counts[entry.tier - 1]++;
  }
  requireValid(tiers.every((tier, index) => counts[index] === snapshot.counts[tier]), 'Tier counts do not match proof entries.');
  requireValid(treeFor([...leaves]).root === snapshot.root, 'Snapshot entries do not reproduce the Merkle root.');
  requireValid(snapshotDigest(snapshot) === snapshot.snapshotHash, 'Snapshot hash mismatch.');
  return snapshot;
}

export function proofFor(snapshot, address) {
  const entry = snapshot.proofs[lookupKey(address)];
  if (!entry) return null;
  requireValid(leafFor(address, entry.tier) === entry.leaf && entry.proof.reduce(pairHash, entry.leaf) === snapshot.root, 'This wallet proof is invalid. Rebuild from the frozen CSVs.');
  return entry;
}

export function checkerScript(snapshot) {
  validateSnapshot(snapshot);
  const lists = Object.fromEntries(tiers.map((tier, index) => [tier, Object.entries(snapshot.proofs).filter(([, entry]) => entry.tier === index + 1).map(([key]) => key.slice(2)).sort()]));
  return `window.NM=window.NM||{};\nNM.checkData=${JSON.stringify({ frozen: snapshot.frozenAt, ...lists })};\n`;
}
