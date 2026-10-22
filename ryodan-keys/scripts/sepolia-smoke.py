#!/usr/bin/env python3
"""Checkpointed Sepolia mint/refund smoke tests. Inject PRIVATE_KEY with hush."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FOUNDRY = Path.home() / ".foundry/bin"
WALLET = "0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc"
PRICE = 10**16
HIDDEN = "data:application/json;base64," + base64.b64encode(json.dumps({
    "name": "Ryodan Key - Unrevealed (Sepolia)",
    "description": "Yomi/Ryodan testnet collection. Final metadata is not revealed.",
    "attributes": [{"trait_type": "State", "value": "Unrevealed"}]
}, separators=(",", ":")).encode()).decode()


def command(tool, *args):
    executable = shutil.which(tool) or str(FOUNDRY / tool)
    result = subprocess.run([executable, *map(str, args)], cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{tool} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["deploy", "refund", "verify"])
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--manifest", default="deployments/sepolia.json")
    parser.add_argument("--chain-id", type=int, choices=[11155111, 31337], default=11155111)
    args = parser.parse_args()
    path = ROOT / args.manifest
    path.parent.mkdir(parents=True, exist_ok=True)
    chain = int(command("cast", "chain-id", "--rpc-url", args.rpc))
    if chain != args.chain_id:
        raise RuntimeError(f"Wrong chain: expected {args.chain_id}, got {chain}")
    state = json.loads(path.read_text()) if path.exists() else {
        "chainId": chain, "deployer": WALLET, "contracts": {}, "transactions": {}, "checks": []
    }
    if state["chainId"] != chain or state["deployer"].lower() != WALLET.lower():
        raise RuntimeError("Manifest belongs to a different chain or wallet")

    def save():
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(path)

    def check(label, condition):
        if not condition:
            raise RuntimeError(f"Check failed: {label}")
        if label not in state["checks"]:
            state["checks"].append(label)
        save()
        print(f"PASS: {label}", flush=True)

    def call(address, signature, *values, **options):
        flags = ["--rpc-url", args.rpc]
        if options.get("sender"):
            flags += ["--from", options["sender"]]
        if options.get("value"):
            flags += ["--value", str(options["value"])]
        return command("cast", "call", address, signature, *values, *flags)

    def number(address, signature):
        return int(call(address, signature).split()[0])

    def expect_revert(label, address, signature, *values, **options):
        if label in state["checks"]:
            return
        try:
            call(address, signature, *values, **options)
        except RuntimeError as exc:
            reason = options.get("reason")
            check(label, "execution reverted" in str(exc) and (reason is None or reason in str(exc)))
        else:
            raise RuntimeError(f"Expected revert: {label}")

    def signer():
        key = os.environ.get("PRIVATE_KEY")
        if not key:
            raise RuntimeError("Inject PRIVATE_KEY using hush run")
        actual = command("cast", "wallet", "address", "--private-key", key)
        if actual.lower() != WALLET.lower():
            raise RuntimeError("Wrong deployer wallet")
        return ["--private-key", key]

    def transaction(label, address, signature, *values, value=0):
        if label in state["transactions"]:
            receipt = state["transactions"][label]
            if receipt.get("status") == "0x1":
                return
            receipt = json.loads(command("cast", "receipt", receipt["transactionHash"], "--rpc-url", args.rpc, "--json"))
        else:
            tx_hash = command("cast", "send", address, signature, *values,
                              "--rpc-url", args.rpc, *signer(), "--value", value, "--async")
            state["transactions"][label] = {"transactionHash": tx_hash}
            save()
            print(f"SUBMITTED: {label}: {tx_hash}", flush=True)
            receipt = json.loads(command("cast", "receipt", tx_hash, "--rpc-url", args.rpc, "--json", "--confirmations", "2"))
        state["transactions"][label] = receipt
        save()
        check(label, receipt["status"] == "0x1")

    def verify_bytecode(label):
        entry = state["contracts"][label]
        artifact = json.loads((ROOT / "out/RyodanKeys.sol/RyodanKeys.json").read_text())
        bytecode = artifact["deployedBytecode"]
        expected = bytearray.fromhex(bytecode["object"].removeprefix("0x"))
        for references in bytecode["immutableReferences"].values():
            for reference in references:
                start, size = reference["start"], reference["length"]
                expected[start:start + size] = entry["mintEndTime"].to_bytes(size, "big")
        actual = bytes.fromhex(command("cast", "code", entry["address"], "--rpc-url", args.rpc).removeprefix("0x"))
        check(f"{label}: exact runtime bytecode including immutable deadline", actual == expected)
        entry["runtimeCodeHash"] = command("cast", "keccak", "0x" + actual.hex())
        check(f"{label}: deadline", number(entry["address"], "mintEndTime()(uint256)") == entry["mintEndTime"])
        check(f"{label}: admin", call(entry["address"], "hasRole(bytes32,address)(bool)", "0x" + "00" * 32, WALLET) == "true")
        role = call(entry["address"], "TREASURY_ROLE()(bytes32)")
        check(f"{label}: treasury", call(entry["address"], "hasRole(bytes32,address)(bool)", role, WALLET) == "true")
        save()

    if args.stage == "deploy":
        command("forge", "build", "--skip", "test", "--skip", "script")
        for label, duration in [("mint", 30 * 86400), ("refund", 600)]:
            if label not in state["contracts"]:
                latest = json.loads(command("cast", "block", "latest", "--rpc-url", args.rpc, "--json"))
                deadline = int(latest["timestamp"], 16) + duration
                deployed = json.loads(command("forge", "create", "src/RyodanKeys.sol:RyodanKeys", "--rpc-url", args.rpc,
                                              *signer(), "--broadcast", "--json", "--constructor-args",
                                              deadline, HIDDEN, WALLET, WALLET))
                state["contracts"][label] = {
                    "address": deployed["deployedTo"], "deploymentTransaction": deployed["transactionHash"],
                    "mintEndTime": deadline, "hiddenMetadataURI": HIDDEN, "purpose": label
                }
                save()
                print(f"DEPLOYED: {label}: {deployed['deployedTo']}", flush=True)
            verify_bytecode(label)
            address = state["contracts"][label]["address"]
            if label == "mint":
                transaction("mint: whitelist self", address, "addToWhitelist(address[])", f"[{WALLET}]")
                transaction("mint: enable whitelist", address, "setWhitelistMintActive(bool,uint256)", "true", 3)
                transaction("mint: whitelist purchase", address, "mint(uint256)", 1, value=PRICE)
                transaction("mint: enable public", address, "setPublicMintActive(bool,uint256)", "true", 3)
                transaction("mint: public purchase", address, "mint(uint256)", 1, value=PRICE)
                check("mint: two paid tokens", number(address, "mintedByUsers()(uint256)") == 2)
                check("mint: whitelist counter", number(address, "mintedByWhitelist()(uint256)") == 1)
                check("mint: phases exclusive", call(address, "isWhitelistMintActive()(bool)") == "false")
                check("mint: original minter", call(address, "originalMinter(uint256)(address)", 0).lower() == WALLET.lower())
                expect_revert("mint: underpayment rejected", address, "mint(uint256)", 1, sender=WALLET, reason="Incorrect payment")
                expect_revert("mint: overpayment rejected", address, "mint(uint256)", 1, sender=WALLET, value=PRICE + 1, reason="Incorrect payment")
                expect_revert("mint: wallet cap enforced", address, "mint(uint256)", 2, sender=WALLET, value=PRICE * 2, reason="Max mint amount reached")
                expect_revert("mint: transfer locked", address, "transferFrom(address,address,uint256)", WALLET,
                              "0x000000000000000000000000000000000000dEaD", 0, sender=WALLET, reason="not transferable")
                expect_revert("mint: treasury withdrawal blocked", address, "withdraw()", sender=WALLET, reason="Not all tokens minted")
                expect_revert("mint: early refund blocked", address, "refund(uint256)", 0, sender=WALLET, reason="Mint not ended")
                expect_revert("mint: early reveal blocked", address, "reveal(string)", "ipfs://test/", sender=WALLET, reason="Not all tokens minted")
                transaction("mint: treasury token", address, "treasuryMint(uint256,address)", 1, WALLET)
                check("mint: hidden JSON URI", json.loads(call(address, "tokenURI(uint256)(string)", 0)) == HIDDEN)
            else:
                transaction("refund: enable public", address, "setPublicMintActive(bool,uint256)", "true", 2)
                transaction("refund: paid purchase", address, "mint(uint256)", 2, value=PRICE * 2)
                transaction("refund: treasury token", address, "treasuryMint(uint256,address)", 1, WALLET)
        print("Deploy smoke complete. Run the refund stage after its on-chain deadline.", flush=True)

    elif args.stage == "refund":
        entry = state["contracts"]["refund"]
        address = entry["address"]
        if call(address, "refundsAvailable()(bool)") != "true":
            raise RuntimeError(f"Refund not available yet; on-chain deadline is {entry['mintEndTime']}")
        expect_revert("refund: nonexistent ID rejected", address, "refund(uint256)", 999999, sender=WALLET,
                      reason="Token not eligible for refund")
        expect_revert("refund: treasury ID rejected", address, "refund(uint256)", 2, sender=WALLET,
                      reason="Token not eligible for refund")
        expect_revert("refund: third party rejected", address, "refund(uint256)", 0,
                      sender="0x000000000000000000000000000000000000dEaD", reason="Not original minter")
        transaction("refund: first legitimate refund", address, "refund(uint256)", 0)
        expect_revert("refund: double refund rejected", address, "refund(uint256)", 0, sender=WALLET,
                      reason="Already refunded")
        transaction("refund: second legitimate refund", address, "refundTo(uint256,address)", 1, WALLET)
        check("refund: both paid tokens refunded", number(address, "totalRefunded()(uint256)") == 2)
        check("refund: treasury token survives", number(address, "totalSupply()(uint256)") == 1)
        check("refund: reserves returned", int(command("cast", "balance", address, "--rpc-url", args.rpc)) == 0)
        expect_revert("refund: first NFT burned", address, "ownerOf(uint256)", 0)
        expect_revert("refund: expired mint rejected", address, "mint(uint256)", 1, sender=WALLET, value=PRICE, reason="Mint ended")
        check("refund: no third-party treasury refund", call(address, "refunded(uint256)(bool)", 2) == "false")

    else:
        for label in state["contracts"]:
            verify_bytecode(label)
        for label, receipt in state["transactions"].items():
            actual = json.loads(command("cast", "receipt", receipt["transactionHash"], "--rpc-url", args.rpc, "--json"))
            check(f"receipt: {label}", actual["status"] == "0x1" and actual["blockHash"] == receipt["blockHash"])
        state["lastVerifiedBlock"] = int(command("cast", "block-number", "--rpc-url", args.rpc))
        save()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
