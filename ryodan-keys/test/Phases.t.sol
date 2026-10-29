// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture, CallbackWallet} from "./RyodanKeys.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PhasesTest is RyodanKeysFixture {
    function _list(uint8 phaseId, address account, bool allowed) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        keys.setPhaseAllowlist(phaseId, accounts, allowed);
    }

    function _next() internal {
        keys.advancePhase();
        keys.setMintPaused(false);
    }

    function test_DefaultPricesAndLimits() public view {
        uint256[4] memory prices = [uint256(0.005 ether), 0.002 ether, 0.001 ether, 0.01 ether];
        uint256[4] memory limits = [uint256(4), 6, 6, 10];
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            (uint256 price, uint256 limit,,,,) = keys.phases(phaseId);
            assertEq(price, prices[phaseId - 1]);
            assertEq(limit, limits[phaseId - 1]);
        }
        assertEq(keys.CONTRACT_VERSION(), 3);
    }

    function test_WalletCanUseIndependentLimitsInAllFourPhases() public {
        for (uint8 phaseId = 1; phaseId <= 3; phaseId++) {
            _list(phaseId, bob, true);
        }
        uint256[4] memory amounts = [uint256(4), 6, 6, 10];
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            _next();
            _buy(bob, amounts[phaseId - 1]);
            assertEq(keys.remainingAllowance(phaseId, bob), 0);
            assertEq(keys.mintedInPhase(phaseId, bob), amounts[phaseId - 1]);
        }
        assertEq(keys.mintedAmount(bob), 26);
        assertEq(keys.balanceOf(bob), 26);
        assertEq(keys.ownerOf(25), bob);
        assertEq(address(keys).balance, 0.138 ether);
    }

    function test_PhasesAdvanceInOrderAndAlwaysPause() public {
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            keys.advancePhase();
            assertEq(keys.currentPhase(), phaseId);
            assertTrue(keys.mintPaused());
            keys.setMintPaused(false);
        }
        vm.expectRevert("Final phase reached");
        keys.advancePhase();
        vm.expectRevert("Phase closed");
        keys.configurePhase(1, 0.005 ether, 4);
        address[] memory accounts = new address[](0);
        vm.expectRevert("Phase closed");
        keys.setPhaseAllowlist(1, accounts, true);
    }

    function test_CannotSelectFutureOrClosedPhaseEvenAtSamePrice() public {
        keys.configurePhase(2, 0.005 ether, 6);
        _list(1, bob, true);
        _list(2, bob, true);
        _next();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.005 ether}(1, 2, 0.005 ether);
        _next();
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.005 ether}(1, 1, 0.005 ether);
        assertEq(keys.mintedByUsers(), 0);
    }

    function test_PriceChangeInvalidatesPendingQuoteAndPreservesPaidAmounts() public {
        _list(1, bob, true);
        _next();
        _buy(bob, 1);
        keys.configurePhase(1, 0.003 ether, 4);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.005 ether}(1, 1, 0.005 ether);
        _buy(bob, 1);
        assertEq(keys.mintPayment(0), 0.005 ether);
        assertEq(keys.mintPayment(1), 0.003 ether);
        vm.warp(end + 1);
        uint256 beforeBalance = bob.balance;
        vm.startPrank(bob);
        keys.refund(1);
        keys.refund(0);
        vm.stopPrank();
        assertEq(bob.balance - beforeBalance, 0.008 ether);
        assertEq(address(keys).balance, 0);
    }

    function test_LimitCountsAllTransactionsInPhaseAndCanIncrease() public {
        _list(1, bob, true);
        _next();
        _buy(bob, 2);
        _buy(bob, 2);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Max mint amount reached for address");
        keys.mint{value: 0.005 ether}(1, 1, 0.005 ether);
        keys.configurePhase(1, 0.005 ether, 7);
        assertEq(keys.totalGtdReserved(), 3);
        _buy(bob, 3);
        assertEq(keys.mintedInPhase(1, bob), 7);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_GtdLimitReductionAndRemovalTrackOnlyUnclaimedAmounts() public {
        _list(1, bob, true);
        _list(1, alice, true);
        _next();
        _buy(bob, 2);
        assertEq(keys.totalGtdReserved(), 6);
        keys.configurePhase(1, 0.005 ether, 3);
        assertEq(keys.totalGtdReserved(), 4);
        _list(1, bob, false);
        assertEq(keys.totalGtdReserved(), 3);
        _list(1, bob, true);
        assertEq(keys.totalGtdReserved(), 4);
        assertEq(keys.remainingAllowance(1, bob), 1);
        vm.expectRevert("Limit below minted allocation");
        keys.configurePhase(1, 0.005 ether, 1);
    }

    function test_DuplicateListEntriesCannotCreateOrDestroyReservations() public {
        address[] memory accounts = new address[](3);
        accounts[0] = bob;
        accounts[1] = bob;
        accounts[2] = alice;
        keys.setPhaseAllowlist(1, accounts, true);
        keys.setPhaseAllowlist(1, accounts, true);
        assertEq(keys.totalGtdReserved(), 8);
        (,,, uint256 members,,) = keys.phases(1);
        assertEq(members, 2);
        keys.setPhaseAllowlist(1, accounts, false);
        keys.setPhaseAllowlist(1, accounts, false);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_CannotPromiseMoreGtdThanRemainingPaidSupply() public {
        keys.configurePhase(1, 0.005 ether, 3000);
        keys.configurePhase(2, 0.002 ether, 2900);
        _list(1, bob, true);
        _list(2, alice, true);
        assertEq(keys.totalGtdReserved(), 5900);
        address[] memory accounts = new address[](1);
        accounts[0] = treasury;
        vm.expectRevert("Insufficient GTD supply");
        keys.setPhaseAllowlist(2, accounts, true);
        vm.expectRevert("Insufficient GTD supply");
        keys.configurePhase(1, 0.005 ether, 3001);
        assertFalse(keys.allowlisted(2, treasury));
        assertEq(keys.totalGtdReserved(), 5900);
        _next();
        _buy(bob, 3000);
        _next();
        _buy(alice, 2900);
        assertEq(keys.mintedByUsers(), 5900);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_UnusedGtdReleasedAndCivilianReceivesRemainder() public {
        _list(1, bob, true);
        _list(2, alice, true);
        _list(3, bob, true);
        _next();
        _buy(bob, 1);
        assertEq(keys.totalGtdReserved(), 9);
        _next();
        assertEq(keys.totalGtdReserved(), 6);
        assertEq(keys.remainingAllowance(1, bob), 0);
        _buy(alice, 2);
        _next();
        assertEq(keys.totalGtdReserved(), 0);
        _buy(bob, 3);
        _next();
        keys.configurePhase(4, 0.01 ether, 5900);
        _buy(alice, 5894);
        assertEq(keys.mintedByUsers(), 5900);
        assertEq(keys.mintedInPhase(4, alice), 5894);
    }

    function test_RecruitIsAllowlistedFcfsWithoutReservation() public {
        keys.configurePhase(3, 0.001 ether, 5900);
        _list(3, bob, true);
        _list(3, alice, true);
        assertEq(keys.totalGtdReserved(), 0);
        _next();
        _next();
        _next();
        _buy(bob, 5900);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("Max supply reached");
        keys.mint{value: 0.001 ether}(1, 3, 0.001 ether);
    }

    function test_AllowlistIsIndependentForEachPhase() public {
        _list(1, bob, true);
        _next();
        _buy(bob, 1);
        _next();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Not allowlisted");
        keys.mint{value: 0.002 ether}(1, 2, 0.002 ether);
        _list(2, bob, true);
        _buy(bob, 1);
        _list(2, bob, false);
        vm.prank(bob);
        vm.expectRevert("Not allowlisted");
        keys.mint{value: 0.002 ether}(1, 2, 0.002 ether);
    }

    function test_InvalidConfigurationRejected() public {
        vm.expectRevert("Invalid phase");
        keys.configurePhase(0, 1, 1);
        vm.expectRevert("Invalid phase");
        keys.configurePhase(5, 1, 1);
        vm.expectRevert("Invalid price");
        keys.configurePhase(1, 0, 1);
        vm.expectRevert("Invalid price");
        keys.configurePhase(1, type(uint256).max, 1);
        vm.expectRevert("No active phase");
        keys.setMintPaused(false);
        address[] memory accounts = new address[](1);
        vm.expectRevert("Zero allowlist address");
        keys.setPhaseAllowlist(1, accounts, true);
        accounts[0] = bob;
        vm.expectRevert("Civilian is public");
        keys.setPhaseAllowlist(4, accounts, true);
        assertEq(keys.remainingAllowance(0, bob), 0);
        assertEq(keys.remainingAllowance(5, bob), 0);
    }

    function test_FcfsLimitCanDropBelowAlreadyMintedWithoutResettingCounter() public {
        _open(10);
        _buy(bob, 5);
        keys.configurePhase(4, 0.01 ether, 2);
        assertEq(keys.remainingAllowance(4, bob), 0);
        keys.configurePhase(4, 0.01 ether, 6);
        assertEq(keys.remainingAllowance(4, bob), 1);
    }

    function test_AdminReceiverCannotMutatePhaseConfigurationDuringMint() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        keys.grantRole(keys.DEFAULT_ADMIN_ROLE(), address(wallet));
        _list(1, address(wallet), true);
        _next();
        vm.deal(address(this), 1 ether);
        bytes[4] memory calls = [
            abi.encodeCall(keys.configurePhase, (1, 1, 100)),
            abi.encodeCall(keys.advancePhase, ()),
            abi.encodeCall(keys.setMintPaused, (true)),
            abi.encodeCall(keys.setPhaseAllowlist, (1, new address[](0), false))
        ];
        for (uint256 i; i < 4; i++) {
            wallet.configure(calls[i], false, false);
            wallet.buy{value: 0.005 ether}(1);
            assertFalse(wallet.reentered());
            assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
            assertEq(keys.mintPayment(i), 0.005 ether);
        }
        assertEq(keys.currentPhase(), 1);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_ExpiredPhaseCannotAdvanceOrReopen() public {
        _next();
        vm.warp(end + 1);
        vm.expectRevert("Mint ended");
        keys.advancePhase();
        vm.expectRevert("Mint ended");
        keys.setMintPaused(false);
        vm.expectRevert("Mint ended");
        keys.configurePhase(2, 1, 10);
    }

    function test_CompletedSaleLocksPhaseAdministration() public {
        _sellOut();
        vm.expectRevert("All tokens minted");
        keys.advancePhase();
        vm.expectRevert("All tokens minted");
        keys.configurePhase(4, 0.01 ether, 10);
    }

    function test_RejectedGuaranteedMintRestoresReservationAndPayment() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        wallet.configure("", false, true);
        _list(1, address(wallet), true);
        _next();
        vm.deal(address(this), 1 ether);
        vm.expectRevert("NFT rejected");
        wallet.buy{value: 0.005 ether}(1);
        assertEq(keys.totalGtdReserved(), 4);
        assertEq(keys.mintedInPhase(1, address(wallet)), 0);
        assertEq(keys.mintPayment(0), 0);
        assertEq(address(keys).balance, 0);
    }

    function testFuzz_IndependentLimitsAndExactRefunds(uint256 seed, uint256 priceSeed) public {
        uint256 totalPaid;
        uint256 totalMinted;
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            uint256 limit = 1 + uint256(keccak256(abi.encode(seed, phaseId))) % 20;
            uint256 price = 1 + uint256(keccak256(abi.encode(priceSeed, phaseId))) % 0.1 ether;
            keys.configurePhase(phaseId, price, limit);
            if (phaseId < 4) _list(phaseId, bob, true);
            _next();
            _buy(bob, limit);
            totalPaid += price * limit;
            totalMinted += limit;
            assertEq(keys.remainingAllowance(phaseId, bob), 0);
        }
        assertEq(address(keys).balance, totalPaid);
        assertEq(keys.mintedAmount(bob), totalMinted);
        vm.warp(end + 1);
        uint256 beforeBalance = bob.balance;
        vm.startPrank(bob);
        for (uint256 id; id < totalMinted; id++) {
            keys.refund(id);
        }
        vm.stopPrank();
        assertEq(bob.balance - beforeBalance, totalPaid);
        assertEq(address(keys).balance, 0);
        assertEq(keys.totalSupply(), 0);
    }

    function testFuzz_GtdResizeRemoveReadd(uint256 capSeed, uint256 usedSeed, uint256 nextSeed) public {
        uint256 cap = bound(capSeed, 1, 100);
        uint256 used = bound(usedSeed, 1, cap);
        uint256 nextCap = bound(nextSeed, used, 200);
        keys.configurePhase(1, 0.005 ether, cap);
        _list(1, bob, true);
        _next();
        _buy(bob, used);
        keys.configurePhase(1, 0.003 ether, nextCap);
        assertEq(keys.totalGtdReserved(), nextCap - used);
        _list(1, bob, false);
        assertEq(keys.totalGtdReserved(), 0);
        _list(1, bob, true);
        assertEq(keys.totalGtdReserved(), nextCap - used);
        assertEq(keys.remainingAllowance(1, bob), nextCap - used);
        _next();
        assertEq(keys.totalGtdReserved(), 0);
    }
}
