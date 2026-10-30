# Frontend agent handoff — Ryodan Keys v4

Use the current [Sepolia manifest](../deployments/sepolia-v4.json), `abi/RyodanKeys.json`, and `console/src/allowlist.js`. The management reference is [ryodan.grooooog.space](https://ryodan.grooooog.space). V3 addresses use `RyodanKeys.v3.json`; do not attach the v4 allowlist API to them. Contracts are not upgradeable and histories must be keyed by chain + contract + wallet.

## Commercial and phase model

| ID | Name | Price/key | Initial independent cap | Eligibility |
| --- | --- | --- | --- | --- |
| 0 | Not started | — | — | No mint |
| 1 | Pioneer | 0.025 ETH | 4 | Tier 1, guaranteed; pairs only |
| 2 | Operative | 0.040 ETH | 10 | Tiers 1–2, guaranteed |
| 3 | Recruit | 0.045 ETH | 10 | Tiers 1–3, FCFS |
| 4 | Civilian | 0.050 ETH | 10 | Everyone, FCFS |

Pioneer quantities count keys, not pairs: 2 keys = 0.050 ETH. Its quantity step/minimum is 2. Other phases step by 1. Read prices and limits live; all are configurable by the admin. Defaults give a Pioneer 34 possible purchases across phases. The same phase's prior transactions always consume its allowance. Transfers/refunds do not reset historical mint counters.

Supply: `MAX_PUBLIC_SUPPLY=6166`, `MAX_TREASURY_SUPPLY=500`, `MAX_SUPPLY=6666`. Civilian has no fixed quota; it receives the remaining paid allocation. Token IDs are assigned sequentially across treasury and paid mints, beginning at 0; they are unrelated to phase/tier.

## Frozen CSV/checker integration

Follow [the shared list workflow](ALLOWLISTS_AND_CLIENT_ALIGNMENT.md). Downloadable empty templates are in the management panel. Publish the generated `allowlist.json` and `check-data.js` from the same three frozen CSVs. The latter matches the ZIP's `NM.checkData` checker format. No production list files have been supplied. The bundled Sepolia snapshot contains only the dedicated test wallet in Pioneer.

Validate the JSON once with `validateSnapshot`. Compare `root`, `snapshotHash` and counts against `allowlistRoot`, `allowlistSnapshotHash` and `tierMembers(1..3)` at a pinned block. Use `proofFor(snapshot, account)` to get its highest tier and proof. Pioneer inherits eligibility for Operative and Recruit; Operative inherits Recruit. Do not duplicate addresses in three on-chain lists or treat raw checker membership as the final per-phase eligibility result.

`walletTier(account)` is a cache populated by the first successful `mintWithProof`. Therefore **`allowlisted` and `remainingAllowance` alone return false/zero before the first list mint**, even for valid members. Use `verifyEligibility` and `remainingAllowanceWithProof` with the downloaded proof for that case. Failed proof validation, payment or NFT receipt rolls registration back.

## Reads and state

Read `CONTRACT_VERSION` and reject unsupported future versions. Read one block and pin calls using `{ blockTag }`, including prices, all four `phases(id)` records, `currentPhase`, `mintPaused`, `mintEndTime`, totals, reserves, role checks and wallet counters. Use the block's timestamp, not the browser clock, for expiry.

`phases(id)` returns `(price, walletLimit, minted, members, reserved, maxWalletMinted)`. Members are inherited totals for phase eligibility; `tierMembers` are exclusive CSV counts. `mintedInPhase(id, account)` is historical phase usage. `mintedAmount(account)` is historical total paid purchases, useful for statistics rather than v4 cap enforcement.

For the ZIP's `NM.chain` adapter:

- `state.phase`: 0 → `pre`, 1–4 → names above; `soldOut()` → `soldout`; timestamp greater than deadline and not sold out → `ended`. Represent `mintPaused` separately; do not show a paused phase as mintable.
- `state.supply`: 6666; `state.minted`: `mintedByUsers + mintedByTreasury`. Burns reduce `totalSupply`, not lifetime minted counters.
- `wallet.lists`: derive inherited phase eligibility from the canonical tier. Preserve exclusive tier separately if the checker displays it.
- `wallet.mintedIn`: `mintedInPhase` for all phases. `remainingFor` uses proof-aware allowance and available supply. A closed phase returns zero.
- `wallet.tokens` and paid history: index `PaidMint`, ERC-721 `Transfer` and `Refunded` from the manifest's deployment block. The contract is not enumerable. Confirm current owner/refunded status before offering a refund.
- `priceFor`: read the per-key `phases` value. If the design displays a Pioneer pair price, multiply by 2 only for that display.
- `eligible` must also consider pause, current phase, deadline, remaining allowance/supply and correct chain. Membership by itself does not promise availability in FCFS.

Clamp allowance to `MAX_PUBLIC_SUPPLY - mintedByUsers`; for FCFS additionally subtract `totalGtdReserved`. Never display negative remaining allowance after a cap reduction. Disable writes on stale RPC data and re-read after account/network changes.

## Mint transaction

Example with ethers, after reading a coherent state and validated proof:

```js
const amount = 2n; // keys; Pioneer requires even quantities
const expectedPhase = await keys.currentPhase();
const { price } = await keys.phases(expectedPhase);
const membership = proofFor(validatedSnapshot, account);
const value = amount * price;
let receipt;
if (expectedPhase < 4n && membership) {
  const args = [amount, expectedPhase, price, membership.tier, membership.proof];
  await keys.mintWithProof.staticCall(...args, { value });
  receipt = await (await keys.mintWithProof(...args, { value })).wait();
} else {
  // Public mint, or a previously registered list wallet.
  const args = [amount, expectedPhase, price];
  await keys.mint.staticCall(...args, { value });
  receipt = await (await keys.mint(...args, { value })).wait();
}
```

Production integration must take phase and price from the same block, estimate gas, review exact arguments/value, and recheck wallet/chain/state before signing. Exact payment is required; prices use bigint wei, never floating-point arithmetic. The expected phase/price arguments make a changed quote revert instead of purchasing under different terms. The user cannot choose another phase even if its price is identical.

Obtain minted IDs from confirmed `Transfer(0x0, account, tokenId)` logs emitted by this contract, or `PaidMint(firstTokenId, amount)`. Do not predict IDs from supply before the transaction. Pending transactions must survive reload and block duplicate sends; reconcile replacements/cancellations by sender and nonce.

## Refunds

`refundsAvailable()` requires `block.timestamp > mintEndTime` and an unsuccessful sale. At the exact deadline minting is still permitted; refunds are not yet available. A sold-out collection never opens refunds.

- `refund(tokenId)`: any caller; sends `mintPayment(tokenId)` to `originalMinter(tokenId)`.
- `refundBatch(tokenIds)`: any caller; 1–50 unique eligible paid IDs, possibly with different original minters/prices. One transaction/signature, individual original recipients, all tokens burned. Split larger histories into batches.
- `refundTo(tokenId, recipient)`: **only the original minter** may redirect their own refund, e.g. a contract wallet that rejects ETH. Third parties cannot choose a recipient.

Preflight every ID and simulate the complete batch. Zero-size, oversized, duplicate, nonexistent, treasury, previously refunded or nonpayable-recipient entries revert the entire batch. Exclude failures and retry valid IDs; a rejecting minter can call `refundTo` separately. No partial payout persists on a revert. Gas is not refunded. Do not describe a third-party batch as paying the caller.

Refund state is per ID. Track `mintPayment`, `originalMinter`, `refunded`, burns and `Refunded(tokenId,minter,recipient,amount)`. Do not calculate refund value from the current phase price or current NFT balance.

## Administrative API

| Call | Effect / guard |
| --- | --- |
| `configurePhase(id, priceWei, walletLimit)` | Current/future phase only; nonzero price/cap, even Pioneer cap; GTD budget enforced; historical counters retained |
| `configureAllowlist(root, hash, P, O, R)` | Admin, pre-Pioneer only; resets pre-start commitments and reserves; frozen after start |
| `advancePhase()` | Sequential irreversible closure; releases unused guarantees; next phase starts paused |
| `setMintPaused(bool)` | Active phase, before expiry; pause does not move deadline |
| `setMintEndTime(timestamp)` | Any future deadline while the existing sale is unexpired and not sold out; expired sales cannot reopen |
| `treasuryMint(amount, recipient)` | Treasury role, separate 500 free keys, before expiry |
| `withdraw()` | Treasury role; complete sellout; entire balance to calling treasury wallet |
| `reveal(baseURI)` | Admin, complete sellout, once, trailing slash required |
| `grantRole` / `revokeRole` / `renounceRole` | AccessControl; avoid removing the final administrator |

Use [the management guide](MANAGEMENT_CONSOLE.md) and [metadata guide](METADATA_AND_REVEAL.md) for operator flows. The contract has a shared editable end date, manual sequential starts and pauses; it does not expose four independent scheduled start/end dates. The ZIP's mock schedule must not drive transaction eligibility.

## Acceptance checks for the consumer frontend

Test a wallet from each exclusive tier, an unlisted wallet, a first-time proof mint, inherited access, odd Pioneer amounts, repeated phase mints, changed price/cap, closed/paused/expired phases, wrong chain, rejected signatures and pending recovery. Test a mixed-minter batch, repeated and nonexistent IDs, exact original payments and the rejecting-wallet fallback. Verify checker/proof/root/hash/count consistency and display a useful recovery path for a missing or stale snapshot.

The repository's browser test exercises actual local EVM transactions with a test EIP-1193 provider, not a specific wallet extension's private confirmation screen. Sepolia smoke testing uses real funds from the dedicated test wallet. Full 6,666-key sellout/reveal/withdrawal is tested locally to avoid funding a complete testnet campaign.
