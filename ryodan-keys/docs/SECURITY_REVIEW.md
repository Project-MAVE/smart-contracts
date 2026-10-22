# Ryodan Keys security review

Review date: 2026-10-19, updated for v2 and the management console. Scope: the contract, deployment script, Foundry dependencies, tests, CI placement, frontend ABI, metadata/reveal behavior and new Sepolia QA deployments. This is a source review with runtime tests and static analysis; it is not a formal proof or an independent third-party audit. No old deployed address or exploit transaction was provided, so findings about the previous version are reproduced against the supplied source.

## Confirmed findings and changes

| ID | Severity | Finding | Resolution and evidence |
| --- | --- | --- | --- |
| RK-01 | High | Anyone could call `refund` with nonexistent or free treasury IDs. Their `originalMinter` was zero, so each new ID sent 0.01 ETH to address zero and consumed legitimate refund reserves. | Only original paid minters can claim their own tokens. Nonexistent and treasury IDs are rejected. Legacy regression tests reproduce reserve destruction and a subsequent legitimate refund failure; revised tests preserve reserves. |
| RK-02 | High, availability | Mint ended at fixed timestamp 1767139200, **2025-12-31 00:00 UTC**. Redeploying that source still creates an expired sale. | Constructor requires a future deadline. In v2 the admin can shorten/extend the deadline while the sale is unexpired and unsold; the new time must be in the future. Once the old deadline passes, edits are permanently rejected even before the first refund. Tests cover exact boundaries, expired-sale reopening and callback reentry. Earlier v1 deployments retain immutable dates. |
| RK-03 | Medium | Metadata used placeholder `ipfs://QmZ/` paths, ignored token IDs, exposed metadata for nonexistent IDs, and provided no explicit reveal. | Valid-token check, constructor hidden URI, one-shot admin reveal after sellout, distinct `<id>.json` paths, ERC-4906 events. Tests cover bounds, errors and irreversible reveal. |
| RK-04 | Medium | Zero-quantity mint and arbitrary overpayment were accepted. Extra value was not refunded and could be locked. | Positive amount and exact payment are required; fuzz tests cover incorrect payments and state rollback. |
| RK-05 | Medium, integration | `_mint` did not verify contract recipients could receive ERC-721 NFTs. | `_safeMint`, accounting before callbacks, shared reentrancy guard on every mint/payment entry point, receiver rejection rollback and adversarial callback tests. |
| RK-06 | Medium, configuration | Deployment script granted roles again to its caller, separately from the actual broadcasting deployer. This could give unintended/default script callers privileged roles. | Constructor takes explicit admin/treasury addresses. Script does not grant extra roles and rejects networks other than Sepolia/local Anvil. Constructor and on-chain role assertions verify recipients. |
| RK-07 | Low | Both mint flags could be enabled simultaneously; whitelist silently took precedence and restricted purported public minting. | Enabling one phase disables the other. Pausing and phase transitions are tested; stateful invariant forbids overlap. |
| RK-08 | Low, integration | Refunded NFTs remained present, which could mislead systems treating NFT ownership as an active entitlement. | Refund burns the NFT, clears token approval via ERC-721 burn, decrements circulating `totalSupply`, and preserves historical counters and refund flags. Burn/metadata/approval tests cover this. |
| RK-09 | Validation gap | Nine baseline tests passed despite RK-01. The workflow lived under `ryodan-keys/.github/workflows`, which GitHub does not discover as repository workflows. Documentation was ignored by `.gitignore`. | Expanded suite, fuzzing, invariants, exported ABI consistency check, workflow at repository-root `.github/workflows`, documentation included. The workflow runs the same Foundry, ABI, Slither and browser checks used for local verification. |

## What “multiple redeem” means here

There is no function named `redeem` in the supplied contract. `refund` is the nearest relevant operation.

The original code already set `refunded[id]` before its ETH transfer. Repeating the **same** valid ID failed with `Already refunded`, including recursive attempts. Refunding several **different paid tokens** is legitimate, one repayment per token. The confirmed bug was unbounded consumption of distinct **invalid or free** IDs, destroying ETH at the zero address. The attacker did not receive the destroyed ETH.

