import { buildSnapshot, capacity, checkerScript, tiers, validateSnapshot } from './allowlist.js';
import { deadlineUTC } from './model.js';
import initial from './allowlist.json';

const $ = selector => document.querySelector(selector);
let loaded = validateSnapshot(initial);
let duplicateRows = 0;
export const currentSnapshot = () => loaded;

function download(name, content, type) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement('a'); link.href = url; link.download = name; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

export function renderAllowlist(state) {
  const list = $('#snapshot-details'); list.replaceChildren();
  const entries = [['FREEZE / UTC', loaded.frozenAt], ['UNIQUE WALLETS', tiers.map(tier => `${tier}: ${loaded.counts[tier]}`).join(' · ')], ['MERKLE ROOT', loaded.root], ['SNAPSHOT HASH', loaded.snapshotHash], ...Object.entries(loaded.sourceHashes).map(([file, hash]) => [`SHA-256 / ${file}`, hash])];
  for (const [key, value] of entries) {
    const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = key; dd.textContent = value; list.append(dt, dd);
  }
  let allocation;
  try {
    const budget = capacity(loaded.counts, state?.phases?.[0].limit, state?.phases?.[1].limit, state?.maxPaid);
    allocation = `Full-list budget at these caps: ${budget.total} guaranteed keys (${budget.pioneer} Pioneer + ${budget.operative} Operative). ${budget.unreserved} initially unreserved. Actual open guarantees: ${state?.reserved ?? 0n}.`;
  } catch (cause) { allocation = cause.message; }
  $('#snapshot-summary').textContent = `${state?.snapshotMatches ? 'Matches the on-chain snapshot.' : 'This snapshot is not loaded on the selected contract.'} ${allocation} ${duplicateRows ? `${duplicateRows} repeated rows removed.` : ''}`;
}

export function mountAllowlist({ getState, refresh, review, error, notice }) {
  $('#snapshot-date').value = new Date().toISOString().slice(0, 19);
  $('#csv-form').addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const files = [...$('#csv-files').files];
      if (files.length !== 3 || new Set(files.map(file => file.name)).size !== 3 || files.some(file => !tiers.some(tier => file.name === `${tier}.csv`))) throw new Error('Select exactly pioneer.csv, operative.csv and recruit.csv.');
      if (files.some(file => file.size > 3_000_000)) throw new Error('Each CSV must be smaller than 3 MB.');
      const sources = Object.fromEntries(await Promise.all(files.map(async file => [file.name, new Uint8Array(await file.arrayBuffer())])));
      const state = getState();
      const result = buildSnapshot(sources, new Date(Number(deadlineUTC($('#snapshot-date').value)) * 1000).toISOString(), { pioneer: state?.phases?.[0].limit, operative: state?.phases?.[1].limit, paidSupply: state?.maxPaid });
      loaded = result.snapshot; duplicateRows = result.duplicateRows;
      renderAllowlist(state); await refresh({ force: true, quiet: true });
      notice('Snapshot generated. Download both files and review the on-chain load before starting Pioneer.');
    } catch (cause) { error(cause); }
  });
  $('#snapshot-file').addEventListener('change', async () => {
    try {
      const file = $('#snapshot-file').files[0]; if (!file) return;
      if (file.size > 20_000_000) throw new Error('Snapshot must be smaller than 20 MB.');
      loaded = validateSnapshot(JSON.parse(await file.text())); duplicateRows = 0;
      renderAllowlist(getState()); await refresh({ force: true, quiet: true });
      notice('Snapshot imported and proofs validated. Compare its root with the selected contract.');
    } catch (cause) { error(cause); }
  });
  $('#download-snapshot').addEventListener('click', () => download('allowlist.json', JSON.stringify(loaded, null, 2) + '\n', 'application/json'));
  $('#download-checker').addEventListener('click', () => download('check-data.js', checkerScript(loaded), 'text/javascript'));
  $('#snapshot-form').addEventListener('submit', event => {
    event.preventDefault();
    Promise.resolve().then(() => {
      const state = getState(); validateSnapshot(loaded);
      if (state?.version !== 4n) throw new Error('Select a v4 contract.');
      capacity(loaded.counts, state.phases[0].limit, state.phases[1].limit, state.maxPaid - state.paid);
      return review({ kind: 'allowlist', label: 'Load frozen allowlist snapshot', method: 'configureAllowlist', args: [loaded.root, loaded.snapshotHash, ...tiers.map(tier => BigInt(loaded.counts[tier]))], expectedPhase: 0n, warning: 'Review the CSV counts, hashes and GTD budget. Starting Pioneer permanently freezes this membership snapshot. Publish the matching allowlist.json and check-data.js to the frontend.' });
    }).catch(error);
  });
}
