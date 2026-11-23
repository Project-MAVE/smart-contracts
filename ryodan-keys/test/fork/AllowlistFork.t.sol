// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";

/// Every wallet of an allowlist snapshot mints on a fork of a live network, with the proofs the console serves.
///
///   node ../console/scripts/allowlist-fixture.mjs --csv-dir DIR --snapshot allowlist.json --out fixtures/NAME.bin
///   FOUNDRY_PROFILE=fork ALLOWLIST_FIXTURE=fixtures/NAME.bin RYODAN_KEYS=0x... \
///     forge test --match-path test/fork/AllowlistFork.t.sol --fork-url RPC --fork-block-number BLOCK
///
/// RYODAN_KEYS is a deployed contract with no paid mint yet; without it the contract is deployed inside the fork.
/// Phases are advanced as the on-chain administrator. Without ALLOWLIST_FIXTURE the tests are skipped.
contract AllowlistForkTest is Test {
    struct Fixture {
        bytes32 root;
        bytes32 snapshotHash;
        uint256 pioneers;
        uint256 operatives;
        uint256 recruits;
        address[] accounts;
        bytes32[][] proofs;
    }

    struct Attempt {
        address wallet;
        uint256 amount;
        uint8 phaseId;
        uint256 unitPrice;
        uint256 value;
        uint8 tier;
        bytes32[] proof;
    }

    event PhaseAdvanced(uint8 indexed previousPhase, uint8 indexed newPhase, uint256 releasedReservation);

    RyodanKeys internal keys;
    address internal admin;
    address internal treasury;
    string internal fixturePath;
    uint256 internal paidSupply;
    uint256 internal guaranteed;
    uint256 internal proceeds;
    uint256 internal balanceAtStart;
    mapping(uint8 => uint256) internal price;
    mapping(uint8 => uint256) internal limit;

    modifier onFork() {
        if (bytes(fixturePath).length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        fixturePath = vm.envOr("ALLOWLIST_FIXTURE", string(""));
        if (bytes(fixturePath).length == 0) return;
        address deployed = vm.envOr("RYODAN_KEYS", address(0));
        if (deployed == address(0)) {
            admin = makeAddr("fork-admin");
            treasury = makeAddr("fork-treasury");
            uint256 end = vm.envOr("MINT_END_TIME", block.timestamp + 2 days);
            keys = new RyodanKeys(end, "ipfs://fork-sbt/", "ipfs://fork-nft/", admin, treasury);
        } else {
            keys = RyodanKeys(deployed);
            admin = keys.defaultAdmin();
            treasury = vm.envOr("TREASURY_ADDRESS", admin);
        }
        assertEq(keys.CONTRACT_VERSION(), 7);
        assertTrue(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(keys.hasRole(keys.TREASURY_ROLE(), treasury));
        assertLe(block.timestamp, keys.mintEndTime(), "sale already expired at the fork block");
        assertEq(keys.mintedByUsers(), 0, "pin the fork before the first paid mint");
        assertLe(keys.currentPhase(), 1, "pin the fork before OPERATIVE opens");
        paidSupply = keys.MAX_PUBLIC_SUPPLY();
        balanceAtStart = address(keys).balance;
        for (uint8 phaseId = 1; phaseId <= 4; phaseId++) {
            (price[phaseId], limit[phaseId],,,) = keys.phases(phaseId);
        }
    }

    function test_EveryWalletProvesOnlyItsOwnTierAndReadsItsAllowance() public onFork {
        Fixture memory fx = _prepare();
        for (uint256 i; i < fx.accounts.length; i++) {
            uint256 free = _freeMemory();
            _assertEligibility(fx, i);
            _releaseMemory(free);
        }
        _strangerIsRefused(fx);
    }

    /// The client's case: every guaranteed wallet claims everything, Pioneers try to mint again in OPERATIVE.
    function test_EveryGuaranteedWalletMintsItsFullAllocationAndTheSaleSellsOut() public onFork {
        Fixture memory fx = _prepare();
        uint256 firstRecruit = fx.pioneers + fx.operatives;

        _enter(1, 0);
        uint256 early = _pioneersMintPartOfTheirKeys(fx);
        _allAreRefused(fx, fx.pioneers, fx.accounts.length, "Not allowlisted");
        assertEq(keys.totalGtdReserved(), guaranteed - early);

        _enter(2, 0);
        assertEq(keys.totalGtdReserved(), guaranteed - early);
        _operativesMintInFull(fx);
        _pioneersClaimTheRest(fx);
        _allAreRefused(fx, firstRecruit, fx.accounts.length, "Not allowlisted");
        assertEq(keys.totalGtdReserved(), 0);
        assertEq(keys.mintedByUsers(), guaranteed);

        _enter(3, 0);
        _recruitsTakeWhatIsLeft(fx, firstRecruit);
        _refused(fx, 0, 1, "Max supply reached");
        _assertSoldOutAndWithdrawn();
    }

    /// Guaranteed wallets barely show up: the unused guarantees are released to RECRUIT and every Recruit mints.
    function test_EveryRecruitMintsAfterTheUnusedGuaranteesAreReleased() public onFork {
        Fixture memory fx = _prepare();
        require(fx.pioneers > 1 && fx.operatives > 2 && fx.recruits > 0, "list too small for this scenario");
        uint256 firstOperative = fx.pioneers;
        uint256 firstRecruit = fx.pioneers + fx.operatives;

        _enter(1, 0);
        _mint(fx, 0, 1);
        _enter(2, 0);
        _mint(fx, 0, limit[1] - 1);
        _refused(fx, 0, 1, "Max mint amount reached for address");
        _mint(fx, firstOperative, limit[2]);
        _mint(fx, firstOperative + 1, 1);
        uint256 used = limit[1] + limit[2] + 1;
        assertEq(keys.totalGtdReserved(), guaranteed - used);

        _enter(3, guaranteed - used);
        assertEq(keys.totalGtdReserved(), 0);
        for (uint256 i = firstRecruit; i < fx.accounts.length; i++) {
            _mint(fx, i, 1);
        }
        assertEq(keys.mintedByUsers(), used + fx.recruits);

        // RECRUIT is not guaranteed: limits restart there and every allowlist tier accumulates.
        _mint(fx, firstRecruit, limit[3] - 1);
        _refused(fx, firstRecruit, 1, "Max mint amount reached for address");
        _mint(fx, 0, limit[3]);
        _mint(fx, firstOperative + 1, limit[3]);
        _mint(fx, 1, 1);
        _mint(fx, firstOperative + 2, 1);
        _strangerIsRefused(fx);

        _enter(4, 0);
        _publicTakesWhatIsLeft(fx.accounts[firstRecruit]);
        _assertSoldOutAndWithdrawn();
    }

    // Every wallet, in every allowlist phase, tries to force a mint the rules do not give it. One test per phase and
    // quarter of the list: Forge slows down quadratically with the number of calls made by a single test.
    function test_ForcedMintsAreAllRefusedInPioneer_Part1Of4() public onFork {
        _forcedMints(1, 0);
    }

    function test_ForcedMintsAreAllRefusedInPioneer_Part2Of4() public onFork {
        _forcedMints(1, 1);
    }

    function test_ForcedMintsAreAllRefusedInPioneer_Part3Of4() public onFork {
        _forcedMints(1, 2);
    }

    function test_ForcedMintsAreAllRefusedInPioneer_Part4Of4() public onFork {
        _forcedMints(1, 3);
    }

    function test_ForcedMintsAreAllRefusedInOperative_Part1Of4() public onFork {
        _forcedMints(2, 0);
    }

    function test_ForcedMintsAreAllRefusedInOperative_Part2Of4() public onFork {
        _forcedMints(2, 1);
    }

    function test_ForcedMintsAreAllRefusedInOperative_Part3Of4() public onFork {
        _forcedMints(2, 2);
    }

    function test_ForcedMintsAreAllRefusedInOperative_Part4Of4() public onFork {
        _forcedMints(2, 3);
    }

    function test_ForcedMintsAreAllRefusedInRecruit_Part1Of4() public onFork {
        _forcedMints(3, 0);
    }

    function test_ForcedMintsAreAllRefusedInRecruit_Part2Of4() public onFork {
        _forcedMints(3, 1);
    }

    function test_ForcedMintsAreAllRefusedInRecruit_Part3Of4() public onFork {
        _forcedMints(3, 2);
    }

    function test_ForcedMintsAreAllRefusedInRecruit_Part4Of4() public onFork {
        _forcedMints(3, 3);
    }

    function _forcedMints(uint8 phaseId, uint256 part) internal {
        Fixture memory fx = _prepare();
        if (keys.currentPhase() == 0) _attempt(_own(fx, 0, 1, 1, 1), "Mint not active");
        _enter(phaseId, phaseId == 3 ? guaranteed : 0);
        for (uint256 i = part; i < fx.accounts.length; i += 4) {
            uint256 free = _freeMemory();
            _forces(fx, i, phaseId);
            _releaseMemory(free);
        }
        assertEq(keys.mintedByUsers(), 0);
        assertEq(keys.registeredMembers(1) + keys.registeredMembers(2) + keys.registeredMembers(3), 0);
        vm.prank(admin);
        keys.setMintPaused(true);
        _attempt(_own(fx, 0, 1, phaseId, phaseId), "Mint not active");
    }

    // Keys are minted with _safeMint, so a wallet with code must accept an ERC-721: smart wallets and EIP-7702
    // delegations do or do not, depending on their code. On a mainnet fork this lists every wallet that cannot mint.
    function test_EveryWalletReceivesAKey_Part1Of4() public onFork {
        _everyWalletReceivesAKey(0);
    }

    function test_EveryWalletReceivesAKey_Part2Of4() public onFork {
        _everyWalletReceivesAKey(1);
    }

    function test_EveryWalletReceivesAKey_Part3Of4() public onFork {
        _everyWalletReceivesAKey(2);
    }

    function test_EveryWalletReceivesAKey_Part4Of4() public onFork {
        _everyWalletReceivesAKey(3);
    }

    function _everyWalletReceivesAKey(uint256 part) internal {
        Fixture memory fx = _prepare();
        _enter(3, guaranteed);
        uint256 refused;
        for (uint256 i = part; i < fx.accounts.length; i += 4) {
            uint256 free = _freeMemory();
            address wallet = fx.accounts[i];
            vm.deal(wallet, wallet.balance + price[3]);
            vm.prank(wallet);
            (bool minted, bytes memory reason) = address(keys).call{value: price[3]}(
                abi.encodeCall(keys.mintWithProof, (1, 3, price[3], _tier(fx, i), fx.proofs[i]))
            );
            if (!minted) {
                refused++;
                emit log_named_address("cannot receive a key", wallet);
                emit log_named_uint("  code size", wallet.code.length);
                emit log_named_bytes("  revert data", reason);
            }
            _releaseMemory(free);
        }
        assertEq(refused, 0, "listed wallets whose own code refuses the key");
    }

    /// The most one wallet can ever hold from the sale, per tier, and what stops the next key.
    function test_AWalletNeverExceedsItsLimitsInAnyPhase() public onFork {
        Fixture memory fx = _prepare();
        uint256 operative = fx.pioneers;
        uint256 recruit = fx.pioneers + fx.operatives;
        address stranger = makeAddr("not-on-any-list");

        _enter(1, 0);
        _attempt(_own(fx, 0, 0, 1, 1), "Zero mint amount");
        Attempt memory huge = _own(fx, 0, type(uint256).max, 1, 1);
        huge.value = 0;
        _attempt(huge, "Max supply reached");
        _mint(fx, 0, limit[1]);
        _refused(fx, 0, 1, "Max mint amount reached for address");
        uint256 lastTokenId = keys.totalSupply();
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        vm.prank(fx.accounts[0]);
        keys.transferFrom(fx.accounts[0], stranger, lastTokenId);
        // On a test deployment the administrator can be on the list: take a listed wallet that holds no role.
        uint256 plain;
        while (fx.accounts[plain] == admin || fx.accounts[plain] == treasury) plain++;
        _onlyRolesMoveTheSale(fx.accounts[plain]);

        _enter(2, 0);
        _refused(fx, 0, 1, "Max mint amount reached for address");
        _mint(fx, operative, limit[2]);
        _refused(fx, operative, 1, "Max mint amount reached for address");
        _refused(fx, recruit, 1, "Not allowlisted");

        _enter(3, guaranteed - limit[1] - limit[2]);
        _mint(fx, 0, limit[3]);
        _mint(fx, operative, limit[3]);
        _mint(fx, recruit, limit[3]);
        _refused(fx, 0, 1, "Max mint amount reached for address");
        _refused(fx, operative, 1, "Max mint amount reached for address");
        _refused(fx, recruit, 1, "Max mint amount reached for address");

        _enter(4, 0);
        _publicMint(fx.accounts[0], limit[4]);
        _publicMint(fx.accounts[operative], limit[4]);
        _publicMint(fx.accounts[recruit], limit[4]);
        _publicMint(stranger, limit[4]);
        _publicRefused(fx.accounts[0], 1, "Max mint amount reached for address");
        _publicRefused(fx.accounts[operative], 1, "Max mint amount reached for address");
        _publicRefused(fx.accounts[recruit], 1, "Max mint amount reached for address");
        _publicRefused(stranger, 1, "Max mint amount reached for address");
        assertEq(keys.mintedAmount(fx.accounts[0]), limit[1] + limit[3] + limit[4]);
        assertEq(keys.mintedAmount(fx.accounts[operative]), limit[2] + limit[3] + limit[4]);
        assertEq(keys.mintedAmount(fx.accounts[recruit]), limit[3] + limit[4]);
        assertEq(keys.mintedAmount(stranger), limit[4]);

        vm.expectRevert("Max supply reached while minting to treasury");
        vm.prank(treasury);
        keys.treasuryMint(1, treasury);
        vm.expectRevert("Final phase reached");
        vm.prank(admin);
        keys.advancePhase();
        vm.warp(keys.mintEndTime() + 1);
        _publicRefused(makeAddr("late"), 1, "Mint ended");
    }

    function _prepare() internal returns (Fixture memory fx) {
        fx = abi.decode(vm.readFileBinary(fixturePath), (Fixture));
        assertEq(fx.accounts.length, fx.pioneers + fx.operatives + fx.recruits);
        assertEq(fx.proofs.length, fx.accounts.length);
        if (!keys.allowlistConfigured()) {
            vm.prank(admin);
            keys.configureAllowlist(fx.root, fx.snapshotHash, fx.pioneers, fx.operatives, fx.recruits);
        }
        assertEq(keys.allowlistRoot(), fx.root);
        assertEq(keys.allowlistSnapshotHash(), fx.snapshotHash);
        assertEq(keys.tierMembers(1), fx.pioneers);
        assertEq(keys.tierMembers(2), fx.operatives);
        assertEq(keys.tierMembers(3), fx.recruits);
        guaranteed = fx.pioneers * limit[1] + fx.operatives * limit[2];
        assertEq(keys.totalGtdReserved(), guaranteed);
        assertLe(guaranteed, paidSupply);
        uint256 treasuryLeft = keys.MAX_TREASURY_SUPPLY() - keys.mintedByTreasury();
        while (treasuryLeft > 0) {
            uint256 batch = treasuryLeft < 100 ? treasuryLeft : 100;
            vm.prank(treasury);
            keys.treasuryMint(batch, treasury);
            treasuryLeft -= batch;
        }
    }

    /// Opens the given phase as the administrator and checks how many guaranteed keys the transition released.
    function _enter(uint8 phaseId, uint256 released) internal {
        while (keys.currentPhase() < phaseId) {
            uint8 previous = keys.currentPhase();
            vm.expectEmit(true, true, false, true, address(keys));
            emit PhaseAdvanced(previous, previous + 1, previous + 1 == phaseId ? released : 0);
            vm.prank(admin);
            keys.advancePhase();
        }
        if (keys.mintPaused()) {
            vm.prank(admin);
            keys.setMintPaused(false);
        }
        assertEq(keys.currentPhase(), phaseId);
        assertEq(keys.mintPrice(), price[phaseId]);
        vm.expectRevert("Phases locked");
        vm.prank(admin);
        keys.configurePhase(phaseId, price[phaseId], limit[phaseId] + 1);
        vm.expectRevert("Allowlist frozen");
        vm.prank(admin);
        keys.configureAllowlist(bytes32(uint256(1)), bytes32(uint256(2)), 1, 0, 0);
    }

    /// Calldata encoded for tens of thousands of calls would outgrow the test memory: loops hand it back.
    function _freeMemory() internal pure returns (uint256 pointer) {
        assembly ("memory-safe") {
            pointer := mload(0x40)
        }
    }

    function _releaseMemory(uint256 pointer) internal pure {
        assembly {
            mstore(0x40, pointer)
        }
    }

    function _tier(Fixture memory fx, uint256 i) internal pure returns (uint8) {
        return i < fx.pioneers ? 1 : i < fx.pioneers + fx.operatives ? 2 : 3;
    }

    function _mint(Fixture memory fx, uint256 i, uint256 amount) internal {
        address wallet = fx.accounts[i];
        uint8 phaseId = keys.currentPhase();
        uint256 value = price[phaseId] * amount;
        uint256 lastTokenId = keys.mintedByUsers() + keys.mintedByTreasury() + amount;
        vm.deal(wallet, wallet.balance + value);
        vm.prank(wallet);
        keys.mintWithProof{value: value}(amount, phaseId, price[phaseId], _tier(fx, i), fx.proofs[i]);
        assertEq(keys.ownerOf(lastTokenId), wallet);
        assertEq(keys.originalMinter(lastTokenId), wallet);
        proceeds += value;
    }

    function _refused(Fixture memory fx, uint256 i, uint256 amount, bytes memory reason) internal {
        address wallet = fx.accounts[i];
        uint8 phaseId = keys.currentPhase();
        uint256 value = price[phaseId] * amount;
        vm.deal(wallet, wallet.balance + value);
        vm.expectRevert(reason);
        vm.prank(wallet);
        keys.mintWithProof{value: value}(amount, phaseId, price[phaseId], _tier(fx, i), fx.proofs[i]);
    }

    function _own(Fixture memory fx, uint256 i, uint256 amount, uint8 quotedPhase, uint8 paidPhase)
        internal
        view
        returns (Attempt memory)
    {
        return Attempt(
            fx.accounts[i],
            amount,
            quotedPhase,
            price[quotedPhase],
            amount > paidSupply ? 0 : price[paidPhase] * amount,
            _tier(fx, i),
            fx.proofs[i]
        );
    }

    function _attempt(Attempt memory a, bytes memory reason) internal {
        vm.deal(a.wallet, a.wallet.balance + a.value);
        vm.expectRevert(reason);
        vm.prank(a.wallet);
        keys.mintWithProof{value: a.value}(a.amount, a.phaseId, a.unitPrice, a.tier, a.proof);
    }

    /// One wallet against the open phase: another phase's quote, another phase's price, a tier it does not hold,
    /// a neighbour's proof and no proof at all.
    function _forces(Fixture memory fx, uint256 i, uint8 open) internal {
        uint8 tier = _tier(fx, i);
        for (uint8 other = 1; other <= 4; other++) {
            if (other == open) continue;
            _attempt(_own(fx, i, 1, other, other), "Mint quote changed");
            _attempt(_own(fx, i, 1, open, other), "Incorrect payment");
            Attempt memory cheaper = _own(fx, i, 1, open, open);
            cheaper.unitPrice = price[other];
            _attempt(cheaper, "Mint quote changed");
        }
        for (uint8 claimed = 0; claimed <= 4; claimed++) {
            if (claimed == tier) continue;
            Attempt memory promoted = _own(fx, i, 1, open, open);
            promoted.tier = claimed;
            _attempt(promoted, "Invalid allowlist proof");
        }
        uint256 neighbour = (i + 1) % fx.accounts.length;
        Attempt memory borrowed = _own(fx, i, 1, open, open);
        borrowed.tier = _tier(fx, neighbour);
        borrowed.proof = fx.proofs[neighbour];
        _attempt(borrowed, "Invalid allowlist proof");
        _publicRefused(fx.accounts[i], 1, "Not allowlisted");
        if (tier > open) _attempt(_own(fx, i, 1, open, open), "Not allowlisted");
    }

    function _publicRefused(address wallet, uint256 amount, bytes memory reason) internal {
        uint8 phaseId = keys.currentPhase();
        uint256 value = price[phaseId] * amount;
        vm.deal(wallet, wallet.balance + value);
        vm.expectRevert(reason);
        vm.prank(wallet);
        keys.mint{value: value}(amount, phaseId, price[phaseId]);
    }

    function _onlyRolesMoveTheSale(address minter) internal {
        bytes memory notAdmin = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, minter, keys.DEFAULT_ADMIN_ROLE()
        );
        bytes memory notTreasury = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, minter, keys.TREASURY_ROLE()
        );
        vm.startPrank(minter);
        vm.expectRevert(notAdmin);
        keys.advancePhase();
        vm.expectRevert(notAdmin);
        keys.setMintPaused(true);
        vm.expectRevert(notAdmin);
        keys.configurePhase(1, 1, 6166);
        vm.expectRevert(notAdmin);
        keys.configureAllowlist(bytes32(uint256(1)), bytes32(uint256(2)), 1, 0, 0);
        vm.expectRevert(notTreasury);
        keys.treasuryMint(1, minter);
        vm.expectRevert(notTreasury);
        keys.withdraw();
        vm.stopPrank();
    }

    function _allAreRefused(Fixture memory fx, uint256 from, uint256 to, bytes memory reason) internal {
        for (uint256 i = from; i < to; i++) {
            uint256 free = _freeMemory();
            _refused(fx, i, 1, reason);
            _releaseMemory(free);
        }
    }

    /// PIONEER: Pioneers take 0 to 4 keys each, one transaction per wallet, odd amounts included.
    function _pioneersMintPartOfTheirKeys(Fixture memory fx) internal returns (uint256 minted) {
        for (uint256 i; i < fx.pioneers; i++) {
            address wallet = fx.accounts[i];
            uint256 amount = i % (limit[1] + 1);
            assertEq(keys.remainingAllowanceWithProof(1, wallet, 1, fx.proofs[i]), limit[1]);
            if (amount > 0) _mint(fx, i, amount);
            assertEq(keys.gtdMinted(wallet), amount);
            assertEq(keys.remainingAllowanceWithProof(1, wallet, 1, fx.proofs[i]), limit[1] - amount);
            _refused(fx, i, limit[1] - amount + 1, "Max mint amount reached for address");
            minted += amount;
        }
    }

    /// OPERATIVE: every Operative mints its full allocation, split over one to four transactions.
    function _operativesMintInFull(Fixture memory fx) internal {
        for (uint256 i = fx.pioneers; i < fx.pioneers + fx.operatives; i++) {
            address wallet = fx.accounts[i];
            assertEq(keys.remainingAllowanceWithProof(2, wallet, 2, fx.proofs[i]), limit[2]);
            uint256 step = 1 + i % limit[2];
            for (uint256 left = limit[2]; left > 0;) {
                uint256 amount = left < step ? left : step;
                _mint(fx, i, amount);
                left -= amount;
            }
            assertEq(keys.gtdMinted(wallet), limit[2]);
            assertEq(keys.remainingAllowance(2, wallet), 0);
            _refused(fx, i, 1, "Max mint amount reached for address");
        }
    }

    /// OPERATIVE: after every Operative, each Pioneer gets what is left of its own keys and nothing more.
    function _pioneersClaimTheRest(Fixture memory fx) internal {
        for (uint256 i; i < fx.pioneers; i++) {
            address wallet = fx.accounts[i];
            uint256 left = limit[1] - keys.gtdMinted(wallet);
            assertEq(keys.remainingAllowanceWithProof(2, wallet, 1, fx.proofs[i]), left);
            _refused(fx, i, left + 1, "Max mint amount reached for address");
            if (left > 0) _mint(fx, i, left);
            assertEq(keys.gtdMinted(wallet), limit[1]);
            assertEq(keys.remainingAllowanceWithProof(2, wallet, 1, fx.proofs[i]), 0);
        }
    }

    /// RECRUIT is first come, first served: Recruits take full limits until the paid supply is gone.
    function _recruitsTakeWhatIsLeft(Fixture memory fx, uint256 firstRecruit) internal {
        uint256 i = firstRecruit;
        for (uint256 left = paidSupply - keys.mintedByUsers(); left > 0; i++) {
            uint256 amount = left < limit[3] ? left : limit[3];
            if (amount < limit[3]) _refused(fx, i, limit[3], "Max supply reached");
            _mint(fx, i, amount);
            left -= amount;
        }
        _refused(fx, i, 1, "Max supply reached");
    }

    /// CIVILIAN: wallets outside every list, and one listed wallet without a proof, take the remaining keys.
    function _publicTakesWhatIsLeft(address listed) internal {
        _publicMint(listed, 1);
        for (uint256 n; keys.mintedByUsers() < paidSupply; n++) {
            uint256 left = paidSupply - keys.mintedByUsers();
            _publicMint(makeAddr(string.concat("civilian-", vm.toString(n))), left < limit[4] ? left : limit[4]);
        }
    }

    function _publicMint(address wallet, uint256 amount) internal {
        uint256 value = price[4] * amount;
        vm.deal(wallet, wallet.balance + value);
        vm.prank(wallet);
        keys.mint{value: value}(amount, 4, price[4]);
        proceeds += value;
    }

    function _assertEligibility(Fixture memory fx, uint256 i) internal view {
        address wallet = fx.accounts[i];
        uint8 tier = _tier(fx, i);
        assertTrue(wallet != address(0));
        for (uint8 claimed = 1; claimed <= 3; claimed++) {
            assertEq(keys.verifyEligibility(wallet, claimed, fx.proofs[i]), claimed == tier);
        }
        for (uint8 phaseId = keys.currentPhase() == 0 ? 1 : keys.currentPhase(); phaseId <= 3; phaseId++) {
            uint256 expected = limit[phaseId];
            if (tier > phaseId) expected = 0;
            else if (phaseId < 3 && limit[tier] < expected) expected = limit[tier];
            assertEq(keys.remainingAllowanceWithProof(phaseId, wallet, tier, fx.proofs[i]), expected);
        }
        assertEq(keys.remainingAllowance(4, wallet), limit[4]);
    }

    function _strangerIsRefused(Fixture memory fx) internal {
        address stranger = makeAddr("not-on-any-list");
        uint256 last = fx.accounts.length - 1;
        assertFalse(keys.verifyEligibility(stranger, _tier(fx, last), fx.proofs[last]));
        if (keys.currentPhase() == 0 || keys.mintPaused()) return;
        uint8 phaseId = keys.currentPhase();
        vm.deal(stranger, price[phaseId]);
        vm.expectRevert("Invalid allowlist proof");
        vm.prank(stranger);
        keys.mintWithProof{value: price[phaseId]}(1, phaseId, price[phaseId], _tier(fx, last), fx.proofs[last]);
        vm.expectRevert("Not allowlisted");
        vm.prank(stranger);
        keys.mint{value: price[phaseId]}(1, phaseId, price[phaseId]);
    }

    function _assertSoldOutAndWithdrawn() internal {
        assertEq(keys.mintedByUsers(), paidSupply);
        assertEq(keys.totalGtdReserved(), 0);
        assertTrue(keys.soldOut());
        assertEq(keys.totalSupply(), keys.MAX_SUPPLY());
        assertEq(
            keys.tokenURI(keys.MAX_SUPPLY()), string.concat(keys.nftBaseURI(), vm.toString(keys.MAX_SUPPLY()), ".json")
        );
        assertEq(address(keys).balance, balanceAtStart + proceeds);
        vm.expectRevert("All tokens minted");
        vm.prank(admin);
        keys.advancePhase();
        vm.expectRevert("Mint not ended");
        vm.prank(treasury);
        keys.withdraw();
        vm.warp(keys.mintEndTime() + 1);
        uint256 before = treasury.balance;
        vm.prank(treasury);
        keys.withdraw();
        assertEq(treasury.balance - before, balanceAtStart + proceeds);
        assertEq(address(keys).balance, 0);
    }
}
