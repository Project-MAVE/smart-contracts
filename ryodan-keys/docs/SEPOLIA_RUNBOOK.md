# Sepolia runbook — v7 test deployment and historical v1–v6

> The current contract is **Ryodan Keys v7: 6,666 keys = 6,166 paid + 500 treasury, token IDs 1–6666.** The v7 console manages only the v7 deployment below and refuses every older contract listed further down.

## V7 test deployment (current)

Deployed 2026-11-23 on Ethereum Sepolia **11155111**, in launch order: client lists, the whole treasury before Pioneer, then Pioneer.

| Item | Value |
| --- | --- |
| Contract | [`0xd84bEbd8C2ED11546578962ebfD07FC56b79f07b`](https://sepolia.etherscan.io/address/0xd84bEbd8C2ED11546578962ebfD07FC56b79f07b) |
| Deploy transaction | [`0x2805324c…5fdc5848`](https://sepolia.etherscan.io/tx/0x2805324c6b7bfaefc551da03deceeb14982e799a26b6a72b2c5209025fdc5848), block 12195097 |
| `CONTRACT_VERSION` / supply | 7 / `MAX_PUBLIC_SUPPLY` 6166, `MAX_TREASURY_SUPPLY` 500, `MAX_SUPPLY` 6666 |
| Deadline (immutable) | 1795629600 = **2026-11-25 18:00:00 UTC** (19:00 Italian time), the mainnet value |
| Admin and treasury | dedicated test wallet `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc` (no Safe on Sepolia) |
| `sbtBaseURI` / `nftBaseURI` | `https://ryodan-meta.grooooog.space/sbt/` / `https://ryodan-meta.grooooog.space/nft/` |
| Runtime code hash | `0xd8fa2ce7c0d3a4927b0ed3b61125bd7c3b9f5983c11ceb5add86320a7cb41d32` |
| Allowlist | the client's 2026-11-23 CSVs plus the six team test wallets in Pioneer: 105 Pioneer, 1,403 Operative, 5,705 Recruit; root `0x684eef196d6778d493101719a1baa468b9bad7e8cfb647aec304c535626c0273`, snapshotHash `0x4340544089b569df44f052e55b46721daaa5c1c717169631e82803d98698ae1d`; 6,032 guaranteed keys reserved |

State after deploy: 500 treasury keys (IDs 1–500) minted in five transactions of 100 before Pioneer; Pioneer started and resumed; the test wallet minted two Pioneer keys (IDs 501–502) at 0.0075 ETH each, and a single-key Pioneer mint passes a static call. Every test wallet's Pioneer proof is accepted on-chain.

Gas on Sepolia is not representative of mainnet: Sepolia prices new storage about 4.7 times higher (10 new slots: 1,320,222 gas on Sepolia, 278,217 on mainnet, `eth_estimateGas` 2026-11-23). Here a 100-key treasury mint used 11.43 million gas and the two-key Pioneer mint 1.64 million.

Evidence: [management receipts and checks](../deployments/sepolia-v7.json).

## V6 test deployment (superseded 2026-11-23)

Deployed 2026-11-20 on Ethereum Sepolia **11155111**.

| Item | Value |
| --- | --- |
| Contract | [`0xd069E170ECD211ca09157Afe6E9110E322BC30f8`](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8) |
| Deploy transaction | [`0x72fc3d2f…e1432bd`](https://sepolia.etherscan.io/tx/0x72fc3d2f69ff3a53d796f8c09cfb3a248042da182f98817db8febc6a6e1432bd), block 12176051 |
| `CONTRACT_VERSION` / supply | 6 / `MAX_PUBLIC_SUPPLY` 6000, `MAX_TREASURY_SUPPLY` 666, `MAX_SUPPLY` 6666 |
| Deadline (immutable) | 1797751512 = **2026-12-20 07:25:12 UTC** |
| Admin and treasury | dedicated test wallet `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc` |
| `sbtBaseURI` / `nftBaseURI` | `https://ryodan-meta.grooooog.space/sbt/` / `https://ryodan-meta.grooooog.space/nft/` |
| Runtime code hash | `0xd513f9406dc352f251360ab5dde58636f14178b1b63ea57a8fbd25668ea080c8` |
| Etherscan | [**Exact Match**](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8#code), verified 2026-11-20 |

Smoke state after deploy: a test snapshot with six wallets in Pioneer (the dedicated test wallet plus five team test wallets) was loaded and every wallet's Pioneer proof was accepted by `verifyEligibility` on-chain; Pioneer was started and resumed, then the test wallet bought one Pioneer pair (IDs 1–2) and the treasury minted one key (ID 3). Pioneer is the active phase; the console shows 2 / 6,000 paid and 1 / 666 treasury. `tokenURI(1)` returns `https://ryodan-meta.grooooog.space/sbt/1.json`.

The metadata are **test placeholders**: random square pixel art generated per ID by `metadata-test/server.js` (grey SBT set, coloured NFT set), served at [ryodan-meta.grooooog.space](https://ryodan-meta.grooooog.space). The base URIs cannot change after deploy, so a campaign with the final artwork needs a fresh deployment.

The source is verified on Etherscan with **Exact Match**: all 25 source files, compiler `v0.8.37+commit.f401782d`, optimizer 200 runs, EVM `cancun` and the five constructor arguments match; the creation transaction and the deployed runtime match the local optimized artifact. The report's `runtimeCodeHash` is the compiled runtime before the immutable deadline is written; the table above hashes the deployed code.

Not done for v6: a refund-QA deployment. The full 6,666-key sellout, the 72-hour keep-or-refund window and refunds are covered by Solidity tests and the local Anvil browser test.

Evidence: [management receipts and checks](../deployments/sepolia-v6.json), [Etherscan verification](../deployments/sepolia-v6-etherscan.json).

A wallet's `walletTier` is written on its first `mintWithProof`; before that, eligibility is read with `verifyEligibility(wallet, 1, proof)` or `remainingAllowanceWithProof(1, wallet, 1, proof)` (4 for an unminted Pioneer).

### Superseded v6 test deployment

The first v6 test contract, [`0xF4A43dF64D41B743Da20582AF49021732Aa298ad`](https://sepolia.etherscan.io/address/0xF4A43dF64D41B743Da20582AF49021732Aa298ad#code) (block 12173845, Etherscan Exact Match), had only the test wallet in Pioneer. Its allowlist froze when Pioneer started, so the six-wallet test list needed the redeployment above. Same source, deadline and metadata folders; records in [sepolia-v6-first.json](../deployments/sepolia-v6-first.json) and [sepolia-v6-first-etherscan.json](../deployments/sepolia-v6-first-etherscan.json). The console no longer selects it.

## V4 deployments (historical)

Recorded 2026-10-30. Network: Ethereum Sepolia **11155111**.

| Purpose | Contract | Verified smoke state |
| --- | --- | --- |
| Management / mint | [`0xCCe14de13cd2f917a2B85b17D5E325Bd5e48BBa8`](https://sepolia.etherscan.io/address/0xCCe14de13cd2f917a2B85b17D5E325Bd5e48BBa8#code) | Pioneer active, 2 paid + 1 treasury key, 0.050 ETH, 12 unclaimed GTD keys |
| Four-phase batch-refund QA | [`0x084E7a42D8CBdBd95F65FEc853f5Bc16E6656B5a`](https://sepolia.etherscan.io/address/0x084E7a42D8CBdBd95F65FEc853f5Bc16E6656B5a#code) | Expired after Civilian; all 5 paid keys refunded, 1 treasury token survives, zero ETH |

Management initial/current deadline at this check: **2026-11-29 18:00:48 UTC**; read its live value before acting. Both contracts use the v4 constants of that time (a supply split since replaced by v6's 6,000 + 666), prices 0.025/0.040/0.045/0.050 ETH and caps 4/10/10/10. No lowered supply cap, storage injection or accelerated clock is used on Sepolia.

Both deploys load a snapshot with only the dedicated test wallet in Pioneer. Its inherited Operative/Recruit access needs no duplicate list writes. The management mint buys a Pioneer pair (IDs 0,1), followed by a treasury key (ID 2). The separate QA sale adds one key in each later phase (IDs 3,4,5) and expires using the public deadline setter. `refundBatch([0,1,3,4,5])` returns **0.185 ETH** and burns those keys in [transaction `0x51f9beef…27871e`](https://sepolia.etherscan.io/tx/0x51f9beefefc4cec5c309b7c6f635c4996dd672c40fdd1d2153a933afc027871e). Duplicate refunds and attempts to reopen expiry are rejected.

The QA batch is signed by the dedicated test wallet, which is also the original minter. Third-party initiation and mixed recipients are independently exercised by Solidity and real local-browser transactions; do not claim a different Sepolia caller for this receipt.

Evidence:

- [Management receipts](../deployments/sepolia-v4.json)
- [Refund QA receipts](../deployments/sepolia-v4-refund.json)
- [Independent second-RPC verification](../deployments/sepolia-v4-verification.json)
- [Management Etherscan verification](../deployments/sepolia-v4-etherscan.json)
- [QA Etherscan association](../deployments/sepolia-v4-refund-etherscan.json)
- [Public-site checks](security/site-v4-verification.json)

## Source verification distinction (v4)

The management contract has **Etherscan Exact Match** verification. All 25 source files, compiler version, optimization, EVM target, constructor arguments and deployed runtime match the local optimized artifact.

Etherscan automatically associates the QA contract's identical runtime with the management source as **Similar Match**. An explicit submission returned “Already Verified”; it does not establish an Exact Match for the QA constructor. The verification script separately compares the QA creation transaction, its own constructor arguments and full runtime with the compiled artifact. `constructorArgumentsMatch: false` in the QA explorer report refers to the explorer's linked management constructor, while `creationBytecodeAndArgumentsMatch: true` records the independent comparison to the actual QA deployment transaction. The reports preserve this distinction.

## Signing wallet and deployment commands

Dedicated Sepolia wallet: `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`, with both admin and treasury roles. Secret name: `YOMI_RYODAN_SEPOLIA_DEPLOYER`. Etherscan key name: `YOMI_ETHERSCAN_API_KEY`. Use hush injection; never put values in source, browser code, logs or plaintext files.

The v4 deploys above used the v4 script of that time. The current script deploys **v6** only, writes `deployments/sepolia-v6.json` (`sepolia-v6-refund.json` with `--qa`) and requires both metadata folders outside local Anvil. `--deadline <unix>` fixes the immutable deadline (default: 30 days after deploy) and `--pioneers <a,b,...>` adds wallets to the test Pioneer snapshot next to the test wallet. From the repository root, after successful Foundry/static/frontend checks and an optimized build:

```sh
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  node console/scripts/deploy.mjs --sbt-base <ipfs-or-https-folder/> --nft-base <ipfs-or-https-folder/>
node console/scripts/deploy.mjs --verify
```

The manifests checkpoint submitted transaction hashes before waiting for two confirmations. Reuse the same manifest to reconcile an interrupted setup, never delete it to blindly resubmit. `--manifest <new-path>` creates a distinct deployment. The v4-only `verify-sepolia.mjs` was removed with the v6 console.

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

A new campaign uses a fresh deployment; old holders and funds are not migrated automatically. The scripts deliberately target Sepolia/local networks and do not deploy mainnet.

The published console is a production static build served persistently through grog. Building `console/dist/` changes the live site; review builds use another output directory. Public RPCs are PublicNode and ethPandaOps with bounded fallback. The full 6,666-key sellout (6,000 paid + 666 treasury) and withdrawal are validated locally rather than funding a complete Sepolia sale.

## Historical deployments

Historical contracts retain their original ABIs and economic rules. Their records remain in `deployments/`; the v6 console refuses them.

| Version | Management | Refund QA |
| --- | --- | --- |
| v3 | `0x3120e791E078ACF04601d623307B0e6866633E7A` | `0x30f41eA9af605cB63C9Fb86af945e9D137B3d804` |
| v2 | `0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B` | `0xBc5338c4a71961d999Ec9551a2636850ec1561e0` |
| v1 | `0x85b1024194cFd547Eb81877f8efF77587e7604f9` | `0x0Ea00FA17cA2f4D44C3BB697d1C98C42567086F7` |

V3 had separate mutable lists and different defaults; v1/v2 shared their earlier whitelist/public model. Coverage and refund receipts of those earlier versions are historical evidence, not current configuration. Do not run the v6 deployment scripts against historical manifests.
