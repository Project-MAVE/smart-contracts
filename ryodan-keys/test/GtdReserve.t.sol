// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RyodanKeysFixture} from "./RyodanKeys.t.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

/// Guaranteed keys live in one reservation shared by Pioneers and Operatives. Each wallet draws on its own
/// allocation, counted across PIONEER and OPERATIVE, and nothing is released before RECRUIT opens.
abstract contract TreeFixture is RyodanKeysFixture {
    bytes32[][] internal tree;
    mapping(address => uint256) internal leafIndex;
    mapping(address => uint8) internal tierOf;
    address[] internal pioneers;
    address[] internal operatives;
    address[] internal recruits;

    event PhaseAdvanced(uint8 indexed previousPhase, uint8 indexed newPhase, uint256 releasedReservation);

    function _wallets(uint256 pioneerCount, uint256 operativeCount, uint256 recruitCount) internal {
        uint256 total = pioneerCount + operativeCount + recruitCount;
        bytes32[] memory level = new bytes32[](total);
        for (uint256 i; i < total; i++) {
            address account = address(uint160(0xA11CE00000 + i));
            uint8 tier = i < pioneerCount ? 1 : i < pioneerCount + operativeCount ? 2 : 3;
            if (tier == 1) pioneers.push(account);
            else if (tier == 2) operatives.push(account);
            else recruits.push(account);
            leafIndex[account] = i;
            tierOf[account] = tier;
            level[i] = keccak256(bytes.concat(keccak256(abi.encode(account, tier))));
        }
        uint256 size = total;
        while (true) {
            tree.push();
            bytes32[] storage stored = tree[tree.length - 1];
            for (uint256 i; i < size; i++) {
                stored.push(level[i]);
            }
            if (size == 1) break;
            for (uint256 i; i < size; i += 2) {
                level[i / 2] = i + 1 < size ? _hashPair(level[i], level[i + 1]) : level[i];
            }
            size = (size + 1) / 2;
        }
        keys.configureAllowlist(level[0], keccak256("gtd-reserve"), pioneerCount, operativeCount, recruitCount);
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofOf(address account) internal view returns (bytes32[] memory proof) {
        bytes32[] memory siblings = new bytes32[](tree.length);
        uint256 depth;
        uint256 index = leafIndex[account];
        for (uint256 i; i + 1 < tree.length; i++) {
            uint256 sibling = index ^ 1;
            if (sibling < tree[i].length) siblings[depth++] = tree[i][sibling];
            index /= 2;
        }
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; i++) {
            proof[i] = siblings[i];
        }
    }

    function _mintGtd(address account, uint256 amount) internal {
        _mintGtd(account, amount, "");
    }

    function _mintGtd(address account, uint256 amount, string memory expectedError) internal {
        uint256 price = keys.mintPrice();
        uint8 phaseId = keys.currentPhase();
        bytes32[] memory proof = _proofOf(account);
        vm.deal(account, amount * price);
        vm.prank(account);
        if (bytes(expectedError).length != 0) vm.expectRevert(bytes(expectedError));
        keys.mintWithProof{value: amount * price}(amount, phaseId, price, tierOf[account], proof);
    }

    function _advance() internal {
        keys.advancePhase();
        keys.setMintPaused(false);
    }

    /// The reservation always equals the allocations that listed wallets have not minted yet.
    function _unclaimed() internal view returns (uint256 unclaimed) {
        (, uint256 pioneerLimit,,,) = keys.phases(1);
        (, uint256 operativeLimit,,,) = keys.phases(2);
        for (uint256 i; i < pioneers.length; i++) {
            unclaimed += pioneerLimit - keys.gtdMinted(pioneers[i]);
        }
        for (uint256 i; i < operatives.length; i++) {
            unclaimed += operativeLimit - keys.gtdMinted(operatives[i]);
        }
    }
}

