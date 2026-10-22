# Ryodan Keys frontend integration

This is the handoff for the agent implementing the minting frontend. Use v2 `src/RyodanKeys.sol`, the generated `abi/RyodanKeys.json`, and `deployments/sepolia-v2.json`. A working management/mint console is now in `../../console/` and published at [ryodan.grooooog.space](https://ryodan.grooooog.space). See [MANAGEMENT_CONSOLE.md](MANAGEMENT_CONSOLE.md) for operator workflows. The console uses ethers 6.17.0 and Vite 8.3.4; the generic viem example below remains an alternative integration pattern.

## Network and deployment

- Ethereum Sepolia, chain ID **11155111** (`0xaa36a7`), currency ETH, 18 decimals.
- Read the top-level `address` from `deployments/sepolia-v2.json`: **`0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B`**, [Sepolia Etherscan](https://sepolia.etherscan.io/address/0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B). `console/src/deployment.json` is its public frontend subset.
- `deployments/sepolia.json` preserves the two earlier v1 deployments under `contracts.mint` / `contracts.refund`; their deadlines remain immutable. The console labels them explicitly. A refund QA contract must never be the default active sale.
- The manifest is evidence of a particular deployment, not live application state. Read current chain state on every visit and after transactions.
- Configure a public browser-safe RPC URL. The reference endpoint is `https://ethereum-sepolia-rpc.publicnode.com`. Allow an RPC fallback and surface network failures.
- The deployed contract has no proxy. A new deployment requires an explicit address/ABI update in the frontend.
- The signer key belongs exclusively in hush on the operator machine. The frontend uses the connected user's wallet. Never embed a private key or a privileged RPC credential in a browser bundle.

## Sale rules

| Item | Contract rule |
| --- | --- |
| Price | `mintPrice()`: 0.01 ETH per paid NFT; send exactly `price * amount` |
| Paid supply | 5,900, including up to 1,000 whitelist mints |
| Free treasury supply | 500, a separate bucket |
| Success | All 6,400 tokens minted, including the treasury bucket |
| Wallet allowance | `MAX_MINT_AMOUNT() - mintedAmount(wallet)`, shared across whitelist and public phases |
| Deadline | Admin-editable while the current deadline has not passed and the sale is not sold out; mint allowed at `timestamp <= mintEndTime()`; refunds start strictly after it if unsuccessful |
| IDs | Start at 0; paid and treasury mints share the same sequence |
| Transfers | Locked until `soldOut()` is true, independently of reveal |
| Refund | Original paid minter only, once per token; token is burned |
| Refund value | 0.01 ETH per paid token, excluding transaction fees |

A wallet holding treasury NFTs may still have its full paid-mint allowance. Use `mintedAmount`, not `balanceOf`, to calculate allowance. A previously purchased NFT still counts toward lifetime allowance even after transfer or refund. The admin may change the deadline and wallet limit; clamp remaining allowance to zero if the new limit is below the amount already minted.

## Read a consistent state snapshot

Read these getters at one block (multicall or individual calls pinned to the same `blockNumber`). Include that block's timestamp; the browser clock alone is not authoritative.

```text
CONTRACT_VERSION(), mintPrice(), mintEndTime(), MAX_MINT_AMOUNT()
MAX_PUBLIC_SUPPLY(), MAX_TREASURY_SUPPLY(), WL_MINT_AMOUNT()
mintedByUsers(), mintedByTreasury(), mintedByWhitelist()
totalSupply(), totalRefunded(), soldOut(), revealed()
isPublicMintActive(), isWhitelistMintActive()
mintedAmount(wallet), whitelisted(wallet) // only if connected
```

Compute using integers / `bigint`:

```text
paidRemaining = MAX_PUBLIC_SUPPLY - mintedByUsers
walletRemaining = max(0, MAX_MINT_AMOUNT - mintedAmount(wallet))
whitelistRemaining = WL_MINT_AMOUNT - mintedByWhitelist
maxSelectable = min(paidRemaining, walletRemaining,
                    whitelistRemaining if whitelist phase else paidRemaining)
```

Show a mint control only when the sale is open, not expired, the wallet is eligible, and `maxSelectable > 0`. Display a dedicated whitelist gate if `isWhitelistMintActive` and the wallet is not allowlisted. Do not present the whitelist allocation as an additional 1,000 NFTs on top of 5,900. Paused flags can remain set after expiry; deadline and caps always take precedence.

Display sold-out success, unsuccessful expiry/refund availability, paused mint, and wallet limit reached as distinct states. If all 5,900 paid tokens have sold but treasury supply is incomplete, paid mint is exhausted and the campaign has not yet succeeded. Do not show withdrawals or transfers as available in that state.

## New v2 deadline API and management writes

`CONTRACT_VERSION()` returns `2`. Earlier listed deployments do not expose this getter; retain v1 read/mint support but disable deadline edits. Do not infer editability merely from having the new ABI.

```solidity
function setMintEndTime(uint256 newEndTime) external;
event MintEndTimeUpdated(uint256 previousEndTime, uint256 newEndTime);
```

The setter requires `DEFAULT_ADMIN_ROLE`, uses `nonReentrant`, and accepts a Unix timestamp in **seconds**. Both extensions and shortening are supported, including after purchases. Conditions: current chain time must be `<=` the current deadline, the sale must not be sold out, and the new deadline must be strictly in the future. At `currentDeadline + 1`, editing is permanently closed even if nobody has claimed a refund. The setter cannot reopen failed sales or revoke accrued refund eligibility. It does not change phase flags, counters or metadata.

Read the latest deadline on every refresh and transaction; invalidate cached dates on `MintEndTimeUpdated`. Display UTC explicitly. The console's date input interprets the entered calendar values as UTC, independent of the browser timezone. It uses block timestamps for eligibility and estimated countdowns. An admin may extend repeatedly while the sale is open; the deadline is no longer a fixed promise before expiry. There is no scheduled start date: phase activation/pause is manual.

| Console action | Write | Required authority |
| --- | --- | --- |
| Deadline | `setMintEndTime(timestamp)` | Admin; v2 open, unsold sale |
| Public phase / wallet cap | `setPublicMintActive(active, cap)` | Admin |
| Whitelist phase / wallet cap | `setWhitelistMintActive(active, cap)` | Admin |
| Allowlist | `addToWhitelist(addresses)` / `removeFromWhitelist(addresses)` | Admin |
| Treasury allocation | `treasuryMint(amount, to)` | Treasury; before expiry |
| Reveal | `reveal(baseURI)` | Admin; sold out; not yet revealed |
| Withdraw | `withdraw()` | Treasury; sold out; nonzero balance |
| Roles | `grantRole(role, account)` / `revokeRole(role, account)` | Admin |
| Paid mint | `mint(amount)` | Eligible connected wallet; exact ETH value |
| Refund | `refund(id)` / `refundTo(id, recipient)` | Original paid minter; failed expiry |

Only `mint` attaches an ETH payment. Get `TREASURY_ROLE()` on chain; admin is `bytes32(0)`. Read `hasRole` for the connected account at the snapshot block. On account/chain changes, clear permissions and any unsigned review immediately. The console limits treasury transactions to 50 keys and whitelist batches to 100 addresses as UI limits; the contract's supply limits still govern independently.

## Mint transaction

Use the frontend project's existing wallet library. For viem, the essential flow is:

```ts
import type { Abi } from 'viem'
import ryodanKeysAbi from './RyodanKeys.json'

const abi = ryodanKeysAbi as Abi
// publicClient and walletClient must both use Ethereum Sepolia.
const { request } = await publicClient.simulateContract({
  address: contractAddress,
  abi,
  functionName: 'mint',
  args: [amount],           // bigint, positive, validated against snapshot
  account: connectedAccount,
  value: mintPrice * amount // bigint in wei, no floating-point arithmetic
})
const hash = await walletClient.writeContract(request)
const receipt = await publicClient.waitForTransactionReceipt({
  hash,
  confirmations: 2
})
if (receipt.status !== 'success') throw new Error('Mint reverted')
```

Request wallet connection and switch chain to 11155111 before simulation. Do not send transactions on an unexpected chain. Re-read state on account or chain changes and cancel stale simulations. Estimate gas through simulation/RPC; do not hardcode a gas limit. Keep enough ETH for both value and gas.

Track disconnected, wrong chain, ready, simulating, awaiting signature, submitted, confirmed, rejected, reverted, and RPC error states. Disable repeat submission while awaiting signature or confirmation. A transaction hash alone is not confirmation. Handle replaced/cancelled transactions using the wallet library's replacement callback and follow the replacement hash. A receipt timeout is an unknown/pending result: keep the hash and reconcile it before offering another mint.

Parse only receipt logs whose emitting address equals `contractAddress`. From `Transfer(address(0), wallet, tokenId)` logs, collect minted IDs. Do not predict IDs from total supply or assume consecutive IDs across different transactions. Refresh supply, allowance, ownership and metadata after confirmation. Use block subscriptions or periodic polling with cleanup and backoff to track other users' activity.

## Refund transactions

Read `refundsAvailable()`, `originalMinter(id)`, and `refunded(id)`. Claimable means refunds are available, `originalMinter(id)` equals the connected wallet, and `refunded(id)` is false. Treasury IDs have `originalMinter == address(0)` and are never claimable. Approval or current ownership does not give someone else the right to claim.

- `refund(id)` sends 0.01 ETH to the connected minter and burns the NFT.
- `refundTo(id, recipient)` lets that same minter choose a nonzero recipient, useful for smart wallets that reject ETH.
- Both calls have **zero transaction value**. Simulate, submit, confirm, and refresh as for mint.
- Never automatically retry a refund after a receipt timeout. Reconcile the submitted transaction and `refunded(id)` first.
- Multiple different paid tokens each have one legitimate refund. The same token can never be refunded twice.

There is no `redeem` function, off-chain voucher, signature mint, Merkle proof, ERC-20 approval, or NFT approval required for mint/refund in this contract. If another service calls its feature "redeem", its integration needs separate review.

## Ownership and token discovery

The contract is not ERC721Enumerable and has no `tokensOfOwner` getter. Build owned/paid token lists from indexed `Transfer` events and `originalMinter`; seed the query with the deployment receipt block and paginate log ranges according to RPC limits. Include burns (`to == address(0)`) and secondary transfers. Revalidate candidate tokens with `ownerOf` and `refunded`. A refunded token's `ownerOf`, `getApproved`, and `tokenURI` revert because it has been burned.

For refund history, index `Refunded(tokenId, minter, recipient, amount)` and retain the original mint transaction. Keep state keyed by chain, contract address and wallet; cached lists from another deployment must not leak into this one.

## Metadata and reveal

Before reveal, every existing token returns one hidden JSON URI. After the admin's one-shot reveal, token `i` returns `<baseURI><i>.json`. See [METADATA_AND_REVEAL.md](METADATA_AND_REVEAL.md).

Support `ipfs://`, `https://`, and JSON `data:` URIs. The Sepolia hidden URI contains inline base64 JSON and deliberately has no artwork; show a graceful image fallback. Resolve IPFS through a configured gateway with a fallback, keep the original canonical URI, and handle timeouts and invalid JSON. Treat metadata as untrusted: render text as text, validate media URLs, and do not execute fetched HTML/SVG/scripts or inject metadata through `innerHTML`.

Refresh metadata on `Revealed` / `BatchMetadataUpdate`, and on initial load. Reveal is collection-wide and requires no holder transaction. `revealed` and `soldOut` are independent flags: tokens can be transferable while metadata remains hidden. There is no random assignment or verifiable randomness in this implementation.

## Error handling

| Revert | Frontend response |
| --- | --- |
| `Mint not active` | Refresh phase; sale is paused |
| `Mint ended` | Refresh deadline; show unsuccessful expiry/refund state if eligible |
| `Max supply reached` | Refresh supply; reduce quantity or disable mint |
| `Incorrect payment` | Refresh price and rebuild exact wei value |
| `Max mint amount reached for address` | Refresh lifetime wallet allowance |
| `Not whitelisted` | Show whitelist eligibility gate |
| `Max whitelist mint amount reached` | Disable whitelist mint; await public phase |
| `Not original minter` / `Token not eligible for refund` | Refresh claim eligibility; never retry automatically |
| `Already refunded` | Refresh token/refund history |
| `Failed to send Ether` | For refund, offer a recipient address through `refundTo` |
| `ERC721InvalidReceiver` | Connected smart wallet must implement ERC721Receiver |
| Wallet rejected signature | Return to ready state without claiming success |
| RPC timeout | Preserve hash and pending state; reconcile before retry |

## Acceptance checks for the frontend agent

Test disconnected and wrong-chain flows, whitelist eligible/ineligible states, paused sale, zero/excess quantity, shared allowance across phases, exact payment, wallet rejection, insufficient gas funds, replaced transactions, stale state, concurrent mint/supply races, and receipt timeouts. Confirm no duplicate submissions occur.

On the active Sepolia contract, exercise mint and metadata reads using a funded user wallet. On the separate expired refund contract, validate the displayed QA history; newly connected wallets have no claimable tokens there. Create a fresh short-deadline sale to test another wallet's own refund. Sold-out reveal, secondary transfers and treasury withdrawal are covered in the full-size local suite; they have not been exercised as successful Sepolia transactions with the available funding.

## Implemented console verification

The browser suite in `console/scripts/browser-test.mjs` drives the actual UI through an injected EIP-1193 test wallet against an isolated Anvil chain. It covers connection, roles, exact-value mint, deadline edits, whitelist phases, treasury mint, role grant/revoke, self-revocation prevention, account/network changes, rejected signatures, pending recovery after reload, refunds, duplicate claims, full-size sellout, permanent reveal and withdrawal. Desktop/mobile views and the public Sepolia read-only deployment are verified separately. Real wallet-extension confirmation screens and mobile wallet apps require their own compatibility checks.

References: [ethers BrowserProvider](https://docs.ethers.org/v6/api/providers/#BrowserProvider), [EIP-1193 wallet provider interface](https://eips.ethereum.org/EIPS/eip-1193).
