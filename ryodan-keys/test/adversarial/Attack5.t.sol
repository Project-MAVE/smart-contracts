// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fixture, IERC721Receiver} from "./Helpers.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";

contract K_Allowlist is Fixture {
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _bobTree() internal returns (bytes32 root, bytes32[2][4] memory pr) {
        bytes32[4] memory ls = [_leaf(bob, 1), _leaf(bob, 3), _leaf(carol, 3), keccak256("pad")];
        (root, pr) = _tree(ls);
    }

    function test_K01_ForgedProofIsRejected() public {
        (bytes32 root,) = _bobTree();
        keys.configureAllowlist(root, keccak256("snap"), 1, 0, 2);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        bytes32[] memory fake = new bytes32[](2);
        fake[0] = keccak256("a");
        fake[1] = keccak256("b");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Invalid allowlist proof");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, fake);
        bytes32[] memory empty = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert("Invalid allowlist proof");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, empty);
    }

    function test_K02_ProofFromARotatedSnapshotIsDeadAfterTheRootChanges() public {
        bytes32[4] memory ls = [_leaf(bob, 1), _leaf(carol, 3), keccak256("x"), keccak256("y")];
        (bytes32 oldRoot, bytes32[2][4] memory oldProof) = _tree(ls);
        keys.configureAllowlist(oldRoot, keccak256("snap-v1"), 1, 0, 1);
        bytes32 freshRoot = keccak256("snap-v2-root");
        keys.configureAllowlist(freshRoot, keccak256("snap-v2"), 1, 0, 1);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Invalid allowlist proof");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(oldProof[0]));
    }

    function test_K03_OneWalletCannotShopForASecondTier() public {
        (bytes32 root, bytes32[2][4] memory pr) = _bobTree();
        keys.configureAllowlist(root, keccak256("snap"), 1, 0, 2);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[0]));
        vm.prank(bob);
        vm.expectRevert("Tier already registered");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 3, _arr2(pr[1]));
        assertEq(keys.walletTier(bob), 1);
    }

    function test_K04_RepeatMintDoesNotDoubleChargeTheTierCounter() public {
        (bytes32 root, bytes32[2][4] memory pr) = _bobTree();
        keys.configureAllowlist(root, keccak256("snap"), 1, 0, 2);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[0]));
        vm.prank(bob);
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[0]));
        assertEq(keys.registeredMembers(1), 1);
        assertEq(keys.mintedByUsers(), 4);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_K05_ProofMintBeforeTheSaleOpensReverts() public {
        (bytes32 root, bytes32[2][4] memory pr) = _bobTree();
        keys.configureAllowlist(root, keccak256("snap"), 1, 0, 2);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Mint not active");
        keys.mintWithProof{value: 0.015 ether}(1, 1, 0.015 ether, 1, _arr2(pr[0]));
    }
}

contract K_Hostage is Fixture {
    address internal buyer = makeAddr("buyer");

    function test_K06_AdminPausingForeverCannotTrapBuyerFunds() public {
        _openCivilian(6166, 0.01 ether);
        _buy(buyer, 3);
        keys.setMintPaused(true);
        _toEnd();
        vm.prank(buyer);
        keys.refund(1);
        vm.prank(buyer);
        keys.refundBatch(_ids2(2, 3));
        assertEq(buyer.balance, 0.03 ether);
        assertEq(keys.totalRefunded(), 3);
        assertEq(address(keys).balance, 0);
    }

    function test_K07_TreasuryThatNeverMintsCannotBlockRefundsOrTakeTheProceeds() public {
        _openCivilian(6166, 0.01 ether);
        _buy(buyer, 6166);
        vm.warp(end + 4 days + 1);
        assertFalse(keys.soldOut());
        assertTrue(keys.refundsAvailable());
        assertFalse(keys.choiceWindowOpen());
        vm.prank(treasury);
        vm.expectRevert("Not all tokens minted");
        keys.withdraw();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 6166;
        keys.refundBatch(ids);
        assertEq(buyer.balance, 0.03 ether);
        assertTrue(_solvent());
    }

    function test_K08_KeptKeysAloneFundTheTreasuryWithdrawal() public {
        _openCivilian(6166, 0.01 ether);
        _buy(buyer, 4);
        _toEnd();
        uint256[] memory keep = new uint256[](2);
        keep[0] = 1;
        keep[1] = 2;
        vm.prank(buyer);
        keys.settle(keep, _ids2(3, 4));
        assertEq(keys.keptFunds(), 0.02 ether);
        vm.prank(treasury);
        keys.withdrawKept();
        assertEq(treasury.balance, 0.02 ether);
        assertEq(address(keys).balance, 0);
        assertTrue(_solvent());
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }
}
