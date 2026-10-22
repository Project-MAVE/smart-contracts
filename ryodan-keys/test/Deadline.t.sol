// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture, CallbackWallet} from "./RyodanKeys.t.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract DeadlineTest is RyodanKeysFixture {
    function test_DeadlineCanExtendAndShortenWithEvents() public {
        vm.expectEmit(false, false, false, true);
        emit RyodanKeys.MintEndTimeUpdated(end, end + 1 days);
        keys.setMintEndTime(end + 1 days);
        assertEq(keys.mintEndTime(), end + 1 days);
        keys.setMintEndTime(end - 1 days);
        assertEq(keys.mintEndTime(), end - 1 days);
    }

    function test_DeadlineCanChangeAtExactOldBoundary() public {
        vm.warp(end);
        keys.setMintEndTime(end + 1);
        assertFalse(keys.refundsAvailable());
    }

    function test_DeadlineRejectsCurrentAndPastTime() public {
        vm.expectRevert("Deadline must be in the future");
        keys.setMintEndTime(block.timestamp);
        vm.expectRevert("Deadline must be in the future");
        keys.setMintEndTime(block.timestamp - 1);
        assertEq(keys.mintEndTime(), end);
    }

    function test_DeadlineCannotReopenExpiredSaleBeforeFirstRefund() public {
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.expectRevert("Mint ended");
        keys.setMintEndTime(end + 1 days);
        assertTrue(keys.refundsAvailable());
        vm.prank(bob);
        keys.refund(0);
        assertEq(bob.balance, keys.mintPrice());
    }

    function test_DeadlineCannotReopenAfterRefund() public {
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.prank(bob);
        keys.refund(0);
        vm.expectRevert("Mint ended");
        keys.setMintEndTime(end + 1 days);
        assertEq(keys.mintEndTime(), end);
        assertEq(keys.totalRefunded(), 1);
    }

    function test_DeadlineCannotChangeAfterSoldOut() public {
        _sellOut();
        vm.expectRevert("All tokens minted");
        keys.setMintEndTime(end + 1 days);
        assertEq(keys.mintEndTime(), end);
    }

    function test_AdminReceiverCannotChangeDeadlineDuringMint() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        keys.grantRole(keys.DEFAULT_ADMIN_ROLE(), address(wallet));
        wallet.configure(abi.encodeCall(keys.setMintEndTime, (end + 1 days)), false, false);
        _open(1);
        wallet.buy{value: keys.mintPrice()}(1);
        assertTrue(wallet.attempted());
        assertFalse(wallet.reentered());
        assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(keys.mintEndTime(), end);
        assertEq(keys.totalSupply(), 1);
    }

    function testFuzz_OnlyAdminCanChangeDeadline(address caller, uint256 futureOffset) public {
        vm.assume(caller != address(this));
        uint256 nextEnd = block.timestamp + bound(futureOffset, 1, 365 days);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
        vm.prank(caller);
        keys.setMintEndTime(nextEnd);
        assertEq(keys.mintEndTime(), end);
    }

    function testFuzz_MintAndRefundFollowChangedDeadline(uint256 offset) public {
        uint256 nextEnd = block.timestamp + bound(offset, 1, 365 days);
        keys.setMintEndTime(nextEnd);
        _open(2);
        vm.warp(nextEnd);
        _buy(bob, 1);
        assertFalse(keys.refundsAvailable());
        vm.warp(nextEnd + 1);
        assertTrue(keys.refundsAvailable());
        uint256 price = keys.mintPrice();
        vm.expectRevert("Mint ended");
        keys.mint{value: price}(1);
        vm.expectRevert("Mint ended");
        keys.setMintEndTime(nextEnd + 2);
        vm.prank(bob);
        keys.refund(0);
        assertEq(keys.totalSupply(), 0);
    }
}
