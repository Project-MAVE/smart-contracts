// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fixture, RejectETH, Recorder, HeavyWallet, ReenterNFT, ReenterETH} from "./Helpers.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract A_Roles is Fixture {
    function test_A01_NonAdminCannotConfigureOrAdvance() public {
        vm.startPrank(address(0xBEEF));
        bytes4 sel = IAccessControl.AccessControlUnauthorizedAccount.selector;
        vm.expectRevert(abi.encodeWithSelector(sel, address(0xBEEF), keys.DEFAULT_ADMIN_ROLE()));
        keys.configurePhase(4, 0.01 ether, 10);
        vm.expectRevert(abi.encodeWithSelector(sel, address(0xBEEF), keys.DEFAULT_ADMIN_ROLE()));
        keys.configureAllowlist(bytes32(0), bytes32(uint256(1)), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(sel, address(0xBEEF), keys.DEFAULT_ADMIN_ROLE()));
        keys.advancePhase();
        vm.expectRevert(abi.encodeWithSelector(sel, address(0xBEEF), keys.DEFAULT_ADMIN_ROLE()));
        keys.setMintPaused(false);
        vm.stopPrank();
    }

    function test_A02_NonTreasuryCannotMoveFundsOrMint() public {
        _sellOut(address(0xAA));
        address atk = address(0xBEEF);
        vm.startPrank(atk);
        bytes4 sel = IAccessControl.AccessControlUnauthorizedAccount.selector;
        vm.expectRevert(abi.encodeWithSelector(sel, atk, keys.TREASURY_ROLE()));
        keys.withdraw();
        vm.expectRevert(abi.encodeWithSelector(sel, atk, keys.TREASURY_ROLE()));
        keys.treasuryMint(1, atk);
        vm.expectRevert(abi.encodeWithSelector(sel, atk, keys.TREASURY_ROLE()));
        keys.withdrawKept();
        vm.expectRevert(abi.encodeWithSelector(sel, atk, keys.TREASURY_ROLE()));
        keys.burnTreasuryKeys(new uint256[](0));
        vm.stopPrank();
    }

    function test_A03_AdminIsNotTreasury() public view {
        assertTrue(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(keys.hasRole(keys.TREASURY_ROLE(), admin));
    }
}

contract B_Deadline is Fixture {
    function test_B01_NoFunctionCanMoveTheDeadline() public {
        vm.prank(admin);
        (bool ok,) = address(keys).call(abi.encodeWithSignature("setMintEndTime(uint256)", end + 365 days));
        assertFalse(ok);
        (ok,) = address(keys).call(abi.encodeWithSignature("extendDeadline(uint256)", end + 365 days));
        assertFalse(ok);
        (ok,) = address(keys).call(abi.encodeWithSignature("setDeadline(uint256)", end + 365 days));
        assertFalse(ok);
        assertEq(keys.mintEndTime(), end);
    }

    function test_B02_TwentyForwardAttemptsFailAndRefundsStillOpenOnTime() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 2);
        for (uint256 i; i < 20; i++) {
            vm.prank(admin);
            (bool ok,) = address(keys).call(abi.encodeWithSignature("setMintEndTime(uint256)", end + i + 1));
            assertFalse(ok);
        }
        vm.warp(end);
        assertFalse(keys.refundsAvailable());
        vm.warp(end + 1);
        assertTrue(keys.refundsAvailable());
    }

    function test_B03_MintStopsExactlyAtDeadline() public {
        _openCivilian(10, 0.01 ether);
        vm.warp(end);
        _buy(address(0xAA), 1);
        vm.warp(end + 1);
        vm.deal(address(0xAA), 1 ether);
        vm.prank(address(0xAA));
        vm.expectRevert("Mint ended");
        keys.mint{value: 0.01 ether}(1, 4, 0.01 ether);
        vm.prank(treasury);
        vm.expectRevert("Mint ended");
        keys.treasuryMint(1, treasury);
        vm.prank(admin);
        vm.expectRevert("Mint ended");
        keys.setMintPaused(false);
        vm.prank(admin);
        vm.expectRevert("Mint ended");
        keys.advancePhase();
    }

    function test_B04_RefundBeforeDeadlineReverts() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 1);
        vm.prank(address(0xAA));
        vm.expectRevert("Mint not ended");
        keys.refund(1);
    }
}

contract C_Price is Fixture {
    function test_C02_ZeroPriceRejected() public {
        vm.expectRevert("Invalid price");
        keys.configurePhase(4, 0, 10);
    }

    function test_C03_PriceChangeCannotOverchargeAPendingBuyer() public {
        _openCivilian(10, 0.01 ether);
        address bob = makeAddr("bob");
        vm.deal(bob, 1 ether);
        uint256 before = bob.balance;
        keys.configurePhase(4, 0.02 ether, 10);
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.01 ether}(1, 4, 0.01 ether);
        assertEq(bob.balance, before);
        assertEq(keys.totalSupply(), 0);
        assertEq(address(keys).balance, 0);
    }

    function test_C04_HugePriceOverflowGuarded() public {
        vm.expectRevert("Invalid price");
        keys.configurePhase(4, type(uint256).max / 6000 + 1, 10);
    }

    function test_C05_PaymentSnapshotPerKey() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 1);
        keys.configurePhase(4, 0.5 ether, 10);
        _buy(address(0xAA), 1);
        assertEq(keys.mintPayment(1), 0.01 ether);
        assertEq(keys.mintPayment(2), 0.5 ether);
        _toEnd();
        vm.prank(address(0xAA));
        keys.refund(1);
        assertEq(keys.totalRefunded(), 1);
    }
}