The legacy regression fixture preserves the old behavior for reproduction only. It must never be deployed. It differs from the original source in contract name and formatting, not contract logic. It is compiled with the updated dependencies; the vulnerable refund logic is independent of the dependency update.

## Test evidence

The original suite had 9 tests. The revised suite has **78 test functions/properties**:

- 7 legacy regression tests documenting the original behavior and exploit.
- 54 deterministic revised-contract tests, including seven deadline administration regressions.
- 9 parameterized fuzz tests, including unauthorized deadline editing and mint/refund behavior after changed dates: amount/counters and wallet cap, arbitrary refund IDs, refund order, exact payment, unauthorized refund redirection, deadline boundaries, unauthorized sale administration.
- 4 deployment-script tests: explicit role assignment, local/Sepolia support, mainnet rejection and expired configuration rejection.
- 4 stateful invariants: supply/cap accounting, ETH conservation/refund solvency, mutually exclusive phases, and aggregate ownership.

CI profile: **1,000 runs per fuzz test**; **256 runs × 128 actions per invariant**, 32,768 handler calls for each property, with `fail_on_revert = true`. Expected invalid operations are caught and asserted by the handler; unexpected handler reverts fail the run. Stateful actions include paid and treasury mint, allowlist/phase changes, time advancement, deadline changes and attempted reopening, refund, invalid refund, attempted transfer and conditional withdrawal. Bounded stateful exploration generally does not reach all 6,400 mints; deterministic full-size tests cover successful sale, withdrawal, transfer and reveal.

The v2 coverage run reached **100% of revised-contract lines (111/111), branches (70/70), and functions (18/18)**, excluding generated getters/imported libraries. The deployment script also reaches 100%: 14/14 lines, 2/2 branches and 1/1 function. The current artifact is `docs/security/coverage-v2.lcov`; `coverage.lcov` preserves the earlier v1 evidence. These metrics do not prove absence of vulnerabilities.

The manual second pass additionally checked refund rollback after rejected ETH, refund recipient redirection, approval invalidation on burn, arbitrary callers, forced ETH, role revocation, malformed reveal URI, maximum integer amounts and phase/limit changes after expiry. Callback wallet tests attempt reentry during paid mint, treasury mint, refund and withdrawal.

A successful full-size test mints 5,900 paid plus 500 free NFTs, verifies a 59 ETH treasury withdrawal, unlocks transfers, and tests final URI paths and metadata events. It runs in the local EVM; transaction batches of this size are not suitable for a real network gas limit.

## Slither 0.11.6

Slither analyzed v2 with 23 contracts and 102 detectors, filtering dependency/test/script reports. The current result is **7 low + 3 informational**, with no unsuppressed medium/high findings. The earlier v1 unfiltered baseline had 1 high, 6 low and 3 informational findings; its one role-protected withdrawal false positive remains explicitly annotated in v2.

| Detector | Assessment |
| --- | --- |
| `arbitrary-send-eth` (high) in `withdraw` | Reviewed false positive: destination is the caller, and `onlyRole(TREASURY_ROLE)` authorizes that caller. `soldOut` protects refunds, and `nonReentrant` protects callbacks. Unauthorized and successful withdrawal tests exercise these checks. A narrowly scoped `slither-disable-next-line arbitrary-send-eth` applies only to this function, with an explanation in source. It does not disable this detector elsewhere. |
| `events-maths` (low) | Mint counters are reflected by per-token ERC-721 `Transfer` events from `_safeMint`; consumers can index them. A separate counter event is not required by the ERC-721 specification. Accepted. |
| `timestamp` (six low findings) | Constructor, deadline setter, mint and refund use the same current deadline boundary. Timestamp is used for a sale deadline, not randomness. Boundary tests cover the ordering; UI must use chain time. Accepted design dependency. |
| `low-level-calls` (two informational findings) | ETH uses checked `call` to support contract wallets. Payment failures revert all effects; reentrant calls are guarded. Refund minters can choose another recipient with `refundTo`. Accepted. |
| `naming-convention` (informational) | `MAX_MINT_AMOUNT` is mutable despite uppercase spelling. Kept for compatibility with the existing getter. |

