// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";
import {HeavyWallet, RejectETH} from "./Helpers.sol";

contract Handler is Test {
    RyodanKeys public keys;
    address public admin;
    address public treasury;
    address[] public actors;
    uint256 public end;
    bool public phaseOpen;
    uint256 public okMints;
    uint256 public okRefunds;
    uint256 public okKeeps;
    uint256 public okClaims;
    uint256 public okProceeds;

    constructor(RyodanKeys k, address a, address t, uint256 e) {
        keys = k;
        admin = a;
        treasury = t;
        end = e;
        actors.push(makeAddr("h1"));
        actors.push(makeAddr("h2"));
        actors.push(makeAddr("h3"));
        actors.push(makeAddr("h4"));
        for (uint256 i; i < actors.length; i++) {
            vm.deal(actors[i], 1000 ether);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function mint(uint256 who, uint256 amount) external {
        address a = actors[who % actors.length];
        uint8 ph = keys.currentPhase();
        if (ph == 0 || keys.mintPaused() || keys.soldOut()) return;
        amount = bound(amount, 1, 12);
        if (ph == 1 && amount % 2 != 0) amount += 1;
        if (amount > keys.remainingAllowance(ph, a)) return;
        uint256 price = keys.mintPrice();
        uint256 value = amount * price;
        vm.prank(a);
        try keys.mint{value: value}(amount, ph, price) {
            okMints++;
        } catch {}
    }

    function treasuryMint(uint256 amount) external {
        if (keys.mintEndTime() < block.timestamp) return;
        amount = bound(amount, 1, 50);
        vm.prank(treasury);
        try keys.treasuryMint(amount, treasury) {} catch {}
    }

    function advance() external {
        if (keys.currentPhase() >= 4) return;
        vm.prank(admin);
        try keys.advancePhase() {} catch {}
    }

    function unpause() external {
        if (keys.currentPhase() == 0) return;
        vm.prank(admin);
        try keys.setMintPaused(false) {} catch {}
    }

    function configure(uint256 limit, uint256 price) external {
        uint8 ph = keys.currentPhase();
        if (ph == 0 || ph > 4) return;
        limit = bound(limit, 1, 6166);
        if (ph == 1 && limit % 2 != 0) limit += 1;
        price = bound(price, 1, 0.1 ether);
        vm.prank(admin);
        try keys.configurePhase(ph, price, limit) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 5 days));
    }

    function refundOne(uint256 who, uint256 id) external {
        address a = actors[who % actors.length];
        id = bound(id, 1, 6666);
        vm.prank(a);
        try keys.refund(id) {
            okRefunds++;
        } catch {}
    }

    function refundBatchSome(uint256 from, uint256 count) external {
        count = bound(count, 1, 10);
        from = bound(from, 1, 6666);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = bound(from + i, 1, 6666);
        }
        try keys.refundBatch(ids) {} catch {}
    }

    function keepSome(uint256 who, uint256 id) external {
        address a = actors[who % actors.length];
        id = bound(id, 1, 6666);
        uint256[] memory keep = new uint256[](1);
        keep[0] = id;
        vm.prank(a);
        try keys.settle(keep, new uint256[](0)) {
            okKeeps++;
        } catch {}
    }

    function claim(uint256 who) external {
        address a = actors[who % actors.length];
        vm.prank(a);
        try keys.claimPendingRefund(payable(a)) {
            okClaims++;
        } catch {}
    }

    function withdrawProceeds() external {
        vm.prank(treasury);
        try keys.withdraw() {
            okProceeds++;
        } catch {}
    }

    function withdrawKept() external {
        vm.prank(treasury);
        try keys.withdrawKept() {} catch {}
    }

    function burnTreasury(uint256 from, uint256 count) external {
        count = bound(count, 1, 5);
        from = bound(from, 1, 6666);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = bound(from + i, 1, 6666);
        }
        vm.prank(treasury);
        try keys.burnTreasuryKeys(ids) {} catch {}
    }
}

contract Invariants is Test {
    RyodanKeys keys;
    Handler h;
    uint256 end;

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 10 days;
        keys = new RyodanKeys(end, "ipfs://sbt/", "ipfs://nft/", address(this), makeAddr("treasury"));
        keys.configureAllowlist(bytes32(0), keccak256("snap"), 0, 0, 0);
        keys.configurePhase(4, 0.01 ether, 50);
        keys.advancePhase();
        keys.setMintPaused(false);
        h = new Handler(keys, address(this), makeAddr("treasury"), end);
        targetContract(address(h));
    }

    function invariant_SupplyConsistent() public view {
        uint256 minted = keys.mintedByUsers() + keys.mintedByTreasury();
        assertEq(keys.totalSupply(), minted - keys.totalBurned() - keys.totalRefunded());
        assertLe(keys.mintedByUsers(), keys.MAX_PUBLIC_SUPPLY());
        assertLe(keys.mintedByTreasury(), keys.MAX_TREASURY_SUPPLY());
    }

    function invariant_EtherCoversLiabilities() public view {
        uint256 owed = keys.totalPendingRefund() + keys.keptFunds() - keys.keptWithdrawn();
        assertGe(address(keys).balance, owed);
    }

    function invariant_SoldOutNeverRefundable() public view {
        if (keys.soldOut()) assertFalse(keys.refundsAvailable());
    }

    function test_HandlerDrivesTheWholeLifecycle() public {
        for (uint256 i; i < 3; i++) {
            keys.advancePhase();
            keys.setMintPaused(false);
        }
        assertEq(keys.currentPhase(), 4);
        h.mint(0, 10);
        h.mint(1, 10);
        assertGt(h.okMints(), 0);
        h.treasuryMint(5);
        assertGt(keys.mintedByTreasury(), 0);
        vm.warp(end + 1);
        h.refundOne(0, 1);
        assertGt(h.okRefunds(), 0);
        h.keepSome(1, 11);
        assertGt(h.okKeeps(), 0);
        assertGe(address(keys).balance, keys.totalPendingRefund() + keys.keptFunds());
    }

    function invariant_RefundedNeverExceedMinted() public view {
        assertLe(keys.totalRefunded(), keys.mintedByUsers());
        assertLe(keys.totalBurned() + keys.totalRefunded(), keys.mintedByUsers() + keys.mintedByTreasury());
    }
}
