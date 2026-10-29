# Ryodan Keys v3 frontend integration

Updated 2026-10-29. This is the handoff for the agent implementing the minting frontend. Use `src/RyodanKeys.sol` and the generated `abi/RyodanKeys.json`. The management reference is `../../console/`; its public URL is [ryodan.grooooog.space](https://ryodan.grooooog.space). Read [MANAGEMENT_CONSOLE.md](MANAGEMENT_CONSOLE.md) for operator workflows.

V3 management contract: [`0x3120e791E078ACF04601d623307B0e6866633E7A`](https://sepolia.etherscan.io/address/0x3120e791E078ACF04601d623307B0e6866633E7A). Initial deadline: **2026-11-28 14:01:12 UTC**; read its current value on chain.

## Deployment and version selection

Use Ethereum Sepolia, chain ID **11155111** (`0xaa36a7`). Read the selected address from `console/src/deployment.json` and verify `CONTRACT_VERSION()` against the corresponding deployment manifest. A manifest records historical deployment evidence; always read live state. There is no proxy: v3 needs a new address, and previous NFTs/funds remain in their original contracts.

`abi/RyodanKeys.json` is **v3**. `abi/RyodanKeys.v2.json` preserves the v2 API and supports the earlier listed v1 deployments (v1 has no version getter and no editable deadline). Never send v3 mint calldata to v1/v2. The console chooses the ABI by the on-chain version and rejects unknown future versions. Its active address is changed only after a verified deployment.

Use a public browser-safe RPC with fallback, such as `https://ethereum-sepolia-rpc.publicnode.com`. A connected wallet signs every write; no server signer or private key belongs in a browser bundle. Keep caches and pending transactions keyed by chain, contract and wallet.

## Four sequential phases

| ID | Phase | Initial price | Discount from initial public price | Initial limit per wallet | Access |
| --- | --- | --- | --- | --- | --- |
| 1 | Pioneer | 0.005 ETH | 50% | 4 | Allowlist, guaranteed allocation |
| 2 | Operative | 0.002 ETH | 80% | 6 | Allowlist, guaranteed allocation |
| 3 | Recruit | 0.001 ETH | 90% | 6 | Allowlist, first come first served |
| 4 | Civilian | 0.01 ETH | — | 10 | Public, first come first served |

These are constructor defaults, not constants to hardcode in the frontend. The admin can change each phase's exact wei price and wallet limit. Prices are stored independently: changing Civilian's price does **not** automatically reprice earlier phases or preserve discount percentages.

`currentPhase()` starts at 0 (not started). The admin calls `advancePhase()` to move **one step forward**: 0 → 1 → 2 → 3 → 4. Every advance pauses minting; `setMintPaused(false)` opens the new phase. A previous phase cannot reopen. The minter cannot select a phase or token ID. Phases are advanced manually, not automatically by dates; the shared mint deadline remains editable before expiry/sellout.

The limit is the total minted by one wallet **within that phase**, across all its transactions. `mintedInPhase(id, wallet)` is independent of earlier phases. There is no additional lifetime wallet cap. With default settings, an eligible wallet may mint 4 + 6 + 6 + 10, subject to availability. `mintedAmount(wallet)` remains a historical total; do not use it to subtract the current phase allowance. Treasury NFTs do not consume paid allowances. Pausing, removing/readding an address, transferring or refunding never resets mint counters.

### Supply and guarantees

There are **5,900 paid NFTs across all four phases**, plus a separate **500 free treasury NFTs**. The old 1,000-token whitelist cap is removed. Civilian has no fixed supply allocation: it receives `5900 - mintedByUsers` when it opens, after all earlier purchases. Earlier phases may exhaust the paid supply, leaving no Civilian inventory.

Pioneer and Operative guarantee each listed wallet its unminted phase allowance. `setPhaseAllowlist` reserves that amount; changing a guaranteed phase limit resizes the reservation for all listed wallets. Reservations across both guaranteed phases must fit the remaining paid pool or the entire transaction reverts. `totalGtdReserved()` and each phase's `reserved` show the outstanding quantities. Duplicate list entries are idempotent. Removing a wallet releases its remaining allocation; readding it reserves only the amount it has not already minted. Advancing closes the previous phase and releases its unused guarantee. Recruit only checks membership; Civilian is public.

Guarantees reflect the admin's current on-chain configuration. An admin can remove members, change price/limit, advance early or shorten the sale. Do not describe a guarantee as irrevocable or as a free NFT. Guaranteed limits cannot be reduced below the highest historical per-wallet mint count in that phase, even if that wallet has since been removed. FCFS limits can be reduced below a wallet's minted count; its remaining allowance becomes zero.

## Read one consistent snapshot

Pin reads to one block and use that block's timestamp, not the browser clock:

```text
CONTRACT_VERSION(), currentPhase(), mintPaused(), mintPrice(), mintEndTime()
phases(1), phases(2), phases(3), phases(4), totalGtdReserved()
MAX_PUBLIC_SUPPLY(), MAX_TREASURY_SUPPLY(), mintedByUsers(), mintedByTreasury()
totalSupply(), totalRefunded(), soldOut(), revealed(), refundsAvailable()
mintedInPhase(phaseId, wallet), remainingAllowance(phaseId, wallet)
allowlisted(phaseId, wallet), mintedAmount(wallet)
hasRole(DEFAULT_ADMIN_ROLE, wallet), hasRole(TREASURY_ROLE, wallet)
```

`phases(id)` returns `(price, walletLimit, minted, members, reserved, maxWalletMinted)`. `mintPrice()` returns the active phase's price, or zero before Pioneer starts. `remainingAllowance` includes eligibility and per-phase usage and returns zero for closed/invalid phases. It does not check pause, deadline, or shared supply; combine those checks:

```text
paidRemaining = MAX_PUBLIC_SUPPLY - mintedByUsers
availableSupply = paidRemaining - (totalGtdReserved if currentPhase > 2 else 0)
maxSelectable = min(availableSupply, remainingAllowance(currentPhase, wallet))
canMint = currentPhase != 0 && !mintPaused && block.timestamp <= mintEndTime
          && maxSelectable > 0
```

Use `bigint` throughout; no floating-point ETH calculations. Show active phase, exact price, current phase allowance and supply. The phase strip is informational; do not add a customer phase selector. Distinguish not started, paused, ineligible, exhausted wallet allowance, paid supply exhausted, successful sellout and failed expiry.

Success still requires **all 6,400 tokens**, including treasury. Selling all paid NFTs alone does not unlock reveal, transfers or withdrawals. At an unsuccessful expiry, paid NFTs become refundable. Mint is allowed at exactly `mintEndTime`; refunds begin strictly afterward. Deadline extensions are rejected after expiry, even before the first refund.

## Mint transaction and stale quotes

```js
// ethers v6; keys is the v3 contract connected to the user's Sepolia signer.
const amount = 2n;
const expectedPhase = snapshot.currentPhase;
const expectedUnitPrice = snapshot.price;
const args = [amount, expectedPhase, expectedUnitPrice];
const value = amount * expectedUnitPrice;
await keys.mint.staticCall(...args, { value });
const gas = await keys.mint.estimateGas(...args, { value });
// Show phase, quantity, exact ETH value, chain and contract for review.
// Refresh and verify the same quote/account/network before requesting a signature.
const tx = await keys.mint(...args, { value, gasLimit: gas * 120n / 100n });
const receipt = await tx.wait(2);
if (receipt.status !== 1) throw new Error('Mint reverted');
```

Signature: `mint(uint256 amount, uint8 expectedPhase, uint256 expectedUnitPrice)`. The phase argument is a stale-quote guard, **not a phase selector**. If either phase or unit price changes before execution, the contract reverts with `Mint quote changed`, even if the new phase happens to cost the same. The UI must request a new review rather than silently accepting a changed price. Limit or membership changes can also invalidate a pending mint; simulate again.

Connect and switch to Sepolia before simulation. Clear privileges and unsigned reviews on account/network changes. Track ready, simulating, awaiting signature, submitted, confirmed, rejected, reverted and RPC failure states. Disable duplicate submissions, preserve pending hashes across reload, and reconcile timeouts before allowing retries. Track equivalent replacements separately from cancellations or changed transactions. A transaction hash is not confirmation.

IDs start at 0 and are sequential across paid and treasury mints. Parse only this contract's `Transfer(address(0), wallet, tokenId)` receipt logs to discover minted IDs. Never predict IDs from a stale supply snapshot. `PaidMint(minter, phase, firstTokenId, amount, unitPrice)` additionally records the purchase phase and price. The contract is not ERC721Enumerable; index transfers from the deployment block and account for burns and secondary transfers.

## Operator functions

| Action | Function | Authority / conditions |
| --- | --- | --- |
| Set phase price and limit | `configurePhase(id, priceWei, walletLimit)` | Admin; current/future phase; open, unsold sale; positive price and limit 1–5,900 |
| Edit phase membership | `setPhaseAllowlist(id, addresses, allowed)` | Admin; current/future phases 1–3; GTD must fit supply |
| Start/advance | `advancePhase()` | Admin; open, unsold sale; one step; next phase starts paused |
| Pause/resume | `setMintPaused(bool)` | Admin; phase started; not expired; no counter reset |
| Change shared deadline | `setMintEndTime(timestampSeconds)` | Admin; current deadline not passed, not sold out; new time strictly future |
| Treasury mint | `treasuryMint(amount, recipient)` | Treasury; before expiry; remaining free allocation |
| Reveal | `reveal(baseURI)` | Admin; all 6,400 minted; one-shot |
| Withdraw | `withdraw()` | Treasury; sold out; sends entire balance to caller |
| Roles | `grantRole` / `revokeRole` | Admin; `DEFAULT_ADMIN_ROLE` is zero, read `TREASURY_ROLE()` |
| Refund | `refund(id)` / `refundTo(id, recipient)` | Original paid minter; unsuccessful expiry |

Only paid mint attaches ETH. The console batches allowlists at 100 addresses and treasury mints at 50 tokens; estimate gas and split large operations. Listen for `PhaseConfigured`, `PhaseAdvanced`, `MintPausedUpdated`, `AllowlistUpdated`, `PaidMint` and `MintEndTimeUpdated`, or poll at a reasonable interval. Re-read after every receipt.

## Refunds at the original payment

`mintPayment(tokenId)` permanently records the unit price paid for that NFT. A later price change never changes its refund. Read `refundsAvailable`, `originalMinter`, `refunded` and `mintPayment` to display eligibility and the exact amount. Treasury tokens have zero original minter/payment and cannot claim.

`refund(id)` burns the NFT and returns its recorded payment to the original minter. `refundTo(id, recipient)` allows that same minter to choose a nonzero recipient, useful for wallets rejecting ETH. Both attach zero ETH. Gas is not refunded. Approvals and NFT ownership do not transfer refund rights. Multiple different paid tokens may each be refunded once; the same token cannot be claimed again. Failed ETH delivery rolls back the burn and refund state.

There is no separate `redeem`, signed voucher, Merkle proof, ERC-20 approval or NFT approval required by this mint/refund API. An external feature called redeem needs its own integration review.

## Metadata

Before reveal, existing tokens return the constructor's hidden JSON URI. After the admin's permanent collection-wide reveal, token `i` returns `<baseURI><i>.json`; no holder transaction or random assignment is involved. Refresh on `Revealed` / ERC-4906 `BatchMetadataUpdate`. See [METADATA_AND_REVEAL.md](METADATA_AND_REVEAL.md).

Support `ipfs://`, HTTPS and JSON `data:` URIs; use IPFS gateway fallback and graceful missing-artwork handling. Treat fetched content as untrusted, validate media URLs and render text as text. Never inject fetched HTML/SVG/scripts. Refunded/burned IDs revert on `ownerOf`, `tokenURI` and `getApproved`.

## Acceptance checks

Test every phase, each membership list, separate wallet counters, repeat transactions within one phase, configurable caps/prices, GTD overbooking rejection, released guarantees and final public remainder. Verify phase/price races reject stale quotes and that minters cannot choose another phase. Include disconnected/wrong-chain flows, callbacks, pause/expiry, exact payment, wallet rejection, insufficient funds, pending/replaced transactions, full sellout and exact mixed-price refunds.

The reference browser suite uses a test EIP-1193 wallet and real Anvil transactions; it exercises all four phases, independent allowances, operator updates, stale-price recovery, refund protection, complete 6,400-token sellout, reveal and withdrawal. Actual wallet-extension dialogs and mobile wallet applications require separate compatibility testing. Successful full sellout/reveal/withdrawal is local evidence, not Sepolia evidence.
