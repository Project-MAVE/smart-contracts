# Ryodan Control — v7 operator guide

Open [ryodan.grooooog.space](https://ryodan.grooooog.space). The console uses Ethereum Sepolia, shows the selected contract's full address and links directly to Sepolia Etherscan. It manages **only Ryodan Keys v6**: it reads `CONTRACT_VERSION` first and refuses any other version (UNSUPPORTED CONTRACT, every action disabled). It manages the v6 test deployment [`0xd069E170ECD211ca09157Afe6E9110E322BC30f8`](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8); with no v6 deployment configured it shows NO V6 CONTRACT. This is testnet, not a mainnet launch.

Supply: **6,666 keys = 6,166 paid + 500 treasury**, token IDs 1–6666.

Read-only operation requires no wallet. To sign, import/use the dedicated test wallet in an Ethereum wallet and connect it on Sepolia. Its public address is `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`; it holds admin and treasury roles in test deployments. The private key is stored in hush under `YOMI_RYODAN_SEPOLIA_DEPLOYER`; never enter it in this webpage. The frontend has no signing server and stores no key.

## Operating from a Safe

When the contract's administrator is a Safe, the overview opens with **00 / Safe operations**: the Safe address, its owners and threshold, the roles it holds and the launch sequence. The current Sepolia deployment `0x28097DF55dA295bB969b8B187c26978D63D099B8` is administered by the client Safe `0x31Cd849c982ED10a94A66b4FD7867e97656952Eb` (2 of 3 owners), which is also its treasury.

Each owner uses its own wallet (Rabby, MetaMask, a hardware wallet), connected with **its own owner address**:

1. **First owner:** connect, press the next step, check the review, press **Approve as owner (1 of 2)** and confirm in the wallet. The approval is recorded on the Safe; nothing else changes.
2. **Second owner:** connect, press the same step. The console shows who approved and offers **Execute from the Safe**; confirming in the wallet runs the call from the Safe.
3. The console follows the chain: the step turns to done and the next one is offered.

Any two owners can take either role. An approval is tied to the Safe's current nonce: if the Safe executes something else first, the step is approved again. Both owners need a little ETH for gas. With a higher threshold the owners approve one after the other and the last one executes.

Launch sequence:

| Step | Safe transactions | Calls |
| --- | --- | --- |
| 1. Load the allowlist | 1 | `configureAllowlist(root, snapshotHash, pioneer, operative, recruit)` from the snapshot loaded in the console |
| 2. Mint the 500 treasury keys | 5 | `treasuryMint(100, Safe)` each; the step always offers the next block |
| 3. Open a phase | 1 per phase | `advancePhase()` then `setMintPaused(false)` in the same Safe transaction, so minting starts when it is executed |

A single transaction cannot use more than 16,777,216 gas. On Sepolia 100 treasury keys minted to the Safe take about 12.3M gas, so the allocation is minted in five Safe transactions; the console refuses a call that would not fit. Every other administrator and treasury form (prices and limits before Pioneer, pause, withdrawals, treasury burn, roles) follows the same two-owner route. The opening can be approved ahead of time and executed at the opening hour.

Before anything is signed the review shows the contract, method, arguments and calldata, the Safe transaction hash read from the Safe, and the approvals already on chain. The wallet then shows a call to the Safe: `approveHash` with that hash, or `execTransaction`.

Other routes:

- **Batch file.** Without an owner wallet, or with **Download batch file** in the review, the step is saved as a JSON file in the Safe Transaction Builder format. In the Safe app open **Apps → Transaction Builder**, drop the file, create and send the batch; the owners sign there.
- **Wallet connected as the Safe.** A wallet that presents the Safe itself as its account (Rabby with the Safe imported, WalletConnect from the Safe app) is treated as the administrator and signs through that wallet. Rabby offers this only on networks where it supports Safe accounts: Ethereum mainnet yes, Sepolia no (it answers *Multi-signature addresses are not on this chain*).

Rabby does not know Sepolia until it is added: on the first connection the console asks the wallet to add it, and Rabby shows **Add Custom Network**.

## Prepare the lists

In **Sale controls → Prepare the three lists**, download the complete template ZIP or the individual Pioneer, Operative and Recruit CSVs. Each is empty except for the `address` header. Add one wallet per line and assign it only to its highest tier. Pioneer inherits Operative/Recruit and Operative inherits Recruit. See [CSV requirements and the full loading procedure](ALLOWLISTS_AND_CLIENT_ALIGNMENT.md).

Select all three completed files and a UTC freeze timestamp. Generate, inspect counts/hashes/capacity, and download `allowlist.json` plus `check-data.js`. A previous JSON snapshot can also be imported. Both outputs must be published by the frontend team from the same build. Downloads and browser processing do not change the chain. Imported/generated data is session-only; download before reloading.

Before starting Pioneer, sign **Review snapshot on chain**. Root/counts can be corrected while phase is 0. Once Pioneer starts, membership is permanently frozen; prices and per-wallet limits are locked too. The final campaign needs its own fresh v7 deployment.

At default caps the guaranteed budget is `4 × Pioneer count + 4 × Operative count` (each Pioneer once: 4 keys across Pioneer and Operative), at most 6,166 paid keys. The panel shows full-list budget at current caps separately from actual remaining on-chain guarantees. Recruit adds no guaranteed reserve. Never invent counts to make an oversized list fit; adjust caps or list membership before committing.

## Mint

The mint page has no phase picker. It reads the active phase, price and remaining wallet allowance. Initial settings:

| Phase | Price/key | Cap per wallet |
| --- | ---: | ---: |
| Pioneer | 0.0075 ETH | 4, any quantity; 4 in total with Operative |
| Operative | 0.012 ETH | 4 |
| Recruit | 0.0135 ETH | 10 |
| Civilian | 0.015 ETH | 20 |

These are the approved prices (2026-11-18) and caps (2026-11-22); the v7 constructor sets them. Prices are per key in every phase and any quantity is allowed. Caps restart in every phase, except that a Pioneer mints at most 4 across Pioneer and Operative together. Nothing can change once Pioneer opens.

Review shows chain, contract, signer, function, arguments, exact payment and gas estimate. Sign in the wallet. Confirmation shows actual minted token IDs and transaction links. If the quoted price or phase changes, review a new transaction. A missing proof snapshot cannot grant first-time list access; import the file matching the on-chain root or use the deployed frontend's matching data.

## Sale controls

- **Phase price & wallet limit:** change the current or a future phase. Price is ETH per key, including Pioneer. Only before Pioneer opens: afterwards the form is disabled and the contract refuses it. GTD caps cannot go below the maximum already minted by one wallet in that phase, and increases must fit remaining paid supply. FCFS cap reductions do not erase earlier mints.
- **Advance:** permanently closes the current phase, releases its unused guarantees and opens the next phase paused. Progress is Pioneer → Operative → Recruit → Civilian. Review the next phase's settings, then resume. Closed phases cannot reopen.
- **Pause/resume:** stops/starts the active phase without moving its deadline.
- **Deadline:** displayed in UTC and fixed at deploy. No function moves it. An expired sale cannot reopen.

There is one shared mint deadline and manual phase advancement, not four automatic schedules. Pausing does not extend guarantees beyond phase closure or expiry. Civilian gets the remaining paid keys after Recruit, without a fixed separate quota.

## Treasury, metadata and access

**Treasury:** mint the 500 treasury keys to a validated recipient, up to 50 per UI transaction, for gas only. The treasury can mint in any phase, also before Pioneer opens; its keys take IDs 1–666 only if all are minted before the first paid mint. Finish all 666 treasury mints before expiry: success needs all 6,000 paid **and** 666 treasury keys. If the treasury is incomplete, even a paid sellout cannot unlock transfers or withdrawal. After complete sellout the connected treasury-role wallet withdraws the full ETH balance (**Review withdrawal**). After an unsuccessful sale it withdraws only what kept keys paid (**Review kept-key withdrawal**) and, once the 72-hour window has closed, burns treasury keys by ID (**Review treasury burn**, up to 50 IDs; paid keys are refused).

**Metadata:** read-only. The page shows the SBT and NFT base URIs read from the contract and inspects a token ID (1–6666): owner, whether the key is locked, kept or unlocked by sellout, whether it is a treasury key, and its URI. There is no reveal: locked keys read the SBT set and switch to the NFT set by themselves. See [metadata](METADATA.md).

**Access control:** administrators grant/revoke admin and treasury roles. Verify addresses and keep an administrator able to act. Self-revocation is blocked in the panel; the underlying AccessControl contract still supports role renunciation/revocation. Role holders, not the webpage, enforce control.

## Refunds

After an unsuccessful expiry, **Refunds** supports:

1. **Keep or refund** (first 4 days): the original minter lists the keys to keep as NFTs and the keys to refund, and signs once (`settle`). In this window the console blocks, before signing, any refund of keys that belong to another minter.
2. Single ID: default payment to its original minter. After the window anyone may trigger it.
3. Optional recipient: only the original minter can use this to redirect their own refund.
4. Batch: 1–50 unique paid IDs separated by commas/newlines. One signature, potentially multiple minters; each receives their original token payment. The caller does not collect other people's funds.
5. **Pending refund claim:** a minter whose wallet rejected ETH inside a batch pulls the recorded amount to a chosen recipient.

Refunds burn tokens. Duplicate, missing, treasury, kept or already refunded IDs revert the entire batch; an ETH-rejecting recipient no longer blocks the batch, its amount waits in the pending refund. Current phase prices do not change historical refunds. Gas is separate.

## Transaction recovery

Wrong chain, missing roles, stale RPC data and pending transactions disable writes with an explanation. Pending hashes persist by chain/contract. Use **Check receipt** after reload; do not submit the operation again because confirmation is slow. For wallet replacements/cancellations, supply the confirmed replacement hash; the panel checks the same sender/nonce and refreshes state. Rejected signatures leave state unchanged.

Public reads use PublicNode with ethPandaOps fallback and bounded requests. Contract permissions and checks apply even if UI controls are bypassed. Read-only public site checks are distinct from local signing tests.
