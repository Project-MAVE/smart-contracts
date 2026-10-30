// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

contract SaleHandler is Test {
    RyodanKeys public keys;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256 public paid;
    uint256 public returned;
    uint256 public withdrawn;

    receive() external payable {}

    function initialize(RyodanKeys keys_) external {
        require(address(keys) == address(0));
        keys = keys_;
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            keys.configurePhase(phaseId, uint256(phaseId) * 0.001 ether, 30);
        }
        keys.configureAllowlist(
            _pair(_pair(leaf(0), leaf(1)), _pair(leaf(2), leaf(3))), keccak256("invariant-snapshot"), 4, 0, 0
        );
        keys.advancePhase();
        keys.setMintPaused(false);
    }

    function leaf(uint256 i) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(actors[i], uint8(1)))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function proof(uint256 i) public view returns (bytes32[] memory result) {
        result = new bytes32[](2);
        result[0] = leaf(i ^ 1);
        result[1] = i < 2 ? _pair(leaf(2), leaf(3)) : _pair(leaf(0), leaf(1));
    }

    function mintPaid(uint256 actorSeed, uint256 amountSeed) external {
        if (block.timestamp > keys.mintEndTime()) return;
        if (keys.mintPaused()) return;
        address actor = actors[actorSeed % actors.length];
        uint8 phaseId = keys.currentPhase();
        uint256 available = keys.MAX_PUBLIC_SUPPLY() - keys.mintedByUsers();
        if (phaseId > 2) available -= keys.totalGtdReserved();
        uint256 walletAvailable = keys.remainingAllowanceWithProof(phaseId, actor, 1, proof(actorSeed % actors.length));
        if (walletAvailable < available) available = walletAvailable;
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available > 30 ? 30 : available);
        if (phaseId == 1) {
            amount = amount / 2 * 2;
            if (amount == 0) return;
        }
        uint256 value = amount * keys.mintPrice();
        vm.deal(actor, actor.balance + value);
        uint256 price = keys.mintPrice();
        bytes32[] memory membershipProof = proof(actorSeed % actors.length);
        vm.prank(actor);
        keys.mintWithProof{value: value}(amount, phaseId, price, 1, membershipProof);
        paid += value;
    }

    function mintTreasury(uint256 amountSeed, uint256 actorSeed) external {
        if (block.timestamp > keys.mintEndTime()) return;
        uint256 available = keys.MAX_TREASURY_SUPPLY() - keys.mintedByTreasury();
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available > 20 ? 20 : available);
        keys.treasuryMint(amount, actors[actorSeed % actors.length]);
    }

    function changePhaseAndWhitelist(uint256 seed) external {
        if (block.timestamp > keys.mintEndTime() || keys.soldOut()) return;
        uint8 phaseId = keys.currentPhase();
        if (seed % 12 == 0 && phaseId < 4) {
            keys.advancePhase();
        } else if (seed % 3 == 0) {
            keys.setMintPaused(seed % 2 == 0);
        } else if (phaseId < 4) {
            bytes32 root = keys.allowlistRoot();
            (bool ok,) =
                address(keys).call(abi.encodeCall(keys.configureAllowlist, (bytes32(0), keccak256("changed"), 0, 0, 0)));
            assertFalse(ok);
            assertEq(keys.allowlistRoot(), root);
        }
    }

    function changeConfiguration(uint256 phaseSeed, uint256 limitSeed, uint256 priceSeed) external {
        if (block.timestamp > keys.mintEndTime() || keys.soldOut()) return;
        uint8 phaseId = uint8(bound(phaseSeed, keys.currentPhase(), 4));
        uint256 limit = bound(limitSeed, 1, 50);
        uint256 price = bound(priceSeed, 1, 0.1 ether);
        (,,,,, uint256 maximumMinted) = keys.phases(phaseId);
        bool shouldSucceed = (phaseId > 2 || limit >= maximumMinted) && (phaseId != 1 || limit % 2 == 0);
        (bool ok,) = address(keys).call(abi.encodeCall(keys.configurePhase, (phaseId, price, limit)));
        assertEq(ok, shouldSucceed);
    }

    function advance(uint256 stepSeed) external {
        vm.warp(block.timestamp + bound(stepSeed, 0, 1 days));
    }

    function changeDeadline(uint256 offsetSeed) external {
        uint256 previous = keys.mintEndTime();
        uint256 nextEnd = block.timestamp + bound(offsetSeed, 1, 14 days);
        bool locked = block.timestamp > previous || keys.soldOut();
        (bool ok,) = address(keys).call(abi.encodeCall(keys.setMintEndTime, (nextEnd)));
        assertEq(ok, !locked);
        assertEq(keys.mintEndTime(), locked ? previous : nextEnd);
        if (block.timestamp > previous && !keys.soldOut()) assertTrue(keys.refundsAvailable());
    }

    function refundPaid(uint256 idSeed, uint256 recipientSeed) external {
        if (!keys.refundsAvailable()) return;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        if (minted == 0) return;
        uint256 id = idSeed % minted;
        address minter = keys.originalMinter(id);
        if (minter == address(0) || keys.refunded(id)) return;
        if (recipientSeed % 3 == 0) {
            keys.refund(id);
        } else if (recipientSeed % 3 == 1) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            keys.refundBatch(ids);
        } else {
            vm.prank(minter);
            keys.refundTo(id, payable(actors[recipientSeed % actors.length]));
        }
        returned += keys.mintPayment(id);
    }

    function invalidRefund(uint256 idSeed) external {
        if (!keys.refundsAvailable()) return;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        uint256 id = bound(idSeed, minted, type(uint256).max);
        uint256 balanceBefore = address(keys).balance;
        (bool ok,) = address(keys).call(abi.encodeCall(keys.refund, (id)));
        assertFalse(ok);
        assertEq(address(keys).balance, balanceBefore);
    }

    function attemptTransfer(uint256 idSeed, uint256 recipientSeed) external {
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        if (minted == 0) return;
        uint256 id = idSeed % minted;
        if (keys.refunded(id)) return;
        address owner = keys.ownerOf(id);
        address to = actors[recipientSeed % actors.length];
        vm.prank(owner);
        (bool ok,) = address(keys).call(abi.encodeCall(keys.transferFrom, (owner, to, id)));
        assertEq(ok, keys.soldOut());
    }

    function withdrawIfSuccessful() external {
        if (!keys.soldOut() || address(keys).balance == 0) return;
        uint256 value = address(keys).balance;
        keys.withdraw();
        withdrawn += value;
    }
}

