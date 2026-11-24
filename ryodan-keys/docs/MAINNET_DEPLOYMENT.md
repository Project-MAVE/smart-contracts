# Ethereum mainnet deployment of Ryodan Keys v8

Run the commands from `ryodan-keys/` with Foundry, the pinned submodules and an Ethereum mainnet RPC. The mainnet profile pins the compiler remappings to reproduce the rehearsed v8 runtime hash. The deadline is 25 November 2026 at 18:00 UTC.

The initial deployment uses nonce zero of `0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc`. The constructor takes the following metadata folders.

- SBT: `ipfs://bafybeigrmc5l5dy7lwnr3xvn7nkzpsqmmoxpvs7rpialaud6abt7sueu6m/sbt/`
- NFT: `ipfs://bafybeigrmc5l5dy7lwnr3xvn7nkzpsqmmoxpvs7rpialaud6abt7sueu6m/nft/`

## Simulate

```sh
export FOUNDRY_PROFILE=mainnet
forge script script/DeployMainnetV8.s.sol --rpc-url "$ETH_RPC_URL"
```

Inspect the twelve simulated transactions under `broadcast/DeployMainnetV8.s.sol/1/dry-run/`. They deploy v8, load the final allowlist (105 Pioneer, 1,455 Operative and 5,699 Recruit), mint 666 keys to the client Safe in seven batches, grant the treasury role to the Safe, renounce the deployer's treasury role and request transfer of the admin role. The sale stays in phase 0.

## Broadcast and verify

For an authorized launch, run the same command with `--broadcast --slow` and the signing option for the dedicated deployer. Preserve the Foundry broadcast receipts. If interrupted, reconcile the confirmed nonces and receipts and resume the same broadcast with `--resume`.

Read back the runtime hash, both metadata folders, allowlist, treasury, roles and sale state before the Safe accepts the admin role.

```sh
forge script script/DeployMainnetV8.s.sol --sig 'verify(bool)' false --rpc-url "$ETH_RPC_URL"
```

Two owners of the client Safe `0x31Cd849c982ED10a94A66b4FD7867e97656952Eb` authorize acceptance in the Safe. After acceptance, repeat the verification with `true` while the sale is still in phase 0. Opening Pioneer is a separate Safe action.
