// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MaveGenesis} from "../src/MaveGenesis.sol";

contract MaveGenesisTest is Test {
    MaveGenesis public maveGenesis;

    function setUp() public {
        maveGenesis = new MaveGenesis();
    }

    function test_Increment() public {
        maveGenesis.increment();
        assertEq(maveGenesis.number(), 1);
    }

    function testFuzz_SetNumber(uint256 x) public {
        maveGenesis.setNumber(x);
        assertEq(maveGenesis.number(), x);
    }
}
