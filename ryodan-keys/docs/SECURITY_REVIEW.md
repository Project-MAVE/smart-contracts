# Ryodan Keys v4 — security review and evidence

Updated 2026-10-30. Scope: current Solidity source, allowlist compiler/loader, public ABI, management UI and deployment tooling. This is an implementation review with automated regression/static testing, not an independent audit or proof that no vulnerability exists.

## Changes from v3

V4 applies the supplied client specification: 6,666 total keys, prices 0.025/0.040/0.045/0.050 ETH, independent caps 4/10/10/10, Pioneer pairs, hierarchical single-tier Merkle eligibility and permissionless original-minter batch refunds. It keeps editable live/future prices/caps, a shared editable deadline, sequential irreversible phases, treasury-gated complete sellout, locked transfers and one-shot reveal.

The old reported “multiple redeem” issue was reproduced in the historical fixture as refunding **nonexistent/free treasury IDs**, which could destroy paid refund reserves. Refunding distinct paid tokens is legitimate; the same ID was already protected by the old flag. Current code requires a recorded original minter/payment, burns refunded tokens and prevents reuse. The seven legacy regressions remain test-only evidence; they do not identify an exploited mainnet address.

## Automated validation

The CI profile passes **108 tests/properties**, including **12 fuzz tests** (1,000 runs each), **5 stateful invariants** (256 runs, depth 128), seven legacy regressions and four deployment-script tests. Evidence: [forge-v4.txt](security/forge-v4.txt).

Coverage excluding imported libraries and generated getters reaches **100% lines (209/209), statements (253/253) and functions (28/28)**, plus **99.22% branches (128/129)**. The remaining branch is the defensive FCFS reservation refusal: sequential phase advancement releases all GTD reservations before FCFS is reachable. Coverage runs exclude invariant handlers; the full CI-profile suite runs those separately. The deployment script reaches 100% line/statement/branch/function coverage. [LCOV evidence](security/coverage-v4.lcov).

Stateful invariants cover supply/accounting, Ether conservation/refund solvency, sequential phases, exact GTD reserves and live-token ownership. The handler exercises mutable prices/caps/deadlines, phase advancement, frozen-list replacement attempts, minting, treasury allocation, transfers and all refund paths. Full sellout/reveal/withdrawal also has deterministic and browser coverage.

Meaningful v4 cases include inherited 34-key purchases; proof replay against a different address/tier; malformed proofs and registration rollback; even Pioneer amounts/caps; exact-fit and oversized GTD allocations; independent phase limits; quote changes; remaining public supply; admin callback reentry; mixed-price/mixed-minter refunds; arbitrary batch callers; zero/oversized/duplicate/nonexistent/treasury IDs; rejecting recipients; complete rollback; callback reentry; exact expiry; expired-sale reopening; forced ETH and lost-role effects.

The JavaScript suite tests CSV parsing/validation, empty downloadable templates, highest-tier deduplication, odd/even Merkle trees, deterministic proofs, checker-schema compatibility, tampered snapshots/counts/hashes, GTD capacity, phase/deadline/role/network gates, metadata URI validation and batch-ID validation. Local deployment tests verify resumable manifests, all four phases and complete mixed-price refunds. Browser tests execute real transactions against Anvil through a test EIP-1193 wallet, including CSV download/build/on-chain loading, first proof mint, inherited phases, updated caps, stale-quote refusal/recovery, pending reload, third-party batch refund, full 6,666-key sellout, reveal and withdrawal. Desktop/mobile evidence is inspected visually; browser/network errors must be explained or fixed before publication.

## Slither 0.11.6

V4 analysis covers 25 contracts and 102 detectors, with dependency/test/script reports filtered. The configured medium/high gate passes. The retained output is **10 low timestamp findings and 4 informational findings** (two costly-loop, two low-level-calls), with no unsuppressed medium/high findings. [Normalized results](security/slither-v4.json).

Three findings receive narrowly scoped source annotations, not a global detector disable:

| Finding | Assessment and enforcement |
| --- | --- |
| `arbitrary-send-eth` in `withdraw` | Only a treasury-role caller receives funds; complete sellout and the reentrancy guard apply. Tests reject unauthorized calls and protect failed-sale reserves. |
| `arbitrary-send-eth` in `_refund` | `refund` and `refundBatch` derive recipients from `originalMinter`. `refundTo` verifies that the caller is that minter before permitting another recipient. Amount is the stored original payment, effects/burn precede the checked call, and all entry points are nonReentrant. |
| `calls-loop` through `refundBatch` | Intentional payout to individual original minters, capped at 50 IDs. Failure reverts the entire batch, never a partial payout. A rejecting wallet can be excluded and recover via its own `refundTo`. Mixed-recipient/rejection/reentry tests cover the behavior. |

Timestamp is a sale boundary, not randomness. Checked low-level `call` supports contract-wallet refunds. Counter writes inside the bounded refund loop preserve per-token accounting; gas estimation and smaller batches remain necessary. Annotations document an assessed trust boundary; they are not evidence that a detector was unnecessary. Use `--show-ignored-findings` for full review. Run Slither separately from tooling consuming build artifacts because its compiler integration may clean them.

