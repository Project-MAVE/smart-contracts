# Metadata and reveal operations

Updated for v3 (2026-10-29): four sale phases do not change metadata or reveal. Token IDs remain sequential across all phases and treasury mints. Reveal remains one permanent admin transaction after all 6,400 NFTs mint; it is not selectable by a holder. Use the v3 deployment manifest and ABI for new integrations.

Current management UI: [ryodan.grooooog.space](https://ryodan.grooooog.space). Select **v2 / active management**, address [`0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B`](https://sepolia.etherscan.io/address/0x4b8D8fd22FB818aa7b312Cb72F7048E4d738109B). The earlier v1 contracts remain separate deployments.

## Original implementation

The previous contract returned `ipfs://QmZ/soulbound/` before 6,400 mints and `ipfs://QmZ/` afterward. `QmZ` is a placeholder, neither path identifies a valid uploaded collection, and the token ID was ignored. There was no reveal transaction, per-token JSON path, metadata setter, or metadata update event. `tokenURI` also returned a URI for tokens that never existed.

Soulbound describes the transfer restriction; it does not imply any particular metadata format. ERC-721 metadata is a JSON document referenced by `tokenURI`. Its `image` property refers to the artwork separately.

## Revised behavior

1. The constructor receives the hidden JSON URI. This URI cannot be changed later.
2. Existing tokens return that same hidden URI until explicit reveal, even if the collection sells out.
3. After all **5,900 paid and 500 treasury** tokens have minted, the admin may call `reveal(baseURI)` once.
4. The base URI must end in `/`. After reveal, ID 0 resolves to `<baseURI>0.json`, ID 6399 to `<baseURI>6399.json`.
5. Reveal emits `Revealed(baseURI)` and ERC-4906 `BatchMetadataUpdate(0, 6399)`; `supportsInterface(0x49064906)` returns true.
6. There is no setter to replace the final base URI and no second reveal.
7. Unknown or refunded/burned token IDs revert on `tokenURI`.

Transferability begins at sellout and does not depend on reveal. If the sale expires unsuccessfully, reveal stays unavailable, paid NFTs can be refunded and burned, and surviving treasury NFTs remain locked with hidden metadata.

## Prepare assets

Prepare and pin artwork first, then JSON metadata. A typical final document is:

```json
{
  "name": "Ryodan Key #0",
  "description": "A Ryodan Key.",
  "image": "ipfs://<artwork-directory-cid>/0.png",
  "attributes": [
    { "trait_type": "Clan", "value": "Example" }
  ]
}
```

These CID placeholders illustrate the format; replace them with actual pinned content. Generate **6,400 files**, `0.json` through `6399.json`. The treasury shares the ID sequence with paid minting, so generate metadata for all IDs rather than assuming the final 500 are treasury tokens.

Upload/pin the JSON directory. If its CID is `<metadata-directory-cid>`, use `ipfs://<metadata-directory-cid>/` as the reveal argument. The directory must directly contain `0.json`, not a second nested folder that changes the path. Use the separate artwork directory CID inside `image`.

The hidden JSON should contain the unrevealed name, description and placeholder artwork URL. Pin it before deployment and pass its full JSON URI, such as `ipfs://<hidden-directory-cid>/hidden.json`, to the constructor. For the current Sepolia QA deployments, the hidden JSON is self-contained in a base64 `data:` URI; it is suitable for metadata reads but does not contain final artwork.

## Pre-reveal verification

- Validate every JSON file, its required text fields, and media URIs. IDs must cover exactly 0..6399, with no gaps or filename padding.
- Confirm metadata and media are pinned with adequate redundancy. A CID guarantees content identity, not continued availability.
- Fetch sample first, middle and final JSON documents and their media through at least two gateways. Validate all collection files before using the irreversible reveal operation.
- Confirm the intended chain and contract address, admin role, `soldOut() == true`, and `revealed() == false`.
- Check the exact base URI including trailing `/` and folder layout. The contract checks the trailing slash but cannot fetch or validate remote JSON.

Call `reveal(string)` from the admin wallet and wait for a successful receipt. Then read `revealed()`, `revealedBaseURI()`, `tokenURI(0)` and `tokenURI(6399)` on chain, resolve both documents and their images, and confirm the metadata update event. Marketplace caches may require refresh even after this event; their refresh behavior is external to the contract.

Use the public ABI with the admin's wallet or inject the operator key through hush for CLI use. No backend or frontend should hold the operator private key.

## Privacy and trust limits

The reveal assigns metadata deterministically by token ID. It does not randomize traits, commit to an initial metadata hash, use VRF, or prove a fair distribution. The admin chooses the final URI at reveal. Publishing an IPFS directory CID before reveal exposes its contents to anyone who knows the CID. A content-addressed immutable URI and a mutable HTTPS endpoint have different trust properties: an immutable on-chain base URI cannot prevent the operator of an HTTPS endpoint from replacing its responses.

Existing deployed copies of the old contract cannot gain this behavior: they have no upgrade mechanism. A new address and an explicit frontend configuration change are required.

## Sources

- [ERC-721 metadata specification](https://eips.ethereum.org/EIPS/eip-721)
- [ERC-4906 metadata update events](https://eips.ethereum.org/EIPS/eip-4906)
- [OpenZeppelin ERC721 reference](https://docs.openzeppelin.com/contracts/5.x/api/token/erc721)

## Reveal from the management console

1. Open **Metadata & reveal** and connect the administrator wallet on Ethereum Sepolia.
2. Use **Token inspector** to check an existing token ID, its owner and canonical URI. It displays metadata as text and does not execute remote content.
3. Upload and validate all final JSON/media assets independently. The console does not upload to IPFS or verify the directory contents.
4. Wait for `soldOut() == true`, including all 500 treasury keys. Reveal stays disabled until this condition is true.
5. Enter the final `ipfs://<directory CID>/` or `https://<host>/<directory>/` base URI, including the final slash. Check the displayed `0.json` example.
6. Acknowledge the irreversible change, review the exact URI/contract/network, then sign in the wallet.
7. Wait for the confirmed transaction in the activity log and inspect several tokens again. The collection status becomes **REVEALED**; reveal is permanently disabled.

Changing the mint deadline is a separate v2 administration operation under **Sale controls**. It neither triggers reveal nor relaxes sellout. The admin can shorten or extend an open sale; once its deadline passes or the collection sells out, the deadline is locked. An unsuccessful expired sale remains refundable and cannot be revealed by moving its date.

Full-size sold-out reveal was exercised through the browser UI on local Anvil with all 6,400 keys. Sepolia is intentionally still sealed with a small test supply; successful Sepolia reveal requires the actual sale to sell out. No final artwork or IPFS directory has been published by this work.
