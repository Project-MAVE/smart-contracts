# Ryodan Keys

ERC-721 sale with whitelist/public minting, a free treasury allocation, transfers locked until sellout, refunds on unsuccessful expiry, and one-shot metadata reveal.

- 5,900 paid NFTs at 0.01 ETH, including at most 1,000 whitelist mints.
- 500 free treasury NFTs; all 6,400 must mint for the campaign to succeed.
- Constructor parameters: future `endTime`, `hiddenURI`, `admin`, `treasury`.
- v2 admin can shorten/extend the deadline using `setMintEndTime`; expiry and sellout permanently lock it.
- A failed sale refunds the original paid minter once per token and burns that token.
- A successful sale allows treasury withdrawal and NFT transfers. Admin can then reveal `<baseURI><id>.json` once.

## Development

Initialize pinned Solidity dependencies from the repository root:

```sh
git submodule update --init --recursive
cd ryodan-keys
forge build --sizes
forge fmt --check
forge test
FOUNDRY_PROFILE=ci forge test
python3 scripts/export-abi.py --check
```

Compiler: Solidity **0.8.37**; EVM: **Cancun**; optimizer: **200 runs**. Dependencies: OpenZeppelin Contracts **5.7.0**, forge-std **1.16.2**. Foundry **1.7.1** was used for validation and is pinned in the prepared CI workflow. Solidity development needs no npm installation; the optional `../console/` UI has its own pinned JavaScript dependencies.

The suite contains 78 tests/properties: deterministic scenarios, legacy exploit reproductions, nine fuzz tests, four stateful invariants and four deployment-script tests. v2 coverage reaches 100% of lines, branches and functions in the contract and deployment script, excluding generated getters and dependencies. `test/fixtures/LegacyRyodanKeys.sol` is vulnerable historical source for tests only; never deploy it.

Slither:

```sh
python3 -m venv /tmp/ryodan-slither
/tmp/ryodan-slither/bin/pip install --only-binary=:all: slither-analyzer==0.11.6
VIRTUAL_ENV=/tmp/ryodan-slither /tmp/ryodan-slither/bin/slither . --config-file slither.config.json
```

Keep `forge` on `PATH`. The Slither configuration gates medium/high findings. Read the security review for the one scoped false-positive annotation and accepted low/informational findings. Slither may rebuild artifacts; run ABI export again after intentional contract changes.

## Documentation

- [Live management console](https://ryodan.grooooog.space) and [operator guide](docs/MANAGEMENT_CONSOLE.md)
- [Security findings, regression evidence and retained risks](docs/SECURITY_REVIEW.md)
- [Frontend mint/refund integration handoff](docs/FRONTEND_INTEGRATION.md)
- [Metadata preparation and reveal procedure](docs/METADATA_AND_REVEAL.md)
- [Sepolia deployments and operations](docs/SEPOLIA_RUNBOOK.md)
- [Frontend ABI](abi/RyodanKeys.json)
- [Current v2 Sepolia deployment receipts](deployments/sepolia-v2.json)
- [v2 shortened-deadline refund QA](deployments/sepolia-v2-refund.json)
- [Archived v1 Sepolia evidence](deployments/sepolia.json)

The old contract is not upgradeable. These changes require a new deployment and frontend address/ABI update; no existing holders or funds are migrated automatically.
