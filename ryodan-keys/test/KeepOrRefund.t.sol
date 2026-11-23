// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeys} from "../src/RyodanKeys.sol";
import {RyodanKeysFixture, CallbackWallet} from "./RyodanKeys.t.sol";

/// Minter contract whose receive() burns all the gas it gets (audit finding, 19 nov).
contract GasBurner {
    RyodanKeys immutable keys;

    constructor(RyodanKeys k) {
        keys = k;
    }

    function buy(uint256 amount) external payable {
        keys.mint{value: msg.value}(amount, keys.currentPhase(), keys.mintPrice());
    }

    function pull(address payable to) external {
        keys.claimPendingRefund(to);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        while (true) {}
    }
}

/// v5 KEEP OR REFUND: without a sellout, original minters choose key by key during a 72h window.
contract KeepOrRefundTest is RyodanKeysFixture {
    event MetadataUpdate(uint256 _tokenId);

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _none() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// bob mints 1,2,3 · alice 4,5 · treasury 6..10 (token IDs start at 1) · then the deadline passes without a sellout
    function _failedSale() internal {
        _open(10);
        _buy(bob, 3);
        _buy(alice, 2);
        vm.prank(treasury);
        keys.treasuryMint(5, treasury);
        vm.warp(end + 1);
    }

    function test_SettleKeepsAndRefundsInOneTransaction() public {
        _failedSale();
        assertTrue(keys.choiceWindowOpen());
        vm.expectEmit(false, false, false, true);
        emit MetadataUpdate(1);
        vm.prank(bob);
        keys.settle(_ids(1), _ids2(2, 3));
        assertTrue(keys.kept(1));
        assertEq(keys.totalKept(), 1);
        assertEq(keys.keptFunds(), 0.01 ether);
        assertEq(bob.balance, 0.02 ether);
        assertEq(keys.ownerOf(1), bob);
        vm.expectRevert();
        keys.ownerOf(2);
    }

    function test_KeptKeyIsTransferableOthersStayLocked() public {
        _failedSale();
        vm.prank(bob);
        keys.settle(_ids(1), _none());
        vm.prank(bob);
        keys.transferFrom(bob, alice, 1);
        assertEq(keys.ownerOf(1), alice);
        vm.prank(bob);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.transferFrom(bob, alice, 2);
    }

    function test_KeptKeyIsNeverRefundable() public {
        _failedSale();
        vm.prank(bob);
        keys.settle(_ids(1), _none());
        vm.prank(bob);
        vm.expectRevert("Key kept");
        keys.refund(1);
        vm.warp(end + 4 days + 1);
        vm.expectRevert("Key kept");
        keys.refundBatch(_ids(1));
    }

    function test_DuringWindowOnlyTheMinterCanRefund() public {
        _failedSale();
        vm.expectRevert("Choice window open");
        keys.refund(4);
        vm.expectRevert("Choice window open");
        keys.refundBatch(_ids2(4, 5));
        vm.prank(alice);
        keys.refund(4);
        assertEq(alice.balance, 0.01 ether);
        vm.warp(end + 4 days + 1);
        assertFalse(keys.choiceWindowOpen());
        keys.refundBatch(_ids(5));
        assertEq(alice.balance, 0.02 ether);
    }

    function test_SettleOnlyByMinterAndOnlyInWindow() public {
        vm.expectRevert("Choice window closed");
        keys.settle(_ids(1), _none());
        _failedSale();
        vm.prank(alice);
        vm.expectRevert("Not original minter");
        keys.settle(_ids(1), _none());
        vm.prank(treasury);
        vm.expectRevert("Not original minter");
        keys.settle(_ids(6), _none());
        vm.prank(bob);
        vm.expectRevert("Invalid settle size");
        keys.settle(_none(), _none());
        vm.prank(bob);
        keys.settle(_ids(1), _none());
        vm.prank(bob);
        vm.expectRevert("Already decided");
        keys.settle(_ids(1), _none());
        vm.warp(end + 4 days + 1);
        vm.prank(bob);
        vm.expectRevert("Choice window closed");
        keys.settle(_ids(2), _none());
    }

    function test_TreasuryWithdrawsOnlyKeptFundsAndRefundsStaySolvent() public {
        _failedSale();
        vm.prank(bob);
        keys.settle(_ids2(1, 2), _none());
        vm.prank(treasury);
        keys.withdrawKept();
        assertEq(treasury.balance, 0.02 ether);
        vm.prank(treasury);
        vm.expectRevert("No balance to withdraw");
        keys.withdrawKept();
        vm.prank(treasury);
        vm.expectRevert("Not all tokens minted");
        keys.withdraw();
        vm.warp(end + 4 days + 1);
        uint256[] memory rest = new uint256[](3);
        rest[0] = 3;
        rest[1] = 4;
        rest[2] = 5;
        keys.refundBatch(rest);
        assertEq(address(keys).balance, 0);
        assertEq(bob.balance, 0.01 ether);
        assertEq(alice.balance, 0.02 ether);
    }

    function test_KeptKeysSwitchToNftMetadataByThemselves() public {
        _failedSale();
        assertEq(keys.tokenURI(1), "ipfs://sbt/1.json");
        vm.prank(bob);
        keys.settle(_ids(1), _none());
        assertEq(keys.tokenURI(1), "ipfs://nft/1.json");
        assertEq(keys.tokenURI(2), "ipfs://sbt/2.json");
        assertEq(keys.tokenURI(6), "ipfs://sbt/6.json");
    }

    function test_KeptKeyCanBeBurnedByOwnerOrApprovedLockedCannot() public {
        _failedSale();
        vm.prank(bob);
        keys.settle(_ids(1), _none());
        vm.prank(bob);
        vm.expectRevert("Key is locked");
        keys.burn(2);
        vm.prank(bob);
        keys.approve(alice, 1);
        uint256 balanceBefore = address(keys).balance;
        vm.prank(alice);
        keys.burn(1);
        assertEq(keys.totalBurned(), 1);
        assertEq(address(keys).balance, balanceBefore);
        vm.prank(treasury);
        vm.expectRevert("Key is locked");
        keys.burn(6);
    }

    function test_TreasuryKeysBurnOnlyAfterTheWindow() public {
        _failedSale();
        vm.prank(treasury);
        vm.expectRevert("Choice window not closed");
        keys.burnTreasuryKeys(_ids(6));
        vm.warp(end + 4 days + 1);
        vm.prank(bob);
        vm.expectRevert();
        keys.burnTreasuryKeys(_ids(6));
        vm.prank(treasury);
        vm.expectRevert("Not a treasury key");
        keys.burnTreasuryKeys(_ids(1));
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            ids[i] = 6 + i;
        }
        uint256 supplyBefore = keys.totalSupply();
        vm.prank(treasury);
        keys.burnTreasuryKeys(ids);
        assertEq(keys.totalSupply(), supplyBefore - 5);
        vm.expectRevert();
        keys.ownerOf(6);
    }

    function test_SoldOutHasNoWindowAndNoKeep() public {
        _sellOut();
        vm.warp(end + 1);
        assertFalse(keys.choiceWindowOpen());
        vm.prank(bob);
        vm.expectRevert("Choice window closed");
        keys.settle(_ids(1), _none());
    }

    function test_RejectingWalletDoesNotBlockBatchAndCanPull() public {
        _open(10);
        _buy(bob, 1);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.01 ether}(1);
        wallet.configure("", true, false);
        vm.warp(end + 4 days + 1);
        keys.refundBatch(_ids2(1, 2));
        assertEq(bob.balance, 0.01 ether);
        assertEq(keys.pendingRefund(address(wallet)), 0.01 ether);
        assertEq(keys.totalPendingRefund(), 0.01 ether);
        vm.expectRevert("Nothing pending");
        keys.claimPendingRefund(payable(alice));
        wallet.claimPending(payable(alice));
        assertEq(alice.balance, 0.01 ether);
        assertEq(address(keys).balance, 0);
    }

    function test_SingleRefundStillRevertsForRejectingWallet() public {
        _open(10);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.01 ether}(1);
        wallet.configure("", true, false);
        vm.warp(end + 4 days + 1);
        vm.expectRevert("Failed to send Ether");
        keys.refund(1);
        wallet.claimTo(1, payable(alice));
        assertEq(alice.balance, 0.01 ether);
    }

    function test_GasBurningMinterCannotStallABatch() public {
        _open(10);
        GasBurner burner = new GasBurner(keys);
        vm.deal(address(this), 1 ether);
        burner.buy{value: 0.01 ether}(1);
        for (uint256 i; i < 49; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            _buy(address(uint160(0x1000 + i)), 1);
        }
        vm.warp(end + 4 days + 1);
        uint256[] memory all = new uint256[](50);
        for (uint256 i; i < 50; i++) {
            all[i] = i + 1;
        }
        (bool ok,) = address(keys).call{gas: 16_000_000}(abi.encodeCall(keys.refundBatch, (all)));
        assertTrue(ok);
        assertEq(keys.totalRefunded(), 50);
        assertEq(keys.pendingRefund(address(burner)), 0.01 ether);
        assertEq(address(keys).balance, 0.01 ether);
        burner.pull(payable(alice));
        assertEq(alice.balance, 0.01 ether);
    }

    function test_TokenIdsStartAtOneTreasuryFirst() public {
        vm.prank(treasury);
        keys.treasuryMint(500, treasury);
        assertEq(keys.ownerOf(1), treasury);
        assertEq(keys.ownerOf(500), treasury);
        vm.expectRevert();
        keys.ownerOf(0);
        _open(10);
        _buy(bob, 1);
        assertEq(keys.ownerOf(501), bob);
        assertEq(keys.originalMinter(501), bob);
        assertEq(keys.tokenURI(501), "ipfs://sbt/501.json");
    }

    function test_SupplyIs6000Plus666() public view {
        assertEq(keys.MAX_PUBLIC_SUPPLY(), 6166);
        assertEq(keys.MAX_TREASURY_SUPPLY(), 500);
        assertEq(keys.MAX_SUPPLY(), 6666);
        assertEq(keys.CHOICE_WINDOW(), 4 days);
    }
}
