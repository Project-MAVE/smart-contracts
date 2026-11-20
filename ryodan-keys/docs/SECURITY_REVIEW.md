# Ryodan Keys v6 — security review and evidence

Updated 2026-11-20. Scope: current Solidity source, allowlist compiler/loader, public ABI, management UI and deployment tooling. This is an implementation review with automated regression and adversarial testing, not an independent audit or proof that no vulnerability exists.

## Changes from v4

- Supply **6,666 = 6,000 paid + 666 treasury**, a different paid/treasury split from v4. Token IDs 1–6666 (v4 started at 0).
- Deadline fixed at deploy (`mintEndTime` immutable); `setMintEndTime` removed.
- No reveal: two numbered metadata sets fixed at deploy, SBT while locked and NFT once unlocked; the sellout emits `BatchMetadataUpdate(1, 6666)`.
- Keep or refund: for 72 hours after an unsuccessful deadline only each original minter keeps or refunds their own keys (`settle`); kept keys are transferable NFTs and never refundable. Afterwards anyone may refund undecided paid keys.
- `refundBatch` no longer reverts on a rejecting recipient: each call gets 50,000 gas without return-data copy, and a failed amount waits in `pendingRefund` for `claimPendingRefund`.
- Treasury: `withdrawKept` takes only kept-key payments; `burnTreasuryKeys` burns treasury keys after the window; `burn` lets the owner or an approved operator burn an unlocked key.

The historical “multiple redeem” issue (refunding nonexistent/free treasury IDs) stays fixed: a refund requires a recorded original minter and payment, burns the token and cannot repeat. The seven legacy regressions remain test-only evidence.

## Automated validation

- Solidity: `RadixV6.t.sol` (IDs 1–6666, numbered URIs, burn by an approved redeemer, sellout `BatchMetadataUpdate(1, 6666)`, low-gas `refundBatch`), `KeepOrRefund.t.sol`, `Phases.t.sol` (`test_SupplyIs6000Plus666`, `CONTRACT_VERSION() == 6`) together with the inherited phase, refund, deadline, deployment and invariant suites.
- Adversarial campaign on the unchanged v6 source (2026-11-19): 82 attack tests in 13 suites and stateful invariants at 2,000 runs × depth 200 (400,000 calls), no failure and no exploitable path to take ETH or mint for free.
- Console: 22 unit tests (only version 6 accepted; GTD capacity at 6,000 paid keys), 4 deployment tests and 26 browser checks on Anvil, including the full 6,666-key sale, the 72-hour keep-or-refund window, kept-payment withdrawal and treasury burn.

V4 coverage and Slither evidence (`security/forge-v4.txt`, `security/coverage-v4.lcov`, `security/slither-v4.json`) describes the v4 source and is kept as history; it is not a v6 measurement.

## Merkle and guaranteed-allocation review

Leaves double-hash `abi.encode(address,uint8 tier)` and nodes sort/hash two bytes32 siblings using OpenZeppelin verification. This avoids leaf/internal-node ambiguity and binds a proof to both address and tier. The compiler uses one canonical highest tier and deterministic leaf ordering; tests compare JavaScript proofs with the actual Solidity verifier.

Membership is set before any paid phase and freezes when Pioneer starts. A successful first proof mint registers that wallet once; a later different-tier proof cannot change its cached tier. All mint/registration changes revert together if payment, limits or ERC-721 receipt fails. Phase allowances remain independent and refunds never restore them.

For `P` exclusive Pioneer and `O` exclusive Operative wallets, reserve is `P×cap1+(P+O)×cap2`. Both guaranteed phases fit within paid supply before launch. Mints decrement the corresponding reserve; phase closure releases its unused portion; cap edits recompute it and cannot undercut the maximum historical GTD purchase. Recruit/Civilian cannot consume a live GTD reserve.

The CSV builder deduplicates and validates addresses, the snapshot validator reconstructs the tree and checks proofs/counts/digest, and the contract bounds registered members by declared tier count. Archive and review the exact CSVs and use their generated counts.

## Refund and lifecycle review

A paid token is eligible only after an unsuccessful expiry. Stored `mintPayment` preserves the exact purchase price across edits/phases. Treasury and nonexistent IDs have no original paid minter. Effects and burn happen before ETH delivery; `nonReentrant` covers every refund path. Inside the 72-hour window a refund by anyone but the original minter reverts, so no key is refunded before its minter could keep it. A kept key is never refundable. A third party cannot redirect another minter's refund.

Batch refunds are bounded to 50 IDs. A recipient that rejects ETH or exceeds the 50,000-gas stipend has its amount deferred to `pendingRefund`; it cannot stall the batch or return-bomb it. Locked keys are not transferable, so original minter and owner coincide for every refundable key.

Expiry is final: the deadline is immutable and no mint or phase reopens after it. Sold-out state depends on lifetime paid + treasury counts (6,000 + 666) and remains true after burns. Forced ETH changes neither outcome nor refund entitlement.

## Frontend and deployment boundary

The panel has no privileged backend or embedded key. Writes require wallet signatures, live chain/role checks, transaction simulation/estimation and fresh state. It rechecks expected phase/price and saves pending hashes by chain/contract. Imported metadata/snapshot details render as text. CSV processing stays in the browser and only hashes/counts are sent on chain.

The loader accepts only Sepolia/local Anvil, defaults to dry run, checks complete snapshot proofs and live capacity, and recognizes an already matching root/hash/count set. Its raw-count trust assumption is identical to the contract's; a valid JSON structure does not establish business approval.

Pinned toolchain remains Solidity 0.8.37, Cancun, optimizer 200; OpenZeppelin 5.7.0; forge-std 1.16.2; ethers 6.17.0; Vite 8.3.4; Playwright 1.64.0. No new npm dependency was added for CSV/Merkle generation.

The v6 test deployment on Sepolia is [`0xF4A43dF64D41B743Da20582AF49021732Aa298ad`](https://sepolia.etherscan.io/address/0xF4A43dF64D41B743Da20582AF49021732Aa298ad) (2026-11-20, test metadata, [Etherscan Exact Match](https://sepolia.etherscan.io/address/0xF4A43dF64D41B743Da20582AF49021732Aa298ad#code)); [the Sepolia runbook](SEPOLIA_RUNBOOK.md) records it with the historical v1–v4 deployments. The full 6,666-key sellout and withdrawal are local tests, not a funded Sepolia sale. No mainnet deployment or final artwork publication is claimed.
