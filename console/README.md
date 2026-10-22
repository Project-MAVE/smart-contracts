# Ryodan Control

Wallet-signed management UI for Ryodan Keys on Ethereum Sepolia.

- Live: https://ryodan.grooooog.space
- [Operator guide](../ryodan-keys/docs/MANAGEMENT_CONSOLE.md)
- [Frontend integration](../ryodan-keys/docs/FRONTEND_INTEGRATION.md)
- [Visual system](../DESIGN.md)

```sh
npm ci --ignore-scripts
npm test
npm run dev
npm run build
```

`npm run test:browser` runs real local-chain transactions through a test wallet in an isolated browser. Foundry and Chrome or Playwright Chromium must be installed. Build the Solidity project and export its ABI before running it.

`src/deployment.json` is a public deployment configuration, never a secret. No private key is shipped in the bundle. Production is served persistently by grog from `dist/`. `VITE_CHAIN_ID=31337`, `VITE_RPC_URL` and `VITE_CONTRACT_ADDRESS` enable a development-only local-chain mode; production always uses Sepolia.