After the scoped annotation, v2 Slither reports **7 low + 3 informational**, with no unsuppressed medium/high findings. Configuration gates medium-or-higher findings and retains low/informational output. To include the reviewed high finding again, use `--show-ignored-findings`; review its source annotation and authorization tests rather than treating a clean exit as a security guarantee.

The current detector output is `docs/security/slither-v2.json`. Earlier normalized outputs in `docs/security/` preserve the initial high finding and v1 low/informational results. A separate standalone Slither run on the legacy fixture analyzed 20 contracts and reported **2 high, 3 low and 10 informational** findings, including arbitrary ETH sends in both `refund` and `withdraw`. The old `refund` finding is consistent with the reproduced invalid/free-ID reserve destruction. Its costly-loop findings were addressed by reserving aggregate counters once per batch. The compiler-constraint warning is addressed by the pinned 0.8.37 build. The role-protected withdrawal send remains the reviewed false positive described above. Results are in `docs/security/slither-legacy.json`.

## Dependency and compiler update

| Component | Previous | Revised |
| --- | --- | --- |
| Project Solidity declaration | `^0.8.13`, compiler unpinned | exact `0.8.37`, compiler pinned |
| OpenZeppelin Contracts | 5.2.0, `acd4ff74de833399287ed6b31b4debf6b2b35527` | 5.7.0, `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| forge-std | 1.9.5, `b93cf4bc34ff214c099dc970b153f85ade8c9f66` | 1.16.2, `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| EVM target | compiler default | Cancun, explicit |
| Optimizer | compiler default | enabled, 200 runs |

Reviewed the upstream Solidity 0.8.37 release fixes and OpenZeppelin release/security notices. No advisory affecting the imported ERC721/AccessControl/ReentrancyGuard/Strings functionality was identified from those notices. This does not certify every unused module of OpenZeppelin or every build tool as vulnerability-free. The compiler/backend uses stable code generation; experimental SSA features are not enabled. Storage-based ReentrancyGuard is deprecated upstream for eventual v6 removal but remains supported in pinned 5.7.0; no transient-storage-only guard is required by this contract.

The optional management console adds pinned ethers 6.17.0, Vite 8.3.4 and Playwright 1.64.0. Dependency installation passed the mcaifee gate with only low/informational findings, npm audit found zero advisories, and npm registry signature verification reported no invalid/missing signatures. Lifecycle scripts were disabled. The Solidity runtime is 12,265 bytes, below EIP-170. v2 runtime bytes are compared exactly with compiler output; its deadline is storage, not an immutable bytecode substitution.

## Retained design and operational risks

- **Treasury allocation is part of success.** Mint all 500 treasury NFTs, in gas-appropriate batches, before opening the public sale. If all 5,900 paid NFTs sell but any treasury allocation is missing at expiry, the campaign still fails, refunds remain available, transfers stay locked, and treasury cannot withdraw. This preserves the original economic rule; changing it would require an explicit product decision.
- **Admin and treasury are privileged.** Admin can change the open-sale deadline, phases/allowlist/wallet caps, grant or revoke roles and choose the final metadata URI. Treasury role holders can withdraw all proceeds after success. Use deliberate role holders, preferably multisigs for production; losing all administrator access can prevent reveal or role recovery. No anti-Sybil identity guarantee is provided by a per-address cap.
- **Reveal is admin-selected and deterministic.** It has no precommitted metadata hash, random shuffle, or VRF. The final on-chain URI is one-shot; invalid remote content cannot be repaired on chain afterward. Mutable HTTPS hosting remains mutable even with a fixed URI. See the reveal guide.
- **Failed sales do not recover unsolicited funds.** Ordinary direct ETH sends revert, but forced ETH can remain after all legitimate refunds. No sweep function is added that could put refund reserves at risk. Paid refunds are fixed at the exact mint price; gas is not refunded.
- **Large batches can run out of gas.** There are hard supply caps, not a small per-transaction batch cap. Operators and clients must estimate gas and split treasury/allowlist actions. A revert rolls back the entire batch.
- **ERC-721 ownership does not imply refund rights.** Only the original paid minter is eligible, approvals do not authorize claiming, and refunded tokens are burned. Indexers must process burns and deployment-specific histories.
- **Existing contracts are not upgraded.** The old contract has no proxy/upgrade path. New deployments do not migrate holders or funds from an old address. No assertion is made about balances, users, or exploited funds at an unprovided old deployment.

