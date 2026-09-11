// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

contract RyodanKeysScript is Script {
    RyodanKeys public ryodanKeys;

    function setUp() public {}

    function run() public {
        // MINT_END_TIME must be a future unix timestamp; defaults to 30 days from now.
        uint256 mintEndTime = vm.envOr("MINT_END_TIME", block.timestamp + 30 days);

        vm.startBroadcast();
        ryodanKeys = new RyodanKeys(mintEndTime);
        console.log("RyodanKeys deployed at:", address(ryodanKeys));
        console.log("Mint end time:", mintEndTime);
        console.log("Refund end time:", ryodanKeys.refundEndTime());
        vm.stopBroadcast();
    }
}
