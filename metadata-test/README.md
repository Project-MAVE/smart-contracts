# Ryodan Keys test metadata

Random square pixel-art metadata for **Sepolia tests only**: not the final artwork.

`server.js` (Node, no dependencies) serves deterministic metadata and SVG images for IDs 1–6666:

- `/sbt/<id>.json`, `/sbt/<id>.svg`: locked set, grey;
- `/nft/<id>.json`, `/nft/<id>.svg`: unlocked set, coloured;
- `/healthz` and an index page with examples.

The same ID always gives the same picture (SHA-256 seeded). `PORT` (default 4361), `HOST` (default 127.0.0.1) and `PUBLIC_URL` (default `https://ryodan-meta.grooooog.space`) configure it.

The Sepolia v6 test deployment uses `https://ryodan-meta.grooooog.space/sbt/` and `/nft/` as its two base URIs.
