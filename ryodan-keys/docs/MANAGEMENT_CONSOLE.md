# Ryodan management console

Updated 2026-10-29 for v3. Public console: **[ryodan.grooooog.space](https://ryodan.grooooog.space)**.

V3 management contract: [`0x3120e791E078ACF04601d623307B0e6866633E7A`](https://sepolia.etherscan.io/address/0x3120e791E078ACF04601d623307B0e6866633E7A). Initial deadline: **2026-11-28 14:01:12 UTC**; read its current value on chain. Separate v3 refund QA: [`0x30f41eA9af605cB63C9Fb86af945e9D137B3d804`](https://sepolia.etherscan.io/address/0x30f41eA9af605cB63C9Fb86af945e9D137B3d804).

A static Ethereum Sepolia console for four-phase minting, per-phase prices and wallet limits, guarantees/allowlists, editable deadline, treasury, reveal, roles and refunds. It is readable without a wallet; every write is simulated, reviewed and signed in the connected wallet.

## Contract and wallet

The selected address and Sepolia Etherscan link are always visible under **Target contract**. `console/src/deployment.json` defines the default deployment; `deployments/sepolia-v3.json` records the v3 management deployment and `deployments/sepolia-v3-refund.json` its separate expired QA sale. Earlier v2/v1 deployments retain their own rules, balances and NFTs; they are not upgraded or migrated. The console reads the on-chain version and uses the matching ABI.

Network: **Ethereum Sepolia / 11155111**. Test admin and treasury wallet: **`0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`**. Its secret is stored as `YOMI_RYODAN_SEPOLIA_DEPLOYER` in hush and was shared separately through an expiring Send. No key or Send URL is stored in this guide or the browser application. Import that key in your wallet application and verify the resulting address, then connect to the console. Use your wallet's in-app browser on mobile.

Production customers must use their own wallets. The dedicated test wallet and Sepolia addresses are not production configuration.

## Phase setup and progression

| Phase | Default price | Default total per wallet in that phase | Access |
| --- | --- | --- | --- |
| Pioneer | 0.005 ETH | 4 | Guaranteed, allowlist |
| Operative | 0.002 ETH | 6 | Guaranteed, allowlist |
| Recruit | 0.001 ETH | 6 | First come, allowlist |
| Civilian | 0.01 ETH | 10 | First come, open to everyone |

The 50%, 80%, 90% discounts are applied to the initial public price. Each price is independently configurable; changing the public price does not recalculate other prices. Wallet limits are independent across phases, while multiple mint transactions in the same phase consume the same allowance. No additional lifetime cap exists.

1. Open **Sale controls**. The four-step strip shows configured prices, limits, mint counts, current phase and closed phases.
2. Under **Phase price & wallet limit**, choose a current/future phase, enter its exact ETH price and total allowance per wallet, then review and sign. Choosing here only edits settings; it does not activate that phase.
3. Under **Allowlist management**, select Pioneer, Operative or Recruit and add addresses, up to 100 per transaction. Each phase has a separate list. Civilian has no list.
4. For Pioneer/Operative, the contract reserves each listed wallet's remaining phase allowance. The combined guarantees must fit the 5,900-token paid supply. Adding too many wallets or raising limits beyond available inventory reverts atomically. Removing a member releases its remaining allocation. Guaranteed limits cannot be lowered below the highest historical mint count of one wallet in that phase.
5. **Start Pioneer** moves from not started to Pioneer, paused. Check settings and membership, then **Resume**. Pausing and resuming never resets counters or stops the deadline.
6. **Advance to Operative**, then Recruit, then Civilian, in order. Every advance permanently closes the old phase and releases its unused guarantees. The new phase starts paused and needs an explicit resume. You cannot go backward or skip a step.

The admin determines when to advance. There are no automatic per-phase start/end timestamps. The single sale deadline remains editable in UTC while unexpired and unsold. Once expired, minting and phase administration cannot reopen. Deadline edits cannot revoke accrued refund rights.

The paid pool is **5,900 across all phases**, plus **500 free treasury NFTs**. Civilian receives the remainder after Recruit; there is no minimum Civilian allocation. Guaranteed allocation means availability under the current configuration, not a free mint or an irrevocable promise: privileged admins can edit lists, prices, limits and closing time.

## Mint

Open **Overview & mint**. The wallet sees the current phase's price and its remaining allowance, chooses a quantity and reviews the payment. Neither phase nor token IDs can be chosen. IDs start at 0 and are shared in sequence with treasury mints. A phase or price change before mining invalidates the quote; review a fresh transaction.

The receipt log shows actual minted IDs. Wait for confirmations; do not send a second transaction merely because the first is slow. Pending hashes survive reload. **Check receipt** reconciles confirmation; a replacement/cancellation hash must consume the same wallet nonce before the original is cleared.

## Deadline, treasury and successful sale

**Change the deadline** interprets dates as UTC and submits Unix seconds. An open sale can be shortened or extended, including after purchases. New time must be strictly in the future. Expired/sold-out sales cannot edit their deadline.

**Treasury** mints up to 50 free NFTs per console transaction to a chosen recipient, within the separate 500-token pool. Complete the treasury allocation before the shared deadline. Success still requires all **6,400** NFTs: selling 5,900 paid NFTs while treasury is incomplete does not unlock transfers, reveal or withdrawal. At failed expiry, paid minters can refund.

After success, **Withdraw** sends the entire contract balance to the connected treasury-role wallet. Revenue depends on quantities and actual prices paid in each phase; it is not fixed at 59 ETH in v3.

## Reveal, roles and refunds

**Metadata & reveal** provides an owner/URI inspector and an irreversible, collection-wide reveal after success. Prepare and pin `0.json` through `6399.json`, verify the final directory URI ends with `/`, acknowledge permanence and review the transaction. No holder reveal transaction exists. Follow [METADATA_AND_REVEAL.md](METADATA_AND_REVEAL.md).

**Access control** grants/revokes admin or treasury roles. Admins control phase settings, dates, membership, roles and final metadata. Treasury controls free mints and successful-sale withdrawals. Console self-revocation is blocked to avoid accidental lockout; the contract's standard AccessControl API still permits it. Verify another administrator before any role change.

**Refunds** opens after unsuccessful expiry. Enter a paid token ID and optionally a recipient address. The review shows that NFT's **original payment**, even if the phase price changed later. Only its original paid minter may claim; it burns the NFT and cannot be repeated. Treasury NFTs cannot refund. A rejected ETH receiver can retry using a different recipient. Gas is separate and is not returned.

## Local development and verification

```sh
cd ryodan-keys
forge build
python3 scripts/export-abi.py --check
cd ../console
npm test
npm run test:browser
```

`npm run test:browser` launches isolated Anvil and Vite instances and drives real transactions through a test wallet provider. It exercises four-phase settings/progression/mint, deadline edits, roles, treasury, stale-price recovery, account/network changes, rejection, pending reload, mixed-price refunds, duplicate rejection and full-size sellout/reveal/withdrawal. Screenshots and the check list are under ignored `console/test-results/`.

Production uses Sepolia only. Development-only Anvil settings are `VITE_CHAIN_ID=31337`, `VITE_RPC_URL` and `VITE_CONTRACT_ADDRESS`. Production builds ignore that local mode. This UI has no backend, database or server-side signing key. Real extension and mobile wallet confirmation screens require their own compatibility checks.

The public hostname is served persistently by grog from `console/dist`. Building into that directory updates the live files; use a temporary output directory for review builds. Publish only after browser journeys, visible output, console errors and network failures are checked.
