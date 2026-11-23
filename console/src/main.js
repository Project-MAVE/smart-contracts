import './styles.css';
import { BrowserProvider, Contract, formatEther, parseEther, getAddress, ZeroHash } from 'ethers';
import { abi, reader, snapshot } from './chain.js';
import { address, friendlyError, gate, phase, phaseNames, remaining, refundIds, settleIds, tokenRange, unsigned, viaSafe } from './model.js';
import { approveCall, batchCall, batchCalldata, batchFile, confirmations, executeCall, executionSignatures, launchSteps, ownerStep, safeGasNeeded, safeLinks, safeTransaction, TRANSACTION_GAS_CAP, TREASURY_BLOCK } from './safe.js';
import { currentSnapshot, mountAllowlist, renderAllowlist } from './allowlist-ui.js';
import deployment from './deployment.json';

const $ = selector => document.querySelector(selector);
const all = selector => [...document.querySelectorAll(selector)];
const text = (selector, value) => { $(selector).textContent = String(value); };
const local = import.meta.env.DEV && import.meta.env.VITE_CHAIN_ID === '31337';
const chainId = local ? 31337 : 11155111;
const chainHex = `0x${chainId.toString(16)}`;
const networkName = local ? 'LOCAL ANVIL' : 'ETH SEPOLIA';
const rpcUrls = local ? [import.meta.env.VITE_RPC_URL || 'http://127.0.0.1:8547'] : [
  'https://ethereum-sepolia-rpc.publicnode.com', 'https://rpc.sepolia.ethpandaops.io',
];
const deployments = local ? [{ address: getAddress(import.meta.env.VITE_CONTRACT_ADDRESS), label: 'Local / integration test' }] : [
  ...(deployment.address ? [deployment] : []),
];
let selected = deployments[0];
let provider = reader(rpcUrls[0], chainId);
let rpcIndex = 0;
let state = null;
let account = null;
let walletChain = null;
let injected = null;
let generation = 0;
let refreshedAt = 0;
let refreshing = false;
let busy = false;
let draft = null;
let pending = null;
let walletEventsInstalled = false;
const storageKey = () => `ryodan:pending:${chainId}:${selected.address.toLowerCase()}`;
const explorer = (type, value) => local ? null : `https://sepolia.etherscan.io/${type}/${value}`;
const short = value => `${value.slice(0, 6)}…${value.slice(-4)}`;
const utc = seconds => new Date(Number(seconds) * 1000).toISOString().replace('T', ' ').replace('.000Z', ' UTC');
const stale = () => !refreshedAt || performance.now() - refreshedAt > 45000;
const context = () => ({ busy, pending, account, correctChain: walletChain === chainId, stale: stale() });

