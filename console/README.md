# Ryodan Control v8

Static, wallet-signed management UI for TheGatebreaker on Ethereum mainnet. Two individual Safe owners approve and execute privileged actions in the console. Opening a phase combines advancement and mint resumption in a single Safe execution after both confirmation dialogs.

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
SAFE_FORK_URL=<Sepolia RPC> npm run test:handover
```

Build the Solidity project and export/check its ABI first. Local integration tests use Anvil and Chrome/Playwright with real EVM transactions, including CSV downloads/build/loading, inherited proofs, all four phases, batch refunds and full 6,666-key sellout with the automatic SBT-to-NFT metadata switch, withdrawal, the 72-hour keep-or-refund window and treasury burn. `npm run test:safe` forks Sepolia with Anvil and runs the Safe launch sequence against the real client Safe: two impersonated owners approve and execute each step from the console with their own wallets, the panel follows the chain after each execution; it is skipped without `SAFE_FORK_URL`. `npm run test:handover` covers the deployment we perform with our own key: list, treasury keys minted to the Safe, treasury role and `beginDefaultAdminTransfer`, then two owners accept the administrator role from the console and open Pioneer (`SAFE_ADDRESS` selects the Safe, `SAFE_FORK_BLOCK` pins the fork). Run Slither separately because it can clean compiler artifacts.

`src/deployment.json` and `src/allowlist.json` configure the Ethereum deployment and the frozen snapshot of 105 Pioneer, 1,455 Operative and 5,699 Recruit wallets. `public/templates/` holds empty CSVs and their ZIP; the Sale controls page builds both proof and checker files entirely in the browser. The CLI is `node scripts/allowlist.mjs build|load`; `load` is a dry run unless `--apply` is explicit. Importing a new snapshot in one browser does not publish it for other visitors.

No private key is shipped. The panel manages only Ryodan Keys v8: it reads `CONTRACT_VERSION` first and refuses any other version (v1 without the getter, v2–v7) with every action disabled. With no v8 deployment in `src/deployment.json` it shows NO V8 CONTRACT. Production is persistently served by grog from a copy of the build on the Mac Pro (`~/Services/ryodan-console/dist`); building into `console/dist/` does not change the public site until that copy is replaced. Development-only `VITE_CHAIN_ID=31337`, `VITE_RPC_URL` and `VITE_CONTRACT_ADDRESS` configure local Anvil; production uses Ethereum mainnet.