contract GtdReserveTest is TreeFixture {
    function test_ClientListsSellFirstComeFirstServedUpTo6000() public {
        // 1,563 wallets and 6,000 keys in one test exceed the default test gas limit.
        vm.pauseGasMetering();
        _wallets(105, 1455, 3);
        // The lists ask for 6,240 keys; the reservation stops at the 6,000 keys on sale.
        assertEq(keys.totalGtdReserved(), 6000);

        _advance();
        uint256 mintedInPioneer;
        for (uint256 i; i < pioneers.length; i++) {
            uint256 amount = i % 5;
            if (amount == 0) continue;
            _mintGtd(pioneers[i], amount);
            mintedInPioneer += amount;
        }
        assertEq(mintedInPioneer, 210);
        _mintGtd(operatives[0], 1, "Not allowlisted");
        assertEq(keys.totalGtdReserved(), 5790);
        assertEq(_unclaimed(), 6030);

        vm.expectEmit(true, true, false, true, address(keys));
        emit PhaseAdvanced(1, 2, 0);
        _advance();
        assertEq(keys.totalGtdReserved(), 5790);

        // OPERATIVE: wallets mint in arrival order until the 6,000 keys are gone.
        for (uint256 i; i < 1447; i++) {
            _mintGtd(operatives[i], 4);
        }
        assertEq(keys.mintedByUsers(), 5998);
        assertEq(keys.totalGtdReserved(), 2);
        _mintGtd(operatives[1447], 4, "Max supply reached");
        _mintGtd(operatives[1447], 2);
        assertEq(keys.mintedByUsers(), 6000);
        assertEq(keys.totalGtdReserved(), 0);
        _mintGtd(operatives[1448], 1, "Max supply reached");
        _mintGtd(pioneers[1], 1, "Max supply reached");
        // The per-wallet reading ignores the stock: a mint page must also read the keys left on sale.
        assertEq(keys.remainingAllowance(2, pioneers[1]), 3);
        assertEq(keys.MAX_PUBLIC_SUPPLY() - keys.mintedByUsers(), 0);

        // The later phases open with nothing left to sell; the treasury keeps its 666 keys.
        vm.expectEmit(true, true, false, true, address(keys));
        emit PhaseAdvanced(2, 3, 0);
        _advance();
        _mintGtd(recruits[0], 1, "Max supply reached");
        _advance();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Max supply reached");
        keys.mint{value: 0.015 ether}(1, 4, 0.015 ether);
        assertFalse(keys.soldOut());
        vm.prank(treasury);
        keys.treasuryMint(666, treasury);
        vm.prank(treasury);
        vm.expectRevert("Max supply reached while minting to treasury");
        keys.treasuryMint(1, treasury);
        assertEq(keys.mintedByTreasury(), 666);
        assertEq(keys.totalSupply(), 6666);
        assertTrue(keys.soldOut());
    }

    function test_ReservationHasNoPhaseBucketsAndIsReleasedOnlyWhenRecruitOpens() public {
        _wallets(2, 2, 1);
        assertEq(keys.totalGtdReserved(), 16);
        _advance();
        _mintGtd(pioneers[0], 1);
        assertEq(keys.totalGtdReserved(), 15);
        vm.expectEmit(true, true, false, true, address(keys));
        emit PhaseAdvanced(1, 2, 0);
        _advance();
        assertEq(keys.totalGtdReserved(), 15);
        // A Pioneer that never minted in PIONEER registers in OPERATIVE and still owns its four keys.
        assertEq(keys.remainingAllowance(2, pioneers[1]), 0);
        assertEq(keys.remainingAllowanceWithProof(2, pioneers[1], 1, _proofOf(pioneers[1])), 4);
        _mintGtd(pioneers[1], 4);
        _mintGtd(pioneers[0], 2);
        _mintGtd(operatives[0], 3);
        assertEq(keys.totalGtdReserved(), 6);
        assertEq(keys.totalGtdReserved(), _unclaimed());
        // Recruit wallets cannot touch guaranteed supply while it is reserved.
        _mintGtd(recruits[0], 1, "Not allowlisted");
        vm.expectEmit(true, true, false, true, address(keys));
        emit PhaseAdvanced(2, 3, 6);
        _advance();
        assertEq(keys.totalGtdReserved(), 0);
        assertEq(keys.remainingAllowance(2, pioneers[0]), 0);
        assertEq(keys.remainingAllowance(3, pioneers[0]), 10);
        _mintGtd(pioneers[0], 10);
        assertEq(keys.gtdMinted(pioneers[0]), 3);
        vm.expectEmit(true, true, false, true, address(keys));
        emit PhaseAdvanced(3, 4, 0);
        _advance();
    }

    function test_PioneerCumulativeCounterBoundsBothGuaranteedPhases() public {
        _wallets(1, 1, 0);
        address pioneer = pioneers[0];
        bytes32[] memory proof = _proofOf(pioneer);
        _advance();
        assertEq(keys.remainingAllowanceWithProof(1, pioneer, 1, proof), 4);
        assertEq(keys.remainingAllowanceWithProof(2, pioneer, 1, proof), 4);
        _mintGtd(pioneer, 3);
        assertEq(keys.gtdMinted(pioneer), 3);
        assertEq(keys.remainingAllowance(1, pioneer), 1);
        assertEq(keys.remainingAllowance(2, pioneer), 1);
        assertEq(keys.remainingAllowanceWithProof(2, pioneer, 1, proof), 1);
        _advance();
        assertEq(keys.mintedInPhase(2, pioneer), 0);
        assertEq(keys.remainingAllowance(2, pioneer), 1);
        _mintGtd(pioneer, 2, "Max mint amount reached for address");
        _mintGtd(pioneer, 1);
        assertEq(keys.gtdMinted(pioneer), 4);
        assertEq(keys.remainingAllowance(2, pioneer), 0);
        assertEq(keys.remainingAllowanceWithProof(2, pioneer, 1, proof), 0);
        vm.deal(pioneer, 1 ether);
        vm.prank(pioneer);
        vm.expectRevert("Max mint amount reached for address");
        keys.mint{value: 0.012 ether}(1, 2, 0.012 ether);
        // The Operative allocation is untouched by the Pioneer's mints.
        _mintGtd(operatives[0], 4);
        assertEq(keys.totalGtdReserved(), 0);
    }

    function test_DifferentTierLimitsKeepEachWalletOnItsOwnAllocation() public {
        keys.configurePhase(1, 0.0075 ether, 6);
        keys.configurePhase(2, 0.012 ether, 2);
        _wallets(2, 2, 0);
        assertEq(keys.totalGtdReserved(), 16);
        _advance();
        _mintGtd(pioneers[0], 5);
        _advance();
        // In OPERATIVE the phase limit (2) and the Pioneer allocation left (1 and 6) both apply.
        assertEq(keys.remainingAllowance(2, pioneers[0]), 1);
        assertEq(keys.remainingAllowanceWithProof(2, pioneers[1], 1, _proofOf(pioneers[1])), 2);
        _mintGtd(pioneers[0], 1);
        _mintGtd(pioneers[1], 3, "Max mint amount reached for address");
        _mintGtd(pioneers[1], 2);
        _mintGtd(operatives[0], 2);
        _mintGtd(operatives[1], 2);
        _mintGtd(operatives[1], 1, "Max mint amount reached for address");
        assertEq(keys.totalGtdReserved(), 4);
        assertEq(keys.totalGtdReserved(), _unclaimed());
    }

    function testFuzz_ReservationAlwaysEqualsUnclaimedAllocations(
        uint256 seed,
        uint8 pioneerLimitSeed,
        uint8 operativeLimitSeed
    ) public {
        uint256 pioneerLimit = bound(pioneerLimitSeed, 1, 8);
        uint256 operativeLimit = bound(operativeLimitSeed, 1, 8);
        keys.configurePhase(1, 0.0075 ether, pioneerLimit);
        keys.configurePhase(2, 0.012 ether, operativeLimit);
        _wallets(4, 5, 0);
        assertEq(keys.totalGtdReserved(), 4 * pioneerLimit + 5 * operativeLimit);
        for (uint8 phaseId = 1; phaseId <= 2; phaseId++) {
            _advance();
            for (uint256 step; step < 24; step++) {
                seed = uint256(keccak256(abi.encode(seed, step)));
                bool pioneerTurn = phaseId == 1 || seed % 2 == 0;
                _fuzzStep(
                    phaseId,
                    pioneerTurn ? pioneers[(seed >> 8) % 4] : operatives[(seed >> 8) % 5],
                    pioneerTurn ? pioneerLimit : operativeLimit,
                    seed >> 16
                );
            }
        }
        uint256 unused = keys.totalGtdReserved();
        vm.expectEmit(true, true, false, true, address(keys));
        emit PhaseAdvanced(2, 3, unused);
        _advance();
        assertEq(keys.totalGtdReserved(), 0);
    }

    function _fuzzStep(uint8 phaseId, address account, uint256 tierLimit, uint256 amountSeed) private {
        (, uint256 phaseLimit,,,) = keys.phases(phaseId);
        uint256 left = tierLimit - keys.gtdMinted(account);
        uint256 phaseLeft = phaseLimit - keys.mintedInPhase(phaseId, account);
        if (phaseLeft < left) left = phaseLeft;
        assertEq(keys.remainingAllowanceWithProof(phaseId, account, tierOf[account], _proofOf(account)), left);
        uint256 reservedBefore = keys.totalGtdReserved();
        _mintGtd(account, left + 1, "Max mint amount reached for address");
        uint256 amount = amountSeed % (left + 1);
        if (amount > 0) _mintGtd(account, amount);
        assertEq(keys.totalGtdReserved(), reservedBefore - amount);
        assertEq(keys.totalGtdReserved(), _unclaimed());
        assertLe(keys.totalGtdReserved() + keys.mintedByUsers(), keys.MAX_PUBLIC_SUPPLY());
    }
}
