# Ryodan Keys v7 — client changes before mainnet (2026-11-23)

v7 (`CONTRACT_VERSION = 7`) is v6 with the changes the client requested in the `neomars-mint-dev-2026-11-23` handoff, §4.1–4.7. No other function was added.

| § | Change | Contract |
| --- | --- | --- |
| 4.1 | Pioneer without pairs: any quantity from 1 to the cap | `_mintPaid` and `configurePhase` no longer require even amounts or caps; `console/src/allowlist.js` `capacity` drops the even check |
| 4.2 | Keep-or-refund window of 4 days | `CHOICE_WINDOW = 4 days` (was 72 hours) |
| 4.3 | Prices and caps locked from the opening of Pioneer | `configurePhase` requires `currentPhase == 0` ("Phases locked") |
| 4.4 | Sellout proceeds leave only after the deadline | `withdraw` requires `block.timestamp > mintEndTime` ("Mint not ended"); the sellout still unlocks transfers and NFT metadata at once |
| 4.5 | Roles on the Safe, admin moved in two steps | `AccessControlDefaultAdminRules` with delay 0: one administrator, `grantRole`/`revokeRole` cannot move it, `beginDefaultAdminTransfer` + `acceptDefaultAdminTransfer`. On mainnet pass the Safe `0x31Cd849c982ED10a94A66b4FD7867e97656952Eb` as both `admin` and `treasury` in the constructor |
| 4.6 | A Pioneer mints at most 4 across Pioneer and Operative | `remainingAllowance*` in Pioneer and Operative return `min(phase cap − used in phase, tier cap − gtdMinted)`, where `gtdMinted(account)` counts the wallet's mints across both guaranteed phases; guaranteed keys are a single reservation, `totalGtdReserved = P × Pioneer cap + O × Operative cap`, with no per-phase split (`phases(id)` no longer returns `reserved`); every Pioneer or Operative mint draws on it and it is released only when Recruit opens |
| 4.7 | Treasury 500, paid supply 6,166 | `MAX_PUBLIC_SUPPLY = 6166`, `MAX_TREASURY_SUPPLY = 500` |
| §4 launch values | Approved prices and caps in the constructor | 0.0075 / 0.012 / 0.0135 / 0.015 ETH per key, caps 4 / 4 / 10 / 20 |

Not changed: optional ERC-5192 `locked()` (not requested as required); `settle` stays all-or-nothing (§11.6: a contract wallet that rejects ETH cannot settle with refunds, it can refund through `refundBatch`/`pendingRefund` or keep everything).

## 2026-11-23 lists

`console/scripts/allowlist.mjs build --frozen-at 2026-11-23T09:36:00.000Z` on the supplied CSVs reproduces the client's expected result: 100 Pioneer, 1,403 Operative, 5,705 Recruit, root `0x40c8b3704d183afdb00b007b9409e4889767748360514333c38b442dfffaac5f`, snapshotHash `0xf367b4e690152ac5561b76480c1f3e3ad025b17ee8d23b907a8e5869d948f858`. On v7, `configureAllowlist` with these counts reserves 6,012 guaranteed keys and leaves 154 (v6 reverts with "Insufficient GTD supply"). With the current caps the lists can grow by at most 38 guaranteed wallets.

## Sepolia test deployment

[`0xd84bEbd8C2ED11546578962ebfD07FC56b79f07b`](https://sepolia.etherscan.io/address/0xd84bEbd8C2ED11546578962ebfD07FC56b79f07b), deployed 2026-11-23 with the mainnet deadline 1795629600, the client lists plus the six team test wallets in Pioneer, the 500 treasury keys minted before Pioneer, and Pioneer open. Details in [SEPOLIA_RUNBOOK.md](SEPOLIA_RUNBOOK.md).

## Launch order (mainnet)

1. Deploy with `mintEndTime = 1795629600` (2026-11-25 18:00 UTC), the final SBT/NFT folders and the Safe as admin and treasury; verify on Etherscan.
2. From the Safe: `configureAllowlist(root, snapshotHash, 100, 1403, 5705)` on the final lists.
3. From the Safe: `treasuryMint` 500 keys in blocks (about 25,600 gas per key, for example 5 × 100) before Pioneer.
4. At each opening time: `advancePhase()` then `setMintPaused(false)`. Pioneer 12:00 UTC, Operative 14:00, Recruit 16:00, Civilian 18:00 on 2026-11-24.
5. Sellout: `withdraw()` after 2026-11-25 18:00 UTC. No sellout: after the 4-day window `burnTreasuryKeys` in blocks of 50 and `withdrawKept()`; refunds stay open to each minter.

## Verification

Foundry: 199 tests, including fuzzing and invariants; the adversarial suites were updated to the new rules. Console: unit tests, the full browser journey on Anvil (two-step admin, locked phase form, 6,166 + 500 sellout with withdrawal after the deadline, 4-day window) and the resumable deploy scripts.
