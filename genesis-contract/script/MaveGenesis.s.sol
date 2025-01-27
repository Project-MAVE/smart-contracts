// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MaveGenesis} from "../src/MaveGenesis.sol";

contract MaveGenesisScript is Script {
    MaveGenesis public maveGenesis;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        maveGenesis = new MaveGenesis();
        console.log("MaveGenesis deployed at:", address(maveGenesis));
        vm.stopBroadcast();
    }
}
