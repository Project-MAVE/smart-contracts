# Frontend agent handoff — Ryodan Keys v7

> v7 (2026-11-23): Pioneer without pairs, a Pioneer cap shared by Pioneer and Operative, 6,166 paid + 500 treasury, a 4-day keep-or-refund window, prices/caps locked from Pioneer, sellout withdrawal after the deadline, two-step admin. See [V7_CHANGES.md](V7_CHANGES.md). Read `CONTRACT_VERSION` and accept only 7.

Use `abi/RyodanKeys.json` (v6) and `console/src/allowlist.js`. The management reference is [ryodan.grooooog.space](https://ryodan.grooooog.space). The v6 test contract on Sepolia is [`0xd069E170ECD211ca09157Afe6E9110E322BC30f8`](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8) (deployment block 12176051, test metadata); see the [Sepolia runbook](SEPOLIA_RUNBOOK.md). Older v1–v4 contracts use other ABIs and different supply; do not attach the v6 API to them. Contracts are not upgradeable and histories must be keyed by chain + contract + wallet.

## Commercial and phase model

| ID | Name | Price/key | Initial independent cap | Eligibility |
| --- | --- | --- | --- | --- |
| 0 | Not started | — | — | No mint |
| 1 | Pioneer | 0.0075 ETH | 4 | Tier 1, guaranteed; any quantity, 4 in total with Operative |
| 2 | Operative | 0.012 ETH | 4 | Tiers 1–2, guaranteed |
| 3 | Recruit | 0.0135 ETH | 10 | Tiers 1–3, FCFS |
| 4 | Civilian | 0.015 ETH | 20 | Everyone, FCFS |

Prices are the approved ones (2026-11-18) and caps the client's (2026-11-22); the v7 constructor sets both and they lock when Pioneer opens. Pioneer quantities count keys: any amount up to the remaining allowance.

Supply: `MAX_PUBLIC_SUPPLY=6166`, `MAX_TREASURY_SUPPLY=500`, `MAX_SUPPLY=6666` — **6,166 paid + 500 treasury = 6,666**. Civilian has no fixed quota; it receives the remaining paid allocation. Token IDs are assigned sequentially across treasury and paid mints from `FIRST_TOKEN_ID = 1` to 6666; they are unrelated to phase/tier.

## Frozen CSV/checker integration

Follow [the shared list workflow](ALLOWLISTS_AND_CLIENT_ALIGNMENT.md). Downloadable empty templates are in the management panel. Publish the generated `allowlist.json` and `check-data.js` from the same three frozen CSVs. The latter matches the ZIP's `NM.checkData` checker format. No production list files have been supplied. The bundled Sepolia snapshot is a test list: the dedicated test wallet plus five team test wallets, all in Pioneer.

Validate the JSON once with `validateSnapshot`. Compare `root`, `snapshotHash` and counts against `allowlistRoot`, `allowlistSnapshotHash` and `tierMembers(1..3)` at a pinned block. Use `proofFor(snapshot, account)` to get its highest tier and proof. Pioneer inherits eligibility for Operative and Recruit; Operative inherits Recruit. Do not duplicate addresses in three on-chain lists or treat raw checker membership as the final per-phase eligibility result.

`walletTier(account)` is a cache populated by the first successful `mintWithProof`. Therefore **`allowlisted` and `remainingAllowance` alone return false/zero before the first list mint**, even for valid members. Use `verifyEligibility` and `remainingAllowanceWithProof` with the downloaded proof for that case. Failed proof validation, payment or NFT receipt rolls registration back.

## Reads and state

Read `CONTRACT_VERSION` and accept only 7. Read one block and pin calls using `{ blockTag }`, including prices, all four `phases(id)` records, `currentPhase`, `mintPaused`, `mintEndTime`, totals, reserves, role checks and wallet counters. Use the block's timestamp, not the browser clock, for expiry.

`phases(id)` returns `(price, walletLimit, minted, members, maxWalletMinted)`. Guaranteed keys are one reservation, `totalGtdReserved`, not split by phase; `gtdMinted(account)` counts what a wallet minted across Pioneer and Operative. Members are inherited totals for phase eligibility; `tierMembers` are exclusive CSV counts. `mintedInPhase(id, account)` is historical phase usage. `mintedAmount(account)` is historical total paid purchases, useful for statistics rather than cap enforcement.

For the ZIP's `NM.chain` adapter:

- `state.phase`: 0 → `pre`, 1–4 → names above; `soldOut()` → `soldout`; timestamp greater than deadline and not sold out → `ended`. Represent `mintPaused` separately; do not show a paused phase as mintable.
- `state.supply`: 6666 (6,166 paid + 500 treasury); `state.minted`: `mintedByUsers + mintedByTreasury`. Burns reduce `totalSupply`, not lifetime minted counters.
- `wallet.lists`: derive inherited phase eligibility from the canonical tier. Preserve exclusive tier separately if the checker displays it.
- `wallet.mintedIn`: `mintedInPhase` for all phases. `remainingFor` uses proof-aware allowance and available supply. A closed phase returns zero.
- `wallet.tokens` and paid history: index `PaidMint`, ERC-721 `Transfer` and `Refunded` from the manifest's deployment block. The contract is not enumerable. Confirm current owner/refunded status before offering a refund.
- `priceFor`: read the per-key `phases` value. If the design displays a Pioneer pair price, multiply by 2 only for that display.
- `eligible` must also consider pause, current phase, deadline, remaining allowance/supply and correct chain. Membership by itself does not promise availability in FCFS.

Clamp allowance to `MAX_PUBLIC_SUPPLY - mintedByUsers`; for FCFS additionally subtract `totalGtdReserved`. Never display negative remaining allowance after a cap reduction. Disable writes on stale RPC data and re-read after account/network changes.

## Mint transaction

Example with ethers, after reading a coherent state and validated proof:

```js
const amount = 1n; // keys; any quantity up to the remaining allowance
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

## Unsuccessful sale: keep or refund

`refundsAvailable()` requires `block.timestamp > mintEndTime` and no sellout. At the exact deadline minting is still permitted; refunds are not yet available. A sold-out collection never opens refunds. The deadline is immutable: it is fixed at deploy and no function moves it.

For `CHOICE_WINDOW` (4 days) after the deadline, `choiceWindowOpen()` is true and only each original minter acts on their own paid keys:

- `settle(keepIds, refundIds)`: one signature, 1–50 IDs in total. Kept keys become transferable NFTs, read the NFT metadata set and are never refundable. Refunded keys are burned and their `mintPayment` sent to the minter. Keys must still be held by their original minter.
- `refund`, `refundTo` and `refundBatch` also work in the window, but only for the caller's own keys.

After the window anyone may call `refund(tokenId)` or `refundBatch(tokenIds)` (1–50 IDs) on undecided paid keys; each original minter receives the exact original payment. `refundTo(tokenId, recipient)` lets **only the original minter** redirect their own refund.

`refundBatch` gives each recipient 50,000 gas (`BATCH_REFUND_GAS`). A recipient that rejects ETH does not revert the batch: its amount is recorded in `pendingRefund(minter)` (event `RefundDeferred`) and the minter later pulls it with `claimPendingRefund(recipient)`. Duplicate, nonexistent, treasury, kept or already refunded IDs still revert the whole batch.

Refund state is per ID. Track `mintPayment`, `originalMinter`, `refunded`, `kept`, burns and the `Refunded`, `Kept`, `RefundDeferred` and `PendingRefundClaimed` events. Do not calculate refund value from the current phase price or current NFT balance.

## Administrative API

| Call | Effect / guard |
| --- | --- |
| `configurePhase(id, priceWei, walletLimit)` | Only before Pioneer opens (`currentPhase == 0`); nonzero price/cap; GTD budget recalculated |
| `configureAllowlist(root, hash, P, O, R)` | Admin, pre-Pioneer only; resets pre-start commitments and reserves; frozen after start |
| `advancePhase()` | Sequential irreversible closure; releases unused guarantees; next phase starts paused |
| `setMintPaused(bool)` | Active phase, before expiry; pause does not move the deadline |
| `treasuryMint(amount, recipient)` | Treasury role, before expiry, up to the separate **500** free treasury keys; mint them all before Pioneer |
| `withdraw()` | Treasury role; complete sellout of all 6,666 and `block.timestamp > mintEndTime`; entire balance to the calling treasury wallet |
| `withdrawKept()` | Treasury role; unsuccessful sale; only the payments of kept keys |
| `burnTreasuryKeys(ids)` | Treasury role; unsuccessful sale, after the 4-day window; treasury keys only (no original minter) |
| `grantRole` / `revokeRole` / `renounceRole` | AccessControl; avoid removing the final administrator |

Use [the management guide](MANAGEMENT_CONSOLE.md) and [metadata guide](METADATA.md) for operator flows. The contract has one end date fixed at deploy, manual sequential starts and pauses; it does not expose four independent scheduled start/end dates. The ZIP's mock schedule must not drive transaction eligibility.

## Acceptance checks for the consumer frontend

Test a wallet from each exclusive tier, an unlisted wallet, a first-time proof mint, inherited access, odd Pioneer amounts, repeated phase mints, changed price/cap, closed/paused/expired phases, wrong chain, rejected signatures and pending recovery. Test keep-or-refund inside the 72-hour window, a third-party refund refused in the window and accepted after it, a mixed-minter batch, repeated and nonexistent IDs, exact original payments and the pending-refund fallback for a rejecting wallet. Verify checker/proof/root/hash/count consistency and display a useful recovery path for a missing or stale snapshot.

The repository's browser test exercises actual local EVM transactions with a test EIP-1193 provider, not a specific wallet extension's private confirmation screen. Sepolia smoke testing will use real funds from the dedicated test wallet once a v6 contract is deployed. The full 6,666-key sellout (6,000 paid + 666 treasury), the automatic switch to NFT metadata and the withdrawal are tested locally to avoid funding a complete testnet campaign.
