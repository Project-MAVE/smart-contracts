// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture, CallbackWallet} from "./RyodanKeys.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

abstract contract ListedFixture is RyodanKeysFixture {
    address[] internal listedAccounts;
    uint8[] internal listedTiers;
    bytes32[] internal leaves;

    function _leaf(address account, uint8 tier) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, tier))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _lists(address[] memory accounts, uint8[] memory tiers) internal {
        listedAccounts = accounts;
        listedTiers = tiers;
        delete leaves;
        uint256[4] memory counts;
        bytes32[] memory level = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; i++) {
            level[i] = _leaf(accounts[i], tiers[i]);
            leaves.push(level[i]);
            counts[tiers[i]]++;
        }
        uint256 size = level.length;
        while (size > 1) {
            for (uint256 i; i < size; i += 2) {
                level[i / 2] = i + 1 < size ? _pair(level[i], level[i + 1]) : level[i];
            }
            size = (size + 1) / 2;
        }
        keys.configureAllowlist(
            size == 0 ? bytes32(0) : level[0], keccak256(abi.encode(accounts, tiers)), counts[1], counts[2], counts[3]
        );
    }

    function _one(address account, uint8 tier) internal {
        address[] memory accounts = new address[](1);
        uint8[] memory tiers = new uint8[](1);
        accounts[0] = account;
        tiers[0] = tier;
        _lists(accounts, tiers);
    }

    function _three() internal {
        address[] memory accounts = new address[](3);
        uint8[] memory tiers = new uint8[](3);
        accounts[0] = bob;
        accounts[1] = alice;
        accounts[2] = treasury;
        tiers[0] = 1;
        tiers[1] = 2;
        tiers[2] = 3;
        _lists(accounts, tiers);
    }

    function _proof(address account) internal view returns (uint8 tier, bytes32[] memory proof) {
        uint256 index;
        while (index < listedAccounts.length && listedAccounts[index] != account) index++;
        require(index < listedAccounts.length, "Unknown fixture account");
        tier = listedTiers[index];
        bytes32[] memory level = leaves;
        bytes32[] memory siblings = new bytes32[](32);
        uint256 depth;
        uint256 size = level.length;
        while (size > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < size) siblings[depth++] = level[sibling];
            for (uint256 i; i < size; i += 2) {
                level[i / 2] = i + 1 < size ? _pair(level[i], level[i + 1]) : level[i];
            }
            size = (size + 1) / 2;
            index /= 2;
        }
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; i++) {
            proof[i] = siblings[i];
        }
    }

    function _mintListed(address account, uint256 amount) internal {
        _mintListed(account, amount, "");
    }

    function _mintListed(address account, uint256 amount, string memory expectedError) internal {
        (uint8 tier, bytes32[] memory proof) = _proof(account);
        uint256 price = keys.mintPrice();
        uint8 phaseId = keys.currentPhase();
        vm.deal(account, account.balance + amount * price);
        vm.prank(account);
        if (bytes(expectedError).length != 0) vm.expectRevert(bytes(expectedError));
        keys.mintWithProof{value: amount * price}(amount, phaseId, price, tier, proof);
    }

    function _next() internal {
        if (!keys.allowlistConfigured()) keys.configureAllowlist(bytes32(0), keccak256("empty"), 0, 0, 0);
        keys.advancePhase();
        keys.setMintPaused(false);
    }
}

