import './styles.css';
import { BrowserProvider, Contract, formatEther, parseEther, getAddress, ZeroHash } from 'ethers';
import { abiForVersion, reader, snapshot } from './chain.js';
import { address, addresses, deadlineUTC, friendlyError, gate, metadataBase, phase, phaseNames, remaining, unsigned } from './model.js';
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
  { address: '0x30f41eA9af605cB63C9Fb86af945e9D137B3d804', label: 'v3 / lifecycle refund QA' },
  ...(deployment.address?.toLowerCase() !== '0x4b8d8fd22fb818aa7b312cb72f7048e4d738109b' ? [{ address: '0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B', label: 'v2 / earlier management' }] : []),
  { address: '0xBc5338c4a71961d999Ec9551a2636850ec1561e0', label: 'v2 / expired refund QA' },
  { address: '0x85b1024194cFd547Eb81877f8efF77587e7604f9', label: 'v1 / original mint test' },
  { address: '0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7', label: 'v1 / expired refund QA' },
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
    if (value && /^0x[0-9a-f]{64}$/i.test(value.hash) && value.chainId === chainId && value.to?.toLowerCase() === selected.address.toLowerCase()) pending = value;
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
    hint.textContent = gate(hint.dataset.hint, state, context()) || 'Ready. Review the transaction before signing.';
  });
  $('#deployment').disabled = busy || Boolean(pending);
  $('#connect').disabled = busy;
  $('#confirm-transaction').disabled = busy || !draft;
}

function render() {
  if (!state) { renderControls(); return; }
  const s = state;
  text('#metric-minted', (s.paid + s.treasuryMinted).toLocaleString('en-US'));
  text('#metric-balance', formatEther(s.balance));
  text('#metric-phase', phase(s));
  text('#phase-detail', s.soldOut ? 'TRANSFERS UNLOCKED' : s.refundsAvailable ? 'REFUNDS AVAILABLE' : s.version >= 3n ? `${phaseNames[Number(s.currentPhase)]} · ${s.limit} / WALLET / PHASE` : `MAX ${s.limit} PAID / WALLET`);
  text('#metric-metadata', s.revealed ? 'REVEALED' : 'SEALED');
  text('#metadata-detail', s.revealed ? 'FINAL URI COMMITTED' : 'AWAITING REVEAL');
  text('#mint-price', s.price ? formatEther(s.price) : '—');
  renderPhases(s);
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
  text('#identity-roles', account ? [s.admin && 'Administrator', s.treasuryRole && 'Treasury', 'Holder / minter'].filter(Boolean).join(' · ') : 'Read-only');
  text('#block-label', `BLOCK ${s.block.toLocaleString('en-US')} / ${utc(s.timestamp).slice(11)}`);
  text('#sync-status', '● SYNCHRONIZED');
  text('#reserve-label', s.soldOut ? 'TREASURY WITHDRAWABLE' : 'SALE / REFUND RESERVES');
  if (!$('#new-deadline').value) $('#new-deadline').value = new Date(Number(s.deadline) * 1000).toISOString().slice(0, 19);
  if (!$('#treasury-recipient').value && account) $('#treasury-recipient').value = account;
  updateTotal();
  renderControls();
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
  const modern = s.version >= 3n;
  all('[data-v3]').forEach(node => { node.hidden = !modern; });
  all('[data-legacy]').forEach(node => { node.hidden = modern; });
  $('#whitelist-form button').dataset.action = modern ? 'allowlist' : 'admin';
  if (!modern) return;
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
  for (const select of [$('#phase'), $('#allowlist-phase')]) {
    [...select.options].forEach(option => { option.disabled = Number(option.value) < current; });
  }
  if (Number($('#phase').value) < current) { $('#phase').value = String(current); fillPhaseConfiguration(); }
  if (current < 4 && Number($('#allowlist-phase').value) < current) $('#allowlist-phase').value = String(current);
  if ($('#phase-form').dataset.loaded !== selected.address || $('#phase-form').dataset.dirty !== 'true') fillPhaseConfiguration();
}

