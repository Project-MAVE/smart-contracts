// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MaveGenesis} from "../src/MaveGenesis.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract MaveGenesisScript is Script, AccessControl {
    MaveGenesis public maveGenesis;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        maveGenesis = new MaveGenesis();
        maveGenesis.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        console.log("MaveGenesis deployed at:", address(maveGenesis));
        vm.stopBroadcast();
    }
}
