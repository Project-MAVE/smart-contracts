// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

import {DeploymentMetadata} from "./DeploymentMetadata.sol";

interface IClientSafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// Ethereum launch using the approved November 24 snapshot and the dedicated nonce-zero deployer.
contract DeployMainnetV8 is Script, DeploymentMetadata {
    address internal constant DEPLOYER = 0x51c88C4Ca390C7509aD250D0F6B52c10F4cE39bc;
    address internal constant SAFE = 0x31Cd849c982ED10a94A66b4FD7867e97656952Eb;
    uint256 internal constant END_TIME = 1795629600;
    bytes32 internal constant ROOT = 0x2a19f9ca68d2a0630ce1ebd9842e9e359d31054a708cd4aabc2d411a72bb51b4;
    bytes32 internal constant SNAPSHOT = 0xa49a0a4717ed59a01c4b2a53fd1b1e4d2ec33e0480b6a03fd83261bb42b44bed;
    bytes32 internal constant RUNTIME = 0x4209a41e6a9039ed969a8bf3ed358c4e3cc6292406acc0646f90f78544fd5478;

    function run() public returns (RyodanKeys keys) {
        require(block.chainid == 1, "Ethereum mainnet only");
        require(block.timestamp < END_TIME, "Sale deadline passed");
        require(vm.getNonce(DEPLOYER) == 0 && DEPLOYER.code.length == 0, "Use the original broadcast to resume");
        require(
            IClientSafe(SAFE).getThreshold() == 2 && IClientSafe(SAFE).getOwners().length == 3, "Expected 2-of-3 Safe"
        );

        vm.startBroadcast(DEPLOYER);
        keys = new RyodanKeys(END_TIME, SBT, NFT, DEPLOYER, DEPLOYER);
        require(address(keys) == vm.computeCreateAddress(DEPLOYER, 0), "Unexpected deployment address");
        require(address(keys).codehash == RUNTIME, "Unexpected v8 runtime");
        keys.configureAllowlist(ROOT, SNAPSHOT, 105, 1455, 5699);
        for (uint256 minted = 0; minted < 666; minted += 100) {
            keys.treasuryMint(minted == 600 ? 66 : 100, SAFE);
        }
        bytes32 treasury = keys.TREASURY_ROLE();
        keys.grantRole(treasury, SAFE);
        keys.renounceRole(treasury, DEPLOYER);
        keys.beginDefaultAdminTransfer(SAFE);
        vm.stopBroadcast();

        verify(false);
        console.log("Ryodan Keys v8, awaiting Safe acceptance:", address(keys));
    }

    /// Read-only checks before opening, first after the deploy and again after the two Safe signatures.
    function verify(bool accepted) public view {
        require(block.chainid == 1, "Ethereum mainnet only");
        RyodanKeys keys = RyodanKeys(vm.computeCreateAddress(DEPLOYER, 0));
        require(address(keys).codehash == RUNTIME && keys.CONTRACT_VERSION() == 8, "Unexpected v8 runtime");
        require(keys.mintEndTime() == END_TIME, "Wrong deadline");
        require(keccak256(bytes(keys.sbtBaseURI())) == keccak256(bytes(SBT)), "Wrong SBT folder");
        require(keccak256(bytes(keys.nftBaseURI())) == keccak256(bytes(NFT)), "Wrong NFT folder");
        require(keys.allowlistRoot() == ROOT && keys.allowlistSnapshotHash() == SNAPSHOT, "Wrong snapshot");
        require(
            keys.tierMembers(1) == 105 && keys.tierMembers(2) == 1455 && keys.tierMembers(3) == 5699, "Wrong counts"
        );
        require(keys.currentPhase() == 0 && keys.mintPaused() && keys.totalGtdReserved() == 6000, "Wrong sale state");
        require(
            keys.mintedByUsers() == 0 && keys.mintedByTreasury() == 666 && keys.balanceOf(SAFE) == 666, "Wrong mints"
        );
        bytes32 treasury = keys.TREASURY_ROLE();
        require(keys.hasRole(treasury, SAFE) && !keys.hasRole(treasury, DEPLOYER), "Wrong treasury role");
        (address pending,) = keys.pendingDefaultAdmin();
        require(keys.defaultAdmin() == (accepted ? SAFE : DEPLOYER), "Wrong admin");
        require(pending == (accepted ? address(0) : SAFE), "Wrong pending admin");
    }
}
