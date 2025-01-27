// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MaveGenesis} from "../src/MaveGenesis.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
contract MaveGenesisTest is Test, AccessControl {
    MaveGenesis public maveGenesis;

    function setUp() public {
        maveGenesis = new MaveGenesis();
        maveGenesis.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function test_Ownership() public view {
        assertEq(maveGenesis.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), true);
    }
}