## v2 deadline and console review

Live shortened-deadline refund QA also passed on [`0xBc5338c4a71961d999Ec9551a2636850ec1561e0`](https://sepolia.etherscan.io/address/0xBc5338c4a71961d999Ec9551a2636850ec1561e0): shortening enabled refunds at the new boundary; reopening failed before and after its first refund; the paid token was burned and a repeat claim rejected. Evidence is in `deployments/sepolia-v2-refund.json`.

The user explicitly requested variable dates. `setMintEndTime` emits `MintEndTimeUpdated(previousEndTime, newEndTime)` and is protected by the admin role and the same reentrancy guard as mint/refund. Expiry remains final even before the first refund, so an admin cannot reopen a failed sale and mint over burned IDs or interfere with refund reserve accounting. A sold-out collection cannot change its date either.

**Changed trust assumption:** before expiry, an administrator can extend the sale repeatedly or shorten it to any future timestamp. There is no maximum extension or notice period. Users must be shown the current chain deadline and understand that an open-sale deadline is mutable. The application does not claim a guaranteed pre-expiry refund date.

The static console at [ryodan.grooooog.space](https://ryodan.grooooog.space) contains no signing key, privileged backend, or server-side automatic signer. Wallet role checks are read at the same block as sale state. The contract enforces permissions even if UI controls are bypassed. The UI simulates/estimates each call, displays network/contract/arguments/value for review, and rechecks wallet/network/state before requesting a signature. Pending hashes persist by chain and contract; reload does not permit a duplicate submission. Confirmed equivalent replacements and confirmed cancellations are reconciled separately. Metadata and transaction details are rendered as text.

Nine frontend validation tests and 17 browser workflow checks passed. Browser workflows use a test EIP-1193 provider with actual local RPC transactions: they do not test a particular wallet extension's own screens. They cover account/network changes, rejection, pending recovery, access controls, UTC edits, mint, treasury, refunds, duplicate refund rejection, full-size successful reveal and withdrawal, and mobile overflow. Static-site browser checks additionally read real Sepolia state and verify Etherscan links. Browser evidence is summarized in `docs/security/console-verification.json`.

## Verification boundaries

The active v2 contract is [`0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B`](https://sepolia.etherscan.io/address/0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B), recorded in `deployments/sepolia-v2.json`. Its deadline changes and paid/treasury mints were confirmed, and a second RPC independently checked runtime bytecode, roles and receipts. Earlier v1 mint/refund transactions remain in `deployments/sepolia.json`; `deployments/sepolia-verification.json` independently confirms both 0.01 ETH repayments from recipient balance changes and actual gas, with an operational summary in `SEPOLIA_RUNBOOK.md`. Failed operations are checked through on-chain `eth_call` simulations, not broadcast as deliberately reverting transactions. Full sellout, successful withdrawal and successful reveal are tested locally, not on Sepolia: paid sellout requires 59 ETH plus gas. No mainnet deployment, explorer source publication or artwork/IPFS publication was performed.

## Upstream references

- [Solidity 0.8.37 release and compiler security fixes](https://www.soliditylang.org/blog/2026/09/10/solidity-0.8.37-release-announcement/)
- [OpenZeppelin Contracts 5.7.0 release](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.7.0)
- [OpenZeppelin security advisories](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories)
- [forge-std releases](https://github.com/foundry-rs/forge-std/releases)
- [Slither detector reference](https://github.com/crytic/slither/wiki/Detector-Documentation)