function download(name, content) {
  const url = URL.createObjectURL(new Blob([content], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = name; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

function notice(message, kind = '') {
  text('#notice', message);
  $('#notice').className = `notice ${kind}`;
}

function log(kind, message, hash) {
  const row = document.createElement('li');
  const time = document.createElement('span');
  time.className = 'log-time';
  time.textContent = new Date().toISOString().slice(11, 19) + 'Z';
  const label = document.createElement('span');
  label.className = `log-kind ${kind === 'ERROR' ? 'error' : ''}`;
  label.textContent = kind;
  const body = document.createElement('span');
  body.textContent = message;
  const href = hash && explorer('tx', hash);
  if (href) {
    const link = document.createElement('a');
    link.href = href; link.target = '_blank'; link.rel = 'noopener noreferrer';
    link.textContent = ` ${short(hash)} ↗`;
    body.append(link);
  }
  row.append(time, label, body);
  $('#activity-log').prepend(row);
  while ($('#activity-log').children.length > 30) $('#activity-log').lastElementChild.remove();
}

function error(error) {
  const message = friendlyError(error);
  notice(message, 'error');
  log('ERROR', message);
}

function setPending(value) {
  pending = value;
  try {
    if (value) localStorage.setItem(storageKey(), JSON.stringify(value));
    else localStorage.removeItem(storageKey());
  } catch { notice('Browser storage unavailable. Keep this page open while your transaction is pending.', 'warning'); }
  renderPending();
}

function loadPending() {
  pending = null;
  try {
    const value = JSON.parse(localStorage.getItem(storageKey()) || 'null');
    if (value && /^0x[0-9a-f]{64}$/i.test(value.hash) && value.chainId === chainId && (value.contract || value.to)?.toLowerCase() === selected.address.toLowerCase()) pending = value;
  } catch { /* Malformed browser state is ignored; it never authorizes a write. */ }
  renderPending();
}

function renderPending() {
  $('#pending-box').hidden = !pending;
  if (pending) text('#pending-label', `Pending confirmation: ${pending.label} · ${pending.hash}. Keep this hash; do not submit the action again.`);
  renderControls();
}

function renderControls() {
  all('[data-action]').forEach(button => {
    const reason = gate(button.dataset.action, state, context());
    button.disabled = Boolean(reason);
    button.title = reason;
  });
  all('[data-hint]').forEach(hint => {
    hint.textContent = gate(hint.dataset.hint, state, context()) || (viaSafe(hint.dataset.hint, state, account) ? 'Ready. Review the call, then download its batch for the Safe.' : 'Ready. Review the transaction before signing.');
  });
  all('[data-safe-step]').forEach(button => {
    const reason = gate(button.dataset.kind, state, context());
    button.disabled = Boolean(reason);
    button.title = reason;
    button.nextElementSibling.textContent = reason;
  });
  $('#deployment').disabled = busy || Boolean(pending);
  $('#connect').disabled = busy;
  $('#confirm-transaction').disabled = busy || !draft || draft.owner?.step === 'wait';
  $('#download-batch').disabled = busy || !draft;
}

function render() {
  if (!state) { renderControls(); return; }
  const s = state;
  text('#metric-minted', (s.paid + s.treasuryMinted).toLocaleString('en-US'));
  text('#metric-balance', formatEther(s.balance));
  text('#metric-phase', phase(s));
  text('#phase-detail', s.soldOut ? 'TRANSFERS UNLOCKED' : s.choiceWindowOpen ? `MINTERS DECIDE UNTIL ${utc(s.deadline + s.choiceWindow)}` : s.refundsAvailable ? 'REFUNDS AVAILABLE' : `${phaseNames[Number(s.currentPhase)]} · ${s.limit} / WALLET / PHASE`);
  text('#metric-metadata', s.soldOut ? 'NFT SET' : s.totalKept ? 'SBT + NFT' : 'SBT SET');
  text('#metadata-detail', s.soldOut ? 'EVERY KEY UNLOCKED' : `${s.totalKept} KEPT AS NFT`);
  text('#mint-price', s.price ? formatEther(s.price) : '—');
  renderPhases(s);
  renderAllowlist(s);
  const total = s.maxPaid + s.maxTreasury;
  text('#metric-supply', `OF ${total.toLocaleString('en-US')} KEYS`);
  text('#hero-supply', `RYODAN / 旅団 / ${total.toLocaleString('en-US')} KEYS`);
  const [firstId, lastId] = tokenRange(s);
  for (const id of ['#refund-id', '#inspect-id']) {
    $(id).min = String(firstId); $(id).max = String(lastId);
    if (Number($(id).value) < Number(firstId)) $(id).value = String(firstId);
  }
  renderV6(s);
  for (const id of ['#mint-amount', '#wallet-limit']) $(id).max = String(s.maxPaid);
  $('#paid-progress').max = Number(s.maxPaid);
  text('#mint-unit-note', s.currentPhase === 2n && s.proof?.tier === 1 ? 'Pioneers mint up to the Pioneer limit across Pioneer and Operative together.' : 'Mint in the active phase. Token IDs are assigned in sequence.');
  $('#batch-refund-panel').hidden = location.hash !== '#refund';
  text('#paid-count', `${s.paid.toLocaleString('en-US')} / ${s.maxPaid.toLocaleString('en-US')}`);
  text('#treasury-count', `${s.treasuryMinted} / ${s.maxTreasury}`);
  $('#paid-progress').value = Number(s.paid);
  $('#treasury-progress').value = Number(s.treasuryMinted);
  text('#deadline-display', utc(s.deadline));
  const remainingSeconds = s.deadline - s.timestamp;
  text('#deadline-remaining', remainingSeconds >= 0n ? `${remainingSeconds / 86400n}d ${remainingSeconds % 86400n / 3600n}h ${remainingSeconds % 3600n / 60n}m remaining at last block` : 'Deadline passed. Sale outcome is final.');
  text('#allowance', account ? `${remaining(s)} keys` : 'Connect wallet');
  text('#withdraw-balance', formatEther(s.balance));
  text('#refund-count', s.refunded);
  text('#live-supply', s.supply);
  text('#identity-address', account || 'Not connected');
  text('#identity-roles', account ? [s.admin && 'Administrator', s.treasuryRole && 'Treasury', s.safe?.owner && 'Safe owner', 'Holder / minter'].filter(Boolean).join(' · ') : 'Read-only');
  text('#block-label', `BLOCK ${s.block.toLocaleString('en-US')} / ${utc(s.timestamp).slice(11)}`);
  text('#sync-status', '● SYNCHRONIZED');
  text('#reserve-label', s.soldOut ? 'TREASURY WITHDRAWABLE' : 'SALE / REFUND RESERVES');
  const treasurySafe = viaSafe('treasuryMint', s, account);
  if (!$('#treasury-recipient').value && (treasurySafe || account)) $('#treasury-recipient').value = treasurySafe ? s.safe.address : account;
  $('#treasury-amount').max = String(treasurySafe ? TREASURY_BLOCK : 50n);
  text('#treasury-amount-label', treasurySafe ? `QUANTITY (UP TO ${TREASURY_BLOCK} PER SAFE TRANSACTION)` : 'QUANTITY (UP TO 50 PER TRANSACTION)');
  renderSafe(s);
  updateTotal();
  renderControls();
}

let safeSignature = '';
const ownerVerbs = { approve: 'Approve as owner', execute: 'Execute as owner', wait: 'Approved · waiting for another owner', connect: 'Prepare for the Safe', observe: 'Prepare for the Safe' };

function stepAction(id, s) {
  if (id === 'allowlist') {
    const loaded = currentSnapshot();
    return { kind: 'allowlist', label: 'Load frozen allowlist snapshot', method: 'configureAllowlist', args: [loaded.root, loaded.snapshotHash, BigInt(loaded.counts.pioneer), BigInt(loaded.counts.operative), BigInt(loaded.counts.recruit)], expectedPhase: 0n };
  }
  if (id === 'treasury') {
    const left = s.maxTreasury - s.treasuryMinted;
    const amount = left < TREASURY_BLOCK ? left : TREASURY_BLOCK;
    const first = s.firstTokenId + s.paid + s.treasuryMinted;
    return { kind: 'treasuryMint', label: `Mint treasury keys ${first}-${first + amount - 1n}`, method: 'treasuryMint', args: [amount, s.safe.address], warning: `The ${amount} keys go to the Safe itself.` };
  }
  const current = Number(s.currentPhase);
  if (current && s.paused) return { kind: 'pause', label: `Resume ${phaseNames[current]}`, method: 'setMintPaused', args: [false], expectedPhase: s.currentPhase };
  return { kind: 'advance', label: `Open ${phaseNames[current + 1]}`, method: 'advancePhase', args: [], expectedPhase: s.currentPhase, followUp: { method: 'setMintPaused', args: [false] },
    warning: `Irreversible: ${current ? `${phaseNames[current]} closes for good` : 'the allowlist, prices and limits freeze'}. Minting in ${phaseNames[current + 1]} starts as soon as the Safe transaction is executed.` };
}

// Owner approvals already on chain for the next open step, so a second owner sees at once that it only has to execute.
async function stepApprovals(s, target) {
  const step = launchSteps(s, currentSnapshot()).find(item => !item.done);
  if (!step || gate({ allowlist: 'allowlist', treasury: 'treasuryMint' }[step.id] || (s.currentPhase > 0n && s.paused ? 'pause' : 'advance'), s, { busy: false, pending: null, stale: false })) return null;
  const action = stepAction(step.id, s);
  const calls = [action, ...(action.followUp ? [action.followUp] : [])].map(call => batchCall(abi, target, call.method, call.args));
  return { step: step.id, ...await confirmations(provider, s.safe, safeTransaction(s.safe, calls), { blockTag: s.block }) };
}

function renderSafe(s) {
  $('#safe-section').hidden = !s.safe;
  if (!s.safe) { safeSignature = ''; return; }
  const { safe } = s;
  const steps = launchSteps(s, currentSnapshot());
  const signature = JSON.stringify([selected.address, safe.address, safe.owners, String(safe.threshold), safe.treasury, String(safe.keys), safe.owner, account, walletChain, safe.pending?.step, safe.pending?.hash, safe.pending?.approved, steps]);
  if (signature === safeSignature) return;
  safeSignature = signature;
  const links = safeLinks(chainId, safe.address);
  text('#safe-tag', `${safe.threshold} OF ${safe.owners.length} OWNERS SIGN`);
  text('#safe-policy', `${safe.threshold} OWNERS PER ACTION`);
  text('#safe-address', safe.address);
  for (const [id, href] of [['#safe-address', links?.home], ['#safe-builder', links?.builder], ['#safe-queue', links?.queue]]) {
    if (href) $(id).href = href; else $(id).removeAttribute('href');
    if (id !== '#safe-address') $(id).hidden = !href;
  }
  text('#safe-owners', `${safe.owners.join('\n')}\n${!account ? 'Connect the wallet of one of these owners to approve or execute a step.' : account === safe.address ? 'The connected wallet is this Safe.' : safe.owner ? 'The connected wallet is one of the owners.' : 'The connected wallet is not an owner.'}`);
  text('#safe-roles', [`Administrator`, safe.treasury && 'Treasury', `holds ${safe.keys} key${safe.keys === 1n ? '' : 's'}`, `Safe ${safe.version}`].filter(Boolean).join(' · '));
  const kinds = { allowlist: 'allowlist', treasury: 'treasuryMint', open: s.currentPhase > 0n && s.paused ? 'pause' : 'advance' };
  const direct = account && account !== safe.address && walletChain === chainId;
  const asSafe = account === safe.address && walletChain === chainId;
  $('#safe-steps').replaceChildren(...steps.map((step, index) => {
    const item = document.createElement('li');
    item.className = `safe-step ${step.status.toLowerCase()}`;
    const approved = safe.pending?.step === step.id ? safe.pending.approved : [];
    const approvals = approved.length ? ` Approved by ${approved.map(short).join(', ')}: ${approved.length} of ${safe.threshold}.` : '';
    for (const [tag, value, className] of [['span', `0${index + 1} / ${step.status}`, 'phase-state'], ['strong', step.title, ''], ['p', step.detail + approvals, 'form-note']]) {
      const node = document.createElement(tag); node.textContent = value; node.className = className; item.append(node);
    }
    if (!step.done) {
      const button = document.createElement('button');
      const left = s.maxTreasury - s.treasuryMinted;
      button.type = 'button'; button.className = `button wide ${step.status === 'NEXT' ? 'primary' : ''}`; button.dataset.safeStep = step.id; button.dataset.kind = kinds[step.id];
      button.textContent = `${asSafe ? 'Send to the Safe wallet' : ownerVerbs[direct ? ownerStep(safe, approved, account) : 'connect']}${step.id === 'treasury' ? ` · next ${left < TREASURY_BLOCK ? left : TREASURY_BLOCK} keys` : ''} ↗`;
      const hint = document.createElement('p'); hint.className = 'action-hint';
      item.append(button, hint);
    }
    return item;
  }));
}

function safeStep(id) {
  if (!state?.safe) throw new Error('This contract is not administered by a Safe.');
  if (id === 'allowlist') return $('#snapshot-form').requestSubmit();
  return review(stepAction(id, state));
}

function renderV6(s) {
  text('#sbt-base', s.sbtBaseURI);
  text('#nft-base', s.nftBaseURI);
  text('#metadata-example', `${s.sbtBaseURI}1.json`);
  text('#metadata-rule', s.soldOut ? 'NFT set for every key: the collection sold out.' : `SBT set while locked; NFT set for the ${s.totalKept} kept key${s.totalKept === 1n ? '' : 's'} and for every key after a sellout.`);
  text('#kept-balance', formatEther(s.keptFunds - s.keptWithdrawn));
  text('#kept-count', s.totalKept);
  text('#pending-refund', formatEther(s.pendingRefund));
  const hours = s.choiceWindow / 3600n;
  text('#choice-hours', hours);
  const closes = s.deadline + s.choiceWindow;
  text('#choice-window', s.soldOut ? 'Not needed: sold out' : s.timestamp <= s.deadline ? `${hours} h after the deadline` : s.choiceWindowOpen ? `Open until ${utc(closes)}` : `Closed at ${utc(closes)}`);
}

function fillPhaseConfiguration() {
  const config = state?.phases?.[Number($('#phase').value) - 1];
  if (!config) return;
  $('#phase-price').value = formatEther(config.price);
  $('#wallet-limit').value = String(config.limit);
  $('#phase-form').dataset.loaded = selected.address;
  $('#phase-form').dataset.dirty = 'false';
}

function renderPhases(s) {
  const current = Number(s.currentPhase);
  for (const track of all('.phase-track')) {
    track.replaceChildren();
    for (const config of s.phases) {
      const closed = config.id < current;
      const active = config.id === current;
      const step = document.createElement('div');
      step.className = `phase-step ${closed ? 'closed' : active ? 'current' : ''}`;
      for (const [tag, value, className] of [
        ['span', `0${config.id} / ${closed ? 'CLOSED' : active ? s.soldOut ? 'SOLD OUT' : s.timestamp > s.deadline ? 'EXPIRED' : s.paused ? 'PAUSED' : 'ACTIVE' : 'UPCOMING'}`, 'phase-state'],
        ['strong', phaseNames[config.id], ''],
        ['span', `${formatEther(config.price)} ETH · ${config.limit} / wallet`, ''],
        ['span', `${config.id <= 2 ? 'Guaranteed' : config.id === 3 ? 'Allowlist · FCFS' : 'Public · FCFS'} · ${config.minted} minted`, ''],
      ]) {
        const node = document.createElement(tag); node.textContent = value; node.className = className; step.append(node);
      }
      track.append(step);
    }
  }
  text('#phase-command-title', `${phaseNames[current]}${current ? ` / ${s.soldOut ? 'sold out' : s.timestamp > s.deadline ? 'expired' : s.paid === s.maxPaid ? 'allocation exhausted' : s.paused ? 'paused' : 'minting'}` : ''}`);
  text('#gtd-reserve', `${s.reserved} keys reserved for guarantees · ${s.maxPaid - s.paid} paid keys unminted. Civilian receives the remainder after Recruit.`);
  text('#advance-label', current < 4 ? `Review ${current ? 'advance to' : 'start'} ${phaseNames[current + 1]} ↗` : 'Final phase reached');
  text('#pause-label', `Review ${s.paused ? 'resume' : 'pause'} ↗`);
  [...$('#phase').options].forEach(option => { option.disabled = Number(option.value) < current; });
  if (Number($('#phase').value) < current) { $('#phase').value = String(current); fillPhaseConfiguration(); }
  if ($('#phase-form').dataset.loaded !== selected.address || $('#phase-form').dataset.dirty !== 'true') fillPhaseConfiguration();
}

async function refresh({ force = false, quiet = false } = {}) {
  if (!selected || (refreshing && !force)) return false;
  const current = ++generation;
  const target = selected.address;
  const identity = account;
  refreshing = true;
  $('#refresh').disabled = true;
  text('#sync-status', 'READING…');
  try {
    let next;
    try { next = await snapshot(provider, target, identity, chainId, currentSnapshot()); }
    catch (first) {
      if (rpcUrls.length < 2 || first.code === 'UNSUPPORTED_CONTRACT') throw first;
      rpcIndex = (rpcIndex + 1) % rpcUrls.length;
      const previousProvider = provider;
      provider = reader(rpcUrls[rpcIndex], chainId);
      previousProvider.destroy();
      next = await snapshot(provider, target, identity, chainId, currentSnapshot());
    }
    if (next.safe) next.safe.pending = await stepApprovals(next, target).catch(() => null);
    if (current !== generation || target !== selected.address || identity !== account) return false;
    state = next;
    refreshedAt = performance.now();
    render();
    if (!quiet) notice(account ? `Connected as ${short(account)}. ${state.admin ? 'Administrator access verified.' : state.safe?.owner ? `Safe owner verified: approve or execute the steps of Safe ${short(state.safe.address)}.` : 'Read access and holder operations available.'}` : state.safe ? 'Read-only session. Connect the wallet of a Safe owner to operate, or any wallet to mint.' : 'Read-only session. Connect your wallet to mint or manage this contract.');
    return true;
  } catch (cause) {
    if (current === generation) {
      state = null;
      const unsupported = cause?.code === 'UNSUPPORTED_CONTRACT';
      text('#sync-status', unsupported ? 'UNSUPPORTED CONTRACT' : 'RPC OFFLINE');
      notice(unsupported ? `${cause.message} Every action is disabled.` : `Unable to refresh chain state. Displayed metrics may be stale. ${friendlyError(cause)}`, 'error');
      renderControls();
    }
    return false;
  } finally {
    if (current === generation) { refreshing = false; $('#refresh').disabled = false; }
  }
}

function updateTotal() {
  try { text('#mint-total', state?.price ? `${formatEther(state.price * unsigned($('#mint-amount').value, state?.maxPaid || 6166n, 1n))} ETH + gas` : 'Awaiting active phase'); }
  catch { text('#mint-total', 'Enter a valid quantity'); }
}

function walletChanged() {
  ++generation;
  state = null;
  draft = null;
  $('#review-dialog').close();
  text('#connect', account ? walletChain === chainId ? short(account) : 'Switch network ↗' : 'Connect wallet ↗');
  text('#identity-address', account || 'Not connected');
  text('#identity-roles', account ? 'Checking on-chain privileges…' : 'Read-only');
  renderControls();
  void refresh({ force: true });
}

async function connect() {
  injected = window.ethereum;
  if (!injected?.request) throw new Error('Install or open an Ethereum browser wallet, then reconnect. On mobile, open this site inside your wallet browser.');
  if (!walletEventsInstalled) {
    injected.on?.('accountsChanged', values => { account = values[0] ? getAddress(values[0]) : null; walletChanged(); });
    injected.on?.('chainChanged', value => { walletChain = Number(value); walletChanged(); });
    injected.on?.('disconnect', () => { account = null; walletChain = null; walletChanged(); });
    walletEventsInstalled = true;
  }
  const accounts = await injected.request({ method: 'eth_requestAccounts' });
  account = accounts[0] ? getAddress(accounts[0]) : null;
  if (!account) throw new Error('The wallet did not provide an account.');
  walletChain = Number(await injected.request({ method: 'eth_chainId' }));
  walletChanged();
  if (walletChain !== chainId) {
    try { await injected.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: chainHex }] }); }
    catch (cause) {
      // Rabby reports an unknown chain as an internal error that wraps code 4902.
      if (!(cause?.code === 4902 || cause?.data?.originalError?.code === 4902 || /unrecognized chain/i.test(cause?.message || '')) || local) throw cause;
      await injected.request({ method: 'wallet_addEthereumChain', params: [{ chainId: chainHex, chainName: 'Ethereum Sepolia', nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 }, rpcUrls, blockExplorerUrls: ['https://sepolia.etherscan.io'] }] });
      await injected.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: chainHex }] });
    }
  }
  walletChain = Number(await injected.request({ method: 'eth_chainId' }));
  walletChanged();
}

