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
        keys.setPublicMintActive(true, 5900);
    }

    function mintPaid(uint256 actorSeed, uint256 amountSeed) external {
        if (block.timestamp > keys.mintEndTime()) return;
        if (!keys.isPublicMintActive() && !keys.isWhitelistMintActive()) return;
        address actor = actors[actorSeed % actors.length];
        if (keys.isWhitelistMintActive() && !keys.whitelisted(actor)) return;
        uint256 available = keys.MAX_PUBLIC_SUPPLY() - keys.mintedByUsers();
        uint256 walletAvailable = keys.MAX_MINT_AMOUNT() - keys.mintedAmount(actor);
        if (walletAvailable < available) available = walletAvailable;
        if (keys.isWhitelistMintActive()) {
            uint256 whitelistAvailable = keys.WL_MINT_AMOUNT() - keys.mintedByWhitelist();
            if (whitelistAvailable < available) available = whitelistAvailable;
        }
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available > 30 ? 30 : available);
        uint256 value = amount * keys.mintPrice();
        vm.deal(actor, actor.balance + value);
        vm.prank(actor);
        keys.mint{value: value}(amount);
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
        address[] memory accounts = new address[](1);
        accounts[0] = actors[seed % actors.length];
        if (seed % 2 == 0) keys.addToWhitelist(accounts);
        else keys.removeFromWhitelist(accounts);
        if (seed % 3 == 0) {
            keys.setPublicMintActive(true, 5900);
        } else if (seed % 3 == 1) {
            keys.setWhitelistMintActive(true, 5900);
        } else {
            keys.setPublicMintActive(false, 5900);
            keys.setWhitelistMintActive(false, 5900);
        }
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
        vm.prank(minter);
        keys.refundTo(id, payable(actors[recipientSeed % actors.length]));
        returned += keys.mintPrice();
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
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.mintPaid.selector;
        selectors[1] = handler.mintTreasury.selector;
        selectors[2] = handler.changePhaseAndWhitelist.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.refundPaid.selector;
        selectors[5] = handler.invalidRefund.selector;
        selectors[6] = handler.attemptTransfer.selector;
        selectors[7] = handler.withdrawIfSuccessful.selector;
        selectors[8] = handler.changeDeadline.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyAndCapsRemainConsistent() public view {
        assertLe(keys.mintedByUsers(), 5900);
        assertLe(keys.mintedByTreasury(), 500);
        assertLe(keys.mintedByWhitelist(), 1000);
        assertLe(keys.mintedByWhitelist(), keys.mintedByUsers());
        assertEq(keys.totalSupply() + keys.totalRefunded(), keys.mintedByUsers() + keys.mintedByTreasury());
    }

    function invariant_EtherIsConservedAndRefundsStaySolvent() public view {
        assertEq(address(keys).balance + handler.returned() + handler.withdrawn(), handler.paid());
        assertEq(handler.paid(), keys.mintedByUsers() * keys.mintPrice());
        assertEq(handler.returned(), keys.totalRefunded() * keys.mintPrice());
        if (!keys.soldOut()) {
            assertGe(address(keys).balance, (keys.mintedByUsers() - keys.totalRefunded()) * keys.mintPrice());
        }
    }

    function invariant_PhasesNeverOverlap() public view {
        assertFalse(keys.isPublicMintActive() && keys.isWhitelistMintActive());
    }

    function invariant_AllLiveTokensBelongToTrackedActors() public view {
        uint256 balance;
        for (uint256 i; i < 4; i++) {
            balance += keys.balanceOf(handler.actors(i));
        }
        assertEq(balance, keys.totalSupply());
    }
}
