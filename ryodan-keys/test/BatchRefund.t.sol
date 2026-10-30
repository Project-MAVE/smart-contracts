// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture, CallbackWallet} from "./RyodanKeys.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BatchRefundTest is RyodanKeysFixture {
    function ids(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    function test_ThirdPartyBatchPaysDifferentMintersTheirOriginalPrices() public {
        _open(10);
        _buy(bob, 1);
        keys.configurePhase(4, 0.045 ether, 10);
        _buy(alice, 1);
        vm.warp(end + 1);
        uint256 bobBefore = bob.balance;
        uint256 aliceBefore = alice.balance;
        vm.prank(treasury);
        keys.refundBatch(ids(1, 0));
        assertEq(bob.balance - bobBefore, 0.01 ether);
        assertEq(alice.balance - aliceBefore, 0.045 ether);
        assertEq(treasury.balance, 0);
        assertEq(keys.totalRefunded(), 2);
        assertEq(address(keys).balance, 0);
    }

    function test_DuplicateAndInvalidIdsRollBackWholeBatch() public {
        _open(2);
        _buy(bob, 2);
        vm.warp(end + 1);
        vm.expectRevert("Already refunded");
        keys.refundBatch(ids(0, 0));
        vm.expectRevert("Token not eligible for refund");
        keys.refundBatch(ids(0, 999));
        assertEq(keys.totalRefunded(), 0);
        assertEq(keys.totalSupply(), 2);
        assertEq(bob.balance, 0);
        assertEq(address(keys).balance, 0.02 ether);
        keys.refundBatch(ids(0, 1));
        vm.expectRevert("Already refunded");
        keys.refundBatch(ids(0, 1));
    }

    function test_RejectingRecipientRollsBackOtherRefundsAndCanRecoverSeparately() public {
        _open(2);
        _buy(bob, 1);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.01 ether}(1);
        wallet.configure("", true, false);
        vm.warp(end + 1);
        vm.expectRevert("Failed to send Ether");
        keys.refundBatch(ids(0, 1));
        assertEq(keys.totalRefunded(), 0);
        assertEq(bob.balance, 0);
        assertEq(keys.ownerOf(0), bob);
        wallet.claimTo(1, payable(alice));
        keys.refund(0);
        assertEq(alice.balance, 0.01 ether);
        assertEq(bob.balance, 0.01 ether);
        assertEq(address(keys).balance, 0);
    }

    function test_BatchCallbackCannotReenterAnotherBatchOrSingleRefund() public {
        _open(3);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.03 ether}(3);
        wallet.configure(abi.encodeCall(keys.refundBatch, (ids(1, 2))), false, false);
        vm.warp(end + 1);
        keys.refundBatch(ids(0, 1));
        assertFalse(wallet.reentered());
        assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(keys.refunded(2));
        assertEq(keys.totalRefunded(), 2);
        assertEq(address(wallet).balance, 0.02 ether);
        keys.refund(2);
        assertEq(address(wallet).balance, 0.03 ether);
    }

    function test_BatchSizeAndOutcomeGuards() public {
        vm.expectRevert("Invalid refund batch size");
        keys.refundBatch(new uint256[](0));
        vm.expectRevert("Invalid refund batch size");
        keys.refundBatch(new uint256[](51));
        _open(2);
        _buy(bob, 2);
        vm.expectRevert("Mint not ended");
        keys.refundBatch(ids(0, 1));
        keys.configurePhase(4, 0.01 ether, 6166);
        _buy(bob, 6164);
        vm.prank(treasury);
        keys.treasuryMint(500, treasury);
        vm.warp(end + 1);
        vm.expectRevert("All tokens minted");
        keys.refundBatch(ids(0, 1));
    }

    function testFuzz_ArbitraryCallerBatchIsSolventAndSingleUse(uint256 countSeed, uint256 rotationSeed, address caller)
        public
    {
        uint256 count = bound(countSeed, 1, 50);
        _open(count);
        _buy(bob, count);
        vm.warp(end + 1);
        uint256[] memory list = new uint256[](count);
        for (uint256 i; i < count; i++) {
            list[i] = (i + rotationSeed % count) % count;
        }
        uint256 beforeBalance = bob.balance;
        vm.prank(caller);
        keys.refundBatch(list);
        assertEq(bob.balance - beforeBalance, count * 0.01 ether);
        assertEq(keys.totalRefunded(), count);
        assertEq(address(keys).balance, 0);
        vm.expectRevert("Already refunded");
        keys.refundBatch(list);
    }
}