async function refresh({ force = false, quiet = false } = {}) {
  if (refreshing && !force) return false;
  const current = ++generation;
  const target = selected.address;
  const identity = account;
  refreshing = true;
  $('#refresh').disabled = true;
  text('#sync-status', 'READING…');
  try {
    let next;
    try { next = await snapshot(provider, target, identity, chainId); }
    catch (first) {
      if (rpcUrls.length < 2) throw first;
      rpcIndex = (rpcIndex + 1) % rpcUrls.length;
      const previousProvider = provider;
      provider = reader(rpcUrls[rpcIndex], chainId);
      previousProvider.destroy();
      next = await snapshot(provider, target, identity, chainId);
    }
    if (current !== generation || target !== selected.address || identity !== account) return false;
    state = next;
    refreshedAt = performance.now();
    render();
    if (!quiet) notice(account ? `Connected as ${short(account)}. ${state.admin ? 'Administrator access verified.' : 'Read access and holder operations available.'}` : 'Read-only session. Connect your wallet to mint or manage this contract.');
    return true;
  } catch (cause) {
    if (current === generation) {
      state = null;
      text('#sync-status', 'RPC OFFLINE');
      notice(`Unable to refresh chain state. Displayed metrics may be stale. ${friendlyError(cause)}`, 'error');
      renderControls();
    }
    return false;
  } finally {
    if (current === generation) { refreshing = false; $('#refresh').disabled = false; }
  }
}

function updateTotal() {
  try { text('#mint-total', state?.price ? `${formatEther(state.price * unsigned($('#mint-amount').value, 5900n, 1n))} ETH + gas` : 'Awaiting active phase'); }
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
      if (cause.code !== 4902 || local) throw cause;
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
  if (action.method === 'mint' && state.version >= 3n && (action.args[1] !== state.currentPhase || action.args[2] !== state.price)) throw new Error('Mint phase or price changed. Review a new quote.');
  if (action.expectedPhase !== undefined && action.expectedPhase !== state.currentPhase) throw new Error('Active phase changed. Review the command again.');
  if (action.method === 'mint' && action.args[0] > remaining(state)) throw new Error('Quantity exceeds your remaining mint allowance.');
  if (action.method === 'treasuryMint' && action.args[0] > state.maxTreasury - state.treasuryMinted) throw new Error('Quantity exceeds the remaining treasury allocation.');
  if (action.method === 'setMintEndTime' && action.args[0] <= state.timestamp) throw new Error('The new deadline must be after the latest block time.');
}

async function review(action) {
  if (busy || pending) throw new Error('Finish the current transaction before starting another.');
  busy = true;
  renderControls();
  try {
    if (!await refresh({ force: true, quiet: true })) throw new Error('Unable to obtain fresh chain state.');
    action.value = action.method === 'mint' ? state.price * action.args[0] : 0n;
    validate(action);
    const reviewAccount = account;
    const reviewAddress = selected.address;
    const signer = await signerForCurrentWallet();
    const keys = new Contract(selected.address, abiForVersion(state?.version || 3n), signer);
    if (action.kind === 'refund') {
      const paid = state.version >= 3n ? await keys.mintPayment(action.args[0], { blockTag: state.block }) : state.price;
      action.warning = `This burns the key and returns its original payment of ${formatEther(paid)} ETH. Network fees are separate.`;
    }
    await keys[action.method].staticCall(...action.args, { value: action.value });
    const gas = await keys[action.method].estimateGas(...action.args, { value: action.value });
    if (reviewAccount !== account || reviewAddress !== selected.address || walletChain !== chainId) throw new Error('Wallet context changed during simulation. Review the action again.');
    draft = { ...action, account, address: selected.address, chainId, gas, generation };
    text('#review-title', action.label);
    const fields = [ ['NETWORK', networkName + ` (${chainId})`], ['CONTRACT', selected.address], ['SIGNER', account], ['CALL', action.method],
      ['ARGUMENTS', action.args.length ? action.args.map(v => Array.isArray(v) ? v.join('\n') : String(v)).join('\n') : 'None'],
      ['PAYMENT', `${formatEther(action.value)} ETH + wallet-estimated network fee`], ['ESTIMATED GAS', gas.toString()] ];
    $('#review-details').replaceChildren();
    for (const [key, value] of fields) {
      const dt = document.createElement('dt'); dt.textContent = key;
      const dd = document.createElement('dd'); dd.textContent = value;
      $('#review-details').append(dt, dd);
    }
    text('#review-warning', action.warning || 'The wallet displays the final network fee. State may change before this transaction is mined.');
    $('#review-dialog').showModal();
  } finally { busy = false; renderControls(); }
}