contract PhasesTest is ListedFixture {
    function test_ClientDefaultsAndSupply() public view {
        uint256[4] memory prices = [uint256(0.0075 ether), 0.012 ether, 0.0135 ether, 0.015 ether];
        uint256[4] memory limits = [uint256(4), 4, 10, 20];
        for (uint8 id = 1; id <= 4; id++) {
            (uint256 price, uint256 limit,,,) = keys.phases(id);
            assertEq(price, prices[id - 1]);
            assertEq(limit, limits[id - 1]);
        }
        assertEq(keys.CONTRACT_VERSION(), 7);
        assertEq(keys.MAX_SUPPLY(), 6666);
        assertEq(keys.MAX_PUBLIC_SUPPLY(), 6166);
        assertEq(keys.MAX_TREASURY_SUPPLY(), 500);
        assertEq(keys.CHOICE_WINDOW(), 4 days);
    }

    function test_PioneerInheritsLaterListsAndCanMint34WithoutDuplicateEntries() public {
        _one(bob, 1);
        assertEq(keys.totalGtdReserved(), 4);
        uint256[4] memory amounts = [uint256(4), 0, 10, 20];
        for (uint8 id = 1; id <= 4; id++) {
            _next();
            if (amounts[id - 1] > 0) _mintListed(bob, amounts[id - 1]);
            else _mintListed(bob, 1, "Max mint amount reached for address");
            assertEq(keys.remainingAllowance(id, bob), 0);
            assertEq(keys.mintedInPhase(id, bob), amounts[id - 1]);
        }
        assertEq(keys.balanceOf(bob), 34);
        assertEq(keys.ownerOf(34), bob);
        assertEq(address(keys).balance, 0.465 ether);
        assertEq(keys.registeredMembers(1), 1);
    }

    function test_PioneerSharesFourGuaranteedKeysAcrossPioneerAndOperative() public {
        _three();
        assertEq(keys.totalGtdReserved(), 8);
        _next();
        _mintListed(bob, 1);
        assertEq(keys.totalGtdReserved(), 7);
        _next();
        // The three unused Pioneer keys stay reserved in OPERATIVE and only bob can draw on them.
        assertEq(keys.totalGtdReserved(), 7);
        (uint256 pioneerPrice,,,,) = keys.phases(1);
        assertEq(pioneerPrice, 0.0075 ether);
        assertEq(keys.gtdMinted(bob), 1);
        assertEq(keys.remainingAllowance(2, bob), 3);
        assertEq(keys.remainingAllowance(2, alice), 0);
        _mintListed(bob, 4, "Max mint amount reached for address");
        _mintListed(bob, 3);
        assertEq(keys.remainingAllowance(2, bob), 0);
        _mintListed(alice, 4);
        assertEq(keys.totalGtdReserved(), 0);
        assertEq(keys.mintPayment(1), 0.0075 ether);
        assertEq(keys.mintPayment(2), 0.012 ether);
        _next();
        assertEq(keys.remainingAllowance(3, bob), 10);
    }

    function test_ClientListsFitTheGuaranteedSupply() public {
        keys.configureAllowlist(bytes32(uint256(1)), keccak256("23-nov"), 100, 1403, 5705);
        assertEq(keys.totalGtdReserved(), 6012);
        RyodanKeys other = new RyodanKeys(end, HIDDEN, NFT, address(this), treasury);
        vm.expectRevert("Insufficient GTD supply");
        other.configureAllowlist(bytes32(uint256(1)), keccak256("too-many"), 100, 1442, 0);
    }

    function test_ThreeExclusiveTiersEnforceHierarchyAndProofsBeforeFirstMint() public {
        _three();
        assertEq(keys.totalGtdReserved(), 8);
        (uint8 tier, bytes32[] memory proof) = _proof(bob);
        assertEq(keys.remainingAllowance(1, bob), 0);
        assertEq(keys.remainingAllowanceWithProof(1, bob, tier, proof), 4);
        assertFalse(keys.verifyEligibility(alice, tier, proof));
        assertFalse(keys.verifyEligibility(bob, 2, proof));
        _next();
        _mintListed(alice, 2, "Not allowlisted");
        assertEq(keys.walletTier(alice), 0);
        _mintListed(bob, 2);
        _next();
        _mintListed(alice, 4);
        _buy(bob, 2);
        _mintListed(treasury, 1, "Not allowlisted");
        _next();
        _mintListed(treasury, 10);
        _buy(alice, 10);
        _buy(bob, 10);
        assertEq(keys.registeredMembers(1), 1);
        assertEq(keys.registeredMembers(2), 1);
        assertEq(keys.registeredMembers(3), 1);
    }

    function test_PioneerAcceptsAnyQuantityUpToItsLimit() public {
        keys.configurePhase(1, 0.0075 ether, 5);
        keys.configurePhase(1, 0.0075 ether, 4);
        _one(bob, 1);
        _next();
        _mintListed(bob, 1);
        _mintListed(bob, 3);
        _mintListed(bob, 1, "Max mint amount reached for address");
        assertEq(keys.mintPayment(1), 0.0075 ether);
        assertEq(address(keys).balance, 0.03 ether);
    }

    function test_InvalidProofCannotConsumeFundsOrRegisterTier() public {
        _three();
        _next();
        (, bytes32[] memory proof) = _proof(bob);
        proof[0] = bytes32(uint256(123));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Invalid allowlist proof");
        keys.mintWithProof{value: 0.015 ether}(2, 1, 0.0075 ether, 1, proof);
        assertEq(keys.walletTier(bob), 0);
        assertEq(keys.registeredMembers(1), 0);
        assertEq(keys.totalGtdReserved(), 8);
        assertEq(address(keys).balance, 0);
        assertFalse(keys.verifyEligibility(address(0), 1, proof));
        assertFalse(keys.verifyEligibility(bob, 0, proof));
        assertFalse(keys.verifyEligibility(bob, 4, proof));
    }

    function test_SnapshotCanBeReplacedBeforeOpeningAndIsFrozenAfterStart() public {
        _one(bob, 1);
        bytes32 previous = keys.allowlistRoot();
        _one(alice, 2);
        assertNotEq(previous, keys.allowlistRoot());
        assertEq(keys.totalGtdReserved(), 4);
        _next();
        vm.expectRevert("Allowlist frozen");
        keys.configureAllowlist(previous, keccak256("changed"), 1, 0, 0);
    }

    function test_PhasesRequireSnapshotAndAdvanceOnlyInOrderWhilePausing() public {
        vm.expectRevert("Configure allowlist first");
        keys.advancePhase();
        _one(bob, 1);
        for (uint8 id = 1; id <= 4; id++) {
            keys.advancePhase();
            assertEq(keys.currentPhase(), id);
            assertTrue(keys.mintPaused());
            keys.setMintPaused(false);
        }
        vm.expectRevert("Final phase reached");
        keys.advancePhase();
        vm.expectRevert("Phases locked");
        keys.configurePhase(4, 1, 4);
    }

    function test_CannotSelectAnotherPhaseEvenWithIdenticalPrice() public {
        _one(bob, 1);
        keys.configurePhase(2, 0.025 ether, 10);
        _next();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mintWithProof{value: 0.05 ether}(2, 2, 0.025 ether, 1, new bytes32[](0));
        _mintListed(bob, 2);
        _next();
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.05 ether}(2, 1, 0.025 ether);
    }

    function test_PriceChangesPreserveOriginalPaymentsAndRejectOldQuote() public {
        _one(bob, 1);
        _next();
        _mintListed(bob, 2);
        vm.expectRevert("Phases locked");
        keys.configurePhase(1, 0.03 ether, 4);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Mint quote changed");
        keys.mint{value: 0.06 ether}(2, 1, 0.03 ether);
        _next();
        _buy(bob, 2);
        vm.warp(end + 4 days + 1);
        uint256 beforeBalance = bob.balance;
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; i++) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        keys.refundBatch(ids);
        assertEq(bob.balance - beforeBalance, 0.039 ether);
        assertEq(address(keys).balance, 0);
    }

    function test_GtdLimitsResizeBothInheritedAllocationsWithoutResettingUsage() public {
        _three();
        keys.configurePhase(1, 0.0075 ether, 6);
        assertEq(keys.totalGtdReserved(), 10);
        keys.configurePhase(2, 0.012 ether, 12);
        assertEq(keys.totalGtdReserved(), 18);
        _next();
        vm.expectRevert("Phases locked");
        keys.configurePhase(2, 0.012 ether, 4);
        _mintListed(bob, 2);
        assertEq(keys.totalGtdReserved(), 16);
        _next();
        assertEq(keys.totalGtdReserved(), 16);
        assertEq(keys.remainingAllowance(2, bob), 4);
        _buy(bob, 4);
        _mintListed(alice, 12);
        assertEq(keys.totalGtdReserved(), 0);
        _next();
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_GtdOverbookingRejectedAtSnapshotAndQuotaUpdate() public {
        vm.expectRevert("Insufficient GTD supply");
        keys.configureAllowlist(bytes32(uint256(1)), keccak256("large"), 1542, 0, 0);
        assertFalse(keys.allowlistConfigured());
        _three();
        vm.expectRevert("Insufficient GTD supply");
        keys.configurePhase(1, 1, 6166);
        assertEq(keys.totalGtdReserved(), 8);
    }

    function test_ExactGtdCapacityIsUsableAcrossInheritedTiers() public {
        address[] memory accounts = new address[](2);
        uint8[] memory tiers = new uint8[](2);
        accounts[0] = bob;
        accounts[1] = alice;
        tiers[0] = 1;
        tiers[1] = 2;
        keys.configurePhase(1, 1, 3083);
        keys.configurePhase(2, 1, 3083);
        _lists(accounts, tiers);
        assertEq(keys.totalGtdReserved(), 6166);
        _next();
        _mintListed(bob, 2000);
        _next();
        assertEq(keys.totalGtdReserved(), 4166);
        _buy(bob, 1083);
        _mintListed(alice, 3083);
        assertEq(keys.mintedByUsers(), 6166);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_UnusedGuaranteesReleaseAndCivilianReceivesRemainder() public {
        keys.configurePhase(4, 1, 6166);
        _three();
        _next();
        _mintListed(bob, 2);
        _next();
        assertEq(keys.totalGtdReserved(), 6);
        _mintListed(alice, 3);
        _next();
        assertEq(keys.totalGtdReserved(), 0);
        _mintListed(treasury, 4);
        _next();
        _buy(bob, 6157);
        assertEq(keys.mintedByUsers(), 6166);
        assertEq(keys.remainingAllowance(1, bob), 0);
    }

    function test_RecruitIsFcfsAndCannotExceedRemainingSupply() public {
        _one(bob, 3);
        assertEq(keys.totalGtdReserved(), 0);
        keys.configurePhase(3, 1, 6166);
        _next();
        _next();
        _next();
        _mintListed(bob, 6166);
        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert("Max supply reached");
        keys.mint{value: 1}(1, 3, 1);
    }

    function test_InvalidSnapshotAndConfigurationRejected() public {
        vm.expectRevert("Root and counts mismatch");
        keys.configureAllowlist(bytes32(0), keccak256("x"), 1, 0, 0);
        vm.expectRevert("Root and counts mismatch");
        keys.configureAllowlist(bytes32(uint256(1)), keccak256("x"), 0, 0, 0);
        vm.expectRevert("Empty snapshot hash");
        keys.configureAllowlist(bytes32(0), bytes32(0), 0, 0, 0);
        vm.expectRevert("Invalid phase");
        keys.configurePhase(0, 1, 2);
        vm.expectRevert("Invalid phase");
        keys.configurePhase(5, 1, 2);
        vm.expectRevert("Invalid price");
        keys.configurePhase(1, 0, 2);
        vm.expectRevert("Invalid price");
        keys.configurePhase(1, type(uint256).max, 2);
        vm.expectRevert("No active phase");
        keys.setMintPaused(false);
        assertEq(keys.remainingAllowance(0, bob), 0);
        assertEq(keys.remainingAllowance(5, bob), 0);
    }

    function test_LimitsAndPricesAreLockedOnceTheSaleOpens() public {
        _open(10);
        _buy(bob, 5);
        vm.expectRevert("Phases locked");
        keys.configurePhase(4, 1, 2);
        vm.expectRevert("Phases locked");
        keys.configurePhase(4, 1, 6166);
        assertEq(keys.remainingAllowance(4, bob), 5);
    }

    function test_ReceiverRejectionRollsBackProofRegistrationAndGuarantees() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        _one(address(wallet), 1);
        _next();
        wallet.configure("", false, true);
        vm.deal(address(this), 1 ether);
        vm.expectRevert("NFT rejected");
        wallet.buyWithProof{value: 0.015 ether}(2, 1, new bytes32[](0));
        assertEq(keys.walletTier(address(wallet)), 0);
        assertEq(keys.registeredMembers(1), 0);
        assertEq(keys.totalGtdReserved(), 4);
        assertEq(address(keys).balance, 0);
    }

    function test_AdminReceiverCannotReenterSaleMutators() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        _one(address(wallet), 1);
        keys.configurePhase(1, 0.0075 ether, 8);
        _next();
        keys.beginDefaultAdminTransfer(address(wallet));
        vm.warp(block.timestamp + 1);
        vm.prank(address(wallet));
        keys.acceptDefaultAdminTransfer();
        assertTrue(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), address(wallet)));
        bytes[4] memory calls = [
            abi.encodeCall(keys.configurePhase, (1, 1, 100)),
            abi.encodeCall(keys.advancePhase, ()),
            abi.encodeCall(keys.setMintPaused, (true)),
            abi.encodeCall(keys.configureAllowlist, (bytes32(0), keccak256("empty"), 0, 0, 0))
        ];
        vm.deal(address(this), 1 ether);
        for (uint256 i; i < 4; i++) {
            wallet.configure(calls[i], false, false);
            wallet.buyWithProof{value: 0.015 ether}(2, 1, new bytes32[](0));
            assertFalse(wallet.reentered());
            assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        }
        assertEq(keys.currentPhase(), 1);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_ExpiryAndSelloutKeepConfigurationLocked() public {
        _next();
        vm.warp(end + 4 days + 1);
        vm.expectRevert("Mint ended");
        keys.advancePhase();
        vm.expectRevert("Mint ended");
        keys.setMintPaused(false);
        vm.expectRevert("Phases locked");
        keys.configurePhase(2, 1, 10);
        vm.expectRevert("Mint ended");
        keys.configureAllowlist(bytes32(0), keccak256("x"), 0, 0, 0);
    }

    function testFuzz_PioneerMintsAnyQuantityUpToItsLimit(uint256 amountSeed, uint256 limitSeed) public {
        uint256 cap = bound(limitSeed, 1, 60);
        keys.configurePhase(1, 7, cap);
        _one(bob, 1);
        _next();
        uint256 amount = bound(amountSeed, 1, cap);
        _mintListed(bob, amount);
        assertEq(keys.mintedByUsers(), amount);
        assertEq(keys.totalGtdReserved(), cap - amount);
        _next();
        assertEq(keys.remainingAllowance(2, bob), cap - amount < 4 ? cap - amount : 4);
    }

    function testFuzz_IndependentLimitsAndOriginalRefunds(uint256 seed, uint256 priceSeed) public {
        uint256[5] memory caps;
        uint256[5] memory prices;
        for (uint8 id = 1; id <= 4; id++) {
            caps[id] = 1 + uint256(keccak256(abi.encode(seed, id))) % 10;
            prices[id] = 1 + uint256(keccak256(abi.encode(priceSeed, id))) % 0.1 ether;
            keys.configurePhase(id, prices[id], caps[id]);
        }
        _one(bob, 1);
        uint256 paid;
        uint256 minted;
        for (uint8 id = 1; id <= 4; id++) {
            _next();
            uint256 amount = id == 2 ? 0 : caps[id];
            if (id > 1) assertEq(keys.remainingAllowance(id, bob), amount);
            if (amount > 0) _mintListed(bob, amount);
            else _mintListed(bob, 1, "Max mint amount reached for address");
            paid += prices[id] * amount;
            minted += amount;
            assertEq(keys.remainingAllowance(id, bob), 0);
        }
        vm.warp(end + 4 days + 1);
        uint256 beforeBalance = bob.balance;
        uint256[] memory ids = new uint256[](minted);
        for (uint256 id; id < minted; id++) {
            ids[id] = minted - id;
        }
        vm.prank(alice);
        keys.refundBatch(ids);
        assertEq(bob.balance - beforeBalance, paid);
        assertEq(address(keys).balance, 0);
        assertEq(keys.totalSupply(), 0);
    }

    function test_ProofViewsHandleClosedInvalidAndExhaustedWallets() public {
        _one(bob, 1);
        bytes32[] memory proof = new bytes32[](0);
        assertEq(keys.remainingAllowanceWithProof(4, bob, 1, proof), 20);
        assertEq(keys.remainingAllowanceWithProof(2, bob, 1, proof), 4);
        assertEq(keys.remainingAllowanceWithProof(0, bob, 1, proof), 0);
        assertEq(keys.remainingAllowanceWithProof(5, bob, 1, proof), 0);
        assertEq(keys.remainingAllowanceWithProof(1, alice, 1, proof), 0);
        assertFalse(keys.allowlisted(1, bob));
        _next();
        _mintListed(bob, 4);
        assertEq(keys.remainingAllowanceWithProof(1, bob, 1, proof), 0);
        assertTrue(keys.allowlisted(1, bob));
        assertTrue(keys.allowlisted(2, bob));
        assertTrue(keys.allowlisted(3, bob));
        assertFalse(keys.allowlisted(0, bob));
        assertFalse(keys.allowlisted(4, bob));
        _next();
        assertEq(keys.remainingAllowanceWithProof(1, bob, 1, proof), 0);
    }

    function test_ProofMintBeforeStartRejected() public {
        _one(bob, 1);
        vm.prank(bob);
        vm.expectRevert("Mint not active");
        keys.mintWithProof(2, 1, 0.025 ether, 1, new bytes32[](0));
    }

    function test_UnderstatedMemberCountCannotOversubscribeGuarantees() public {
        address[] memory accounts = new address[](2);
        uint8[] memory tiers = new uint8[](2);
        accounts[0] = bob;
        accounts[1] = alice;
        tiers[0] = 1;
        tiers[1] = 1;
        _lists(accounts, tiers);
        keys.configureAllowlist(keys.allowlistRoot(), keccak256("incorrect-count"), 1, 0, 0);
        _next();
        _mintListed(bob, 4);
        _mintListed(alice, 4, "Tier member count exceeded");
        assertEq(keys.walletTier(alice), 0);
        assertEq(keys.registeredMembers(1), 1);
        assertEq(keys.totalGtdReserved(), 0);
        assertEq(keys.mintedByUsers(), 4);
    }

    function test_ConflictingRootTiersCannotChangeCachedTier() public {
        address[] memory accounts = new address[](2);
        uint8[] memory tiers = new uint8[](2);
        accounts[0] = bob;
        accounts[1] = bob;
        tiers[0] = 1;
        tiers[1] = 2;
        _lists(accounts, tiers);
        _next();
        _mintListed(bob, 2);
        _next();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(bob, 1);
        vm.prank(bob);
        vm.expectRevert("Tier already registered");
        keys.mintWithProof(1, 2, 0.04 ether, 2, proof);
        assertEq(keys.walletTier(bob), 1);
        assertEq(keys.registeredMembers(2), 0);
    }

    function test_SelloutLocksAdvanceAndConfiguration() public {
        _sellOut();
        vm.expectRevert("All tokens minted");
        keys.advancePhase();
        vm.expectRevert("Phases locked");
        keys.configurePhase(4, 1, 10);
    }

    function test_AdminRoleMovesOnlyInTwoStepsAndNeverThroughGrantRole() public {
        bytes32 adminRole = keys.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlEnforcedDefaultAdminRules()"));
        keys.grantRole(adminRole, alice);
        keys.beginDefaultAdminTransfer(alice);
        assertTrue(keys.hasRole(adminRole, address(this)));
        assertFalse(keys.hasRole(adminRole, alice));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlInvalidDefaultAdmin(address)", bob));
        keys.acceptDefaultAdminTransfer();
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        keys.acceptDefaultAdminTransfer();
        assertTrue(keys.hasRole(adminRole, alice));
        assertFalse(keys.hasRole(adminRole, address(this)));
        assertEq(keys.defaultAdmin(), alice);
        assertTrue(keys.hasRole(keys.TREASURY_ROLE(), treasury));
    }
}