async function signerForCurrentWallet() {
  if (!injected || !account) throw new Error('Connect your wallet first.');
  const [actualChain, accounts] = await Promise.all([
    injected.request({ method: 'eth_chainId' }), injected.request({ method: 'eth_accounts' }),
  ]);
  if (Number(actualChain) !== chainId || accounts[0]?.toLowerCase() !== account.toLowerCase()) throw new Error('Wallet or network changed. Reconnect and review the action again.');
  return new BrowserProvider(injected, 'any').getSigner(account);
}

function validate(action) {
  const reason = gate(action.kind, state, { ...context(), busy: false });
  if (reason) throw new Error(reason);
  if (['mint', 'mintWithProof'].includes(action.method) && (action.args[1] !== state.currentPhase || action.args[2] !== state.price)) throw new Error('Mint phase or price changed. Review a new quote.');
  if (action.expectedPhase !== undefined && action.expectedPhase !== state.currentPhase) throw new Error('Active phase changed. Review the command again.');
  if (['mint', 'mintWithProof'].includes(action.method) && action.args[0] > remaining(state)) throw new Error('Quantity exceeds your remaining mint allowance.');
  if (action.method === 'treasuryMint' && action.args[0] > state.maxTreasury - state.treasuryMinted) throw new Error('Quantity exceeds the remaining treasury allocation.');
}

