// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fixture, RejectETH, Recorder, HeavyWallet, ReenterNFT, ReenterETH} from "./Helpers.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract E_Refunds is Fixture {
    function test_E01_DoubleRefundEveryRouteFails() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 3);
        _toEnd();
        vm.startPrank(bob);
        keys.refund(1);
        vm.expectRevert("Already refunded");
        keys.refund(1);
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.expectRevert("Already refunded");
        keys.refundBatch(one);
        vm.expectRevert("Already refunded");
        keys.refundTo(1, payable(bob));
        vm.expectRevert("Already refunded");
        keys.settle(new uint256[](0), one);
        vm.stopPrank();
        assertEq(keys.totalRefunded(), 1);
        assertEq(keys.totalSupply(), 2);
    }

    function test_E03_MinterCannotBeRefundedByAThirdPartyInsideTheWindow() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        vm.warp(end + 1 hours);
        vm.prank(address(0xBAD));
        vm.expectRevert("Choice window open");
        keys.refund(1);
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.prank(address(0xBAD));
        vm.expectRevert("Choice window open");
        keys.refundBatch(one);
    }

    function test_E04_TreasuryKeysAreNotRefundable() public {
        _openCivilian(10, 0.01 ether);
        vm.prank(treasury);
        keys.treasuryMint(3, treasury);
        _toEnd();
        vm.prank(treasury);
        vm.expectRevert("Token not eligible for refund");
        keys.refund(1);
        vm.prank(address(0xBAD));
        vm.expectRevert("Token not eligible for refund");
        keys.refund(1);
    }

    function test_E05_RefundsAfterSelloutRevert() public {
        _sellOut(address(0xAA));
        vm.warp(end + 1);
        vm.prank(address(0xAA));
        vm.expectRevert("All tokens minted");
        keys.refund(1);
        assertTrue(keys.soldOut());
        assertFalse(keys.refundsAvailable());
    }

    function test_E06_KeptKeyCannotBeRefunded() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        _toEnd();
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(bob);
        keys.settle(keep, new uint256[](0));
        assertTrue(keys.kept(1));
        vm.prank(bob);
        vm.expectRevert("Key kept");
        keys.refund(1);
        vm.prank(address(0xBAD));
        vm.expectRevert("Key kept");
        keys.refund(1);
    }

    function test_E07_ThirdPartyCannotKeepSomeoneElsesKey() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        _toEnd();
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(address(0xBAD));
        vm.expectRevert("Not original minter");
        keys.settle(keep, new uint256[](0));
    }

    function test_E08_SettleCannotKeepAndRefundTheSameKey() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        _toEnd();
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(bob);
        vm.expectRevert("Key kept");
        keys.settle(keep, keep);
        assertEq(keys.totalKept(), 0);
    }

    function test_E09_RefundToRequiresTheMinter() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 1);
        _toEnd();
        vm.prank(address(0xBAD));
        vm.expectRevert("Not original minter");
        keys.refundTo(1, payable(address(0xBAD)));
        vm.prank(bob);
        vm.expectRevert("Zero refund recipient");
        keys.refundTo(1, payable(address(0)));
    }

    function test_E10_HeavyWalletIsDeferredAndCanClaimOnce() public {
        HeavyWallet w = new HeavyWallet(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(w), 1 ether);
        w.buy{value: 0.02 ether}(2);
        vm.warp(end + 4 days + 1 hours);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        keys.refundBatch(ids);
        assertEq(keys.pendingRefund(address(w)), 0.02 ether);
        assertEq(address(w).balance, 1 ether);
        vm.expectRevert("Nothing pending");
        keys.claimPendingRefund(payable(address(this)));
        vm.prank(address(w));
        keys.claimPendingRefund(payable(address(w)));
        assertEq(address(w).balance, 1.02 ether);
        assertEq(keys.pendingRefund(address(w)), 0);
        assertEq(keys.totalPendingRefund(), 0);
        vm.prank(address(w));
        vm.expectRevert("Nothing pending");
        keys.claimPendingRefund(payable(address(w)));
    }

    function test_E11_RejectingWalletDoesNotBlockTheBatch() public {
        RejectETH w = new RejectETH(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(w), 1 ether);
        vm.deal(address(0xAA), 1 ether);
        w.buy{value: 0.02 ether}(2);
        vm.prank(address(0xAA));
        keys.mint{value: 0.02 ether}(2, 4, 0.01 ether);
        vm.warp(end + 4 days + 1 hours);
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        keys.refundBatch(ids);
        assertEq(keys.pendingRefund(address(w)), 0.02 ether);
        assertEq(address(0xAA).balance, 1 ether);
        assertEq(keys.totalSupply(), 0);
        vm.prank(address(w));
        keys.claimPendingRefund(payable(address(0xAA)));
        assertEq(address(0xAA).balance, 1 ether + 0.02 ether);
    }

    function test_E12_WithdrawKeptDuringWindowLeavesRefundsSolvent() public {
        address bob = makeAddr("bob");
        address alice = makeAddr("alice");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 5);
        _buy(alice, 5);
        _toEnd();
        uint256[] memory keep = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            keep[i] = i + 1;
        }
        vm.prank(bob);
        keys.settle(keep, new uint256[](0));
        assertEq(keys.keptFunds(), 0.05 ether);
        vm.prank(treasury);
        keys.withdrawKept();
        assertEq(address(treasury).balance, 0.05 ether);
        assertTrue(_solvent());
        for (uint256 i = 6; i <= 10; i++) {
            vm.prank(alice);
            keys.refund(i);
        }
        assertEq(alice.balance, 0.05 ether);
        assertEq(keys.totalRefunded(), 5);
        assertEq(keys.totalKept(), 5);
        assertTrue(_solvent());
    }

    function test_E13_WithdrawKeptBeforeTheDeadlineReverts() public {
        _openCivilian(10, 0.01 ether);
        vm.prank(treasury);
        vm.expectRevert("Refunds not available");
        keys.withdrawKept();
    }

    function test_E14_TreasuryCanBurnTreasuryKeysOnlyAfterTheWindow() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 2);
        vm.prank(treasury);
        keys.treasuryMint(3, treasury);
        _toEnd();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 3;
        ids[1] = 4;
        ids[2] = 5;
        vm.prank(treasury);
        vm.expectRevert("Choice window not closed");
        keys.burnTreasuryKeys(ids);
        vm.warp(end + 4 days + 1);
        uint256[] memory pub = new uint256[](1);
        pub[0] = 1;
        vm.prank(treasury);
        vm.expectRevert("Not a treasury key");
        keys.burnTreasuryKeys(pub);
        vm.prank(treasury);
        keys.burnTreasuryKeys(ids);
        assertEq(keys.totalSupply(), 2);
        assertEq(keys.totalBurned(), 3);
    }

    function test_E15_BatchSizeLimits() public {
        _openCivilian(6166, 0.01 ether);
        _buy(address(0xAA), 51);
        _toEnd();
        uint256[] memory ids = new uint256[](51);
        for (uint256 i; i < 51; i++) {
            ids[i] = i + 1;
        }
        vm.prank(address(0xAA));
        vm.expectRevert("Invalid refund batch size");
        keys.refundBatch(ids);
        vm.prank(address(0xAA));
        vm.expectRevert("Invalid settle size");
        keys.settle(ids, new uint256[](0));
    }

    function test_E16_DuplicateIdsInOneBatchRevertEverything() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 3);
        _toEnd();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 1;
        ids[2] = 2;
        vm.prank(address(0xAA));
        vm.expectRevert("Already refunded");
        keys.refundBatch(ids);
        assertEq(keys.totalRefunded(), 0);
        assertEq(keys.totalSupply(), 3);
    }

    function test_E17_SettleKeepsAndRefundsInOneCall() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 4);
        _toEnd();
        uint256[] memory keep = new uint256[](2);
        keep[0] = 1;
        keep[1] = 2;
        uint256[] memory refundIds = new uint256[](2);
        refundIds[0] = 3;
        refundIds[1] = 4;
        vm.prank(bob);
        keys.settle(keep, refundIds);
        assertEq(keys.totalKept(), 2);
        assertEq(keys.keptFunds(), 0.02 ether);
        assertEq(keys.totalRefunded(), 2);
        assertEq(bob.balance, 0.02 ether);
        assertEq(keys.totalSupply(), 2);
        assertTrue(_solvent());
    }

    function test_E18_TwoThousandWalletBatchPaysEverybody() public {
        _openCivilian(50, 0.01 ether);
        address[5] memory ws = [makeAddr("w1"), makeAddr("w2"), makeAddr("w3"), makeAddr("w4"), makeAddr("w5")];
        for (uint256 i; i < 5; i++) {
            _buy(ws[i], 10);
        }
        vm.warp(end + 4 days + 1 hours);
        uint256[] memory ids = new uint256[](50);
        for (uint256 i; i < 50; i++) {
            ids[i] = i + 1;
        }
        uint256 gasBefore = gasleft();
        keys.refundBatch(ids);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("refundBatch(50) gas", used);
        for (uint256 i; i < 5; i++) {
            assertEq(ws[i].balance, 0.1 ether);
        }
        assertEq(keys.totalSupply(), 0);
    }

    function test_E19_WithdrawKeptCannotBeDrainedTwice() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        _toEnd();
        uint256[] memory keep = new uint256[](2);
        keep[0] = 1;
        keep[1] = 2;
        vm.prank(bob);
        keys.settle(keep, new uint256[](0));
        vm.prank(treasury);
        keys.withdrawKept();
        vm.prank(treasury);
        vm.expectRevert("No balance to withdraw");
        keys.withdrawKept();
        assertEq(keys.keptWithdrawn(), keys.keptFunds());
    }

    function test_E20_PendingRefundCannotBeRedirectedByAThirdParty() public {
        HeavyWallet w = new HeavyWallet(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(w), 1 ether);
        w.buy{value: 0.01 ether}(1);
        vm.warp(end + 4 days + 1 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        keys.refundBatch(ids);
        vm.prank(address(0xBAD));
        vm.expectRevert("Nothing pending");
        keys.claimPendingRefund(payable(address(0xBAD)));
    }

    function test_E21_SettleAfterTheWindowRevertsButRefundBatchWorks() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        vm.warp(end + 4 days + 1);
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(bob);
        vm.expectRevert("Choice window closed");
        keys.settle(keep, new uint256[](0));
        assertFalse(keys.kept(1));
    }
}

