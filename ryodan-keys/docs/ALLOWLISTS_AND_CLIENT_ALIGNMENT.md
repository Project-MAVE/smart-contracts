# Client alignment and allowlist workflow — v4

Updated 2026-10-30. The supplied `neomars-mint-dev-2026-10-08.zip` and the client's latest instruction supersede v3's earlier commercial defaults. The ZIP's mock dates are illustrative, not a launch schedule. Source archive SHA-256: `15035ab84d2b4e877a718b1c00e9e26c0f134c1719cedfe714b0a03368b761bb`.

## Responses to the frontend handoff

| Question | V4 resolution |
| --- | --- |
| Operative / Recruit discounts | Public 0.050 ETH; Pioneer 0.025/key, Operative 0.040/key and Recruit 0.045/key. Discounts are 50%, 20%, 10%. V3's 80%/90% discounts followed an earlier chat instruction and are superseded. `configurePhase` can change current/future prices. |
| Hierarchical lists | One canonical tier per wallet. Pioneer inherits Operative and Recruit; Operative inherits Recruit. No duplicate on-chain list transactions are needed. |
| Wallet limits | Initial caps 4 / 10 / 10 / 10, independent per phase. Contract and panel allow changes. Pioneer cap and quantities must be even. |
| Batch refund | `refundBatch(uint256[])`, 1–50 unique eligible IDs, any caller, original minters receive their individual original payments. Atomic failure and duplicate protection apply. |
| Supply | 6,666 total, retaining the separate 500 treasury allocation: 6,166 paid. Civilian receives the remaining paid supply. |
| CSV ownership and timing | The client/operator fills the templates. The administrator loads the generated root/counts before starting Pioneer. Frontend publishes the matching `allowlist.json` and `check-data.js`. No production lists currently exist or are loaded. |

Pioneer buys pairs: 2 keys cost 0.050 ETH and 4 keys cost 0.100 ETH. The on-chain price is always **per key**, including Pioneer. Do not multiply a pair price by a key quantity.

## Download and fill the templates

