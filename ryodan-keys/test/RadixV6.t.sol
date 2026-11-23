// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture} from "./RyodanKeys.t.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";

contract CheapWallet {
    uint256 public hits;

    receive() external payable {
        hits += 1;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract Griefer6 {
    function grief(address target, uint256[] calldata ids, uint256 gas_) external returns (bool ok) {
        (ok,) = target.call{gas: gas_}(abi.encodeWithSignature("refundBatch(uint256[])", ids));
    }
}

contract Redeemer {
    function redeem(RyodanKeys k, uint256 id) external {
        k.burn(id);
    }
}

contract RadixV6Test is RyodanKeysFixture {
    function one(uint256 a) internal pure returns (uint256[] memory l) {
        l = new uint256[](1);
        l[0] = a;
    }

    function test_IdsRunFromOneTo6666TreasuryFirst() public {
        vm.prank(treasury);
        keys.treasuryMint(500, treasury);
        assertEq(keys.ownerOf(1), treasury);
        assertEq(keys.ownerOf(500), treasury);
        _open(6166);
        _buy(bob, 1);
        assertEq(keys.ownerOf(501), bob);
        assertEq(keys.originalMinter(501), bob);
        _buy(bob, 6165);
        assertEq(keys.ownerOf(6666), bob);
        assertTrue(keys.soldOut());
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        keys.ownerOf(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 6667));
        keys.ownerOf(6667);
    }

    function test_SelloutEmitsBatchUpdateOneTo6666() public {
        _open(6166);
        _buy(bob, 6166);
        vm.recordLogs();
        vm.prank(treasury);
        keys.treasuryMint(500, treasury);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("BatchMetadataUpdate(uint256,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(a, 1);
                assertEq(b, 6666);
                found++;
            }
        }
        assertEq(found, 1);
        assertEq(keys.tokenURI(1), "ipfs://nft/1.json");
        assertEq(keys.tokenURI(6666), "ipfs://nft/6666.json");
    }

    function test_NumberedUriFollowsStateAndRevertsWhenBurned() public {
        _open(10);
        _buy(bob, 3); // ids 1,2,3
        assertEq(keys.tokenURI(1), "ipfs://sbt/1.json");
        assertEq(keys.tokenURI(3), "ipfs://sbt/3.json");
        vm.warp(end + 1);
        vm.prank(bob);
        keys.settle(one(2), one(3));
        assertEq(keys.tokenURI(2), "ipfs://nft/2.json");
        assertEq(keys.tokenURI(1), "ipfs://sbt/1.json");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 3));
        keys.tokenURI(3);
        vm.prank(bob);
        keys.burn(2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        keys.tokenURI(2);
    }

    function test_ConstructorBaseUriRules() public {
        vm.expectRevert("Base URI must end with slash");
        new RyodanKeys(end, "ipfs://sbt", NFT, bob, treasury);
        vm.expectRevert("Base URI must end with slash");
        new RyodanKeys(end, HIDDEN, "/", bob, treasury);
        RyodanKeys k = new RyodanKeys(end, "ipfs://a/", "ar://b/", bob, treasury);
        assertEq(k.sbtBaseURI(), "ipfs://a/");
        assertEq(k.nftBaseURI(), "ar://b/");
    }

    function test_IdZeroAndOutOfRangeNeverRefundOrBurn() public {
        _open(10);
        _buy(bob, 1);
        vm.warp(end + 4 days + 1);
        vm.expectRevert("Token not eligible for refund");
        keys.refundBatch(one(0));
        vm.expectRevert("Token not eligible for refund");
        keys.refundBatch(one(6667));
        vm.prank(treasury);
        vm.expectRevert("Not a treasury key");
        keys.burnTreasuryKeys(one(0));
        keys.refundBatch(one(1));
        assertEq(keys.totalSupply(), 0);
    }

    function test_LowGasBatchCannotDeferCheapWallet() public {
        _open(10);
        CheapWallet w = new CheapWallet();
        uint256 price = keys.mintPrice();
        vm.deal(address(w), price);
        uint8 phaseId = keys.currentPhase();
        vm.prank(address(w));
        keys.mint{value: price}(1, phaseId, price);
        vm.warp(end + 4 days + 1);
        Griefer6 g = new Griefer6();
        uint256 deferrals;
        uint256 paid;
        for (uint256 gas_ = 20_000; gas_ < 400_000; gas_ += 250) {
            uint256 snap = vm.snapshotState();
            bool ok = g.grief(address(keys), one(1), gas_);
            if (ok && keys.pendingRefund(address(w)) > 0) deferrals++;
            if (ok && address(w).balance == price) paid++;
            vm.revertToState(snap);
        }
        assertEq(deferrals, 0);
        assertGt(paid, 0);
    }

    function test_RedeemerBurnNeedsApprovalAndUnlockedKey() public {
        _open(10);
        _buy(bob, 2);
        Redeemer r = new Redeemer();
        vm.prank(bob);
        keys.setApprovalForAll(address(r), true);
        vm.expectRevert("Key is locked");
        r.redeem(keys, 1);
        vm.warp(end + 1);
        uint256[] memory none = new uint256[](0);
        vm.prank(bob);
        keys.settle(one(1), none);
        r.redeem(keys, 1);
        assertEq(keys.totalBurned(), 1);
        vm.expectRevert("Key is locked");
        r.redeem(keys, 2);
    }
}
