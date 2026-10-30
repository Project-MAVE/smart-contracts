# Ryodan Keys v4

ERC-721 sale aligned with `neomars-mint-dev-2026-10-08.zip`: four sequential mint phases, inherited list eligibility, guaranteed allocations, editable phase prices/caps/deadline, atomic batch refunds and a one-shot reveal.

| Phase | ETH per key | Initial wallet cap | Access |
| --- | ---: | ---: | --- |
| Pioneer | 0.025 (0.050 per pair) | 4 | Pioneer; guaranteed; even quantities only |
| Operative | 0.040 | 10 | Pioneer + Operative; guaranteed |
| Recruit | 0.045 | 10 | Pioneer + Operative + Recruit; FCFS |
| Civilian | 0.050 | 10 | Public; FCFS |

Caps are independent per phase and admin-editable. A Pioneer can initially mint 34 keys across the four phases. Phase selection is controlled by the contract: users cannot choose or revisit a phase. Token IDs are sequential across paid and treasury mints.

Supply is **6,666 = 6,166 paid + 500 treasury**. Civilian receives the paid supply remaining after Recruit; it has no fixed separate allocation. All 6,666 lifetime mints are required to unlock transfers, reveal and treasury withdrawal. Unsuccessful expiry enables refunds of each token's original payment, burns the token and prevents a second refund.

Lists come from three CSVs with one highest tier per address. The console downloads empty templates and builds a Merkle snapshot plus the checker data from exactly those files. Membership freezes when Pioneer starts. No production CSVs were supplied; the Sepolia deployment uses only the dedicated test wallet.

## Development

```sh
git submodule update --init --recursive
cd ryodan-keys
forge build --sizes
forge fmt --check
FOUNDRY_PROFILE=ci forge test
python3 scripts/export-abi.py --check
slither . --config-file slither.config.json
cd ../console
npm ci --ignore-scripts
npm test
npm run test:deploy
npm run test:browser
```

Pinned Solidity 0.8.37, Cancun, optimizer 200 runs, OpenZeppelin 5.7.0, forge-std 1.16.2, Foundry 1.7.1 and Slither 0.11.6. Slither may clean/rebuild artifacts: run it sequentially with deployment/coverage tooling. Never deploy coverage artifacts; rebuild the optimized artifact afterward.

The legacy vulnerable fixture is test-only. V4 requires a new deployment: previous contracts, holders and funds are not automatically upgraded or migrated.

## Operations and integration

- [Single document to forward to other agents](docs/AGENT_HANDOFF_V4.md)

- [Management panel](https://ryodan.grooooog.space/#sale)
- [Client requirements and CSV workflow](docs/ALLOWLISTS_AND_CLIENT_ALIGNMENT.md)
- [Frontend agent handoff](docs/FRONTEND_INTEGRATION.md)
- [Management guide](docs/MANAGEMENT_CONSOLE.md)
- [Metadata and reveal](docs/METADATA_AND_REVEAL.md)
- [Security review and verification limits](docs/SECURITY_REVIEW.md)
- [Sepolia runbook](docs/SEPOLIA_RUNBOOK.md)
- [V4 ABI](abi/RyodanKeys.json); [v3 ABI](abi/RyodanKeys.v3.json); [v1/v2 ABI](abi/RyodanKeys.v2.json)
- [V4 management receipts](deployments/sepolia-v4.json)

The operator console is a static application with wallet signing; it contains no private key or signing backend.