## Merkle and guaranteed-allocation review

Leaves double-hash `abi.encode(address,uint8 tier)` and nodes sort/hash two bytes32 siblings using OpenZeppelin verification. This avoids leaf/internal-node ambiguity and binds a proof to both address and tier. The compiler uses one canonical highest tier and deterministic leaf ordering; tests compare JavaScript proofs with the actual Solidity verifier.

Membership is set before any paid phase and freezes when Pioneer starts. A successful first proof mint registers that wallet once; a later different-tier proof cannot change its cached tier. All mint/registration changes revert together if payment, limits or ERC-721 receipt fails. Phase allowances remain independent and refunds never restore them.

For `P` exclusive Pioneer and `O` exclusive Operative wallets, reserve is `P×cap1+(P+O)×cap2`. Both guaranteed phases fit within paid supply before launch. Mints decrement the corresponding reserve; phase closure releases its unused portion; cap edits recompute it and cannot undercut the maximum historical GTD purchase. Recruit/Civilian cannot consume a live GTD reserve.

**Admin trust remains:** a Merkle root alone cannot prove leaf count or address uniqueness. The CSV builder deduplicates and validates addresses, the snapshot validator reconstructs the tree and checks proofs/counts/digest, and the contract bounds registered members by declared tier count. A dishonest or mistaken root/count commitment can deny access or invalidate guarantees. Archive and review the exact CSVs and use their generated counts. Snapshot hashes attest identity of input bytes; they do not establish client approval. Hash-only lists are not an anonymity guarantee against known-address lookups.

## Refund and lifecycle review

A paid token is eligible only after unsuccessful expiry. Stored `mintPayment` preserves the exact purchase price across edits/phases. Treasury and nonexistent IDs have no original paid minter. Effects and burn happen before ETH delivery; `nonReentrant` covers single, batch and redirected refunds. Any failed ETH transfer restores ownership, flags, balances and counts. A third-party caller cannot redirect another minter's refund.

Batch refunds are atomic and bounded to 50. They can still exceed gas limits for expensive recipient contracts; estimate and split them. Recipient rejection denies that particular batch, not all other users' refunds. Since transfer is impossible before success and refunds are impossible after success, original minter/ownership assumptions do not diverge during an eligible refund.

Expiry is final: no deadline extension, mint or phase reopening after it, even before the first refund. Therefore burned sequential IDs cannot be reused by reopening a failed sale. Sold-out state depends on lifetime paid+treasury counts and remains true after transfers. Forced ETH changes neither outcome nor refund entitlement.

## Retained product and operational risks

- Complete success includes all 500 treasury keys. Mint them before expiry; paid sellout alone is insufficient. Free treasury tokens never receive refunds.
- Administrators can change open/future prices/caps and the deadline before expiry, shorten it to any future timestamp, advance phases and choose the final metadata URI. There is no timelock, notice period or maximum extension. Display live settings accurately.
- Phase advancement abandons unused guarantees and cannot be reversed. Review loaded CSV commitments before starting; final production lists have not been supplied.
- Reveal has no randomness/provenance commitment. A wrong final URI is permanent; mutable hosting may still change its contents. Metadata must be independently validated and pinned.
- Losing all administrator access can prevent reveal or role recovery. A treasury-role holder can withdraw the entire successful-sale balance. Use intentionally assigned production role holders; the shared test wallet is for Sepolia.
- Forced/unsolicited ETH can remain after legitimate failed-sale refunds. No sweep function is introduced that could endanger refund reserves.
- Merkle snapshots are not chain/contract-specific signatures; the same deliberately configured root grants the same tier on another deployment. Mint counters, funds and refund rights remain deployment-specific.
- No upgrade or automatic holder/fund migration exists. Old deployments retain their original behavior.

## Frontend and deployment boundary

The panel has no privileged backend or embedded key. Writes require wallet signatures, live chain/role checks, transaction simulation/estimation and fresh state. It rechecks expected phase/price and saves pending hashes by chain/contract. Imported metadata/snapshot details render as text. CSV processing stays in the browser and only hashes/counts are sent on chain.

The loader accepts only Sepolia/local Anvil, defaults to dry run, checks complete snapshot proofs and live capacity, and recognizes an already matching root/hash/count set. Its raw-count trust assumption is identical to the contract's; a valid JSON structure does not establish business approval.

Pinned toolchain remains Solidity 0.8.37, Cancun, optimizer 200; OpenZeppelin 5.7.0; forge-std 1.16.2; ethers 6.17.0; Vite 8.3.4; Playwright 1.64.0. No new npm dependency was added for CSV/Merkle generation. The compiled runtime is 17,367 bytes, below EIP-170's limit.

See [the Sepolia runbook](SEPOLIA_RUNBOOK.md) for actual deployment/receipt/source-verification evidence. Full-size sellout, reveal and withdrawal are local tests, not a funded Sepolia sale. No mainnet deployment or final artwork publication is claimed.
