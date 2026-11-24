# Ryodan Keys v8 — final lists in order of arrival (2026-11-24)

v8 (`CONTRACT_VERSION = 8`) is v7 with the supply split restored to 6,000 paid + 666 treasury and a guaranteed reservation that no longer rejects a list larger than the paid supply. No function, event or storage variable was added or removed: the ABI is the v7 ABI.

| Change | Contract |
| --- | --- |
| Supply 6,666 = 6,000 paid + 666 treasury | `MAX_PUBLIC_SUPPLY = 6000`, `MAX_TREASURY_SUPPLY = 666` (v7: 6,166 + 500) |
| A list that asks for more guaranteed keys than the paid supply is accepted | `configureAllowlist` no longer reverts with "Insufficient GTD supply": `totalGtdReserved = min(P × Pioneer cap + O × Operative cap, MAX_PUBLIC_SUPPLY − mintedByUsers)` |

Everything else is v7: phases, prices, caps, the Pioneer cap shared by Pioneer and Operative, the immutable deadline, keep-or-refund, roles and metadata. See [V7_CHANGES.md](V7_CHANGES.md).

## What the oversubscribed list means

The wallet caps of Pioneer and Operative are **maximum purchases, not guarantees**, whenever the lists ask for more than 6,000 keys. Keys go to the wallets that mint first.

- With the 2026-11-24 lists (105 Pioneer, 1,455 Operative, 5,699 Recruit; 7,259 wallets) the caps add up to 105 × 4 + 1,455 × 4 = **6,240 keys against 6,000 for sale**. The reservation is 6,000: nothing is left outside it for Recruit and Civilian unless Pioneer and Operative wallets leave keys unminted.
- If every wallet mints its full cap, the sale ends during Operative: the last 60 wallets (240 keys) are refused with "Max supply reached", and Recruit and Civilian receive no key.
- Keys that Pioneer and Operative wallets do not mint are released when Recruit opens and reach Recruit and Civilian as in v7.
- The 666 treasury keys are a separate supply: `treasuryMint` works before, during and after the paid sellout, until the deadline; the 667th is refused.
- `advancePhase` reverts with "All tokens minted" once all 6,666 keys exist. If the paid supply ends in Operative and the treasury keys are already minted, the phase stays Operative; the sale is complete and nothing more can be minted.

## Mint page

`remainingAllowance` and `remainingAllowanceWithProof` return the wallet's cap that is still unused; they do not look at the supply. After the paid sellout they still return a positive number while `mint` reverts with "Max supply reached". Show a wallet `min(remainingAllowance, MAX_PUBLIC_SUPPLY − mintedByUsers)` and the sold-out state when `mintedByUsers == MAX_PUBLIC_SUPPLY`.

## 2026-11-24 lists

Root `0x2a19f9ca68d2a0630ce1ebd9842e9e359d31054a708cd4aabc2d411a72bb51b4`, snapshotHash `0xa49a0a4717ed59a01c4b2a53fd1b1e4d2ec33e0480b6a03fd83261bb42b44bed`, counts 105 / 1,455 / 5,699. `configureAllowlist` with these values succeeds on v8 and sets `totalGtdReserved` to 6,000; on v7 it reverts.

## Launch order

As in v7, with the v8 numbers: `configureAllowlist(root, snapshotHash, 105, 1455, 5699)`, then `treasuryMint` of the 666 treasury keys in blocks before Pioneer (they take IDs 1–666), then `advancePhase()` and `setMintPaused(false)` at each opening.

## Verification

Foundry: 211 tests with fuzzing and invariants in CI. Two further suites run when a list fixture is supplied and are skipped otherwise: `test/fork/AllowlistFork.t.sol` (20 tests, every wallet of the list in every phase) and `test/fork/FinalListFcfs.t.sol` (2 tests on the definitive list: full-cap mints exhaust the paid supply in Operative, partial mints leave keys for Recruit and Civilian). All 22 pass on the 2026-11-24 lists.
