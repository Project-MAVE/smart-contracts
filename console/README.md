# Ryodan Control v7

Static, wallet-signed management UI for Ryodan Keys on Ethereum Sepolia.

- [Live panel](https://ryodan.grooooog.space)
- [Operator guide](../ryodan-keys/docs/MANAGEMENT_CONSOLE.md)
- [CSV templates and loading workflow](../ryodan-keys/docs/ALLOWLISTS_AND_CLIENT_ALIGNMENT.md)
- [Frontend agent handoff](../ryodan-keys/docs/FRONTEND_INTEGRATION.md)
- [Visual system](../DESIGN.md)

```sh
npm ci --ignore-scripts
npm test
npm run dev
npm run build
npm run test:deploy
npm run test:browser
SAFE_FORK_URL=<Sepolia RPC> npm run test:safe
```

Build the Solidity project and export/check its ABI first. Local integration tests use Anvil and Chrome/Playwright with real EVM transactions, including CSV downloads/build/loading, inherited proofs, all four phases, batch refunds and full 6,666-key sellout with the automatic SBT-to-NFT metadata switch, withdrawal, the 72-hour keep-or-refund window and treasury burn. `npm run test:safe` forks Sepolia with Anvil and runs the Safe launch sequence against the real client Safe: the console prepares each Transaction Builder batch, two impersonated owners execute it, and the panel follows the chain; it is skipped without `SAFE_FORK_URL`. Run Slither separately because it can clean compiler artifacts.

`src/deployment.json` and `src/allowlist.json` are public testnet configuration, not secrets. The default snapshot is the Sepolia test list: the dedicated test wallet plus five team test wallets, all in Pioneer. `public/templates/` holds empty CSVs and their ZIP; the Sale controls page builds both proof and checker files entirely in the browser. The CLI is `node scripts/allowlist.mjs build|load`; `load` is a dry run unless `--apply` is explicit. Importing a new snapshot in one browser does not publish it for other visitors.

No private key is shipped. The panel manages only Ryodan Keys v7: it reads `CONTRACT_VERSION` first and refuses any other version (v1 without the getter, v2–v6) with every action disabled. With no v7 deployment in `src/deployment.json` it shows NO V6 CONTRACT. Production is persistently served by grog from a copy of the build on the Mac Pro (`~/Services/ryodan-console/dist`); building into `console/dist/` does not change the public site until that copy is replaced. Development-only `VITE_CHAIN_ID=31337`, `VITE_RPC_URL` and `VITE_CONTRACT_ADDRESS` configure local Anvil; production always uses Sepolia.