contract RyodanKeysInvariantTest is StdInvariant, Test {
    RyodanKeys internal keys;
    SaleHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new SaleHandler();
        keys = new RyodanKeys(block.timestamp + 7 days, "ipfs://hidden/hidden.json", address(handler), address(handler));
        handler.initialize(keys);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.mintPaid.selector;
        selectors[1] = handler.mintTreasury.selector;
        selectors[2] = handler.changePhaseAndWhitelist.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.refundPaid.selector;
        selectors[5] = handler.invalidRefund.selector;
        selectors[6] = handler.attemptTransfer.selector;
        selectors[7] = handler.withdrawIfSuccessful.selector;
        selectors[8] = handler.changeDeadline.selector;
        selectors[9] = handler.changeConfiguration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyAndCapsRemainConsistent() public view {
        assertLe(keys.mintedByUsers(), 6166);
        assertLe(keys.mintedByTreasury(), 500);
        uint256 phaseTotal;
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            (,, uint256 minted,,,) = keys.phases(phaseId);
            phaseTotal += minted;
        }
        assertEq(phaseTotal, keys.mintedByUsers());
        assertEq(keys.totalSupply() + keys.totalRefunded(), keys.mintedByUsers() + keys.mintedByTreasury());
    }

    function invariant_EtherIsConservedAndRefundsStaySolvent() public view {
        assertEq(address(keys).balance + handler.returned() + handler.withdrawn(), handler.paid());
        uint256 historicalPayments;
        uint256 refundedPayments;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        for (uint256 id; id < minted; ++id) {
            uint256 payment = keys.mintPayment(id);
            if (keys.originalMinter(id) == address(0)) assertEq(payment, 0);
            historicalPayments += payment;
            if (keys.refunded(id)) refundedPayments += payment;
        }
        assertEq(handler.paid(), historicalPayments);
        assertEq(handler.returned(), refundedPayments);
        if (!keys.soldOut()) {
            assertGe(address(keys).balance, historicalPayments - refundedPayments);
        }
    }

    function invariant_PhasesNeverOverlap() public view {
        assertGe(keys.currentPhase(), 1);
        assertLe(keys.currentPhase(), 4);
        for (uint8 phaseId = 1; phaseId < keys.currentPhase(); phaseId++) {
            assertEq(keys.remainingAllowance(phaseId, handler.actors(0)), 0);
        }
    }

    function invariant_GtdReservationsEqualUnclaimedAllocations() public view {
        uint256 total;
        for (uint8 phaseId = 1; phaseId <= 2; phaseId++) {
            uint256 expected;
            for (uint256 i; i < 4; i++) {
                expected += keys.remainingAllowanceWithProof(phaseId, handler.actors(i), 1, handler.proof(i));
            }
            (,,,, uint256 reserved,) = keys.phases(phaseId);
            assertEq(reserved, expected);
            total += reserved;
        }
        assertEq(total, keys.totalGtdReserved());
        assertLe(total + keys.mintedByUsers(), keys.MAX_PUBLIC_SUPPLY());
    }

    function invariant_AllLiveTokensBelongToTrackedActors() public view {
        uint256 balance;
        for (uint256 i; i < 4; i++) {
            balance += keys.balanceOf(handler.actors(i));
        }
        assertEq(balance, keys.totalSupply());
    }
}
