// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

contract RyodanKeysScript is Script {
    RyodanKeys public ryodanKeys;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        ryodanKeys = new RyodanKeys();
        ryodanKeys.grantRole(ryodanKeys.DEFAULT_ADMIN_ROLE(), msg.sender);
        ryodanKeys.grantRole(ryodanKeys.TREASURY_ROLE(), msg.sender);
        console.log("RyodanKeys deployed at:", address(ryodanKeys));
        vm.stopBroadcast();
    }
}
