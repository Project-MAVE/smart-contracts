# Agent Instructions

All global agent instructions are centralized in `~/.agents/AGENTS.md`.
Read that file at the start of every session and before any external action.
Global rules are maintained only in that file; the following section is project reference material.

## Project reference

- `ryodan-keys/` is the Foundry project, pinned to Solidity 0.8.37, OpenZeppelin 5.7.0 and forge-std 1.16.2. Ryodan Keys v2 adds admin-controlled deadlines before expiry/sellout, original-minter refunds that burn paid tokens, optional refund recipients and permanent collection-wide metadata reveal after all 6,400 tokens mint.
- The public contract API is exported in `ryodan-keys/abi/RyodanKeys.json`; `ryodan-keys/scripts/export-abi.py --check` checks consistency with compiled artifacts. Deployment manifests under `ryodan-keys/deployments/` contain public Sepolia addresses and receipt evidence.
- `console/` is a static Vite/ethers application with injected-wallet signing, pinned-block reads, role/network checks, transaction review and pending-transaction recovery. Its routes are `#mint`, `#sale`, `#treasury`, `#reveal`, `#access` and `#refund`. There is no backend API, database or server-side signer.
- The production console is https://ryodan.grooooog.space; its selected deployment is configured in `console/src/deployment.json`. Production uses Ethereum Sepolia; the local Anvil mode is development-only. Branding tokens and official logo sources are documented in `DESIGN.md`.
- `.github/workflows/test.yml` runs Foundry tests with fuzzing/invariants, ABI validation, Slither and frontend unit/build/browser checks. Browser tests perform actual transactions against local Anvil through a test wallet provider.
- Integration, metadata/reveal, operator, security and deployment documentation is in `ryodan-keys/docs/`, starting with `FRONTEND_INTEGRATION.md` and `MANAGEMENT_CONSOLE.md`.
