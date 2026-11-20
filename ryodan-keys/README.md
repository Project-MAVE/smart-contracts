# Ryodan Keys v6

ERC-721 sale for the NEOMARS mint: four sequential mint phases, inherited list eligibility, guaranteed allocations, editable phase prices/caps, a deadline fixed at deploy, keep-or-refund after an unsuccessful sale and two numbered metadata sets (SBT while locked, NFT once unlocked) with no reveal transaction.

## Supply

**6,666 keys = 6,000 paid + 666 treasury** (`MAX_PUBLIC_SUPPLY = 6000`, `MAX_TREASURY_SUPPLY = 666`, `MAX_SUPPLY = 6666`). Token IDs run from **1 to 6666** (key #0042 is token 42) and are assigned in one sequence across paid and treasury mints. Civilian receives the paid supply remaining after Recruit; it has no fixed separate allocation.

The sale succeeds only when all 6,666 keys are minted: 6,000 paid **and** 666 treasury. `treasuryMint` checks only the treasury role, the deadline and the 666 cap, not the phase: the treasury can mint before Pioneer opens. Treasury keys take IDs 1–666 only if all of them are minted before the first paid mint.

## Phases

| Phase | Constructor price per key | Approved price per key (2026-11-18) | Initial wallet cap | Access |
| --- | ---: | ---: | ---: | --- |
| Pioneer | 0.025 ETH | 0.0075 ETH (0.015 per pair) | 4 | Pioneer; guaranteed; even quantities only |
| Operative | 0.040 ETH | 0.012 ETH | 10 | Pioneer + Operative; guaranteed |
| Recruit | 0.045 ETH | 0.0135 ETH | 10 | Pioneer + Operative + Recruit; FCFS |
| Civilian | 0.050 ETH | 0.015 ETH | 10 | Public; FCFS |

The constructor still sets the older prices. Set the approved price of each phase with `configurePhase` before resuming it: `advancePhase` does not check that a phase was configured. Caps are independent per phase and admin-editable. A Pioneer can initially mint 34 keys across the four phases. Phase selection is controlled by the contract: users cannot choose or revisit a phase.

## Outcome

- **Sellout (6,666 minted):** every key becomes a transferable NFT and reads the NFT metadata set; the treasury withdraws the whole balance with `withdraw`.
- **Deadline passes without sellout:** for 72 hours (`CHOICE_WINDOW`) only each original minter decides, key by key, with `settle(keepIds, refundIds)`: a kept key becomes a transferable NFT and is never refundable; a refunded key is burned and its original payment returned. After the window anyone may refund undecided paid keys. The treasury withdraws only what kept keys paid (`withdrawKept`) and burns its own keys with `burnTreasuryKeys`.
- `burn(tokenId)` burns an unlocked key (after sellout, or a kept key) by its owner or an approved operator, for the future burn-to-redeem contract.

Lists come from three CSVs with one highest tier per address. The console downloads empty templates and builds a Merkle snapshot plus the checker data from exactly those files. Membership freezes when Pioneer starts. No production CSVs have been supplied.

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

The constructor takes five arguments: `endTime`, `sbtBaseURI`, `nftBaseURI`, `admin`, `treasury`. Both base URIs must end with `/`. The legacy vulnerable fixture is test-only. V6 requires a new deployment: previous contracts, holders and funds are not upgraded or migrated. The v6 test deployment on Sepolia is [`0xd069E170ECD211ca09157Afe6E9110E322BC30f8`](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8).

## Operations and integration

- [Single document to forward to other agents](docs/AGENT_HANDOFF_V6.md)
- [Management panel](https://ryodan.grooooog.space/#sale)
- [Client requirements and CSV workflow](docs/ALLOWLISTS_AND_CLIENT_ALIGNMENT.md)
- [Frontend agent handoff](docs/FRONTEND_INTEGRATION.md)
- [Management guide](docs/MANAGEMENT_CONSOLE.md)
- [Metadata](docs/METADATA.md)
- [Security review and verification limits](docs/SECURITY_REVIEW.md)
- [Sepolia runbook (v6 test deployment, historical v1–v4)](docs/SEPOLIA_RUNBOOK.md)
- [V6 ABI](abi/RyodanKeys.json)

The operator console is a static application with wallet signing; it contains no private key or signing backend. It manages only v6 contracts.
