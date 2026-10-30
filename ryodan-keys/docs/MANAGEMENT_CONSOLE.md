# Ryodan Control — v4 operator guide

Open [ryodan.grooooog.space](https://ryodan.grooooog.space). The console uses Ethereum Sepolia, shows the selected contract's full address and links directly to Sepolia Etherscan. V4 is selected by default; older v1/v2/v3 deployments retain their original controls and ABI. This is testnet, not a mainnet launch.

Read-only operation requires no wallet. To sign, import/use the dedicated test wallet in an Ethereum wallet and connect it on Sepolia. Its public address is `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`; it holds admin and treasury roles in these test deployments. The private key is stored in hush under `YOMI_RYODAN_SEPOLIA_DEPLOYER`; never enter it in this webpage. The frontend has no signing server and stores no key.

## Prepare the lists

In **Sale controls → Prepare the three lists**, download the complete template ZIP or the individual Pioneer, Operative and Recruit CSVs. Each is empty except for the `address` header. Add one wallet per line and assign it only to its highest tier. Pioneer inherits Operative/Recruit and Operative inherits Recruit. See [CSV requirements and the full loading procedure](ALLOWLISTS_AND_CLIENT_ALIGNMENT.md).

Select all three completed files and a UTC freeze timestamp. Generate, inspect counts/hashes/capacity, and download `allowlist.json` plus `check-data.js`. A previous JSON snapshot can also be imported. Both outputs must be published by the frontend team from the same build. Downloads and browser processing do not change the chain. Imported/generated data is session-only; download before reloading.

Before starting Pioneer, sign **Review snapshot on chain**. Root/counts can be corrected while phase is 0. Once Pioneer starts, membership is permanently frozen; prices and per-wallet limits remain editable under their respective guards. Existing v4 smoke deployments already started with the test-wallet-only snapshot and cannot accept a different real list. The final campaign needs its own fresh deployment and completed lists.

At default caps the guaranteed budget is `14 × Pioneer count + 10 × Operative count`, at most 6,166 paid keys. The panel shows full-list budget at current caps separately from actual remaining on-chain guarantees. Recruit adds no guaranteed reserve. Never invent counts to make an oversized list fit; adjust caps or list membership before committing.

## Mint

The mint page has no phase picker. It reads the active phase, price and remaining wallet allowance. Initial settings:

| Phase | Price/key | Cap per wallet |
| --- | ---: | ---: |
| Pioneer | 0.025 ETH | 4, in pairs |
| Operative | 0.040 ETH | 10 |
| Recruit | 0.045 ETH | 10 |
| Civilian | 0.050 ETH | 10 |

Pioneer buys 2 or 4 keys under the initial cap, at 0.050 ETH per pair. The other phases buy individual keys. Wallet caps are independent between phases; repeat transactions in the same phase consume the same allowance. Existing test purchases count toward their caps.

Review shows chain, contract, signer, function, arguments, exact payment and gas estimate. Sign in the wallet. Confirmation shows actual minted token IDs and transaction links. If the quoted price or phase changes, review a new transaction. A missing proof snapshot cannot grant first-time list access; import the file matching the on-chain root or use the deployed frontend's matching data.

## Sale controls

- **Phase price & wallet limit:** change the current or a future phase. Price is ETH per key, including Pioneer. Pioneer cap must be even. GTD caps cannot go below the maximum already minted by one wallet in that phase, and increases must fit remaining paid supply. FCFS cap reductions do not erase earlier mints.
- **Advance:** permanently closes the current phase, releases its unused guarantees and opens the next phase paused. Progress is Pioneer → Operative → Recruit → Civilian. Review the next phase's settings, then resume. Closed phases cannot reopen.
- **Pause/resume:** stops/starts the active phase without moving its deadline.
- **Deadline:** displayed and entered in UTC. It can be shortened or extended while the existing deadline has not passed and the sale has not sold out. The new value must be in the future. An expired sale cannot reopen, including before its first refund.

There is one shared mint deadline and manual phase advancement, not four automatic schedules. Pausing does not extend guarantees beyond phase closure or expiry. Civilian gets the remaining paid keys after Recruit, without a fixed separate quota.

## Treasury, metadata and access

**Treasury:** mint reserved keys to a validated recipient, up to 50 per UI transaction, for gas only. Finish all 500 treasury mints before expiry. All 6,166 paid **and** 500 treasury keys are required for success. If treasury is incomplete, even paid sellout cannot unlock transfers, reveal or withdrawal. After complete sellout the connected treasury-role wallet can withdraw the full ETH balance.

**Metadata & reveal:** inspect existing tokens and their canonical URI. Prepare and pin `0.json` through `6665.json`, then enter a final directory URI ending in `/`. Review and acknowledge the permanent reveal after full sellout. Reveal can happen once and has no on-chain undo. See [metadata preparation](METADATA_AND_REVEAL.md).

**Access control:** administrators grant/revoke admin and treasury roles. Verify addresses and keep an administrator able to act. Self-revocation is blocked in the panel; the underlying AccessControl contract still supports role renunciation/revocation. Role holders, not the webpage, enforce control.

## Refunds

After unsuccessful expiry, **Refunds** supports:

1. Single ID: default payment to its original minter. In v4 anyone may trigger it.
2. Optional recipient: only the original minter can use this to redirect their own refund, including recovery for a wallet that rejects incoming ETH.
3. Batch: enter 1–50 unique paid IDs separated by commas/newlines. One signature, potentially multiple minters; each receives their original token payment. The caller does not collect other people's funds.

Refunds burn tokens. Duplicate, missing, treasury or already refunded IDs revert the entire batch; an ETH-rejecting recipient also rolls all of it back. Exclude that ID and have its minter use the optional-recipient flow separately. Current phase prices do not change historical refunds. Gas is separate.

## Transaction recovery

Wrong chain, missing roles, stale RPC data and pending transactions disable writes with an explanation. Pending hashes persist by chain/contract. Use **Check receipt** after reload; do not submit the operation again because confirmation is slow. For wallet replacements/cancellations, supply the confirmed replacement hash; the panel checks the same sender/nonce and refreshes state. Rejected signatures leave state unchanged.

Public reads use PublicNode with ethPandaOps fallback and bounded requests. Contract permissions and checks apply even if UI controls are bypassed. Read-only public site checks are distinct from local signing tests.