async function review(action) {
  if (busy || pending) throw new Error('Finish the current transaction before starting another.');
  busy = true;
  renderControls();
  try {
    if (!await refresh({ force: true, quiet: true })) throw new Error('Unable to obtain fresh chain state.');
    action.value = ['mint', 'mintWithProof'].includes(action.method) ? state.price * action.args[0] : 0n;
    validate(action);
    const reviewAccount = account;
    const reviewAddress = selected.address;
    const safe = viaSafe(action.kind, state, account) ? state.safe : null;
    const keys = new Contract(selected.address, abi, safe ? provider : await signerForCurrentWallet());
    const sender = safe ? { from: safe.address } : {};
    if (action.kind === 'refund' && state.choiceWindowOpen) {
      const ids = action.method === 'refundBatch' ? action.args[0] : [action.args[0]];
      const minters = await Promise.all(ids.map(id => keys.originalMinter(id, { blockTag: state.block })));
      const foreign = ids.filter((id, index) => minters[index].toLowerCase() !== account.toLowerCase());
      if (foreign.length) throw new Error(`During the keep-or-refund window only the original minter can refund a key. Not yours: ${foreign.join(', ')}.`);
    }
    if (action.method === 'settle') {
      const sum = async ids => (await Promise.all(ids.map(id => keys.mintPayment(id, { blockTag: state.block })))).reduce((a, b) => a + b, 0n);
      const [keep, refund] = action.args;
      action.warning = `Keep ${keep.length} key(s) as transferable NFTs (${formatEther(await sum(keep))} ETH goes to the treasury) and refund ${refund.length} key(s): they are burned and ${formatEther(await sum(refund))} ETH returns to your wallet. Keeping is final.`;
    }
    if (action.method === 'burnTreasuryKeys') {
      const minters = await Promise.all(action.args[0].map(id => keys.originalMinter(id, { blockTag: state.block })));
      const paid = action.args[0].filter((id, index) => minters[index] !== '0x0000000000000000000000000000000000000000');
      if (paid.length) throw new Error(`Only free treasury keys can be burned. Paid keys: ${paid.join(', ')}.`);
    }
    if (action.kind === 'refund') {
      const ids = action.method === 'refundBatch' ? action.args[0] : [action.args[0]];
      const paid = (await Promise.all(ids.map(id => keys.mintPayment(id, { blockTag: state.block })))).reduce((a, b) => a + b, 0n);
      action.warning = `This burns the selected key(s) and returns their original payments, totaling ${formatEther(paid)} ETH. Default recipients are the original minters. Network fees are separate.`;
    }
    await keys[action.method].staticCall(...action.args, { value: action.value, ...sender });
    const gas = await keys[action.method].estimateGas(...action.args, { value: action.value, ...sender });
    if (reviewAccount !== account || reviewAddress !== selected.address || (!safe && walletChain !== chainId)) throw new Error('Wallet context changed during simulation. Review the action again.');
    if (safe && safeGasNeeded(gas) > TRANSACTION_GAS_CAP) throw new Error(`Through the Safe this call needs about ${safeGasNeeded(gas).toLocaleString('en-US')} gas, above the ${TRANSACTION_GAS_CAP.toLocaleString('en-US')} a single transaction may use. Reduce the quantity.`);
    const calls = safe ? [action, ...(action.followUp ? [action.followUp] : [])].map(call => batchCall(abi, selected.address, call.method, call.args)) : null;
    let owner = null;
    if (safe) {
      const tx = safeTransaction(safe, calls);
      const seen = await confirmations(provider, safe, tx, { blockTag: state.block });
      owner = { tx, ...seen, step: walletChain === chainId ? ownerStep(safe, seen.approved, account) : 'connect' };
      if (['approve', 'execute'].includes(owner.step) && await provider.getBalance(account) === 0n) throw new Error('This owner wallet has no ETH on this network to pay for gas. Fund it, or let another owner act.');
      if (owner.step === 'execute') {
        const call = executeCall(safe, tx, executionSignatures(safe, seen.approved, account));
        await provider.call({ ...call, from: account });
        owner.gas = await provider.estimateGas({ ...call, from: account });
        if (owner.gas > TRANSACTION_GAS_CAP) throw new Error(`Executing this from the Safe needs ${owner.gas.toLocaleString('en-US')} gas, above the ${TRANSACTION_GAS_CAP.toLocaleString('en-US')} a single transaction may use. Reduce the quantity.`);
      }
    }
    if (reviewAccount !== account || reviewAddress !== selected.address) throw new Error('Wallet context changed during simulation. Review the action again.');
    draft = { ...action, account, address: selected.address, chainId, gas, generation, safe, calls, owner };
    text('#review-title', action.label);
    const fields = [ ['NETWORK', networkName + ` (${chainId})`], ['CONTRACT', selected.address],
      safe ? ['EXECUTED BY', `Safe ${safe.address}\n${safe.threshold} of ${safe.owners.length} owners sign`] : ['SIGNER', account],
      ...(safe ? [['OWNER APPROVALS', `${owner.approved.length} of ${safe.threshold} on chain${owner.approved.map(item => `\n${item}`).join('')}`], ['SAFE TRANSACTION', `nonce ${owner.nonce}\n${owner.hash}`]] : []),
      ['CALL', [action, ...(safe && action.followUp ? [action.followUp] : [])].map(call => `${call.method}(${call.args.map(v => Array.isArray(v) ? `[${v.length} values]` : String(v)).join(', ')})`).join('\nthen ')],
      ['ARGUMENTS', action.args.length ? action.args.map(v => Array.isArray(v) ? v.join('\n') : String(v)).join('\n') : 'None'],
      safe ? ['SIMULATED GAS', `${gas.toLocaleString('en-US')} from the Safe at block ${state.block}`] : ['PAYMENT', `${formatEther(action.value)} ETH + wallet-estimated network fee`],
      ...(safe ? calls.map((call, index) => [`CALLDATA ${index + 1} / ${calls.length}`, batchCalldata(call)]) : [['ESTIMATED GAS', gas.toString()]]) ];
    $('#review-details').replaceChildren();
    for (const [key, value] of fields) {
      const dt = document.createElement('dt'); dt.textContent = key;
      const dd = document.createElement('dd'); dd.textContent = value;
      $('#review-details').append(dt, dd);
    }
    const direct = safe && ['approve', 'execute', 'wait'].includes(owner.step);
    text('#review-note', !safe ? 'Verify these details before opening your wallet.' : {
      approve: 'Verify the call. Your wallet then approves this exact Safe transaction; another owner executes it.',
      execute: 'Verify the call. The approvals are complete with your wallet: it executes the Safe transaction now.',
      wait: 'You have already approved this Safe transaction. Another owner opens this step and executes it.',
    }[owner.step] || 'Verify the call. Connect the wallet of a Safe owner to approve it here, or download its batch for the Safe app.');
    text('#confirm-transaction', !safe ? 'Sign in wallet ↗' : { approve: `Approve as owner (${owner.approved.length + 1} of ${safe.threshold}) ↗`, execute: 'Execute from the Safe ↗', wait: 'Waiting for another owner' }[owner.step] || 'Download Safe batch ↓');
    $('#download-batch').hidden = !direct;
    text('#review-warning', safe ? `${(action.warning || '').replaceAll('your connected treasury wallet', 'the Safe')} The call succeeds when simulated from the Safe now.`.trim()
      : action.warning || 'The wallet displays the final network fee. State may change before this transaction is mined.');
    $('#review-dialog').showModal();
  } finally { busy = false; renderControls(); }
}

