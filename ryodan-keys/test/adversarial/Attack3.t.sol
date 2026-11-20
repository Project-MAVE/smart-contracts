// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fixture, RejectETH, Recorder, HeavyWallet, ReenterNFT, ReenterETH} from "./Helpers.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Vm} from "forge-std/Vm.sol";

contract G_Transfer is Fixture {
    function test_G01_LockedKeyCannotBeTransferred() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 1);
        vm.startPrank(bob);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.transferFrom(bob, address(0xAA), 1);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.safeTransferFrom(bob, address(0xAA), 1);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.transferFrom(bob, bob, 1);
        vm.stopPrank();
        assertEq(keys.ownerOf(1), bob);
    }

    function test_G02_ApprovalDoesNotUnlockTheKey() public {
        address bob = makeAddr("bob");
        address op = makeAddr("op");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 1);
        vm.prank(bob);
        keys.approve(op, 1);
        vm.prank(bob);
        keys.setApprovalForAll(op, true);
        vm.prank(op);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.transferFrom(bob, op, 1);
        assertEq(keys.ownerOf(1), bob);
        vm.prank(op);
        vm.expectRevert("Key is locked");
        keys.burn(1);
    }

    function test_G03_KeptKeyBecomesTransferable() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 1);
        _toEnd();
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(bob);
        keys.settle(keep, new uint256[](0));
        vm.prank(bob);
        keys.transferFrom(bob, address(0xAA), 1);
        assertEq(keys.ownerOf(1), address(0xAA));
        vm.prank(address(0xAA));
        vm.expectRevert("Key kept");
        keys.refund(1);
    }

    function test_G04_SoldOutKeysAreTransferable() public {
        _sellOut(address(0xAA));
        vm.prank(address(0xAA));
        keys.transferFrom(address(0xAA), address(0xBB), 1);
        assertEq(keys.ownerOf(1), address(0xBB));
        vm.prank(address(0xBB));
        keys.burn(1);
        assertEq(keys.totalSupply(), 6665);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        keys.ownerOf(1);
    }
}

contract H_Metadata is Fixture {
    function test_H01_UriSwitchOnKeepAndSellout() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 2);
        assertEq(keys.tokenURI(1), "ipfs://sbt/1.json");
        _toEnd();
        uint256[] memory keep = new uint256[](1);
        keep[0] = 1;
        vm.prank(bob);
        keys.settle(keep, new uint256[](0));
        assertEq(keys.tokenURI(1), "ipfs://nft/1.json");
        assertEq(keys.tokenURI(2), "ipfs://sbt/2.json");
    }

    function test_H03_BurnedTokenHasNoUri() public {
        address bob = makeAddr("bob");
        _openCivilian(10, 0.01 ether);
        _buy(bob, 1);
        _toEnd();
        vm.prank(bob);
        keys.refund(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        keys.tokenURI(1);
    }

    function test_H04_SelloutAnnouncementOnlyAt6666() public {
        address collector = makeAddr("collector");
        _openCivilian(6000, 0.01 ether);
        vm.recordLogs();
        _buy(collector, 10);
        bytes32 sig = keccak256("BatchMetadataUpdate(uint256,uint256)");
        uint256 seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) seen++;
        }
        assertEq(seen, 0);
        _buy(collector, 5990);
        logs = vm.getRecordedLogs();
        seen = 0;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) seen++;
        }
        assertEq(seen, 0);
        vm.recordLogs();
        vm.prank(treasury);
        keys.treasuryMint(666, treasury);
        logs = vm.getRecordedLogs();
        seen = 0;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) seen++;
        }
        assertEq(seen, 1);
    }
}

contract I_MeV is Fixture {
    function test_I01_PhaseAdvanceInvalidatesStaleQuoteWithoutLoss() public {
        address bob = makeAddr("bob");
        bytes32 l = _leaf(bob, 1);
        keys.configureAllowlist(l, keccak256("snap"), 1, 0, 0);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.configurePhase(2, 0.03 ether, 10);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.06 ether}(4, 1, 0.015 ether, 1, new bytes32[](0));
        keys.advancePhase();
        keys.setMintPaused(false);
        uint256 before = bob.balance;
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.03 ether}(1, 1, 0.015 ether);
        assertEq(bob.balance, before);
    }

    function test_I02_MintMustBeExactPayment() public {
        _openCivilian(10, 0.01 ether);
        vm.deal(address(0xAA), 1 ether);
        vm.prank(address(0xAA));
        vm.expectRevert("Incorrect payment");
        keys.mint{value: 0.009 ether}(1, 4, 0.01 ether);
        vm.prank(address(0xAA));
        vm.expectRevert("Incorrect payment");
        keys.mint{value: 0.011 ether}(1, 4, 0.01 ether);
    }

    function test_I03_SingleWalletCanMintItsFullLifetimeAllocation() public {
        address bob = makeAddr("bob");
        bytes32 l = _leaf(bob, 1);
        keys.configureAllowlist(l, keccak256("snap"), 1, 0, 0);
        keys.configurePhase(1, 0.015 ether, 4);
        keys.configurePhase(2, 0.03 ether, 10);
        keys.configurePhase(3, 0.035 ether, 10);
        keys.configurePhase(4, 0.04 ether, 10);
        keys.advancePhase();
        keys.setMintPaused(false);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        keys.mintWithProof{value: 0.06 ether}(4, 1, 0.015 ether, 1, new bytes32[](0));
        while (keys.currentPhase() < 4) {
            keys.advancePhase();
            keys.setMintPaused(false);
            uint256 n = 10;
            uint8 ph = keys.currentPhase();
            uint256 price = keys.mintPrice();
            vm.prank(bob);
            keys.mint{value: n * price}(n, ph, price);
        }
        assertEq(keys.mintedAmount(bob), 34);
    }
}

