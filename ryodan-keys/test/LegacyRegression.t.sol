// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LegacyRyodanKeys} from "./fixtures/LegacyRyodanKeys.sol";

contract LegacyRegressionTest is Test {
    LegacyRyodanKeys internal keys;
    address internal buyer = makeAddr("buyer");
    address internal attacker = makeAddr("attacker");
    uint256 internal constant END = 1767139200;

    function setUp() public {
        vm.warp(END - 1 days);
        keys = new LegacyRyodanKeys();
        keys.setPublicMintActive(true, 10);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        keys.mint{value: 0.02 ether}(2);
    }

    function test_LegacyNonexistentIdsDestroyAllRefundReserves() public {
        vm.warp(END + 1);
        uint256 zeroBalance = address(0).balance;
        vm.startPrank(attacker);
        keys.refund(100_000);
        keys.refund(type(uint256).max);
        vm.stopPrank();
        assertEq(address(keys).balance, 0);
        assertEq(address(0).balance - zeroBalance, 0.02 ether);
        vm.prank(buyer);
        vm.expectRevert("Failed to send Ether");
        keys.refund(0);
        assertFalse(keys.refunded(0));
    }

    function test_LegacyFreeTreasuryTokenDestroysPaidRefundReserve() public {
        keys.treasuryMint(1, attacker);
        vm.warp(END + 1);
        uint256 zeroBalance = address(0).balance;
        vm.prank(attacker);
        keys.refund(2);
        assertEq(address(0).balance - zeroBalance, 0.01 ether);
        assertEq(address(keys).balance, 0.01 ether);
    }

    function test_LegacySameTokenCannotBeRefundedTwice() public {
        vm.warp(END + 1);
        vm.startPrank(buyer);
        keys.refund(0);
        vm.expectRevert("Already refunded");
        keys.refund(0);
        vm.stopPrank();
    }

    function test_LegacyDifferentPaidTokensEachHaveOneLegitimateRefund() public {
        vm.warp(END + 1);
        uint256 balanceBefore = buyer.balance;
        vm.startPrank(buyer);
        keys.refund(0);
        keys.refund(1);
        vm.stopPrank();
        assertEq(buyer.balance - balanceBefore, 0.02 ether);
    }

    function test_LegacyExpiredDeadlinePreventsRestart() public {
        vm.warp(END + 1);
        vm.prank(buyer);
        vm.expectRevert("Mint ended");
        keys.mint{value: 0.01 ether}(1);
    }

    function test_LegacyMetadataAcceptsUnmintedIdAndIgnoresTokenId() public view {
        assertEq(keys.tokenURI(0), keys.tokenURI(type(uint256).max));
        assertEq(keys.tokenURI(0), "ipfs://QmZ/soulbound/");
    }

    function test_LegacyZeroMintAndOverpaymentAreAccepted() public {
        vm.startPrank(buyer);
        keys.mint{value: 0.1 ether}(0);
        keys.mint{value: 0.02 ether}(1);
        vm.stopPrank();
        assertEq(keys.totalSupply(), 3);
        assertEq(address(keys).balance, 0.14 ether);
    }
}
