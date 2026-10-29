# Ryodan Keys v3 deployment runbook

Updated 2026-10-29. The current contract source and `console/scripts/deploy.mjs` deploy **v3**, with four sequential phases and original-payment refunds. Earlier deployment records below are historical and retain their original API.

V3 management contract: [`0x3120e791E078ACF04601d623307B0e6866633E7A`](https://sepolia.etherscan.io/address/0x3120e791E078ACF04601d623307B0e6866633E7A). Initial deadline: **2026-11-28 14:01:12 UTC**; read its current value on chain. Separate v3 refund QA: [`0x30f41eA9af605cB63C9Fb86af945e9D137B3d804`](https://sepolia.etherscan.io/address/0x30f41eA9af605cB63C9Fb86af945e9D137B3d804).

Verified on 2026-10-29: the management sale is in Pioneer with one paid key, one treasury key and 0.005 ETH reserved. The QA sale completed all four phases, expired, and refunded its four paid keys for **0.018 ETH total**; only its free treasury key remains, with zero contract balance. Repeated refunds and reopening the expired sale were rejected. The public management panel is updated at [ryodan.grooooog.space](https://ryodan.grooooog.space), with all six historical/current deployments selectable. Transaction receipts are in [`sepolia-v3.json`](../deployments/sepolia-v3.json) and [`sepolia-v3-refund.json`](../deployments/sepolia-v3-refund.json); independently verified refund amounts and final state are in [`sepolia-v3-verification.json`](../deployments/sepolia-v3-verification.json).

## v3 deployment procedure

Use the dedicated test wallet `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`; its hush name is `YOMI_RYODAN_SEPOLIA_DEPLOYER`. No key belongs in files, logs, frontend code or command arguments. Compile the optimized pinned artifact, export/check its ABI and run Foundry, Slither and browser tests before deploying.

From the repository root:

```sh
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- node console/scripts/deploy.mjs
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- node console/scripts/deploy.mjs --qa
# After the QA deadline has passed:
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- node console/scripts/deploy.mjs --refund
node console/scripts/deploy.mjs --verify
```

The default manifest is `deployments/sepolia-v3.json`. It records each transaction before waiting for two confirmations, allowing interrupted runs to resume. The management deployment opens Pioneer with only the test wallet listed, mints one Pioneer key at 0.005 ETH and one free treasury key, and verifies extend/restore deadline operations. The other phases keep their default settings for further UI testing. Actual customer lists are not loaded.

`--qa` uses the separate `deployments/sepolia-v3-refund.json`: one paid NFT in each phase (0.005, 0.002, 0.001 and 0.01 ETH), plus one free treasury NFT. It verifies independent counters, releases unused guarantees, reaches Civilian sequentially and shortens the deadline. `--refund` then returns all four original payments (0.018 ETH total), checks duplicate rejection and rejects attempts to reopen expiry. Both scripts verify exact deployed runtime bytecode against the optimized artifact and role assignments. `--verify --rpc <second-public-rpc>` provides independent verification; add `--qa` to select the refund contract. The QA receipts were independently verified using `https://rpc.sepolia.ethpandaops.io`. Do not point these v3 scripts at v1/v2 manifests.

Use `--local --rpc <anvil-url> --manifest <temporary-path>` to exercise deployment without a secret. The active frontend subset is written only by a successful non-QA Sepolia deployment. Preserve all previous deployment records. Select the v3 address/ABI in integrations; there is no upgrade or holder/fund migration.

For a real campaign, provision final hidden metadata, choose admin/treasury role holders, mint the 500 treasury NFTs before expiry, configure phase prices/limits and guaranteed membership within remaining supply, then start/resume Pioneer. See [MANAGEMENT_CONSOLE.md](MANAGEMENT_CONSOLE.md). Revenue varies by phase prices; full-size sellout, successful reveal and withdrawal remain local test coverage rather than successful Sepolia transactions.

## Historical v1/v2 deployment evidence

### Original v1/v2 operations

Updated for v2 on 2026-10-19. Chain: **Ethereum Sepolia 11155111**. Management UI: [ryodan.grooooog.space](https://ryodan.grooooog.space). See [MANAGEMENT_CONSOLE.md](MANAGEMENT_CONSOLE.md) for wallet setup and all UI operations.

## Current v2 deployments

| Purpose | Address | Verified deadline (UTC) |
| --- | --- | --- |
| Default active management/mint | [`0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B`](https://sepolia.etherscan.io/address/0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B) | 2026-11-18 19:47:12; editable before expiry/sellout |
| Shortened-deadline refund QA | [`0xBc5338c4a71961d999Ec9551a2636850ec1561e0`](https://sepolia.etherscan.io/address/0xBc5338c4a71961d999Ec9551a2636850ec1561e0) | 2026-10-19 19:55:42; expired and locked |

The active v2 sale was verified with one paid token, one treasury token, public phase enabled, wallet cap 3, 0.01 ETH reserved and sealed metadata. The QA sale had the same two-token setup, shortened its date, then refunded and burned its paid token. Its live supply is one treasury token and balance is zero. Always refresh live state; these are verification snapshots.

The same dedicated wallet holds Admin/Treasury: `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`, stored under hush name `YOMI_RYODAN_SEPOLIA_DEPLOYER`. No key or sharing URL is included in documentation or the site.

Current receipts/checks: [`sepolia-v2.json`](../deployments/sepolia-v2.json) and [`sepolia-v2-refund.json`](../deployments/sepolia-v2-refund.json). The console uses the public subset `console/src/deployment.json`. All four test contracts are selectable with separate Etherscan links; v1 deployments remain immutable and are not upgraded.

Confirmed v2 checks include exact optimized runtime bytecode, version/roles, extension and restoration of the date, paid/treasury mint, and shortened-deadline expiry. The QA sale rejects reopening before and after its first refund and rejects a second claim. Its successful refund is [0x06cef2ed…c1a10b0](https://sepolia.etherscan.io/tx/0x06cef2ed089ae2dee3e602f79bbf93e8608bf7c614085c7436e4ff471c1a10b0). The active sale's bytecode, roles and receipts were independently checked through `https://sepolia.drpc.org` after deployment through PublicNode.

## Current v2 deployment commands

Use `console/scripts/deploy.mjs`, with the optimized Forge artifact. Coverage temporarily disables optimization, so run `forge build` again before deployment/bytecode verification. Manifest paths are relative to repository root.

```sh
cd ryodan-keys
forge build
python3 scripts/export-abi.py --check
cd ../console

# Existing manifest resumes/verifies its recorded deployment.
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- node scripts/deploy.mjs

# Independent verification requires no key.
node scripts/deploy.mjs --verify --rpc https://sepolia.drpc.org
node scripts/deploy.mjs --verify --qa

# QA setup for a new/unexpired setup run, then refund after its chain deadline.
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- node scripts/deploy.mjs --qa
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- node scripts/deploy.mjs --refund
```

After the QA refund is complete, use `--verify --qa`, not its setup stage. Use a distinct `--manifest ryodan-keys/deployments/<new-name>.json` only when intentionally creating another sale. Do not delete a manifest to retry an unknown transaction. Hashes are checkpointed before waiting. `--local` uses unlocked Anvil accounts on chain 31337; Sepolia signing uses hush. Other chain IDs are rejected.

`setMintEndTime(newEndTime)` allows shortening/extension while `block.timestamp <= mintEndTime`, the sale is not sold out and the new time is strictly in the future. It emits `MintEndTimeUpdated(previousEndTime, newEndTime)`. There is no maximum extension or notice period. After expiry the sale cannot reopen, even before the first refund. Phase starts remain manual; pausing does not move the date. Reveal still requires all 6,400 lifetime mints.

Full-size successful reveal and withdrawal are verified through the actual UI on local Anvil. They have not been completed on Sepolia, where paid sellout requires 59 ETH plus gas. The public site serves only the production `console/dist/` through persistent `grog serve`; it contains no key or privileged signing backend.

## Archived v1 runbook and evidence

The remaining sections document the **earlier v1 deployment run**, retained for historical evidence. Their immutable-date rules apply only to v1. Do not run the historical Python verification against v1 using today's v2 compiler artifact: the bytecode necessarily differs. Use the v2 commands and operator guide above for current work. Earlier receipts remain in [`deployments/sepolia.json`](../deployments/sepolia.json).

## Operator wallet

- Address: `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`.
- Private key: encrypted in hush under **`YOMI_RYODAN_SEPOLIA_DEPLOYER`**.
- This wallet holds both admin and treasury roles for the QA deployments. A production deployment should deliberately assign its own role holders.
- User supplied 0.55 Sepolia ETH. Two paid mints are left in the active sale; the separate short-deadline sale returns its two paid mints through refunds. Remaining funds stay in this dedicated test wallet.

Use the key only with `hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- ...`. Never export, log or copy it into source, frontend configuration, command history or a plaintext file.

## Deployments

| Purpose | Address | Immutable mint deadline (UTC) |
| --- | --- | --- |
| Active mint integration | [`0x85b1024194cFd547Eb81877f8efF77587e7604f9`](https://sepolia.etherscan.io/address/0x85b1024194cFd547Eb81877f8efF77587e7604f9) | 2026-11-18 19:11:36 |
| Expiry/refund QA | [`0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7`](https://sepolia.etherscan.io/address/0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7) | 2026-10-19 19:24:36 |

Final independent verification: Sepolia block **11950237**, using `sepolia.drpc.org` in addition to the deployment RPC. Full snapshot: [`deployments/sepolia-verification.json`](../deployments/sepolia-verification.json).

- Primary contract: 3 live NFTs (2 paid + 1 treasury), 0.02 ETH reserves, public phase active, hidden metadata.
- Refund contract: 2 historical refunds, both paid NFTs burned, 1 surviving treasury NFT, **0 ETH** reserves.
- Refund transactions: [first claim](https://sepolia.etherscan.io/tx/0x73d2493128b47e14a558d991a4a37f6eaf5aa2a44c2903284ef68bd9ecda48a6), [second claim](https://sepolia.etherscan.io/tx/0xaa6895617cc5c241f7f4dfb75fcf222ce8a1401df23315d8c2552cc4d82b2648).
- Recipient balances before/after each refund, adjusted for that transaction's actual gas, independently confirm **0.01 ETH received per token**.
- Operator wallet balance at the snapshot: **0.524746283788756177 Sepolia ETH**. The active primary contract separately holds 0.02 ETH from its two smoke mints.

The primary sale is public with a lifetime wallet cap of 3. The operator wallet has bought two NFTs, one during whitelist mint and one during public mint, and received one treasury NFT. Treasury supply is deliberately incomplete in these limited-funding smoke deployments; there is no claim that the live primary campaign has sold out. The refund QA deployment is a separate failed sale with two paid tokens and one free treasury token. After both refunds, only its treasury token survives.

Both use actual production constants: 5,900 paid + 500 treasury, 1,000 whitelist subset, price 0.01 ETH. No artificial lower cap, zero price, storage injection, time manipulation or test-only contract is used on Sepolia. The same addresses can also occur on a local chain because the same signer/nonce produces the same deployment address; always include chain ID when selecting a deployment.

## Reproduce and inspect

Run commands from `ryodan-keys` with Foundry available on `PATH`.

```sh
forge build
python3 scripts/export-abi.py --check
cast chain-id --rpc-url https://ethereum-sepolia-rpc.publicnode.com
cast balance 0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc \
  --ether --rpc-url https://ethereum-sepolia-rpc.publicnode.com
python3 scripts/sepolia-smoke.py verify \
  --rpc https://ethereum-sepolia-rpc.publicnode.com
```

The read-only `verify` stage compares the **entire runtime bytecode**, substituting every immutable deadline location from compiler output, verifies deadline and roles, and re-fetches stored transaction receipts. It writes updated public verification evidence to the manifest. It does not publish Solidity source to an explorer. Sourcify/Etherscan source verification has not been requested or performed.

The completed `deploy` stage records one successful whitelist mint, one successful public mint, the treasury mint, and simulations proving underpayment, overpayment, wallet overflow, premature refund, premature reveal, locked transfer and treasury withdrawal rejection. Every state-changing smoke transaction waits for two confirmations.

The completed `refund` stage checks nonexistent/free IDs and wrong callers through `eth_call`, executes legitimate `refund(0)` and `refundTo(1, operator)` transactions, then verifies burned ownership, zero remaining reserves, two historical refunds, one surviving treasury token, rejection of a duplicate refund and rejection of mint after expiry. `Refunded` events identify the recipient and exact repayment; transaction receipts also show burn `Transfer` events.

Use a **new manifest path** to create another pair of QA deployments. The initial stage creates a 30-day active sale and a separate 10-minute refund sale, then runs the smoke operations:

```sh
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  python3 scripts/sepolia-smoke.py deploy \
  --rpc https://ethereum-sepolia-rpc.publicnode.com \
  --manifest deployments/sepolia-new-qa.json

# Run only after that refund deployment's actual on-chain deadline.
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  python3 scripts/sepolia-smoke.py refund \
  --rpc https://ethereum-sepolia-rpc.publicnode.com \
  --manifest deployments/sepolia-new-qa.json
```

Treat this as an operator tool with fixed smoke assertions, not a general wallet or a repeatable load test against an evolving public sale. Submitted transaction hashes are checkpointed before awaiting receipts; reconcile pending receipts rather than resubmitting. If a creation command disconnects before returning its deployment hash, check wallet nonce and explorer history before retrying deployment.

## Custom deployment

`script/RyodanKeys.s.sol:RyodanKeysScript` takes these nonsecret environment settings:

```text
DEPLOYER_ADDRESS       Broadcasting signer address (required)
ADMIN_ADDRESS          Optional; defaults to deployer
TREASURY_ADDRESS       Optional; defaults to deployer
MINT_END_TIME          Explicit future Unix timestamp (required)
HIDDEN_METADATA_URI    Full URI of already-available hidden JSON (required)
```

Run a simulation first with `forge script script/RyodanKeys.s.sol:RyodanKeysScript --rpc-url <sepolia-rpc> --sender <deployer>`. Inject the signer only for the authorized broadcast using hush; expand any private-key flag inside hush's child process. The script refuses chain IDs other than 11155111 or 31337 and does not grant implicit additional roles to its caller. Mint flags start disabled.

Before a real campaign, check admin/treasury roles, immutable deadline and hidden JSON; mint all 500 treasury NFTs in appropriately estimated batches; configure the allowlist and wallet cap; then enable the intended phase. Switching to public automatically closes whitelist mint. Pausing the active phase does not change the refund deadline. Pausing both flags is unambiguous if the operator is unsure which phase is active.

## Full lifecycle coverage and limits

The local suite covers all 6,400 token mints, successful withdrawal of 59 ETH, unlocked direct/approved transfers, one-shot reveal, metadata paths/events, refund failure rollback and malicious callbacks. A local Anvil RPC smoke test also exercises the same deploy/mint/refund script.

Successful sellout, treasury withdrawal and final reveal have **not** been executed on Sepolia. The supplied 0.55 ETH cannot fund a 59 ETH paid sellout. Final artwork and IPFS pins have not been supplied or published; Sepolia currently uses valid inline hidden JSON without artwork. Use the [metadata/reveal procedure](METADATA_AND_REVEAL.md) to prepare the real collection.
