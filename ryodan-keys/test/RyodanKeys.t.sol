// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {console} from "forge-std/console.sol";

contract RyodanKeysTest is Test, AccessControl {
    RyodanKeys public ryodanKeys;
    address bob = makeAddr("bob");
    address alice = makeAddr("alice");

    function setUp() public {
        ryodanKeys = new RyodanKeys();
        ryodanKeys.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        ryodanKeys.grantRole(ryodanKeys.TREASURY_ROLE(), msg.sender);
    }

    function test_ownership() public view {
        assertEq(ryodanKeys.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), true);
        assertEq(
            ryodanKeys.hasRole(ryodanKeys.TREASURY_ROLE(), msg.sender),
            true
        );
    }

    function test_mint() public {
        ryodanKeys.setPublicMintActive(true);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        assertEq(ryodanKeys.originalMinter(0), bob);
    }

    function test_whitelist_mint() public {
        ryodanKeys.setWhitelistMintActive(true);
        address[] memory whitelist = new address[](1);
        whitelist[0] = bob;
        ryodanKeys.addToWhitelist(whitelist);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        assertEq(ryodanKeys.originalMinter(0), bob);
    }

    function test_whitelist_fail() public {
        ryodanKeys.setWhitelistMintActive(true);
        vm.expectRevert("Not whitelisted");
        vm.startPrank(alice);
        vm.deal(alice, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
    }

    function test_limit_fail() public {
        ryodanKeys.setPublicMintActive(true);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether * 101);
        ryodanKeys.mint{value: 0.01 ether * 20}(20);
        ryodanKeys.mint{value: 0.01 ether * 20}(20);
        ryodanKeys.mint{value: 0.01 ether * 20}(20);
        ryodanKeys.mint{value: 0.01 ether * 20}(20);
        ryodanKeys.mint{value: 0.01 ether * 20}(20);
        vm.expectRevert("Max mint amount reached");
        ryodanKeys.mint{value: 0.01 ether}(1);
    }

    function test_refund() public {
        ryodanKeys.setPublicMintActive(true);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        vm.warp(1767139201);
        vm.deal(bob, 0 ether);
        ryodanKeys.refund(0);
        assertEq(ryodanKeys.refunded(0), true);
        assertEq(bob.balance, 0.01 ether);
    }
}
