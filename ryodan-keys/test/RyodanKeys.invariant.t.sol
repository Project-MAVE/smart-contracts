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
        (,,,, uint256 maximumMinted) = keys.phases(phaseId);
        maximumMinted;
        (bool ok,) = address(keys).call(abi.encodeCall(keys.configurePhase, (phaseId, price, limit)));
        // Prices and limits are frozen once the first phase opened in initialize().
        assertFalse(ok);
    }

    function advance(uint256 stepSeed) external {
        vm.warp(block.timestamp + bound(stepSeed, 0, 1 days));
    }

    function refundPaid(uint256 idSeed, uint256 recipientSeed) external {
        if (!keys.refundsAvailable()) return;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        if (minted == 0) return;
        uint256 id = idSeed % minted + 1;
        address minter = keys.originalMinter(id);
        if (minter == address(0) || keys.refunded(id)) return;
        if (keys.kept(id)) return;
        // v5: during the choice window only the original minter may refund.
        bool asMinter = keys.choiceWindowOpen();
        if (recipientSeed % 3 == 0) {
            if (asMinter) vm.prank(minter);
            keys.refund(id);
        } else if (recipientSeed % 3 == 1) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            if (asMinter) vm.prank(minter);
            keys.refundBatch(ids);
        } else {
            vm.prank(minter);
            keys.refundTo(id, payable(actors[recipientSeed % actors.length]));
        }
        returned += keys.mintPayment(id);
    }

    function keepPaid(uint256 idSeed) external {
        if (!keys.choiceWindowOpen()) return;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        if (minted == 0) return;
        uint256 id = idSeed % minted + 1;
        address minter = keys.originalMinter(id);
        if (minter == address(0) || keys.refunded(id) || keys.kept(id)) return;
        uint256[] memory keep = new uint256[](1);
        keep[0] = id;
        vm.prank(minter);
        keys.settle(keep, new uint256[](0));
    }

    function burnUnlocked(uint256 idSeed) external {
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        if (minted == 0) return;
        uint256 id = idSeed % minted + 1;
        if (keys.refunded(id) || !(keys.soldOut() || keys.kept(id))) return;
        (bool exists, bytes memory data) = address(keys).staticcall(abi.encodeCall(keys.ownerOf, (id)));
        if (!exists) return;
        address owner = abi.decode(data, (address));
        uint256 balanceBefore = address(keys).balance;
        vm.prank(owner);
        keys.burn(id);
        assertEq(address(keys).balance, balanceBefore);
    }

    function withdrawKeptIfAny() external {
        if (!keys.refundsAvailable() || keys.keptFunds() == keys.keptWithdrawn()) return;
        uint256 value = keys.keptFunds() - keys.keptWithdrawn();
        keys.withdrawKept();
        withdrawn += value;
    }

    function invalidRefund(uint256 idSeed) external {
        if (!keys.refundsAvailable()) return;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        // token IDs run from 1 to minted: 0 and anything above are invalid
        uint256 id = idSeed % 2 == 0 ? 0 : bound(idSeed, minted + 1, type(uint256).max);
        uint256 balanceBefore = address(keys).balance;
        (bool ok,) = address(keys).call(abi.encodeCall(keys.refund, (id)));
        assertFalse(ok);
        assertEq(address(keys).balance, balanceBefore);
    }

    function attemptTransfer(uint256 idSeed, uint256 recipientSeed) external {
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        if (minted == 0) return;
        uint256 id = idSeed % minted + 1;
        if (keys.refunded(id)) return;
        (bool exists, bytes memory data) = address(keys).staticcall(abi.encodeCall(keys.ownerOf, (id)));
        if (!exists) return;
        address owner = abi.decode(data, (address));
        address to = actors[recipientSeed % actors.length];
        vm.prank(owner);
        (bool ok,) = address(keys).call(abi.encodeCall(keys.transferFrom, (owner, to, id)));
        assertEq(ok, keys.soldOut() || keys.kept(id));
    }

    function withdrawIfSuccessful() external {
        if (!keys.soldOut() || address(keys).balance == 0 || block.timestamp <= keys.mintEndTime()) return;
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
        keys =
            new RyodanKeys(block.timestamp + 7 days, "ipfs://sbt/", "ipfs://nft/", address(handler), address(handler));
        handler.initialize(keys);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.mintPaid.selector;
        selectors[1] = handler.mintTreasury.selector;
        selectors[2] = handler.changePhaseAndWhitelist.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.refundPaid.selector;
        selectors[5] = handler.invalidRefund.selector;
        selectors[6] = handler.attemptTransfer.selector;
        selectors[7] = handler.withdrawIfSuccessful.selector;
        selectors[8] = handler.changeConfiguration.selector;
        selectors[9] = handler.keepPaid.selector;
        selectors[10] = handler.withdrawKeptIfAny.selector;
        selectors[11] = handler.burnUnlocked.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyAndCapsRemainConsistent() public view {
        assertLe(keys.mintedByUsers(), 6000);
        assertLe(keys.mintedByTreasury(), 666);
        uint256 phaseTotal;
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            (,, uint256 minted,,) = keys.phases(phaseId);
            phaseTotal += minted;
        }
        assertEq(phaseTotal, keys.mintedByUsers());
        assertEq(
            keys.totalSupply() + keys.totalRefunded() + keys.totalBurned(),
            keys.mintedByUsers() + keys.mintedByTreasury()
        );
    }

    function invariant_EtherIsConservedAndRefundsStaySolvent() public view {
        assertEq(address(keys).balance + handler.returned() + handler.withdrawn(), handler.paid());
        uint256 historicalPayments;
        uint256 refundedPayments;
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        for (uint256 id = 1; id <= minted; ++id) {
            uint256 payment = keys.mintPayment(id);
            if (keys.originalMinter(id) == address(0)) assertEq(payment, 0);
            historicalPayments += payment;
            if (keys.refunded(id)) refundedPayments += payment;
        }
        assertEq(handler.paid(), historicalPayments);
        assertEq(handler.returned(), refundedPayments);
        if (!keys.soldOut()) {
            // v5: only kept payments may leave without a sellout; everything refundable stays in the contract.
            assertGe(address(keys).balance, historicalPayments - refundedPayments - keys.keptWithdrawn());
            assertEq(keys.keptFunds() >= keys.keptWithdrawn(), true);
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
        // Every actor is a Pioneer: one shared guarantee of the Pioneer limit across PIONEER and OPERATIVE.
        (, uint256 pioneerLimit,,,) = keys.phases(1);
        uint256 expected;
        for (uint256 i; i < 4; i++) {
            address actor = handler.actors(i);
            assertEq(keys.gtdMinted(actor), keys.mintedInPhase(1, actor) + keys.mintedInPhase(2, actor));
            if (keys.currentPhase() <= 2) expected += pioneerLimit - keys.gtdMinted(actor);
        }
        assertEq(keys.totalGtdReserved(), expected);
        assertLe(keys.totalGtdReserved() + keys.mintedByUsers(), keys.MAX_PUBLIC_SUPPLY());
    }

    function invariant_AllLiveTokensBelongToTrackedActors() public view {
        uint256 balance;
        for (uint256 i; i < 4; i++) {
            balance += keys.balanceOf(handler.actors(i));
        }
        assertEq(balance, keys.totalSupply());
    }
}
