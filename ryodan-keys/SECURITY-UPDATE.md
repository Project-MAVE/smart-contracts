# RyodanKeys — Security Update

Security review of `ryodan-keys/src/RyodanKeys.sol`, the fixes applied, and the regression
suite that proves each issue is closed.

All findings were reproduced with executable proof-of-concept tests before the fix and are now
covered by regression tests. Full suite: **23 tests passing** (`forge test`).

---

## Root cause

`refund()` used `originalMinter[tokenId]` as a payment ledger but never validated that the
`tokenId` had actually been minted and paid for, and never burned the token. Every critical and
high finding below descends from that single gap.

---

## Findings and fixes

### CRITICAL

**F-01 — `refund()` accepted unminted token IDs and burned ETH to `address(0)`**

`refund()` had no existence check. For any token ID that was never minted,
`originalMinter[tokenId]` is `address(0)`, and the low-level
`call{value: 0.01 ether}("")` to the zero address **succeeds** — the ETH is permanently
destroyed. An attacker could loop over arbitrary IDs to drain the entire contract balance and
permanently DoS every legitimate refund (`"Failed to send Ether"`).

*Fix:* `require(minter != address(0), "Token not minted")`.

**F-02 — `treasuryMint()` never recorded a payer, so treasury tokens were refundable**

`mint()` set `originalMinter[totalSupply] = msg.sender`; `treasuryMint()` did not. Every treasury
token therefore had `originalMinter == address(0)` and hit the same zero-address burn path — up to
500 tokens × 0.01 ETH = **5 ETH** of user funds destroyable by anyone.

*Fix:* same guard as F-01. Treasury tokens are now explicitly non-refundable, which is correct —
no ETH was ever paid for them.

### HIGH

**F-03 — `refund()` did not burn the NFT: free NFTs**

The refund credited `mintPrice` back to the minter but left ownership untouched. A user could take
the refund **and keep the token**; once the collection sold out, `_update` unlocked transfers and
the token could be resold. This extracted value directly from the project.

*Fix:* `refund()` now calls `_burn(tokenId)`. The `_update` override was rewritten to block only
genuine transfers (`from != address(0) && to != address(0)`), so minting and burning still work
while the soulbound restriction holds until sell-out.

### MEDIUM

**F-04 — `refund()` was permissionless**

Any third party could trigger a refund on someone else's token, consuming the one-shot
`refunded[tokenId]` flag and destroying an asset the owner may have wanted to keep.

*Fix:* `require(msg.sender == minter, "Only the original minter can refund")`.

**F-05 — the public and whitelist phases shared a single per-address cap**

`setPublicMintActive()` and `setWhitelistMintActive()` both wrote `MAX_MINT_AMOUNT`. Activating the
public phase silently overwrote the whitelist cap, so whitelisted users could no longer mint what
they had been promised.

*Fix:* split into `maxPublicMintAmount` and `maxWhitelistMintAmount`, each written by its own setter
and applied by the corresponding phase.

**F-08 — proceeds were permanently locked if the collection did not sell out**

`withdraw()` required `totalSupply == 6400`. If the sale fell short, the only other exit was
`refund()`, which was itself griefable (F-01/F-02) — so the ETH was unrecoverable or destroyable.

*Fix:* introduced `refundPool`, which tracks exactly the ETH owed to refundable, not-yet-refunded
user mints. `withdraw()` releases everything above `refundReserve()`, and the reserve is released
in full once refunds are permanently closed (collection sold out, or refund period expired).

### LOW

**F-06 — `tokenURI()` ignored the token ID and did not validate existence**
Returned metadata for tokens that were never minted. *Fix:* `_requireOwned(tokenId)`.

**F-07 — `mint()` accepted `amount == 0` and kept excess ETH**
`require(msg.value >= mintPrice * amount)` silently absorbed overpayment.
*Fix:* `require(amount > 0)` and `require(msg.value == MINT_PRICE * amount)`.

**F-09 — the refund window never closed, and `mintEndTime` was already in the past**
`mintEndTime` was hardcoded to `1767139200` (31 Dec 2025, now in the past), making the contract
dead on arrival, and refunds stayed open forever afterwards.
*Fix:* `mintEndTime` is now an `immutable` constructor argument validated to be in the future, with
`refundEndTime = mintEndTime + REFUND_PERIOD` (90 days) bounding the refund window.

### Hardening

- `ReentrancyGuard` on `refund()` and `withdraw()`, the two functions that send ETH.
- `treasuryMint()` rejects `address(0)` and `amount == 0`.
- Events added: `Minted`, `TreasuryMinted`, `Refunded`, `MintPhaseUpdated`, `Withdrawn`.
- Supply constants are now `public` and `MAX_TOTAL_SUPPLY` is derived rather than repeated.
- Solidity pragma raised to `^0.8.24`.

---

## Breaking changes

1. **Constructor takes an argument.** `constructor()` → `constructor(uint256 mintEndTime_)`. The
   deploy script reads `MINT_END_TIME` from the environment and defaults to
   `block.timestamp + 30 days`.
2. **`MAX_MINT_AMOUNT()` removed**, replaced by `maxPublicMintAmount()` and
   `maxWhitelistMintAmount()`.
3. **`mintPrice` (internal) → `MINT_PRICE` (public).**
4. **`refund()` burns the token.** Any frontend that still displays the NFT after a refund must be
   updated; `tokenURI()` for a refunded token now reverts.

## Design decisions worth confirming

- **Whitelist phase takes precedence.** When both phases are active, non-whitelisted callers still
  get `"Not whitelisted"` — the original semantics, preserved so existing tests and expectations
  hold. Routing them into the public phase instead is a one-line change.
- **Refunds burn but do not decrement `totalSupply`.** `totalSupply` is the token ID counter, not
  the live token count; decrementing it would cause ID reuse. Supply slots are therefore not
  recycled after a refund — which is fine, since refunds only open after minting has ended.

---

## Verification

```bash
cd ryodan-keys
forge test
```

```
Ran 14 tests for test/RyodanKeysSecurity.t.sol:RyodanKeysSecurityTest
Ran 9 tests for test/RyodanKeys.t.sol:RyodanKeysTest
Ran 2 test suites: 23 tests passed, 0 failed, 0 skipped
```

`test/RyodanKeysSecurity.t.sol` is the regression suite — one test per finding, each asserting the
exploit is now blocked, plus regressions for the soulbound transfer restriction, the refund reserve
invariant, and reentrancy on `refund()`.

Static analysis: `slither .` reports no High or Medium findings. The remaining informational
results are `block.timestamp` comparisons (by design), mint loops (unchanged), and the two
low-level ETH sends in `withdraw()`/`refund()`, both of which are role- or minter-gated and
reentrancy-guarded.
