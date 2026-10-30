# Ryodan Keys v4 — handoff to frontend and integration agents

Updated: 2026-10-30. This document supersedes the v3 handoff. The reference is the client-supplied `neomars-mint-dev-2026-10-08.zip`, followed by the instruction to provide empty CSV templates because final lists do not yet exist.

## Use these endpoints and files

- Network: **Ethereum Sepolia, chain ID 11155111**.
- Current management/mint contract: **`0xCCe14de13cd2f917a2B85b17D5E325Bd5e48BBa8`**.
- [Verified source on Sepolia Etherscan](https://sepolia.etherscan.io/address/0xCCe14de13cd2f917a2B85b17D5E325Bd5e48BBa8#code): exact match, Solidity 0.8.37, optimizer 200, Cancun; 25 source files compared.
- [Management panel](https://ryodan.grooooog.space/) and [CSV preparation](https://ryodan.grooooog.space/#sale).
- Repository: [Project-MAVE/smart-contracts](https://github.com/Project-MAVE/smart-contracts), branch `main`.
- [V4 ABI](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/abi/RyodanKeys.json).
- [Deployment manifest and receipts](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/deployments/sepolia-v4.json).
- [Shared CSV/Merkle implementation](https://github.com/Project-MAVE/smart-contracts/blob/main/console/src/allowlist.js).
- [Current testnet snapshot](https://github.com/Project-MAVE/smart-contracts/blob/main/console/src/allowlist.json).

The current smoke sale is in Pioneer with two paid keys and one treasury key, holding 0.050 ETH. The dedicated test wallet is `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`; it is the only Pioneer member in this snapshot and has already consumed two of its four Pioneer keys. No key material belongs in the frontend.

V4 is a new, non-upgradeable contract. V3 and its histories remain at their previous addresses; do not mix deployment histories or use the old ABI against v4.

## Final defaults

| Phase | Price per key | Discount against public | Initial cap per wallet | Access |
| --- | ---: | ---: | ---: | --- |
| Pioneer | 0.025 ETH | 50% | 4 | Pioneer tier, guaranteed, pairs only |
| Operative | 0.040 ETH | 20% | 10 | Pioneer + Operative, guaranteed |
| Recruit | 0.045 ETH | 10% | 10 | Pioneer + Operative + Recruit, FCFS |
| Civilian | 0.050 ETH | — | 10 | Public, FCFS |

**Pioneer quantity is keys, not pairs:** 2 keys cost 0.050 ETH; 4 cost 0.100 ETH. Enforce step 2 in the UI; the contract rejects odd quantities and odd Pioneer caps.

Caps are independent per phase. A Pioneer can initially buy 4 + 10 + 10 + 10 = **34 keys**. Repeat mints in one phase consume its existing allowance. Prices/caps remain configurable by admin; read live values instead of hardcoding defaults.

Supply: **6,666 total = 6,166 paid + 500 treasury**. Civilian receives the paid remainder after Recruit, without a fixed separate quota. All 6,666 must mint to unlock transfers/reveal/withdrawal. Complete the treasury allocation before expiry; paid sellout alone does not succeed.

Phases are sequential and selected by the contract, not the buyer. Admin advancement closes the previous phase forever and starts the next paused. There is one editable shared deadline, plus manual advance/pause/resume. The ZIP's mock dates must not drive mint eligibility.

## Lists, checker and downloadable templates

Final client CSVs are not available. The panel now provides:

- [All three templates + instructions (ZIP)](https://ryodan.grooooog.space/templates/ryodan-allowlist-templates.zip)
- [pioneer.csv](https://ryodan.grooooog.space/templates/pioneer.csv)
- [operative.csv](https://ryodan.grooooog.space/templates/operative.csv)
- [recruit.csv](https://ryodan.grooooog.space/templates/recruit.csv)

Every template contains only the `address` header. Add one address per line, in its highest tier only. Repeated addresses are deduplicated with Pioneer > Operative > Recruit. Invalid/zero addresses stop generation.

In Sale controls, select all three files, choose the UTC freeze time, generate, review counts/hashes/capacity, and download **both `allowlist.json` and `check-data.js`**. CSV processing stays in the browser. These files are generated from the same input snapshot; `check-data.js` matches Gigio's `NM.checkData` schema with SHA-256 hashes of lowercase addresses.

The client/operator owns CSV completion. The administrator signs the generated root/counts **before starting Pioneer**. The frontend team publishes both generated files. Imported/generated files are session-only until explicitly downloaded/deployed. Do not maintain a separately edited checker list.

Membership and counts freeze when Pioneer starts. The current Sepolia smoke sale has already frozen its test-only snapshot; real campaign lists require the fresh campaign deployment. At default caps the GTD reservation is `14 × Pioneer count + 10 × Operative count ≤ 6166`. Both the builder and contract enforce capacity. The root alone cannot prove cardinality; always use generated counts and review the CSV commitments.

## Required frontend changes

1. Switch the configured address, deployment block and ABI to v4. Preserve history namespaces by chain + contract + wallet.
2. Read version, phase, paused state, phase price/cap, minted counters, deadline, reserves and supply from one pinned block. Use chain time.
3. Load and validate the matching snapshot. Compare root, snapshot hash and exclusive counts against chain state; get the wallet's proof with `proofFor(snapshot, account)` from the shared implementation.
4. First list purchase uses `mintWithProof(amount, expectedPhase, expectedUnitPrice, tier, proof)` with exact `amount × unitPrice` wei. Use bigint. Pioneer amount must be even.
5. `walletTier`, `allowlisted` and `remainingAllowance` only know cached membership after a successful first proof mint. Before that, use `verifyEligibility` and **`remainingAllowanceWithProof`**. Otherwise a valid first-time member can appear ineligible.
6. A previously registered list wallet may use `mint(amount, expectedPhase, expectedUnitPrice)`; Civilian uses that method without a proof. The expected phase/price prevent purchasing under a stale quote.
7. Apply inherited eligibility to the mint UI: Pioneer qualifies for 1/2/3, Operative for 2/3, Recruit for 3, everyone for 4. Preserve one exclusive tier for the checker. Keep wallet usage separate by phase.
8. Obtain actual IDs from confirmed `Transfer`/`PaidMint` logs. IDs are sequential across paid and treasury mints, not selected or partitioned by phase.
9. Simulate, estimate gas, recheck wallet/network/state before signing, and retain pending hashes through reload. Rejected signatures and changed quotes must recover without duplicate transactions.

Merkle leaf is `keccak256(bytes.concat(keccak256(abi.encode(account, tier))))`; tier is 1/2/3. Nodes hash sorted pairs, leaves are sorted, and odd unmatched nodes are promoted. Use the supplied implementation rather than another tree convention. The reference Solidity expression is `keccak256(bytes.concat(keccak256(abi.encode(account, tier))))`.

## Batch refunds

`refundBatch(uint256[] tokenIds)` is available, with **1–50 unique eligible paid IDs** and **one signature per batch**. Any caller can trigger it; each original minter receives the exact original amount recorded for their token. The caller never receives other wallets' refunds. IDs may belong to different minters and prices.

Refunds are available only after unsuccessful expiry. A batch burns all selected tokens atomically. A duplicate, missing, free treasury, already refunded or ETH-rejecting-recipient entry reverts the whole transaction. Preflight, remove invalid entries and retry; split batches when needed for gas. Repeating a refund cannot pay twice.

`refund(id)` now also permits any caller and always pays the original minter. `refundTo(id, recipient)` is retained solely for the original minter to redirect their own refund, including recovery for a wallet that rejects ETH. A third party cannot redirect it. Refund values come from `mintPayment(id)`, not today's phase price; gas is not refunded.

## Management and reveal

The panel covers mint, phase prices/caps, sequential advance, pause/resume, UTC deadline, CSV/snapshot preparation, treasury mint/withdrawal, one-shot reveal, role changes, single refunds and batch refunds. It includes the active address and Sepolia Etherscan link.

Admin can edit a current/future phase with `configurePhase`; GTD reductions cannot undercut historical purchases and increases must fit remaining supply. `setMintEndTime` only changes an unexpired, unsold-out sale to a future time. Expired sales never reopen.

Reveal is once, after full sellout. Prepare and pin metadata `0.json` through `6665.json`, then call `reveal(baseURI)` with a trailing `/`. Before reveal all existing tokens share the hidden URI. There is no random shuffle or metadata provenance commitment. Final artwork has not been published as part of these test deployments.

## Verification and remaining production inputs

- **108 Solidity tests/properties**, including 12 fuzz tests at 1,000 runs and 5 stateful invariants at 256 runs/depth 128.
- Contract coverage: 100% lines, statements and functions; 128/129 branches. The uncovered defensive branch requires an FCFS phase with a live GTD reservation, which sequential closure prevents.
- Slither: no unsuppressed medium/high findings. Reviewed annotations cover role-authorized withdrawal, original-minter refund destinations and the intentionally bounded atomic payout loop. Ten low timestamp and four informational findings remain documented.
- 19 JavaScript tests; 22 local browser journey checks, with screenshots inspected on desktop/mobile; live-site checks include template downloads, old ABI compatibility and RPC fallback recovery.
- Full 6,666-key sellout, reveal and mixed-price withdrawal were exercised locally. The live Sepolia sale is a smoke test, not a complete funded collection.
- Live Sepolia QA completed all four phases and refunded all five paid keys for **0.185 ETH in one batch**, with duplicate and expired-reopen rejection. [Refund receipt](https://sepolia.etherscan.io/tx/0x51f9beefefc4cec5c309b7c6f635c4996dd672c40fdd1d2153a933afc027871e). Only the free treasury token remains, with zero ETH in the QA contract. The Sepolia caller is the original minter; third-party initiation is covered locally.
- Separate refund QA contract: [`0x084E7a42D8CBdBd95F65FEc853f5Bc16E6656B5a`](https://sepolia.etherscan.io/address/0x084E7a42D8CBdBd95F65FEc853f5Bc16E6656B5a). Etherscan links its identical runtime to the verified management source as a Similar Match; its own creation bytes and constructor arguments were independently checked against the deployment transaction. This is distinct from the management contract's Exact Match.

Production still needs completed CSVs, an agreed real schedule, final hidden/revealed assets and deliberately selected production admin/treasury wallets. No mainnet deployment or production member list is claimed.

## Detailed references

- [Frontend integration guide](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/docs/FRONTEND_INTEGRATION.md)
- [CSV/client alignment guide](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/docs/ALLOWLISTS_AND_CLIENT_ALIGNMENT.md)
- [Management guide](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/docs/MANAGEMENT_CONSOLE.md)
- [Metadata/reveal guide](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/docs/METADATA_AND_REVEAL.md)
- [Security review](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/docs/SECURITY_REVIEW.md)
- [Sepolia runbook](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/docs/SEPOLIA_RUNBOOK.md)