async function submit(asFile = false) {
  const action = draft;
  if (!action || busy) return;
  busy = true;
  $('#review-dialog').close();
  renderControls();
  notice('Rechecking the transaction against the latest block…');
  let submitted = false;
  try {
    if (action.account !== account || action.address !== selected.address || action.chainId !== chainId) throw new Error('The transaction context changed. Review it again.');
    if (!await refresh({ force: true, quiet: true })) throw new Error('Cannot confirm fresh state before signing.');
    validate(action);
    let request, label = action.label;
    if (action.safe) await new Contract(selected.address, abi, provider)[action.method].staticCall(...action.args, { from: action.safe.address });
    if (action.safe && !asFile && ['approve', 'execute'].includes(action.owner.step)) {
      const seen = await confirmations(provider, action.safe, action.owner.tx);
      if (seen.hash !== action.owner.hash) throw new Error('The Safe has executed another transaction since this review. Review the step again.');
      const step = ownerStep(action.safe, seen.approved, account);
      if (step !== action.owner.step) throw new Error('Owner approvals changed since this review. Review the step again.');
      const call = step === 'approve' ? approveCall(action.safe, seen.hash) : executeCall(action.safe, action.owner.tx, executionSignatures(action.safe, seen.approved, account));
      await provider.call({ ...call, from: account });
      const needed = await provider.estimateGas({ ...call, from: account });
      request = { ...call, value: 0n, gasLimit: needed * 120n / 100n > TRANSACTION_GAS_CAP ? TRANSACTION_GAS_CAP : needed * 120n / 100n };
      label = `${step === 'approve' ? `Owner approval ${seen.approved.length + 1} of ${action.safe.threshold}` : 'Safe execution'}: ${action.label}`;
    } else if (action.safe) {
      const file = batchFile({ chainId, safe: action.safe.address, name: action.label, description: `Ryodan Keys ${selected.address} on chain ${chainId}: ${action.calls.map(call => call.contractMethod.name).join(' then ')}.`, transactions: action.calls });
      download(`ryodan-safe-${action.label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}.json`, JSON.stringify(file, null, 2) + '\n');
      log('PREPARED', `${action.label} · batch for Safe ${short(action.safe.address)} downloaded`);
      notice(`Batch downloaded: ${action.label}. Drop it in the Safe Transaction Builder; ${action.safe.threshold} of ${action.safe.owners.length} owners sign and one executes. This page follows the chain and updates when it is mined.`);
      return;
    }
    const signer = await signerForCurrentWallet();
    if (!request) {
      const keys = new Contract(selected.address, abi, signer);
      await keys[action.method].staticCall(...action.args, { value: action.value });
      const gas = await keys[action.method].estimateGas(...action.args, { value: action.value });
      request = { to: selected.address, data: keys.interface.encodeFunctionData(action.method, action.args), value: action.value, gasLimit: gas * 120n / 100n };
    }
    if (state.safe && account === state.safe.address) {
      // A wallet that presents the Safe collects the owners' signatures on its side and may never answer this request.
      signer.sendTransaction({ ...request, chainId }).then(async sent => {
        log('SUBMITTED', label, sent.hash);
        const mined = await sent.wait(local ? 1 : 2, 120000);
        log(mined?.status === 1 ? 'CONFIRMED' : 'REVERTED', label, sent.hash);
        notice(mined?.status === 1 ? `${label} confirmed.` : 'The transaction reverted. Its state changes were rolled back.', mined?.status === 1 ? '' : 'error');
        await refresh({ force: true, quiet: true });
      }).catch(error);
      log('REQUESTED', `${label} · sent to the Safe wallet`);
      notice(`${label}: request sent to the Safe wallet. Collect the owner signatures and submit it there. This page follows the chain and updates by itself; do not send the same request twice.`);
      return;
    }
    notice('Awaiting your wallet signature…');
    const transaction = await signer.sendTransaction({ ...request, chainId });
    submitted = true;
    setPending({ hash: transaction.hash, from: transaction.from, to: request.to, contract: action.address, data: transaction.data, value: request.value.toString(), nonce: transaction.nonce, label, chainId });
    log('SUBMITTED', label, transaction.hash);
    notice('Transaction submitted. Waiting for confirmation…');
    let receipt;
    try { receipt = await transaction.wait(local ? 1 : 2, 120000); }
    catch (cause) {
      if (cause.code === 'TRANSACTION_REPLACED' && cause.receipt) {
        const replacement = cause.replacement;
        log('REPLACED', cause.cancelled ? 'Original transaction cancelled or changed in the wallet.' : 'Following the replacement transaction.', replacement.hash);
        setPending({ ...pending, hash: replacement.hash });
        receipt = cause.receipt;
        if (cause.cancelled) {
          setPending(null);
          notice('The original action was cancelled or replaced by a different transaction. Refresh state before continuing.', 'warning');
          await refresh({ force: true, quiet: true });
          return;
        }
      } else throw cause;
    }
    finishReceipt(receipt);
    if (receipt?.status === 1 && action.method === 'configurePhase') $('#phase-form').dataset.dirty = 'false';
    await refresh({ force: true, quiet: true });
  } catch (cause) {
    if (submitted && pending) {
      if (cause.receipt) finishReceipt(cause.receipt);
      else notice('Confirmation is still unknown. The hash is saved below; check its receipt before trying again.', 'warning');
    } else error(cause);
  } finally { busy = false; draft = null; renderControls(); }
}

