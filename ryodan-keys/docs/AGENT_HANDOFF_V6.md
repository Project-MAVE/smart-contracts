# Ryodan Keys v6 — handoff to frontend and integration agents

Updated: 2026-11-20. This document supersedes the v4 handoff.

## Use these files

- Repository: [Project-MAVE/smart-contracts](https://github.com/Project-MAVE/smart-contracts), branch `main`.
- [V6 ABI](https://github.com/Project-MAVE/smart-contracts/blob/main/ryodan-keys/abi/RyodanKeys.json); `CONTRACT_VERSION() == 6`.
- [Shared CSV/Merkle implementation](https://github.com/Project-MAVE/smart-contracts/blob/main/console/src/allowlist.js).
- [Management panel](https://ryodan.grooooog.space/) and [CSV preparation](https://ryodan.grooooog.space/#sale). The panel manages only v6.
- Network for tests: **Ethereum Sepolia, chain ID 11155111**. V6 test contract: [`0xd069E170ECD211ca09157Afe6E9110E322BC30f8`](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8), deployment block 12176051, immutable deadline 2026-12-20 07:25:12 UTC, test pixel-art metadata (not final). Source verified on Etherscan with [Exact Match](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8#code) ([report](../deployments/sepolia-v6-etherscan.json)). The v1–v4 contracts on Sepolia are a different version with a different supply; do not use them for v6 work.

V6 is a new, non-upgradeable contract. Do not mix deployment histories or use an older ABI against v6.

## Supply and IDs

**6,666 keys = 6,000 paid + 666 treasury.** Token IDs run from **1 to 6666** in one sequence across paid and treasury mints. The front-end counter is `mintedByUsers + mintedByTreasury` out of 6,666.

The treasury mints its 666 keys with `treasuryMint(amount, to)`, free (gas only), in any phase and also before Pioneer opens. They take IDs 1–666 only if all are minted before the first paid mint. All 6,666 must be minted before the deadline to unlock transfers and withdrawal: a paid sellout of 6,000 alone does not succeed.

## Phases and prices

| Phase | Price per key (approved 2026-11-18) | Initial cap per wallet | Access |
| --- | ---: | ---: | --- |
| Pioneer | 0.0075 ETH (0.015 per pair) | 4 | Pioneer tier, guaranteed, pairs only |
| Operative | 0.012 ETH | 10 | Pioneer + Operative, guaranteed |
| Recruit | 0.0135 ETH | 10 | Pioneer + Operative + Recruit, FCFS |
| Civilian | 0.015 ETH | 10 | Public, FCFS |

The constructor sets 0.025/0.040/0.045/0.050; the admin sets the approved price with `configurePhase` before resuming each phase. Read live prices and caps instead of hardcoding them. **Pioneer quantity is keys, not pairs**; the contract rejects odd quantities and odd Pioneer caps. Caps are independent per phase: a Pioneer can initially buy 4 + 10 + 10 + 10 = **34 keys**.

Phases are sequential and selected by the contract, not the buyer. Advancing closes the previous phase forever and starts the next paused. The deadline is fixed at deploy and cannot move.

## Lists and checker

The panel provides empty templates ([ZIP](https://ryodan.grooooog.space/templates/ryodan-allowlist-templates.zip), [pioneer.csv](https://ryodan.grooooog.space/templates/pioneer.csv), [operative.csv](https://ryodan.grooooog.space/templates/operative.csv), [recruit.csv](https://ryodan.grooooog.space/templates/recruit.csv)) and generates **both `allowlist.json` and `check-data.js`** from the same three CSVs. The administrator signs the root/counts before Pioneer starts; membership then freezes. At default caps the guaranteed reservation is `14 × Pioneer count + 10 × Operative count ≤ 6000`. Details: [CSV/client alignment guide](ALLOWLISTS_AND_CLIENT_ALIGNMENT.md).

## Metadata

No reveal. Two numbered sets fixed at deploy: `sbtBaseURI` for locked keys and `nftBaseURI` for unlocked keys, files `1.json` to `6666.json`. Every key switches to the NFT set at sellout; a kept key switches alone. Details: [metadata guide](METADATA.md).

## Unsuccessful sale

For 72 hours after the deadline only each original minter keeps or refunds their own keys in one signature (`settle(keepIds, refundIds)`). Afterwards anyone may refund undecided paid keys with `refund` or `refundBatch` (1–50 IDs); each original minter receives the exact original payment. A wallet that rejects ETH does not block a batch: the amount waits in `pendingRefund` and is pulled with `claimPendingRefund`. The treasury withdraws only kept-key payments and burns its own keys after the window.

## Detailed references

- [Frontend integration guide](FRONTEND_INTEGRATION.md)
- [Management guide](MANAGEMENT_CONSOLE.md)
- [Security review](SECURITY_REVIEW.md)
- [Sepolia runbook (v6 test deployment, historical v1–v4)](SEPOLIA_RUNBOOK.md)

Production still needs completed CSVs, an agreed schedule, both pinned metadata sets and deliberately selected production admin/treasury wallets. No mainnet deployment or production member list is claimed.
