# Metadata and reveal — Ryodan Keys v4

V4 contains 6,666 possible token IDs, **0 through 6665**. IDs are assigned in one sequence across paid and treasury mints. Phases, tiers and Pioneer pairs do not create separate ID ranges or choose artwork.

## Before reveal

The constructor receives a nonempty `hiddenURI`. Every existing token returns that same full URI from `tokenURI(tokenId)`. A typical value is `ipfs://<hidden-directory-CID>/hidden.json`. The Sepolia smoke deployment instead uses a small `data:application/json;base64,...` placeholder explicitly labelled as a test collection. It is not final customer artwork.

`tokenURI` rejects nonexistent or refunded/burned IDs. Hidden metadata is immutable after construction; there is no hidden-URI setter. Supply stats and refund eligibility should come from contract state, not metadata attributes.

## Prepare the final assets

1. Prepare all 6,666 JSON metadata files named `0.json` through `6665.json` without padding. Include standard fields such as `name`, `description`, `image` and `attributes`; add `animation_url` only where needed.
2. Upload/pin media first and refer to stable URIs from the JSON. Check content types, availability, URI resolution and attributes across the complete set.
3. Upload/pin the metadata directory. Test exact paths for IDs 0 and 6665 and validate all intermediate files, not only those two examples. Keep durable backups and pinning coverage.
4. Record the final directory base URI, e.g. `ipfs://<metadata-directory-CID>/`, including the trailing slash. Confirm that concatenating an ID and `.json` returns the intended metadata.

Example metadata structure, using the project's actual pinned media in place of this illustrative URI:

```json
{
  "name": "Ryodan Key #0",
  "description": "A Ryodan access key.",
  "image": "ipfs://<media-CID>/0.png",
  "attributes": [{ "trait_type": "Class", "value": "Example" }]
}
```

The mint contract never fetches or validates remote files. A fixed HTTPS base URI can still serve mutable content; an IPFS content-addressed directory provides stronger content stability. Availability still requires pinning.

## Execute reveal

All **6,166 paid + 500 treasury keys** must have minted: `soldOut()` must be true. Paid sellout alone is insufficient. The administrator then calls `reveal(baseURI)` once, either directly or through [Metadata & reveal in the management panel](https://ryodan.grooooog.space/#reveal).

The call requires a nonempty base URI ending with `/`, sets `revealed=true` and stores `revealedBaseURI`. Subsequently:

```text
tokenURI(0)    = <baseURI>0.json
tokenURI(6665) = <baseURI>6665.json
```

The contract emits `Revealed(baseURI)` and ERC-4906 `BatchMetadataUpdate(0, 6665)` for indexers. Marketplace refresh timing is external to the contract. The URI cannot be changed afterward. The panel additionally accepts only `ipfs://` or `https://` directory paths without spaces, query strings or fragments.

There is no shuffle, VRF, provenance commitment or automatic reveal scheduler. The administrator chooses the final deterministic ID-to-file mapping. A fairness/provenance requirement would require a separately specified design before deployment.

## Failed sale and verification boundary

If the deadline passes before complete sellout, reveal remains unavailable and paid refunds burn the relevant tokens. No URI remains available for a burned token. Admin cannot reopen an expired sale to undo refund rights.

Full-size reveal, sequential metadata paths, one-shot enforcement, metadata events and withdrawal are tested locally. Sepolia smoke contracts use hidden test metadata and do not claim a complete real artwork publication or collection-wide successful reveal. Historical v1/v2/v3 collections retain their original 6,400-token bounds; the console reads each selected deployment's actual supply.
