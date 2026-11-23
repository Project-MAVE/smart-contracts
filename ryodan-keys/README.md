# Ryodan Keys v7

ERC-721 sale for the NEOMARS mint: four sequential mint phases, inherited list eligibility, guaranteed allocations, phase prices and caps fixed before Pioneer opens, a deadline fixed at deploy, keep-or-refund after an unsuccessful sale and two numbered metadata sets (SBT while locked, NFT once unlocked) with no reveal transaction. v7 applies the client's pre-mainnet changes of 2026-11-22/23 to v6; see [docs/V7_CHANGES.md](docs/V7_CHANGES.md).

## Supply

**6,666 keys = 6,166 paid + 500 treasury** (`MAX_PUBLIC_SUPPLY = 6166`, `MAX_TREASURY_SUPPLY = 500`, `MAX_SUPPLY = 6666`). Token IDs run from **1 to 6666** (key #0042 is token 42) and are assigned in one sequence across paid and treasury mints. Civilian receives the paid supply remaining after Recruit; it has no fixed separate allocation.

The sale succeeds only when all 6,666 keys are minted: 6,166 paid **and** 500 treasury. `treasuryMint` checks only the treasury role, the deadline and the 500 cap, not the phase: mint the 500 treasury keys before Pioneer opens (they then take IDs 1–500).

## Phases

| Phase | Price per key (constructor = approved) | Wallet cap | Access |
| --- | ---: | ---: | --- |
| Pioneer | 0.0075 ETH | 4 | Pioneer; guaranteed; any quantity from 1 |
| Operative | 0.012 ETH | 4 | Pioneer + Operative; guaranteed. A Pioneer mints at most 4 across Pioneer and Operative together |
| Recruit | 0.0135 ETH | 10 | Pioneer + Operative + Recruit; FCFS |
| Civilian | 0.015 ETH | 20 | Public; FCFS |

The constructor sets the approved prices and caps. `configurePhase` works only while `currentPhase == 0`: from the moment Pioneer opens no role can change a price or a cap. Caps restart in every phase except that a Pioneer shares one cap across the two guaranteed phases, so each Pioneer is reserved once: the guaranteed reservation is `Pioneer count × Pioneer cap + Operative count × Operative cap` (6,012 with the 2026-11-23 lists: 100 × 4 + 1,403 × 4). Unused Pioneer guarantees stay reserved through Operative; both guaranteed reservations are released when Recruit opens. A Pioneer can mint 4 + 10 + 20 = 34 keys across the four phases. Phase selection is controlled by the contract: users cannot choose or revisit a phase.

## Roles

The admin role uses OpenZeppelin `AccessControlDefaultAdminRules` (delay 0): there is exactly one administrator, `grantRole`/`revokeRole` cannot move it, and it moves only in two steps (`beginDefaultAdminTransfer(new)`, then `acceptDefaultAdminTransfer()` signed by the new address). On mainnet admin and treasury are both the client's Safe.

## Outcome

- **Sellout (6,666 minted):** every key becomes a transferable NFT and reads the NFT metadata set at once; the treasury withdraws the whole balance with `withdraw` only after `mintEndTime`.
- **Deadline passes without sellout:** for 4 days (`CHOICE_WINDOW`) only each original minter decides, key by key, with `settle(keepIds, refundIds)`: a kept key becomes a transferable NFT and is never refundable; a refunded key is burned and its original payment returned. After the window undecided paid keys stay refundable forever, always to the original minter. The treasury withdraws only what kept keys paid (`withdrawKept`) and burns its own keys with `burnTreasuryKeys`.
- `burn(tokenId)` burns an unlocked key (after sellout, or a kept key) by its owner or an approved operator, for the future burn-to-redeem contract.

Lists come from three CSVs with one highest tier per address. The console downloads empty templates and builds a Merkle snapshot plus the checker data from exactly those files. Membership freezes when Pioneer starts. The client supplied the 2026-11-23 lists (100 Pioneer, 1,403 Operative, 5,705 Recruit; root `0x40c8b370…ac5f`), which the repository builder reproduces exactly.

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

The constructor takes five arguments: `endTime`, `sbtBaseURI`, `nftBaseURI`, `admin`, `treasury`. Both base URIs must end with `/`. The legacy vulnerable fixture is test-only. V7 requires a new deployment: previous contracts, holders and funds are not upgraded or migrated. The v6 test deployment on Sepolia is [`0xd069E170ECD211ca09157Afe6E9110E322BC30f8`](https://sepolia.etherscan.io/address/0xd069E170ECD211ca09157Afe6E9110E322BC30f8).

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

The operator console is a static application with wallet signing; it contains no private key or signing backend. It manages only v7 contracts.
