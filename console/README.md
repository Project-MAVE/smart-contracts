# Ryodan Control v4

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
```

Build the Solidity project and export/check its ABI first. Local integration tests use Anvil and Chrome/Playwright with real EVM transactions, including CSV downloads/build/loading, inherited proofs, all four phases, batch refunds and complete sellout/reveal/withdrawal. Run Slither separately because it can clean compiler artifacts.

`src/deployment.json` and `src/allowlist.json` are public testnet configuration, not secrets. The default snapshot contains only the dedicated test wallet. `public/templates/` holds empty CSVs and their ZIP; the Sale controls page builds both proof and checker files entirely in the browser. The CLI is `node scripts/allowlist.mjs build|load`; `load` is a dry run unless `--apply` is explicit. Importing a new snapshot in one browser does not publish it for other visitors.

No private key is shipped. The panel selects v4/v3/legacy ABIs and preserves old deployment access. Production is persistently served by grog from `dist/`; **building into `dist/` updates the public site**. Use an alternate output directory for review builds. Development-only `VITE_CHAIN_ID=31337`, `VITE_RPC_URL` and `VITE_CONTRACT_ADDRESS` configure local Anvil; production always uses Sepolia.