function finishReceipt(receipt) {
  if (!receipt || !pending) return;
  const label = pending.label;
  if (receipt.status === 1) {
    const iface = new Contract(selected.address, abi).interface;
    const minted = receipt.logs.filter(item => item.address.toLowerCase() === selected.address.toLowerCase()).flatMap(item => {
      try { const event = iface.parseLog(item); return event?.name === 'Transfer' && event.args[0] === '0x0000000000000000000000000000000000000000' ? [event.args[2].toString()] : []; } catch { return []; }
    });
    const ids = minted.length > 12 ? `${minted[0]}-${minted.at(-1)} (${minted.length} keys)` : minted.join(', ');
    log('CONFIRMED', label + (minted.length ? ` · Token IDs: ${ids}` : ''), receipt.hash);
    notice(`${label} confirmed${minted.length ? ` · Token IDs: ${ids}` : ''}.`);
  } else { log('REVERTED', label, receipt.hash); notice('The transaction reverted. Its state changes were rolled back.', 'error'); }
  setPending(null);
}

async function reconcile() {
  if (!pending) return;
  const receipt = await provider.getTransactionReceipt(pending.hash);
  if (!receipt || await receipt.confirmations() < (local ? 1 : 2)) {
    notice('Transaction is still pending or awaiting confirmations. Keep its hash and check again.', 'warning');
    return;
  }
  finishReceipt(receipt);
  await refresh({ force: true, quiet: true });
}

