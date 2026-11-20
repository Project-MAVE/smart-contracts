// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fixture} from "./Helpers.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract GasProbe is IERC721Receiver {
    RyodanKeys public immutable k;
    uint256 public seenGas;
    uint256 public writes;

    constructor(RyodanKeys k_) {
        k = k_;
    }

    function buy(uint256 a) external payable {
        uint8 p = k.currentPhase();
        uint256 pr = k.mintPrice();
        k.mint{value: msg.value}(a, p, pr);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        seenGas = gasleft();
        for (uint256 i; i < writes; i++) {
            assembly { sstore(add(0x100, i), add(sload(add(0x100, i)), 1)) }
        }
    }

    function setWrites(uint256 w) external {
        writes = w;
    }
}

contract BadReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

contract J_Extras is Fixture {
    function test_J01_BatchRefundForwardsExactlyTheCap() public {
        GasProbe p = new GasProbe(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(p), 1 ether);
        p.buy{value: 0.01 ether}(1);
        _toEnd();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.warp(end + 73 hours);
        keys.refundBatch(ids);
        assertEq(keys.pendingRefund(address(p)), 0);
        assertLe(p.seenGas(), 52_300);
        assertGe(p.seenGas(), 51_000);
    }

    function test_J02_OverCapRecipientIsDeferredNotBlocked() public {
        GasProbe p = new GasProbe(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(p), 1 ether);
        p.setWrites(3);
        p.buy{value: 0.01 ether}(1);
        vm.warp(end + 73 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        keys.refundBatch(ids);
        assertEq(keys.pendingRefund(address(p)), 0.01 ether);
        vm.prank(address(p));
        keys.claimPendingRefund(payable(address(p)));
        assertEq(address(p).balance, 1.01 ether);
    }

    function test_J03_ForceFedEtherDoesNotBreakAccounting() public {
        address bob = makeAddr("bob");
        vm.deal(address(keys), 1 ether);
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        _toEnd();
        vm.prank(bob);
        keys.refund(1);
        vm.prank(bob);
        keys.refund(2);
        assertEq(bob.balance, 0.02 ether);
        assertEq(address(keys).balance, 1 ether);
        vm.prank(treasury);
        vm.expectRevert("No balance to withdraw");
        keys.withdrawKept();
    }

    function test_J04_ClaimToABrokenRecipientRevertsAndCanBeRetried() public {
        GasProbe p = new GasProbe(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(p), 1 ether);
        p.setWrites(3);
        p.buy{value: 0.01 ether}(1);
        vm.warp(end + 73 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        keys.refundBatch(ids);
        BadReceiver bad = new BadReceiver();
        vm.prank(address(p));
        vm.expectRevert();
        keys.claimPendingRefund(payable(address(bad)));
        assertEq(keys.pendingRefund(address(p)), 0.01 ether);
        vm.prank(address(p));
        keys.claimPendingRefund(payable(address(0xCAFE)));
        assertEq(address(0xCAFE).balance, 0.01 ether);
    }

    function test_J05_BadReceiverCannotReceive() public {
        _openCivilian(10, 0.01 ether);
        BadReceiver bad = new BadReceiver();
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(bad)));
        keys.treasuryMint(1, address(bad));
    }

    function test_J06_CapsRejectTheExactBoundary() public {
        _openCivilian(6000, 0.01 ether);
        _buy(address(0xAA), 5999);
        vm.deal(address(0xAA), 100 ether);
        vm.prank(address(0xAA));
        vm.expectRevert("Max supply reached");
        keys.mint{value: 0.02 ether}(2, 4, 0.01 ether);
        vm.prank(address(0xAA));
        keys.mint{value: 0.01 ether}(1, 4, 0.01 ether);
        assertEq(keys.mintedByUsers(), 6000);
    }

    function test_J07_PreApprovedOperatorCanMoveAKeptKey() public {
        address bob = makeAddr("bob");
        address op = makeAddr("op");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 1);
        vm.prank(bob);
        keys.setApprovalForAll(op, true);
        _toEnd();
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(bob);
        keys.settle(keep, new uint256[](0));
        vm.prank(op);
        keys.transferFrom(bob, op, 1);
        assertEq(keys.ownerOf(1), op);
    }
}
