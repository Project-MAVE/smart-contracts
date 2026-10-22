# Ryodan management console

Updated: 2026-10-19. Live UI: **[https://ryodan.grooooog.space](https://ryodan.grooooog.space)**.

This is a static, wallet-signed Ethereum Sepolia operator console. It supports public/whitelist minting, sale phases, editable v2 deadlines, whitelist membership, treasury allocation, sale withdrawals, one-shot metadata reveal, role administration and refunds. The UI can be read without connecting a wallet.

## Contract and wallet

| Item | Value |
| --- | --- |
| Network | Ethereum Sepolia, chain ID `11155111` (`0xaa36a7`) |
| Default v2 contract | [`0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B`](https://sepolia.etherscan.io/address/0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B) |
| Test admin and treasury wallet | `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc` |
| v2 refund QA contract | [`0xBc5338c4a71961d999Ec9551a2636850ec1561e0`](https://sepolia.etherscan.io/address/0xBc5338c4a71961d999Ec9551a2636850ec1561e0) |
| Earlier v1 mint test | [`0x85b1024194cFd547Eb81877f8efF77587e7604f9`](https://sepolia.etherscan.io/address/0x85b1024194cFd547Eb81877f8efF77587e7604f9) |
| Earlier v1 refund QA | [`0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7`](https://sepolia.etherscan.io/address/0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7) |

Use **Target contract** to choose a deployment. The full selected address is a Sepolia Etherscan link. Every submitted/confirmed transaction in the session log links to its transaction page. The contract is not upgradeable: v2 has a new address and does not migrate previous NFTs or funds.

The v2 active sale initially has one paid token, one treasury token, a wallet limit of 3, public mint enabled, 0.01 ETH in reserve and sealed metadata. These are verified initial conditions, not permanently fixed values; always read current chain state in the console.

## Connect the test wallet

1. Obtain the dedicated test wallet's private key through the separately shared expiring Bitwarden Send. The key is stored under hush name `YOMI_RYODAN_SEPOLIA_DEPLOYER`; this document never contains it or its sharing link.
2. Import that key into your Ethereum wallet application's import-account screen. Verify the resulting public address equals the test wallet above. If the wallet requires a `0x` prefix, add it to the 64 hexadecimal characters in that import screen.
3. Open the console in the same browser and select **Connect wallet**. Choose Ethereum Sepolia when prompted. For mobile, use the wallet's in-app browser, which must expose an EIP-1193 provider.
4. Check **Access control → Connected identity**. The dedicated test wallet should have both Administrator and Treasury privileges.

The site never asks for a private key and never signs on the server. Other connected wallets can mint if eligible but cannot administer the contract unless an admin grants the required role. This implementation uses the browser's injected wallet; it does not include WalletConnect QR pairing.

## How a transaction works

Every operation follows the same flow: enter values, select **Review**, inspect the exact network, contract, signer, method, arguments and ETH value, then select **Sign in wallet**. The console first simulates the call and estimates gas, and rechecks state before signing. The wallet displays the final fee.

A transaction hash means submission, not success. Wait for **CONFIRMED** in the activity log: Sepolia uses two confirmations. If confirmation is unknown, the hash is preserved in browser storage by chain and contract and other writes remain blocked. Use **Check receipt**. If the wallet replaced/cancelled the transaction, the console follows detected replacements; after reload, paste the confirmed replacement hash into **Track replacement**. It must come from the same wallet and nonce; a different action consuming that nonce is reported as cancellation/replacement, not as success of the original action.

Do not clear browser storage or switch browsers to retry a pending operation. Reconcile the recorded hash first. Wallet rejection, RPC failure, permission errors and contract reverts are displayed explicitly. Stale/unavailable chain data disables writes. The activity log itself is session-only; pending transaction records persist.

## Operations

| Section | Operator steps and contract calls |
| --- | --- |
| **Overview & mint** | Set quantity and review `mint(amount)`. Payment is exactly `mintPrice * amount`; currently 0.01 ETH/key plus gas. Supply, phase, whitelist and lifetime allowance must permit the mint. Confirmed token IDs come from receipt events. |
| **Sale controls → Phase** | Choose public, whitelist or paused and set a positive lifetime per-wallet cap. Uses `setPublicMintActive` / `setWhitelistMintActive`. Activating one phase disables the other. Pausing turns off the currently active phase. |
| **Sale controls → Deadline** | Enter a UTC date/time, review `setMintEndTime(timestamp)`, sign. Both shortening and extension are supported before expiry/sellout. The new date must be strictly in the future. See the rules below. |
| **Sale controls → Whitelist** | Paste addresses separated by commas/newlines. Choose add/remove; review `addToWhitelist` / `removeFromWhitelist`. The console validates/deduplicates and limits batches to 100 addresses. |
| **Treasury → Reserved allocation** | Choose 1–50 keys and a nonzero recipient, then `treasuryMint(amount, to)`. Mint is free except gas and requires the Treasury role. All 500 treasury keys count toward sellout. |
| **Treasury → Sale proceeds** | After all 6,400 keys mint, use `withdraw()`. All remaining contract ETH goes to the connected Treasury-role wallet. |
| **Metadata & reveal** | Inspect an existing token. After sellout, enter a final directory URI ending in `/`, acknowledge permanence, then `reveal(baseURI)`. Upload/validate assets separately first. |
| **Access control** | Enter an address, choose Administrator/Treasury and grant/revoke. Uses `grantRole` / `revokeRole`. Self-revocation is deliberately blocked in this UI to prevent accidental operator lockout. |
| **Refunds** | After unsuccessful expiry, enter an eligible paid token ID. `refund(id)` pays the connected original minter; an optional recipient uses `refundTo(id, recipient)`. No ETH payment is attached. The key is burned and cannot be refunded twice. |

Admin and Treasury are separate on-chain roles even though the test wallet holds both. Mint/refund eligibility comes from the connected holder's own on-chain state. Receiving free treasury tokens does not create refund rights.

## Date rules in v2

- There is one sale end time, `mintEndTime()`, expressed as Unix seconds. Phase starts are manually controlled; there is no separate scheduled whitelist/public start date.
- Only an admin can call `setMintEndTime`. It emits `MintEndTimeUpdated(previousEndTime, newEndTime)`.
- Editing is allowed while chain time is **at or before the current deadline**, the sale is not sold out, and the new time is **strictly in the future**.
- After `currentDeadline + 1`, the date is permanently locked even before the first refund. Moving it cannot revoke accrued refund eligibility or reopen the sale.
- Sold-out sales also lock the date. Editing does not reset counters, phases, refunds or metadata.
- Before expiry, the admin can extend repeatedly. There is no maximum extension or notice period. Communicate this mutable-date policy to minters.
- The two earlier v1 deployments still have immutable dates. The console detects v1 and blocks date editing there.

The date input always means **UTC**, even when the browser formats its calendar controls according to local language. Eligibility is calculated from the latest block timestamp, not the laptop clock.

## Metadata and sale outcome

Reveal requires all 5,900 paid plus 500 treasury NFTs. If the paid allocation sells out but the treasury allocation is incomplete at expiry, the sale still fails: refunds open, transfers remain locked, reveal/withdraw stay unavailable. Complete treasury allocation in manageable batches before opening a real sale.

Hidden metadata is configured at construction. The current test URI is inline JSON without artwork. Final reveal assigns `<baseURI><id>.json` once; token IDs range from 0 to 6399. It is deterministic, without random assignment. See [METADATA_AND_REVEAL.md](METADATA_AND_REVEAL.md) for asset preparation and checks.

## Build, hosting and tests

The UI lives in `console/`, outside the Foundry project. `DESIGN.md` at repository root records the visual system. Prerequisites are Node 20.19+ and the repository's compiled/exported ABI.

```sh
cd console
npm ci --ignore-scripts
npm test
npm run build
npm run dev
```

Dependency changes must pass the repository's mcaifee review. `.npmrc` disables lifecycle scripts and optional peer resolution that triggers a known local npm 10 resolver error. Exact direct versions and integrity hashes are pinned in the lockfile.

The persistent `grog serve` entry for `ryodan.grooooog.space` serves only `console/dist/` on the Mac Pro. It does not expose the repository, source tools, hush vault or a development server. Build production before updating served assets. The launchd service restarts the static host across crashes/reboots; availability still depends on the host and relay.

```sh
# Local Anvil + actual browser transaction workflows; no testnet funds used.
npm run test:browser
# Read-only verification of the published production site and Sepolia data.
node scripts/check-site.mjs https://ryodan.grooooog.space
```

The browser runner starts isolated Anvil/Vite processes, uses Chrome when installed (otherwise Playwright Chromium), and shuts its processes down. For Linux CI install the Playwright Chromium browser. Its fake wallet transport is test-only and never bundled. It exercises the actual contract, including a full 6,400-key sale, permanent reveal and 59 ETH withdrawal locally. Nine pure frontend validation tests, 17 browser workflow checks and desktop/mobile site checks passed. The Solidity suite contains 78 tests, nine fuzz properties and four stateful invariants. See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for evidence and limitations.