function onForm(id, callback) {
  $(id).addEventListener('submit', event => {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    Promise.resolve().then(() => callback(data)).catch(error);
  });
}

onForm('#mint-form', data => {
  const amount = unsigned(data.get('amount'), state?.maxPaid || 6166n, 1n);
  const proof = state?.currentPhase < 4n ? state.proof : null;
  return review({ kind: 'mint', label: 'Mint Ryodan Keys', method: proof ? 'mintWithProof' : 'mint', args: [amount, state?.currentPhase, state?.price, ...(proof ? [proof.tier, proof.proof] : [])] });
});
onForm('#advance-form', () => review({ kind: 'advance', label: `Advance to ${phaseNames[Number(state.currentPhase) + 1]}`, method: 'advancePhase', args: [], expectedPhase: state.currentPhase, warning: 'Irreversible phase closure: unused guarantees are released, earlier phases cannot reopen. The next phase starts paused.' }));
onForm('#pause-form', () => review({ kind: 'pause', label: state.paused ? 'Resume active phase' : 'Pause active phase', method: 'setMintPaused', args: [!state.paused], expectedPhase: state.currentPhase }));
onForm('#phase-form', data => {
  if (!/^\d+(\.\d{1,18})?$/.test(data.get('price').trim())) throw new Error('Enter an ETH price with up to 18 decimal places.');
  const price = parseEther(data.get('price').trim());
  if (price <= 0n) throw new Error('The price must be greater than zero.');
  const id = unsigned(data.get('phase'), 4n, 1n);
  return review({ kind: 'phaseAdmin', label: `Configure ${phaseNames[Number(id)]}`, method: 'configurePhase', args: [id, price, unsigned(data.get('limit'), state?.maxPaid || 6166n, 1n)], warning: 'Set every phase before Pioneer opens: from then on prices and per-wallet limits cannot change. Guaranteed allocations are recalculated and must fit the paid supply.' });
});
onForm('#treasury-form', data => review({ kind: 'treasuryMint', label: 'Mint treasury allocation', method: 'treasuryMint', args: [unsigned(data.get('amount'), viaSafe('treasuryMint', state, account) ? TREASURY_BLOCK : 50n, 1n), address(data.get('recipient'))] }));
onForm('#withdraw-form', () => review({ kind: 'withdraw', label: 'Withdraw sale proceeds', method: 'withdraw', args: [], warning: 'The full contract balance is sent to your connected treasury wallet.' }));
onForm('#role-form', data => {
  const target = address(data.get('account'));
  const revoke = data.get('operation') === 'revoke';
  if (data.get('operation') === 'accept') {
    if (target.toLowerCase() !== account?.toLowerCase()) throw new Error('Only the pending administrator accepts the transfer: connect that wallet and enter its address.');
    return review({ kind: 'acceptAdmin', label: 'Accept administrator role', method: 'acceptDefaultAdminTransfer', args: [], warning: 'The previous administrator loses the role in this same transaction.' });
  }
  if (data.get('role') === 'admin') {
    if (revoke) throw new Error('The administrator role moves only in two steps: start a transfer to the new address, which then accepts it.');
    return review({ kind: 'admin', label: 'Start administrator transfer', method: 'beginDefaultAdminTransfer', args: [target], warning: 'Step 1 of 2. The role moves only when this address accepts with its own signature; until then you stay administrator and can start a new transfer to replace a wrong address.' });
  }
  if (revoke && target === account) throw new Error('Self-revocation is disabled in the console. Verify another administrator before using a separate administration tool.');
  return review({ kind: 'admin', label: `${revoke ? 'Revoke' : 'Grant'} ${data.get('role')} role`, method: revoke ? 'revokeRole' : 'grantRole', args: [data.get('role') === 'admin' ? ZeroHash : state.treasuryRoleId, target], warning: data.get('role') === 'admin' ? 'Administrators can grant roles, change sale settings and select final metadata. Verify the recipient carefully.' : 'Treasury role holders can mint reserved tokens and withdraw all successful-sale proceeds.' });
});
onForm('#batch-refund-form', data => review({ kind: 'refund', label: 'Refund paid keys in one batch', method: 'refundBatch', args: [refundIds(data.get('ids'), tokenRange(state)[1], tokenRange(state)[0])] }));
onForm('#settle-form', data => {
  const [keep, refund] = settleIds(data.get('keep'), data.get('refund'), tokenRange(state)[1], tokenRange(state)[0]);
  return review({ kind: 'settle', label: `Keep ${keep.length}, refund ${refund.length}`, method: 'settle', args: [keep, refund] });
});
onForm('#claim-pending-form', data => {
  const recipient = data.get('recipient').trim();
  return review({ kind: 'claimPending', label: 'Claim pending refund', method: 'claimPendingRefund', args: [recipient ? address(recipient) : account], warning: `${formatEther(state.pendingRefund)} ETH is sent to ${recipient || 'the connected wallet'}.` });
});
onForm('#withdraw-kept-form', () => review({ kind: 'withdrawKept', label: 'Withdraw kept-key payments', method: 'withdrawKept', args: [], warning: `${formatEther(state.keptFunds - state.keptWithdrawn)} ETH paid for kept keys is sent to your connected treasury wallet. Refundable funds stay in the contract.` }));
onForm('#burn-treasury-form', data => review({ kind: 'burnTreasury', label: 'Burn treasury keys', method: 'burnTreasuryKeys', args: [refundIds(data.get('ids'), tokenRange(state)[1], tokenRange(state)[0])], warning: 'The selected free treasury keys are burned for good.' }));
onForm('#refund-form', data => {
  const id = unsigned(data.get('id'), tokenRange(state)[1], tokenRange(state)[0]);
  const recipient = data.get('recipient').trim();
  return review({ kind: 'refund', label: `Refund token #${id}`, method: recipient ? 'refundTo' : 'refund', args: recipient ? [id, address(recipient)] : [id] });
});
onForm('#inspect-form', async data => {
  const id = unsigned(data.get('id'), tokenRange(state)[1], tokenRange(state)[0]);
  const keys = new Contract(selected.address, abi, provider);
  const block = await provider.getBlockNumber();
  const target = selected.address;
  const [owner, uri, minter, kept] = await Promise.all([keys.ownerOf(id, { blockTag: block }), keys.tokenURI(id, { blockTag: block }), keys.originalMinter(id, { blockTag: block }), keys.kept(id, { blockTag: block })]);
  if (target !== selected.address) return;
  $('#token-result').replaceChildren();
  const rows = [['TOKEN', `#${id}`], ['OWNER', owner], ['ORIGINAL PAID MINTER', minter === '0x0000000000000000000000000000000000000000' ? 'None: treasury key' : minter]];
  rows.push(['STATE', state.soldOut ? 'Unlocked: sold out' : kept ? 'Kept: transferable NFT' : 'Locked: soulbound']);
  rows.push(['CANONICAL URI', uri]);
  for (const [key, value] of rows) {
    const dt = document.createElement('dt'); dt.textContent = key;
    const dd = document.createElement('dd'); dd.textContent = value;
    $('#token-result').append(dt, dd);
  }
});
onForm('#replacement-form', async data => {
  if (!pending) return;
  const hash = data.get('hash').trim();
  if (!/^0x[0-9a-f]{64}$/i.test(hash)) throw new Error('Enter a valid transaction hash.');
  const transaction = await provider.getTransaction(hash);
  if (!transaction || transaction.from.toLowerCase() !== pending.from.toLowerCase() || transaction.nonce !== pending.nonce) throw new Error('This transaction does not replace the pending wallet nonce.');
  const receipt = await provider.getTransactionReceipt(hash);
  if (!receipt || await receipt.confirmations() < (local ? 1 : 2)) throw new Error('The replacement is not yet confirmed. Keep tracking the original action.');
  const equivalent = transaction.to?.toLowerCase() === pending.to.toLowerCase() && transaction.data === pending.data && transaction.value === BigInt(pending.value);
  if (equivalent) { setPending({ ...pending, hash }); finishReceipt(receipt); }
  else { log('REPLACED', 'Original nonce consumed by a different confirmed transaction. Re-read contract state.', hash); setPending(null); notice('Original action was replaced or cancelled. Contract state has been refreshed.', 'warning'); }
  await refresh({ force: true, quiet: true });
});