Open [Sale controls](https://ryodan.grooooog.space/#sale). Download the [complete ZIP](https://ryodan.grooooog.space/templates/ryodan-allowlist-templates.zip), or [pioneer.csv](https://ryodan.grooooog.space/templates/pioneer.csv), [operative.csv](https://ryodan.grooooog.space/templates/operative.csv), [recruit.csv](https://ryodan.grooooog.space/templates/recruit.csv) separately. Templates contain only the `address` header; no sample address can accidentally become a member.

Each file uses UTF-8 CSV, first column `address`, one Ethereum address per subsequent row. Keep the header for empty lists. Keep original filenames. Extra columns are ignored; avoid including personal information. Never include secrets. Quoted fields, BOM and CRLF are accepted. Zero/malformed addresses and malformed CSV are rejected rather than silently omitted.

Assign each address to its highest tier. Duplicate rows and overlaps are deduplicated with Pioneer > Operative > Recruit. The panel reports removed duplicates. Each canonical wallet still has a distinct allowance in every phase it can enter.

## Generate, review, distribute, load

1. Select all three completed CSVs and an explicit UTC freeze timestamp in Sale controls. CSV parsing remains in the browser.
2. Generate the snapshot. Review counts, source SHA-256 hashes, root, freeze timestamp and GTD budget using the contract's current caps.
3. Download **both** `allowlist.json` and `check-data.js`. Archive the original CSV bytes privately with these outputs. Generation does not write on chain.
4. The frontend publishes both outputs from this exact build. `check-data.js` matches Gigio's `NM.checkData` schema: lowercase-address SHA-256 hashes without `0x`, highest-tier lists and `frozen`. `allowlist.json` supplies Merkle proofs indexed by the same SHA-256 digest with `0x`.
5. Before Pioneer starts, the administrator reviews and signs `configureAllowlist(root, snapshotHash, pioneerCount, operativeCount, recruitCount)` from the panel. Compare the confirmed root/hash/counts to the files. The panel can also import a previously generated JSON snapshot.
6. Start Pioneer only after this comparison. Starting it freezes membership and counts permanently. Then resume minting. Continue with sequential phase advancement/resumption.

Generated/imported data is held in the current browser session. Download it before reloading. The console initially loads the shipped Sepolia test snapshot; importing a different snapshot does not publish it to other browsers. The frontend team must deploy the generated outputs explicitly. A wrong-root proof cannot mint; the panel shows when its loaded snapshot does not match on chain.

## Guaranteed capacity

With exclusive counts `P` and `O`, the initial reservation is:

```text
Pioneer reserve  = P × Pioneer wallet cap
Operative reserve = (P + O) × Operative wallet cap
Combined reserve ≤ 6,166 paid keys
```

At defaults this is `14P + 10O ≤ 6166`. Recruit membership adds no guaranteed allocation. For example, 440 Pioneers alone reserve 6,160 keys; 441 cannot fit. The compiler/panel and contract reject an oversized reservation. The panel's full-list budget is the allocation computed at current caps, not the unclaimed live reserve; the latter is displayed separately.

A paid mint consumes its phase's reservation. Closing a phase releases its unused guarantee permanently. Changing an open/future GTD cap recalculates reservations and cannot lower the cap below the highest quantity already minted by one wallet in that phase. Increasing limits may fail if the combined promises exceed remaining supply. Recruit/Civilian caps can be reduced below historical purchases; that wallet then has zero remaining allowance until the cap increases. Purchased tokens and counters are not reset.

## Reproducible command-line workflow

From `console/`:

```sh
node scripts/allowlist.mjs build --csv-dir /path/to/frozen-csvs \
  --out /path/to/output --frozen-at 2026-10-30T12:00:00.000Z
# Optional --pioneer-limit and --operative-limit match nondefault caps.
node scripts/allowlist.mjs load --snapshot /path/to/output/allowlist.json \
  --contract <v4-address> --rpc <sepolia-rpc>
# After reviewing the dry run, the authorized operator signs:
hush run --name YOMI_RYODAN_SEPOLIA_DEPLOYER --env PRIVATE_KEY --redact -- \
  node scripts/allowlist.mjs load --snapshot /path/to/output/allowlist.json \
  --contract <v4-address> --rpc <sepolia-rpc> --apply
```

The loader supports Sepolia/local Anvil only, validates every proof and manifest, checks live phase/caps/capacity and skips an already matching root/hash/count set. It never prints private keys or wallet lists. The hash-only outputs are not an anonymity guarantee: known addresses can be checked against them.

## Merkle encoding and trust boundary

Leaf: `keccak256(bytes.concat(keccak256(abi.encode(account, uint8(tier)))))`, with tiers 1/2/3. Leaves are sorted lexicographically; internal nodes hash two sorted `bytes32` values. An unmatched node is promoted unchanged. OpenZeppelin `MerkleProof.verifyCalldata` verifies the resulting sibling path. Do not substitute packed address encoding or a single leaf hash.

The canonical manifest includes schema version, freeze timestamp, three raw CSV hashes, root and exclusive counts. Its digest is `keccak256(UTF8(JSON.stringify(manifest)))` in the order implemented in `console/src/allowlist.js`. Use that shared implementation, not a separately guessed serialization. Source-file row order can change the manifest hash even if eligibility/root are unchanged, because the original bytes are committed.

The admin is trusted to commit the correct list and counts. A Merkle root alone does not prove member cardinality or uniqueness. The builder validates/deduplicates CSVs; snapshot validation checks counts, reconstructed root, all proofs and manifest digest. The contract additionally limits registered members per tier to the declared count. Incorrect administrator commitments can deny access and invalidate the intended guarantee; they cannot be repaired after Pioneer starts. Never configure arbitrary counts independently from the generated snapshot.