contract D_Supply is Fixture {
    function test_D01_PublicSupplyHardCap() public {
        _openCivilian(6000, 0.01 ether);
        _buy(address(0xAA), 6000);
        vm.deal(address(0xAA), 1 ether);
        vm.prank(address(0xAA));
        vm.expectRevert("Max supply reached");
        keys.mint{value: 0.01 ether}(1, 4, 0.01 ether);
        assertEq(keys.mintedByUsers(), 6000);
    }

    function test_D02_TreasurySupplyHardCap() public {
        _openCivilian(10, 0.01 ether);
        vm.prank(treasury);
        keys.treasuryMint(666, treasury);
        vm.prank(treasury);
        vm.expectRevert("Max supply reached while minting to treasury");
        keys.treasuryMint(1, treasury);
        assertEq(keys.mintedByTreasury(), 666);
        assertEq(keys.totalSupply(), 666);
    }

    function test_D03_TotalCapEquals6000Plus666() public view {
        assertEq(keys.MAX_PUBLIC_SUPPLY() + keys.MAX_TREASURY_SUPPLY(), 6666);
        assertEq(keys.MAX_SUPPLY(), 6666);
        assertEq(keys.FIRST_TOKEN_ID(), 1);
    }

    function test_D04_NoIdCollisionAfterRefund() public {
        _openCivilian(10, 0.01 ether);
        _buy(address(0xAA), 2);
        _toEnd();
        vm.prank(address(0xAA));
        keys.refund(2);
        vm.expectRevert("Mint ended");
        keys.configurePhase(4, 0.01 ether, 10);
        assertEq(keys.ownerOf(1), address(0xAA));
        assertEq(keys.totalSupply(), 1);
    }

    function test_D05_GtdReservationCannotBeSpentInPublicPhases() public {
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        bytes32[4] memory ls = [_leaf(bob, 1), _leaf(carol, 2), _leaf(dave, 3), _leaf(eve, 3)];
        (bytes32 root, bytes32[2][4] memory pr) = _tree(ls);
        keys.configureAllowlist(root, keccak256("snap"), 1, 1, 2);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.configurePhase(2, 0.03 ether, 10);
        keys.configurePhase(3, 0.035 ether, 10);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.06 ether}(4, 1, 0.015 ether, 1, _arr2(pr[0]));
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert("Not allowlisted");
        keys.mintWithProof{value: 0.06 ether}(4, 1, 0.015 ether, 2, _arr2(pr[1]));
    }

    function test_D06_RegistrationCapAndTierBinding() public {
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        bytes32[4] memory ls = [_leaf(bob, 1), _leaf(carol, 2), _leaf(dave, 3), _leaf(eve, 3)];
        (bytes32 root, bytes32[2][4] memory pr) = _tree(ls);
        keys.configureAllowlist(root, keccak256("snap"), 1, 1, 2);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[0]));
        vm.prank(bob);
        vm.expectRevert("Invalid allowlist proof");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 2, _arr2(pr[1]));
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert("Invalid allowlist proof");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[0]));
        vm.deal(dave, 1 ether);
        vm.prank(dave);
        vm.expectRevert("Not allowlisted");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 3, _arr2(pr[2]));
    }

    function test_D06b_RegistrationCounterCannotBeOverrun() public {
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        bytes32[4] memory ls = [_leaf(bob, 1), _leaf(carol, 1), bytes32(0), bytes32(0)];
        (bytes32 root, bytes32[2][4] memory pr) = _tree(ls);
        keys.configureAllowlist(root, keccak256("snap"), 1, 0, 0);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[0]));
        assertEq(keys.registeredMembers(1), 1);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert("Tier member count exceeded");
        keys.mintWithProof{value: 0.03 ether}(2, 1, 0.015 ether, 1, _arr2(pr[1]));
    }

    function test_D07_EmptyAllowlistBlocksAllowedPhases() public {
        keys.configureAllowlist(bytes32(0), keccak256("snap"), 0, 0, 0);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(address(0xAA), 1 ether);
        vm.prank(address(0xAA));
        vm.expectRevert("Not allowlisted");
        keys.mint{value: 0.05 ether}(2, 1, 0.025 ether);
    }

    function test_D08_AllowlistFrozenAfterStart() public {
        _openCivilian(10, 0.01 ether);
        vm.expectRevert("Allowlist frozen");
        keys.configureAllowlist(bytes32(uint256(1)), keccak256("snap"), 1, 0, 0);
    }

    function test_D09_PairRuleInPioneer() public {
        address bob = makeAddr("bob");
        bytes32 l = _leaf(bob, 1);
        keys.configureAllowlist(l, keccak256("snap"), 1, 0, 0);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Pioneer requires pairs");
        keys.mintWithProof{value: 0.015 ether}(1, 1, 0.015 ether, 1, new bytes32[](0));
    }
}
