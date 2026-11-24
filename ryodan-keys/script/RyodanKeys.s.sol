// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

import {DeploymentMetadata} from "./DeploymentMetadata.sol";

contract RyodanKeysScript is Script, DeploymentMetadata {
    function run() public returns (RyodanKeys keys) {
        require(block.chainid == 11155111 || block.chainid == 31337, "Use Ethereum Sepolia or local Anvil");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        uint256 deadline = vm.envUint("MINT_END_TIME");
        require(keccak256(bytes(vm.envOr("SBT_BASE_URI", SBT))) == keccak256(bytes(SBT)), "Wrong SBT folder");
        require(keccak256(bytes(vm.envOr("NFT_BASE_URI", NFT))) == keccak256(bytes(NFT)), "Wrong NFT folder");
        vm.startBroadcast(deployer);
        keys = new RyodanKeys(deadline, SBT, NFT, admin, treasury);
        vm.stopBroadcast();
        console.log("RyodanKeys:", address(keys));
        console.log("Admin:", admin);
        console.log("Treasury:", treasury);
        console.log("Mint end:", deadline);
    }
}
