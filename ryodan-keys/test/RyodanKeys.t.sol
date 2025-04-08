// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {console} from "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RyodanKeysTest is Test, AccessControl {
    RyodanKeys public ryodanKeys;
    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address treasury = makeAddr("treasury");

    function setUp() public {
        ryodanKeys = new RyodanKeys();
        ryodanKeys.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        ryodanKeys.grantRole(ryodanKeys.TREASURY_ROLE(), treasury);
    }

    function test_ownership() public view {
        assertEq(ryodanKeys.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), true);
        assertEq(
            ryodanKeys.hasRole(ryodanKeys.TREASURY_ROLE(), treasury),
            true
        );
    }

    function test_mint() public {
        ryodanKeys.setPublicMintActive(true, 20);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        assertEq(ryodanKeys.originalMinter(0), bob);
    }

    function test_whitelist_mint() public {
        ryodanKeys.setWhitelistMintActive(true, 10);
        address[] memory whitelist = new address[](1);
        whitelist[0] = bob;
        ryodanKeys.addToWhitelist(whitelist);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        assertEq(ryodanKeys.originalMinter(0), bob);
    }

    function test_whitelist_fail() public {
        ryodanKeys.setWhitelistMintActive(true, 10);
        vm.expectRevert("Not whitelisted");
        vm.startPrank(alice);
        vm.deal(alice, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
    }

    function test_whitelist_fail_limit() public {
        ryodanKeys.setWhitelistMintActive(true, 2000);
        address[] memory whitelist = new address[](1);
        whitelist[0] = bob;
        ryodanKeys.addToWhitelist(whitelist);
        vm.startPrank(bob);
        vm.deal(bob, 101 ether);
        ryodanKeys.mint{value: 100 ether}(1000);
        vm.expectRevert("Max whitelist mint amount reached");
        ryodanKeys.mint{value: 0.01 ether}(1);
    }

    function test_limit_fail() public {
        ryodanKeys.setPublicMintActive(true, 20);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether * 101);
        ryodanKeys.mint{value: 0.01 ether * 20}(20);
        vm.expectRevert("Max mint amount reached for address");
        ryodanKeys.mint{value: 0.01 ether}(1);
    }

    function test_refund() public {
        ryodanKeys.setPublicMintActive(true, 20);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        vm.warp(1767139201);
        vm.deal(bob, 0 ether);
        ryodanKeys.refund(0);
        assertEq(ryodanKeys.refunded(0), true);
        assertEq(bob.balance, 0.01 ether);
    }

    function test_soldout() public {
        ryodanKeys.setPublicMintActive(true, 20);
        // Mint 500 to treasury
        ryodanKeys.treasuryMint(500, bob);
        // Test fail overminting to treasury
        vm.expectRevert("Max supply reached while minting to treasury");
        ryodanKeys.treasuryMint(1, alice);
        // Mint 5900 to users
        for (uint256 i = 0; i < 5900; i++) {
            address user = makeAddr(
                string(abi.encodePacked("user", Strings.toString(i)))
            );
            vm.startPrank(user);
            vm.deal(user, 0.01 ether);
            ryodanKeys.mint{value: 0.01 ether}(1);
        }
        // Test fail overminting to user
        vm.expectRevert("Max supply reached");
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        // Test withdraw
        vm.startPrank(treasury);
        ryodanKeys.withdraw();
        assertEq(treasury.balance, 59 ether);
        // Test transfer after minting is over
        vm.startPrank(bob);
        ryodanKeys.transferFrom(bob, alice, 0);
        assertEq(ryodanKeys.ownerOf(0), alice);
    }

    function test_transfer() public {
        ryodanKeys.setPublicMintActive(true, 20);
        vm.startPrank(bob);
        vm.deal(bob, 0.01 ether);
        ryodanKeys.mint{value: 0.01 ether}(1);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        ryodanKeys.transferFrom(bob, alice, 0);
    }
}