contract F_Reentrancy is Fixture {
    function test_F01_ReenterMintFromNFTReceiveReverts() public {
        ReenterNFT w = new ReenterNFT(keys);
        _openCivilian(10, 0.01 ether);
        w.setMode(5);
        vm.deal(address(w), 1 ether);
        w.buy{value: 0.02 ether}(2);
        assertTrue(w.entered() == false);
        bytes memory err = w.lastError();
        bytes4 sel;
        assembly { sel := mload(add(err, 0x20)) }
        assertEq(sel, ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_F02_ReenterTreasuryMintFromNFTReceiveReverts() public {
        ReenterNFT w = new ReenterNFT(keys);
        _openCivilian(10, 0.01 ether);
        keys.grantRole(keys.TREASURY_ROLE(), address(w));
        w.setMode(6);
        vm.prank(treasury);
        keys.treasuryMint(2, address(w));
        assertFalse(w.entered());
        bytes memory err = w.lastError();
        bytes4 sel;
        assembly { sel := mload(add(err, 0x20)) }
        assertEq(sel, ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_F03_ReenterRefundBatchAndClaimFromETHReceive() public {
        ReenterETH w = new ReenterETH(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(w), 1 ether);
        w.buy{value: 0.02 ether}(2);
        vm.warp(end + 4 days + 1 hours);
        w.setMode(4);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        keys.refundBatch(ids);
        assertFalse(w.entered());
        assertEq(keys.totalRefunded(), 2);
        assertEq(address(w).balance, 1.02 ether);
        bytes memory err = w.lastError();
        bytes4 sel;
        assembly { sel := mload(add(err, 0x20)) }
        assertEq(sel, ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_F04_ReenterSettleFromETHReceiveIsBlocked() public {
        ReenterETH w = new ReenterETH(keys);
        _openCivilian(10, 0.01 ether);
        vm.deal(address(w), 1 ether);
        w.buy{value: 0.02 ether}(2);
        _toEnd();
        w.setMode(3);
        uint256[] memory keep = new uint256[](2);
        keep[0] = 1;
        keep[1] = 2;
        vm.prank(address(w));
        w.keep(keep, new uint256[](0));
        assertFalse(w.entered());
        assertEq(keys.totalKept(), 2);
    }

    function test_F05_BurnReentryAtSelloutIsHarmless() public {
        ReenterNFT w = new ReenterNFT(keys);
        _openCivilian(6166, 0.01 ether);
        w.setMode(4);
        vm.deal(address(w), 100 ether);
        _buy(address(0xAA), 6166);
        vm.prank(treasury);
        keys.treasuryMint(500, address(w));
        assertEq(w.burnOk(), 500);
        assertTrue(keys.soldOut());
        assertEq(keys.totalSupply(), 6166);
        assertEq(keys.totalBurned(), 500);
        assertEq(keys.mintedByTreasury(), 500);
    }

    function test_F06_BurnBeforeSelloutReverts() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 1);
        vm.prank(address(0xAA));
        vm.expectRevert("Key is locked");
        keys.burn(1);
    }
}