async function submit() {
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
    if (action.pause && ((state.publicActive && action.method !== 'setPublicMintActive') || (state.whitelistActive && action.method !== 'setWhitelistMintActive'))) throw new Error('The active phase changed. Review the pause command again.');
    const signer = await signerForCurrentWallet();
    const keys = new Contract(selected.address, abiForVersion(state?.version || 3n), signer);
    await keys[action.method].staticCall(...action.args, { value: action.value });
    const gas = await keys[action.method].estimateGas(...action.args, { value: action.value });
    notice('Awaiting your wallet signature…');
    const transaction = await signer.sendTransaction({ to: selected.address, data: keys.interface.encodeFunctionData(action.method, action.args), value: action.value, chainId, gasLimit: gas * 120n / 100n });
    submitted = true;
    setPending({ hash: transaction.hash, from: transaction.from, to: action.address, data: transaction.data, value: action.value.toString(), nonce: transaction.nonce, label: action.label, chainId });
    log('SUBMITTED', action.label, transaction.hash);
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
    const iface = new Contract(selected.address, abiForVersion(state?.version || 3n)).interface;
    const minted = receipt.logs.filter(item => item.address.toLowerCase() === selected.address.toLowerCase()).flatMap(item => {
      try { const event = iface.parseLog(item); return event?.name === 'Transfer' && event.args[0] === '0x0000000000000000000000000000000000000000' ? [event.args[2].toString()] : []; } catch { return []; }
    });
    log('CONFIRMED', label + (minted.length ? ` · Token IDs: ${minted.join(', ')}` : ''), receipt.hash);
    notice(`${label} confirmed${minted.length ? ` · Token IDs: ${minted.join(', ')}` : ''}.`);
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

onForm('#mint-form', data => review({ kind: 'mint', label: 'Mint Ryodan Keys', method: 'mint', args: [unsigned(data.get('amount'), 5900n, 1n), ...(state?.version >= 3n ? [state.currentPhase, state.price] : [])] }));
onForm('#advance-form', () => review({ kind: 'advance', label: `Advance to ${phaseNames[Number(state.currentPhase) + 1]}`, method: 'advancePhase', args: [], expectedPhase: state.currentPhase, warning: 'Irreversible phase closure: unused guarantees are released, earlier phases cannot reopen. The next phase starts paused.' }));
onForm('#pause-form', () => review({ kind: 'pause', label: state.paused ? 'Resume active phase' : 'Pause active phase', method: 'setMintPaused', args: [!state.paused], expectedPhase: state.currentPhase }));
onForm('#phase-form', data => {
  if (!/^\d+(\.\d{1,18})?$/.test(data.get('price').trim())) throw new Error('Enter an ETH price with up to 18 decimal places.');
  const price = parseEther(data.get('price').trim());
  if (price <= 0n) throw new Error('The price must be greater than zero.');
  const id = unsigned(data.get('phase'), 4n, 1n);
  return review({ kind: 'phaseAdmin', label: `Configure ${phaseNames[Number(id)]}`, method: 'configurePhase', args: [id, price, unsigned(data.get('limit'), 5900n, 1n)], warning: 'Price and per-wallet allowance apply to this phase. Existing mints still count; refunds preserve each token’s original payment. Guaranteed allocations must fit the remaining paid supply.' });
});
onForm('#legacy-phase-form', data => {
  const chosen = data.get('phase');
  const method = chosen === 'whitelist' || (chosen === 'paused' && state?.whitelistActive) ? 'setWhitelistMintActive' : 'setPublicMintActive';
  return review({ kind: 'admin', label: `Set mint phase: ${chosen}`, method, args: [chosen !== 'paused', unsigned(data.get('limit'), 5900n, 1n)], pause: chosen === 'paused' });
});
onForm('#deadline-form', data => review({ kind: 'deadline', label: 'Change mint deadline', method: 'setMintEndTime', args: [deadlineUTC(data.get('deadline'))], warning: `New deadline: ${utc(deadlineUTC(data.get('deadline')))}. Changing this date changes when refunds for an unsuccessful sale can begin. Expired sales cannot reopen.` }));
onForm('#whitelist-form', data => {
  const allowed = data.get('operation') === 'add';
  const accounts = addresses(data.get('addresses'));
  const modern = state?.version >= 3n;
  return review({ kind: modern ? 'allowlist' : 'admin', label: `${allowed ? 'Add to' : 'Remove from'} allowlist`, method: modern ? 'setPhaseAllowlist' : allowed ? 'addToWhitelist' : 'removeFromWhitelist', args: modern ? [unsigned(data.get('phase'), 3n, 1n), accounts, allowed] : [accounts], warning: modern ? 'Each phase has its own list. Adding Pioneer or Operative wallets reserves their unminted allowance. Removing a wallet cancels that remaining guarantee.' : '' });
});
onForm('#treasury-form', data => review({ kind: 'treasuryMint', label: 'Mint treasury allocation', method: 'treasuryMint', args: [unsigned(data.get('amount'), 50n, 1n), address(data.get('recipient'))] }));
onForm('#withdraw-form', () => review({ kind: 'withdraw', label: 'Withdraw sale proceeds', method: 'withdraw', args: [], warning: 'The full contract balance is sent to your connected treasury wallet.' }));
onForm('#reveal-form', data => {
  if (!data.get('acknowledge')) throw new Error('Acknowledge the permanent metadata change.');
  return review({ kind: 'reveal', label: 'Permanently reveal metadata', method: 'reveal', args: [metadataBase(data.get('uri'))], warning: 'Irreversible: this collection can be revealed only once. The contract does not validate remote metadata files.' });
});
onForm('#role-form', data => {
  const target = address(data.get('account'));
  const revoke = data.get('operation') === 'revoke';
  if (revoke && target === account) throw new Error('Self-revocation is disabled in the console. Verify another administrator before using a separate administration tool.');
  return review({ kind: 'admin', label: `${revoke ? 'Revoke' : 'Grant'} ${data.get('role')} role`, method: revoke ? 'revokeRole' : 'grantRole', args: [data.get('role') === 'admin' ? ZeroHash : state.treasuryRoleId, target], warning: data.get('role') === 'admin' ? 'Administrators can grant roles, change sale settings and select final metadata. Verify the recipient carefully.' : 'Treasury role holders can mint reserved tokens and withdraw all successful-sale proceeds.' });
});
onForm('#refund-form', data => {
  const id = unsigned(data.get('id'), 6399n);
  const recipient = data.get('recipient').trim();
  return review({ kind: 'refund', label: `Refund token #${id}`, method: recipient ? 'refundTo' : 'refund', args: recipient ? [id, address(recipient)] : [id] });
});
onForm('#inspect-form', async data => {
  const id = unsigned(data.get('id'), 6399n);
  const keys = new Contract(selected.address, abiForVersion(state?.version || 3n), provider);
  const block = await provider.getBlockNumber();
  const target = selected.address;
  const [owner, uri, minter] = await Promise.all([keys.ownerOf(id, { blockTag: block }), keys.tokenURI(id, { blockTag: block }), keys.originalMinter(id, { blockTag: block })]);
  if (target !== selected.address) return;
  $('#token-result').replaceChildren();
  for (const [key, value] of [['TOKEN', `#${id}`], ['OWNER', owner], ['ORIGINAL PAID MINTER', minter], ['CANONICAL URI', uri]]) {
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
$('#refresh').addEventListener('click', () => void refresh({ force: true }));
$('#reconcile').addEventListener('click', () => reconcile().catch(error));
$('#confirm-transaction').addEventListener('click', () => void submit());
$('#review-dialog').addEventListener('close', () => { if (!busy) { draft = null; renderControls(); } });
$('#mint-amount').addEventListener('input', updateTotal);
$('#phase').addEventListener('change', fillPhaseConfiguration);
for (const id of ['#phase-price', '#wallet-limit']) $(id).addEventListener('input', () => { $('#phase-form').dataset.dirty = 'true'; });
for (const [selector, change] of [['#decrement', -1], ['#increment', 1]]) $(selector).addEventListener('click', () => {
  $('#mint-amount').value = Math.max(1, Math.min(5900, (Number($('#mint-amount').value) || 1) + change)); updateTotal();
});
$('#base-uri').addEventListener('input', () => text('#uri-preview', `${$('#base-uri').value || '<base URI>'}0.json`));
$('#new-deadline').addEventListener('input', () => { try { text('#deadline-preview', utc(deadlineUTC($('#new-deadline').value))); } catch { text('#deadline-preview', 'Enter a valid date; all values are interpreted as UTC.'); } });

function route() {
  const page = ['mint', 'sale', 'treasury', 'reveal', 'access', 'refund'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'mint';
  all('.page').forEach(section => { section.hidden = section.id !== `page-${page}`; section.classList.toggle('active', !section.hidden); });
  all('.nav-item').forEach(link => { link.classList.toggle('active', link.dataset.page === page); if (link.dataset.page === page) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current'); });
  text('#page-label', { mint: 'OVERVIEW', sale: 'SALE CONTROLS', treasury: 'TREASURY', reveal: 'REVEAL', access: 'ACCESS', refund: 'REFUNDS' }[page]);
}

function selectDeployment() {
  ++generation;
  state = null; refreshedAt = 0; draft = null;
  $('#new-deadline').value = '';
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
text('#network-name', networkName);
route();
selectDeployment();