$('#connect').addEventListener('click', () => connect().catch(error));
$('#safe-steps').addEventListener('click', event => {
  const step = event.target.closest('[data-safe-step]')?.dataset.safeStep;
  if (step) Promise.resolve().then(() => safeStep(step)).catch(error);
});
$('#refresh').addEventListener('click', () => void refresh({ force: true }));
$('#reconcile').addEventListener('click', () => reconcile().catch(error));
$('#confirm-transaction').addEventListener('click', () => void submit());
$('#download-batch').addEventListener('click', () => void submit(true));
$('#review-dialog').addEventListener('close', () => { if (!busy) { draft = null; renderControls(); } });
$('#mint-amount').addEventListener('input', updateTotal);
$('#phase').addEventListener('change', fillPhaseConfiguration);
for (const id of ['#phase-price', '#wallet-limit']) $(id).addEventListener('input', () => { $('#phase-form').dataset.dirty = 'true'; });
for (const [selector, change] of [['#decrement', -1], ['#increment', 1]]) $(selector).addEventListener('click', () => {
  $('#mint-amount').value = Math.max(1, Math.min(Number(state?.maxPaid || 6166n), (Number($('#mint-amount').value) || 1) + change)); updateTotal();
});

function route() {
  const page = ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'mint';
  all('.page').forEach(section => { section.hidden = section.id !== `page-${page}`; section.classList.toggle('active', !section.hidden); });
  all('.nav-item').forEach(link => { link.classList.toggle('active', link.dataset.page === page); if (link.dataset.page === page) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current'); });
  $('#batch-refund-panel').hidden = !state || page !== 'refund';
  text('#page-label', { mint: 'OVERVIEW', sale: 'SALE CONTROLS', treasury: 'TREASURY', reveal: 'METADATA', access: 'ACCESS', refund: 'REFUNDS' }[page]);
}

function selectDeployment() {
  if (!selected) {
    $('#deployment').disabled = true;
    text('#contract-link', 'No v7 contract deployed');
    text('#deadline-remaining', 'No v7 contract deployed');
    text('#sync-status', 'NO V6 CONTRACT');
    notice('No Ryodan Keys v7 contract is deployed on this network yet. This console manages only v7.');
    renderControls();
    return;
  }
  ++generation;
  state = null; refreshedAt = 0; draft = null;
  for (const selector of ['#metric-minted', '#metric-balance', '#metric-phase', '#metric-metadata', '#paid-count', '#treasury-count', '#deadline-display', '#refund-count', '#live-supply', '#withdraw-balance']) text(selector, '—');
  text('#deadline-remaining', 'Reading chain time…');
  notice('Reading the selected contract…');
  text('#contract-link', selected.address);
  const href = explorer('address', selected.address);
  if (href) { $('#contract-link').href = href; $('#contract-link').title = 'Open this contract on Sepolia Etherscan'; }
  else $('#contract-link').removeAttribute('href');
  loadPending();
  void refresh({ force: true });
}

for (const entry of deployments) {
  const option = document.createElement('option'); option.value = entry.address; option.textContent = entry.label;
  $('#deployment').append(option);
}
$('#deployment').addEventListener('change', () => { selected = deployments.find(entry => entry.address === $('#deployment').value); selectDeployment(); });
window.addEventListener('hashchange', route);
document.addEventListener('visibilitychange', () => { if (!document.hidden && !busy) void refresh(); });
setInterval(() => { renderControls(); if (!document.hidden && !busy && !draft) void refresh({ quiet: true }); }, 15000);
mountAllowlist({ getState: () => state, refresh, review, error, notice });
text('#network-name', networkName);
route();
selectDeployment();
