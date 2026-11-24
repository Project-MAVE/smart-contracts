// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";

/// The definitive 2026-11-24 allowlist asks for more keys than the paid supply: keys go in order of arrival.
///
///   FOUNDRY_PROFILE=fork FINAL_LIST_FIXTURE=fixtures/final-v8.bin forge test --match-path test/fork/FinalListFcfs.t.sol
///
/// The fixture is built with console/scripts/allowlist-fixture.mjs. Without FINAL_LIST_FIXTURE the tests are skipped.
contract FinalListFcfsTest is Test {
    struct List {
        bytes32 root;
        bytes32 snapshotHash;
        uint256 pioneers;
        uint256 operatives;
        uint256 recruits;
        address[] accounts;
        bytes32[][] proofs;
    }

    RyodanKeys keys;
    address treasury = makeAddr("treasury");
    string fixturePath;

    modifier withFixture() {
        fixturePath = vm.envOr("FINAL_LIST_FIXTURE", string(""));
        if (bytes(fixturePath).length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function configure() private returns (List memory list) {
        list = abi.decode(vm.readFileBinary(fixturePath), (List));
        assertEq(list.root, 0x2a19f9ca68d2a0630ce1ebd9842e9e359d31054a708cd4aabc2d411a72bb51b4);
        assertEq(list.snapshotHash, 0xa49a0a4717ed59a01c4b2a53fd1b1e4d2ec33e0480b6a03fd83261bb42b44bed);
        assertEq(list.accounts.length, 7259);
        assertEq(list.proofs.length, 7259);
        assertEq(list.pioneers, 105);
        assertEq(list.operatives, 1455);
        assertEq(list.recruits, 5699);
        keys = new RyodanKeys(block.timestamp + 2 days, "ipfs://sbt/", "ipfs://nft/", address(this), treasury);
        keys.configureAllowlist(list.root, list.snapshotHash, list.pioneers, list.operatives, list.recruits);
        assertTrue(keys.allowlistConfigured());
        assertEq(keys.allowlistRoot(), list.root);
        assertEq(keys.totalGtdReserved(), 6000);
    }

    function openNext() private {
        keys.advancePhase();
        keys.setMintPaused(false);
    }

    function buy(List memory list, uint256 i, uint8 phase, uint8 tier, uint256 n, bool exhausted) private {
        uint256 price = keys.mintPrice();
        vm.deal(list.accounts[i], price * n);
        if (exhausted) vm.expectRevert("Max supply reached");
        vm.prank(list.accounts[i]);
        keys.mintWithProof{value: price * n}(n, phase, price, tier, list.proofs[i]);
    }

    function test_FinalListFirstComeFirstServed() public withFixture {
        List memory list = configure();
        openNext();
        for (uint256 i; i < list.pioneers; i++) {
            buy(list, i, 1, 1, 4, false);
        }
        openNext();
        for (uint256 i = list.pioneers; i < 1500; i++) {
            buy(list, i, 2, 2, 4, false);
        }
        assertEq(keys.mintedByUsers(), 6000);
        assertEq(keys.totalGtdReserved(), 0);
        uint256 end = list.pioneers + list.operatives;
        assertEq((end - 1500) * 4, 240);
        for (uint256 i = 1500; i < end; i++) {
            buy(list, i, 2, 2, 1, true);
        }
        openNext();
        buy(list, end, 3, 3, 1, true);
        assertEq(keys.mintedByTreasury(), 0);
        vm.startPrank(treasury);
        for (uint256 i; i < 6; i++) {
            keys.treasuryMint(100, treasury);
        }
        keys.treasuryMint(66, treasury);
        vm.expectRevert("Max supply reached while minting to treasury");
        keys.treasuryMint(1, treasury);
        vm.stopPrank();
        assertEq(keys.balanceOf(treasury), 666);
        assertEq(keys.totalSupply(), 6666);
        assertTrue(keys.soldOut());
    }

    function test_UnsoldKeysReachCivilian() public withFixture {
        List memory list = configure();
        openNext();
        buy(list, 0, 1, 1, 2, false);
        openNext();
        buy(list, 0, 2, 1, 2, false);
        openNext();
        assertEq(keys.totalGtdReserved(), 0);
        buy(list, list.pioneers + list.operatives, 3, 3, 1, false);
        openNext();
        address buyer = makeAddr("public");
        uint256 price = keys.mintPrice();
        vm.deal(buyer, price);
        vm.prank(buyer);
        keys.mint{value: price}(1, 4, price);
        assertEq(keys.mintedByUsers(), 6);
    }
}
