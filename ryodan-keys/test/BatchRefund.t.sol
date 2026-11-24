// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture, CallbackWallet} from "./RyodanKeys.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

/// Re-enters from receive() without writing storage, so the attempt fits inside the batch gas cap.
/// It accepts the ETH only if both re-entries are rejected by the reentrancy guard.
contract BatchReentryWallet is IERC721Receiver {
    event ReentryBlocked(bytes4 batchError, bytes4 singleError);

    RyodanKeys public immutable keys;
    bool public armed = true;

    constructor(RyodanKeys keys_) {
        keys = keys_;
    }

    function buy(uint256 amount) external payable {
        keys.mint{value: msg.value}(amount, keys.currentPhase(), keys.mintPrice());
    }

    function disarm() external {
        armed = false;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (!armed) return;
        uint256[] memory list = new uint256[](2);
        list[0] = 2;
        list[1] = 3;
        (bool batchOk, bytes memory batchError) = address(keys).call(abi.encodeCall(keys.refundBatch, (list)));
        (bool singleOk, bytes memory singleError) = address(keys).call(abi.encodeCall(keys.refund, (3)));
        require(!batchOk && !singleOk, "Reentered");
        emit ReentryBlocked(bytes4(batchError), bytes4(singleError));
    }
}

contract BatchRefundTest is RyodanKeysFixture {
    function ids(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    function test_ThirdPartyBatchPaysDifferentMintersTheirOriginalPrices() public {
        _open(10);
        _buy(bob, 1);
        vm.expectRevert("Phases locked");
        keys.configurePhase(4, 0.045 ether, 10);
        _buy(alice, 1);
        vm.warp(end + 4 days + 1);
        uint256 bobBefore = bob.balance;
        uint256 aliceBefore = alice.balance;
        vm.prank(treasury);
        keys.refundBatch(ids(2, 1));
        assertEq(bob.balance - bobBefore, 0.01 ether);
        assertEq(alice.balance - aliceBefore, 0.01 ether);
        assertEq(treasury.balance, 0);
        assertEq(keys.totalRefunded(), 2);
        assertEq(address(keys).balance, 0);
    }

    function test_DuplicateAndInvalidIdsRollBackWholeBatch() public {
        _open(2);
        _buy(bob, 2);
        vm.warp(end + 4 days + 1);
        vm.expectRevert("Already refunded");
        keys.refundBatch(ids(1, 1));
        vm.expectRevert("Token not eligible for refund");
        keys.refundBatch(ids(1, 1000));
        assertEq(keys.totalRefunded(), 0);
        assertEq(keys.totalSupply(), 2);
        assertEq(bob.balance, 0);
        assertEq(address(keys).balance, 0.02 ether);
        keys.refundBatch(ids(1, 2));
        vm.expectRevert("Already refunded");
        keys.refundBatch(ids(1, 2));
    }

    function test_RejectingRecipientRollsBackOtherRefundsAndCanRecoverSeparately() public {
        _open(2);
        _buy(bob, 1);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.01 ether}(1);
        wallet.configure("", true, false);
        vm.warp(end + 4 days + 1);
        // v5: a rejecting recipient no longer blocks the batch; its amount waits until it pulls it.
        keys.refundBatch(ids(1, 2));
        assertEq(keys.totalRefunded(), 2);
        assertEq(bob.balance, 0.01 ether);
        assertEq(keys.pendingRefund(address(wallet)), 0.01 ether);
        assertEq(address(keys).balance, 0.01 ether);
        wallet.claimPending(payable(alice));
        assertEq(alice.balance, 0.01 ether);
        assertEq(keys.pendingRefund(address(wallet)), 0);
        assertEq(address(keys).balance, 0);
    }

    function test_BatchCallbackCannotReenterAnotherBatchOrSingleRefund() public {
        _open(3);
        BatchReentryWallet wallet = new BatchReentryWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.03 ether}(3);
        vm.warp(end + 4 days + 1);
        bytes4 guard = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        // Both payments of the batch try to re-enter refundBatch and refund within the 50k gas cap.
        for (uint256 i; i < 2; i++) {
            vm.expectEmit(address(wallet));
            emit BatchReentryWallet.ReentryBlocked(guard, guard);
        }
        keys.refundBatch(ids(1, 2));
        assertFalse(keys.refunded(3));
        assertEq(keys.totalRefunded(), 2);
        assertEq(keys.pendingRefund(address(wallet)), 0);
        assertEq(address(wallet).balance, 0.02 ether);
        assertEq(address(keys).balance, 0.01 ether);
        wallet.disarm();
        keys.refund(3);
        assertEq(address(wallet).balance, 0.03 ether);
        assertEq(address(keys).balance, 0);
    }

    function test_BatchSizeAndOutcomeGuards() public {
        vm.expectRevert("Invalid refund batch size");
        keys.refundBatch(new uint256[](0));
        vm.expectRevert("Invalid refund batch size");
        keys.refundBatch(new uint256[](51));
        _open(6000);
        _buy(bob, 2);
        vm.expectRevert("Mint not ended");
        keys.refundBatch(ids(1, 2));
        _buy(bob, 5998);
        vm.prank(treasury);
        keys.treasuryMint(666, treasury);
        vm.warp(end + 4 days + 1);
        vm.expectRevert("All tokens minted");
        keys.refundBatch(ids(1, 2));
    }

    function testFuzz_ArbitraryCallerBatchIsSolventAndSingleUse(uint256 countSeed, uint256 rotationSeed, address caller)
        public
    {
        uint256 count = bound(countSeed, 1, 50);
        _open(count);
        _buy(bob, count);
        vm.warp(end + 4 days + 1);
        uint256[] memory list = new uint256[](count);
        for (uint256 i; i < count; i++) {
            list[i] = (i + rotationSeed % count) % count + 1;
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
