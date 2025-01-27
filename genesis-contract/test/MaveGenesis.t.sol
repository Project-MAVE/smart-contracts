// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MaveGenesis} from "../src/MaveGenesis.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {console} from "forge-std/console.sol";

contract MaveGenesisTest is Test, AccessControl {
    MaveGenesis public maveGenesis;
    address bob = makeAddr("bob");

    function setUp() public {
        maveGenesis = new MaveGenesis();
        maveGenesis.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        maveGenesis.grantRole(maveGenesis.TREASURY_ROLE(), msg.sender);
    }

    function test_Ownership() public view {
        assertEq(maveGenesis.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), true);
        assertEq(maveGenesis.hasRole(maveGenesis.TREASURY_ROLE(), msg.sender), true);
    }

    function test_mint() public {
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        vm.warp(1735689600);
        maveGenesis.mint{value: 0.01 ether}(1);
        assertEq(maveGenesis.originalMinter(0), bob);
    }

    function test_refund() public {
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        vm.warp(1735689600);
        maveGenesis.mint{value: 0.01 ether}(1);
        vm.warp(1767139201);
        maveGenesis.refund(0);
        assertEq(maveGenesis.refunded(0), true);
    }

    function test_full_mint() public {
        vm.startPrank(bob);
        vm.deal(bob, 10000 * 0.01 ether);
        vm.warp(1735689600);
        for (uint256 i = 0; i < 9999; i++) {
            maveGenesis.mint{value: 0.01 ether}(1);
        }
        assertEq(maveGenesis.totalSupply(), 9999);
        vm.expectRevert("Max supply reached");
        maveGenesis.mint{value: 0.01 ether}(1);
        vm.warp(1767139201);
        vm.expectRevert("All tokens minted");
        maveGenesis.refund(0);
    }
}
