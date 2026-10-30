# Sepolia runbook — Ryodan Keys v4

Updated 2026-10-30. Network: Ethereum Sepolia **11155111**. [Live management UI](https://ryodan.grooooog.space), with v4 selected and eight current/historical deployments retained.

## Current deployments and confirmed results

| Purpose | Contract | Verified smoke state |
| --- | --- | --- |
| Management / mint | [`0xCCe14de13cd2f917a2B85b17D5E325Bd5e48BBa8`](https://sepolia.etherscan.io/address/0xCCe14de13cd2f917a2B85b17D5E325Bd5e48BBa8#code) | Pioneer active, 2 paid + 1 treasury key, 0.050 ETH, 12 unclaimed GTD keys |
| Four-phase batch-refund QA | [`0x084E7a42D8CBdBd95F65FEc853f5Bc16E6656B5a`](https://sepolia.etherscan.io/address/0x084E7a42D8CBdBd95F65FEc853f5Bc16E6656B5a#code) | Expired after Civilian; all 5 paid keys refunded, 1 treasury token survives, zero ETH |

Management initial/current deadline at this check: **2026-11-29 18:00:48 UTC**; read its live value before acting. Both contracts use final v4 constants: 6,166 paid + 500 treasury, prices 0.025/0.040/0.045/0.050 ETH and caps 4/10/10/10. No lowered supply cap, storage injection or accelerated clock is used on Sepolia.

Both deploys load a snapshot with only the dedicated test wallet in Pioneer. Its inherited Operative/Recruit access needs no duplicate list writes. The management mint buys a Pioneer pair (IDs 0,1), followed by a treasury key (ID 2). The separate QA sale adds one key in each later phase (IDs 3,4,5) and expires using the public deadline setter. `refundBatch([0,1,3,4,5])` returns **0.185 ETH** and burns those keys in [transaction `0x51f9beef…27871e`](https://sepolia.etherscan.io/tx/0x51f9beefefc4cec5c309b7c6f635c4996dd672c40fdd1d2153a933afc027871e). Duplicate refunds and attempts to reopen expiry are rejected.

The QA batch is signed by the dedicated test wallet, which is also the original minter. Third-party initiation and mixed recipients are independently exercised by Solidity and real local-browser transactions; do not claim a different Sepolia caller for this receipt.

Evidence:

- [Management receipts](../deployments/sepolia-v4.json)
- [Refund QA receipts](../deployments/sepolia-v4-refund.json)
- [Independent second-RPC verification](../deployments/sepolia-v4-verification.json)
- [Management Etherscan verification](../deployments/sepolia-v4-etherscan.json)
- [QA Etherscan association](../deployments/sepolia-v4-refund-etherscan.json)
- [Public-site checks](security/site-v4-verification.json)

## Source verification distinction

The management contract has **Etherscan Exact Match** verification. All 25 source files, compiler version, optimization, EVM target, constructor arguments and deployed runtime match the local optimized artifact.

Etherscan automatically associates the QA contract's identical runtime with the management source as **Similar Match**. An explicit submission returned “Already Verified”; it does not establish an Exact Match for the QA constructor. The verification script separately compares the QA creation transaction, its own constructor arguments and full runtime with the compiled artifact. `constructorArgumentsMatch: false` in the QA explorer report refers to the explorer's linked management constructor, while `creationBytecodeAndArgumentsMatch: true` records the independent comparison to the actual QA deployment transaction. The reports preserve this distinction.

## Signing wallet and deployment commands

Dedicated Sepolia wallet: `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`, with both admin and treasury roles. Secret name: `YOMI_RYODAN_SEPOLIA_DEPLOYER`. Etherscan key name: `YOMI_ETHERSCAN_API_KEY`. Use hush injection; never put values in source, browser code, logs or plaintext files.

From the repository root, after successful Foundry/static/frontend checks and an optimized build:

```sh
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  node console/scripts/deploy.mjs
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  node console/scripts/deploy.mjs --qa
# Only after the QA deadline has passed:
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  node console/scripts/deploy.mjs --refund
node console/scripts/deploy.mjs --verify
node console/scripts/deploy.mjs --verify --qa
node console/scripts/verify-sepolia.mjs
```

The manifests checkpoint submitted transaction hashes before waiting for two confirmations. Reuse the same manifest to reconcile an interrupted setup, never delete it to blindly resubmit. After QA refunds, use `--verify --qa`, not the setup stage. `--manifest <new-path>` creates a distinct intentional deployment. Local testing uses `--local --rpc <Anvil-url> --manifest <temporary-path>` with an unlocked local account. Other chain IDs are refused.

`verify-sepolia.mjs` independently uses ethPandaOps, compares runtime, checks final state, five refund events/recipients and original payments, and reconciles the minter's block balance change plus the actual gas charge against the payout. It asserts this documented smoke state; it is not a generic monitor for a sale operators have since changed.

Source publication and checks:

```sh
hush run --name YOMI_ETHERSCAN_API_KEY --env ETHERSCAN_API_KEY --redact -- \
  node console/scripts/verify-etherscan.mjs
hush run --name YOMI_ETHERSCAN_API_KEY --env ETHERSCAN_API_KEY --redact -- \
  node console/scripts/verify-etherscan.mjs --qa --check
```

The script rebuilds standard JSON from pinned source, compares actual creation/runtime bytecode and records the explorer's actual Exact/Similar status. No API key is persisted.

## Production preparation

Use [the CSV workflow](ALLOWLISTS_AND_CLIENT_ALIGNMENT.md), [management guide](MANAGEMENT_CONSOLE.md) and [frontend handoff](FRONTEND_INTEGRATION.md). The downloadable templates are empty; no customer list is invented. A real campaign needs completed/frozen lists, agreed actual timing, final metadata and chosen production role holders. Set phase prices/caps, commit the generated list root/hash/counts, compare frontend/checker outputs, complete the treasury allocation and only then start/resume phases in order.

The current test deployment's membership is already frozen. A new campaign uses a fresh deployment; old holders and funds are not migrated automatically. The scripts deliberately target Sepolia/local networks and do not deploy mainnet.

The published console is a production static build served persistently through grog. Building `console/dist/` changes the live site; review builds use another output directory. Public RPCs are PublicNode and ethPandaOps with bounded fallback. Full-size sellout/reveal/withdrawal is validated locally rather than funding a complete Sepolia sale.

## Historical deployments

Historical contracts retain their original ABIs and economic rules. Their records remain in `deployments/`; the console reads the version and selects the compatible ABI.

| Version | Management | Refund QA |
| --- | --- | --- |
| v3 | `0x3120e791E078ACF04601d623307B0e6866633E7A` | `0x30f41eA9af605cB63C9Fb86af945e9D137B3d804` |
| v2 | `0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B` | `0xBc5338c4a71961d999Ec9551a2636850ec1561e0` |
| v1 | `0x85b1024194cFd547Eb81877f8efF77587e7604f9` | `0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7` |

V3 had separate mutable lists and different defaults; v1/v2 shared their earlier whitelist/public model. Earlier 6,400-key coverage and refund receipts are historical evidence, not v4 configuration. Do not run current v4 deployment scripts against historical manifests.
