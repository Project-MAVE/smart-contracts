// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture} from "./RyodanKeys.t.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

contract DeadlineTest is RyodanKeysFixture {
    function _one(uint256 id) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = id;
    }

    function _tryExtend(address caller, uint256 newEnd) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(keys).call(abi.encodeWithSignature("setMintEndTime(uint256)", newEnd));
    }

    function test_DeadlineIsTheDeployValue() public view {
        assertEq(keys.mintEndTime(), end);
    }

    function test_ConstructorRejectsCurrentOrPastDeadline() public {
        vm.expectRevert("Deadline must be in the future");
        new RyodanKeys(block.timestamp, HIDDEN, NFT, address(this), treasury);
    }

    function test_NoSetterCanMoveTheDeadline() public {
        _open(1);
        _buy(bob, 1);
        address[3] memory callers = [address(this), treasury, bob];
        for (uint256 c; c < callers.length; c++) {
            assertFalse(_tryExtend(callers[c], end + 365 days));
            assertFalse(_tryExtend(callers[c], end - 1 days));
        }
        vm.warp(end);
        assertFalse(_tryExtend(address(this), end + 1));
        assertEq(keys.mintEndTime(), end);
    }

    function test_AdminRetryingTwentyTimesCannotDelayRefunds() public {
        _open(10);
        _buy(bob, 1);
        _buy(alice, 1);
        for (uint256 i; i < 20; i++) {
            vm.warp(end - 1 hours + i);
            assertFalse(_tryExtend(address(this), block.timestamp + 365 days));
        }
        assertEq(keys.mintEndTime(), end);

        vm.warp(end + 1);
        assertTrue(keys.refundsAvailable());
        assertTrue(keys.choiceWindowOpen());
        vm.prank(bob);
        keys.refund(1);
        assertEq(bob.balance, 0.01 ether);

        vm.warp(end + keys.CHOICE_WINDOW() + 1);
        keys.refundBatch(_one(2));
        assertEq(alice.balance, 0.01 ether);
        assertEq(keys.totalSupply(), 0);
        assertEq(address(keys).balance, 0);
    }

    function test_MintClosesExactlyAtDeployDeadline() public {
        _open(2);
        vm.warp(end);
        _buy(bob, 1);
        assertFalse(keys.refundsAvailable());
        vm.warp(end + 1);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Mint ended");
        keys.mint{value: 0.01 ether}(1, 4, 0.01 ether);
        vm.prank(treasury);
        vm.expectRevert("Mint ended");
        keys.treasuryMint(1, treasury);
        assertTrue(keys.refundsAvailable());
    }

    function testFuzz_RefundsOpenRightAfterDeployDeadline(uint256 offset) public {
        uint256 deadline = block.timestamp + bound(offset, 1, 365 days);
        keys = new RyodanKeys(deadline, HIDDEN, NFT, address(this), treasury);
        end = deadline;
        _open(2);
        _buy(bob, 1);
        assertFalse(_tryExtend(address(this), deadline + 1));
        vm.warp(deadline + 1);
        assertTrue(keys.refundsAvailable());
        vm.prank(bob);
        keys.refund(1);
        assertEq(keys.totalSupply(), 0);
    }
}
