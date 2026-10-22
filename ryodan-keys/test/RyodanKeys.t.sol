// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CallbackWallet is IERC721Receiver {
    RyodanKeys public immutable keys;
    bytes public callback;
    bytes public result;
    bool public attempted;
    bool public reentered;
    bool public rejectEther;
    bool public rejectNFT;
    uint256 public supplyInCallback;
    address public minterInCallback;

    constructor(RyodanKeys keys_) {
        keys = keys_;
    }

    function configure(bytes memory data, bool rejectEther_, bool rejectNFT_) external {
        callback = data;
        attempted = false;
        reentered = false;
        rejectEther = rejectEther_;
        rejectNFT = rejectNFT_;
    }

    function buy(uint256 amount) external payable {
        keys.mint{value: msg.value}(amount);
    }

    function claim(uint256 id) external {
        keys.refund(id);
    }

    function claimTo(uint256 id, address payable to) external {
        keys.refundTo(id, to);
    }

    function mintTreasury(uint256 amount) external {
        keys.treasuryMint(amount, address(this));
    }

    function takeProceeds() external {
        keys.withdraw();
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        require(!rejectNFT, "NFT rejected");
        supplyInCallback = keys.totalSupply();
        minterInCallback = keys.originalMinter(id);
        _attempt();
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        require(!rejectEther, "Ether rejected");
        _attempt();
    }

    function _attempt() private {
        if (!attempted && callback.length > 0) {
            attempted = true;
            (reentered, result) = address(keys).call(callback);
        }
    }
}

contract NonReceiverWallet {
    function buy(RyodanKeys keys) external payable {
        keys.mint{value: msg.value}(1);
    }
}

abstract contract RyodanKeysFixture is Test {
    RyodanKeys internal keys;
    address internal bob = makeAddr("bob");
    address internal alice = makeAddr("alice");
    address internal treasury = makeAddr("treasury");
    string internal constant HIDDEN = "ipfs://hidden/hidden.json";
    uint256 internal end;

    receive() external payable {}

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 7 days;
        keys = new RyodanKeys(end, HIDDEN, address(this), treasury);
    }

    function _open(uint256 limit) internal {
        keys.setPublicMintActive(true, limit);
    }

    function _buy(address buyer, uint256 amount) internal {
        uint256 value = amount * keys.mintPrice();
        vm.deal(buyer, buyer.balance + value);
        vm.prank(buyer);
        keys.mint{value: value}(amount);
    }

    function _whitelist(address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        keys.addToWhitelist(accounts);
    }

    function _sellOut() internal {
        _open(5900);
        _buy(bob, 5900);
        vm.prank(treasury);
        keys.treasuryMint(500, treasury);
    }
}

contract RyodanKeysTest is RyodanKeysFixture {
    function test_ConstructorAssignsOnlyExplicitRoles() public view {
        assertTrue(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(keys.hasRole(keys.TREASURY_ROLE(), address(this)));
        assertTrue(keys.hasRole(keys.TREASURY_ROLE(), treasury));
        assertFalse(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), treasury));
        assertEq(keys.mintEndTime(), end);
        assertFalse(keys.isPublicMintActive());
        assertFalse(keys.isWhitelistMintActive());
    }

    function test_ConstructorRejectsPastOrCurrentDeadline() public {
        vm.expectRevert("Deadline must be in the future");
        new RyodanKeys(block.timestamp, HIDDEN, bob, treasury);
        vm.expectRevert("Deadline must be in the future");
        new RyodanKeys(block.timestamp - 1, HIDDEN, bob, treasury);
    }

    function test_ConstructorRejectsEmptyMetadata() public {
        vm.expectRevert("Empty metadata URI");
        new RyodanKeys(end, "", bob, treasury);
    }

    function test_ConstructorRejectsZeroRoles() public {
        vm.expectRevert("Zero role address");
        new RyodanKeys(end, HIDDEN, address(0), treasury);
        vm.expectRevert("Zero role address");
        new RyodanKeys(end, HIDDEN, bob, address(0));
    }

    function test_InterfaceSupport() public view {
        assertTrue(keys.supportsInterface(0x01ffc9a7));
        assertTrue(keys.supportsInterface(0x80ac58cd));
        assertTrue(keys.supportsInterface(0x5b5e139f));
        assertTrue(keys.supportsInterface(0x7965db0b));
        assertTrue(keys.supportsInterface(0x49064906));
        assertFalse(keys.supportsInterface(0xffffffff));
    }

    function test_MintInactiveReverts() public {
        vm.expectRevert("Mint not active");
        keys.mint(1);
    }

    function test_MintZeroReverts() public {
        _open(1);
        vm.expectRevert("Zero mint amount");
        keys.mint(0);
    }

    function test_MintRejectsUnderpaymentAndOverpayment() public {
        _open(2);
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        vm.expectRevert("Incorrect payment");
        keys.mint{value: 0.009 ether}(1);
        vm.expectRevert("Incorrect payment");
        keys.mint{value: 0.011 ether}(1);
        vm.stopPrank();
        assertEq(keys.totalSupply(), 0);
        assertEq(address(keys).balance, 0);
    }

    function test_MintTracksSequentialIdsAndLifetimeLimits() public {
        _open(3);
        _buy(bob, 2);
        vm.prank(treasury);
        keys.treasuryMint(2, alice);
        _buy(bob, 1);
        assertEq(keys.totalSupply(), 5);
        assertEq(keys.mintedByUsers(), 3);
        assertEq(keys.mintedByTreasury(), 2);
        assertEq(keys.mintedAmount(bob), 3);
        assertEq(keys.ownerOf(0), bob);
        assertEq(keys.ownerOf(2), alice);
        assertEq(keys.ownerOf(4), bob);
        assertEq(keys.originalMinter(4), bob);
        assertEq(keys.originalMinter(2), address(0));
        vm.deal(bob, 0.01 ether);
        vm.prank(bob);
        vm.expectRevert("Max mint amount reached for address");
        keys.mint{value: 0.01 ether}(1);
    }

    function test_MintAtDeadlineAndRejectAfterDeadline() public {
        _open(2);
        vm.warp(end);
        _buy(bob, 1);
        assertFalse(keys.refundsAvailable());
        vm.prank(bob);
        vm.expectRevert("Mint not ended");
        keys.refund(0);
        vm.warp(end + 1);
        vm.deal(bob, 0.01 ether);
        vm.prank(bob);
        vm.expectRevert("Mint ended");
        keys.mint{value: 0.01 ether}(1);
        assertTrue(keys.refundsAvailable());
    }

    function test_MintCannotOverflowAmount() public {
        _open(type(uint256).max);
        vm.expectRevert("Max supply reached");
        keys.mint(type(uint256).max);
    }

    function test_PhasesAreMutuallyExclusiveAndPausable() public {
        _open(3);
        keys.setWhitelistMintActive(true, 2);
        assertFalse(keys.isPublicMintActive());
        assertTrue(keys.isWhitelistMintActive());
        _open(4);
        assertTrue(keys.isPublicMintActive());
        assertFalse(keys.isWhitelistMintActive());
        keys.setPublicMintActive(false, 4);
        assertFalse(keys.isPublicMintActive());
        assertFalse(keys.isWhitelistMintActive());
        vm.expectRevert("Mint not active");
        keys.mint(1);
    }

    function test_ZeroWalletLimitsRejected() public {
        vm.expectRevert("Zero wallet limit");
        keys.setPublicMintActive(true, 0);
        vm.expectRevert("Zero wallet limit");
        keys.setWhitelistMintActive(true, 0);
    }

    function test_WhitelistIncludesAndRemovesWallets() public {
        keys.setWhitelistMintActive(true, 3);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Not whitelisted");
        keys.mint{value: 0.01 ether}(1);
        _whitelist(bob);
        _buy(bob, 1);
        assertEq(keys.mintedByWhitelist(), 1);
        address[] memory accounts = new address[](1);
        accounts[0] = bob;
        keys.removeFromWhitelist(accounts);
        vm.prank(bob);
        vm.expectRevert("Not whitelisted");
        keys.mint{value: 0.01 ether}(1);
    }

    function test_WalletLimitIsSharedAcrossPhases() public {
        keys.setWhitelistMintActive(true, 2);
        _whitelist(bob);
        _buy(bob, 2);
        _open(2);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Max mint amount reached for address");
        keys.mint{value: 0.01 ether}(1);
        assertEq(keys.mintedByWhitelist(), 2);
    }

    function test_WhitelistCapIsPartOfPublicSupply() public {
        keys.setWhitelistMintActive(true, 1001);
        _whitelist(bob);
        _buy(bob, 1000);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Max whitelist mint amount reached");
        keys.mint{value: 0.01 ether}(1);
        _open(1001);
        _buy(bob, 1);
        assertEq(keys.mintedByUsers(), 1001);
        assertEq(keys.mintedByWhitelist(), 1000);
    }

    function test_TreasuryCapAndDeadline() public {
        vm.startPrank(treasury);
        keys.treasuryMint(500, bob);
        vm.expectRevert("Max supply reached while minting to treasury");
        keys.treasuryMint(1, bob);
        vm.warp(end + 1);
        vm.expectRevert("Mint ended");
        keys.treasuryMint(1, bob);
        vm.stopPrank();
        assertEq(keys.mintedByTreasury(), 500);
    }

    function test_TreasuryRejectsZeroAmountAndRecipient() public {
        vm.startPrank(treasury);
        vm.expectRevert("Zero mint amount");
        keys.treasuryMint(0, bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        keys.treasuryMint(1, address(0));
        vm.stopPrank();
        assertEq(keys.totalSupply(), 0);
        assertEq(keys.mintedByTreasury(), 0);
    }

    function test_TreasuryDoesNotConsumeWalletAllowance() public {
        vm.prank(treasury);
        keys.treasuryMint(1, bob);
        _open(1);
        _buy(bob, 1);
        assertEq(keys.balanceOf(bob), 2);
        assertEq(keys.mintedAmount(bob), 1);
    }

    function test_OnlyAdminCanManageSaleAndMetadata() public {
        bytes32 treasuryRole = keys.TREASURY_ROLE();
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, bytes32(0));
        vm.startPrank(bob);
        vm.expectRevert(denied);
        keys.setPublicMintActive(true, 3);
        vm.expectRevert(denied);
        keys.setWhitelistMintActive(true, 3);
        address[] memory accounts = new address[](0);
        vm.expectRevert(denied);
        keys.addToWhitelist(accounts);
        vm.expectRevert(denied);
        keys.removeFromWhitelist(accounts);
        vm.expectRevert(denied);
        keys.reveal("ipfs://test/");
        vm.expectRevert(denied);
        keys.grantRole(treasuryRole, bob);
        vm.stopPrank();
    }

    function test_OnlyTreasuryCanMintOrWithdraw() public {
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, keys.TREASURY_ROLE());
        vm.startPrank(bob);
        vm.expectRevert(denied);
        keys.treasuryMint(1, bob);
        vm.expectRevert(denied);
        keys.withdraw();
        vm.stopPrank();
    }

    function test_RevokedTreasuryLosesAccess() public {
        bytes32 role = keys.TREASURY_ROLE();
        keys.revokeRole(role, treasury);
        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, treasury, role)
        );
        keys.treasuryMint(1, bob);
    }

    function test_TransfersAndApprovedTransfersLockedUntilSoldOut() public {
        _open(1);
        _buy(bob, 1);
        vm.startPrank(bob);
        keys.approve(alice, 0);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.transferFrom(bob, alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.safeTransferFrom(bob, alice, 0);
        vm.warp(end + 1);
        vm.prank(bob);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        keys.transferFrom(bob, alice, 0);
    }

    function test_PaidSelloutWithoutTreasuryIsNotSuccessful() public {
        _open(5900);
        _buy(bob, 5900);
        assertFalse(keys.soldOut());
        vm.prank(treasury);
        vm.expectRevert("Not all tokens minted");
        keys.withdraw();
        vm.expectRevert("Not all tokens minted");
        keys.reveal("ipfs://test/");
        vm.warp(end + 1);
        assertTrue(keys.refundsAvailable());
        vm.prank(bob);
        keys.refund(0);
    }

    function test_SoldOutWithdrawsExactlyOnceAndEnablesTransfers() public {
        _sellOut();
        assertTrue(keys.soldOut());
        assertEq(keys.totalSupply(), 6400);
        uint256 beforeBalance = treasury.balance;
        vm.prank(treasury);
        keys.withdraw();
        assertEq(treasury.balance - beforeBalance, 59 ether);
        assertEq(address(keys).balance, 0);
        vm.prank(treasury);
        vm.expectRevert("No balance to withdraw");
        keys.withdraw();
        vm.prank(bob);
        keys.transferFrom(bob, alice, 0);
        assertEq(keys.ownerOf(0), alice);
        assertEq(keys.originalMinter(0), bob);
        vm.warp(end + 1);
        assertFalse(keys.refundsAvailable());
        vm.prank(bob);
        vm.expectRevert("All tokens minted");
        keys.refund(1);
    }

    function test_PublicSupplyCapCannotBeExceeded() public {
        _open(6000);
        _buy(bob, 5900);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("Max supply reached");
        keys.mint{value: 0.01 ether}(1);
    }

    function test_HiddenMetadataAndNonexistentId() public {
        _open(2);
        _buy(bob, 2);
        assertEq(keys.tokenURI(0), HIDDEN);
        assertEq(keys.tokenURI(1), HIDDEN);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        keys.tokenURI(2);
    }

    function test_RevealRequiresSellout() public {
        vm.expectRevert("Not all tokens minted");
        keys.reveal("ipfs://test/");
    }

    function test_RevealIsOneShotAndEmitsMetadataUpdate() public {
        _sellOut();
        assertEq(keys.tokenURI(6399), HIDDEN);
        vm.expectEmit(false, false, false, true);
        emit RyodanKeys.Revealed("ipfs://final/");
        vm.expectEmit(false, false, false, true);
        emit BatchMetadataUpdate(0, 6399);
        keys.reveal("ipfs://final/");
        assertTrue(keys.revealed());
        assertEq(keys.tokenURI(0), "ipfs://final/0.json");
        assertEq(keys.tokenURI(6399), "ipfs://final/6399.json");
        vm.expectRevert("Already revealed");
        keys.reveal("ipfs://replacement/");
    }

    event BatchMetadataUpdate(uint256 fromId, uint256 toId);

    function test_RevealRejectsEmptyOrMalformedBaseURI() public {
        _sellOut();
        vm.expectRevert("Base URI must end with slash");
        keys.reveal("");
        vm.expectRevert("Base URI must end with slash");
        keys.reveal("ipfs://final");
        assertFalse(keys.revealed());
    }

    function test_RefundBurnsTokenAndPaysOnlyOnce() public {
        _open(2);
        _buy(bob, 2);
        vm.warp(end + 1);
        uint256 beforeBalance = bob.balance;
        vm.prank(bob);
        keys.refund(0);
        assertEq(bob.balance - beforeBalance, 0.01 ether);
        assertTrue(keys.refunded(0));
        assertEq(keys.totalRefunded(), 1);
        assertEq(keys.totalSupply(), 1);
        assertEq(keys.mintedByUsers(), 2);
        assertEq(keys.mintedAmount(bob), 2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        keys.ownerOf(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        keys.tokenURI(0);
        vm.prank(bob);
        vm.expectRevert("Already refunded");
        keys.refund(0);
        vm.prank(bob);
        keys.refund(1);
        assertEq(bob.balance - beforeBalance, 0.02 ether);
        assertEq(address(keys).balance, 0);
        assertEq(keys.totalSupply(), 0);
    }

    function test_RefundRejectsNonexistentIdsWithoutDestroyingReserves() public {
        _open(2);
        _buy(bob, 2);
        vm.warp(end + 1);
        vm.startPrank(alice);
        vm.expectRevert("Token not eligible for refund");
        keys.refund(100_000);
        vm.expectRevert("Token not eligible for refund");
        keys.refund(type(uint256).max);
        vm.stopPrank();
        assertEq(address(keys).balance, 0.02 ether);
        assertFalse(keys.refunded(100_000));
        vm.prank(bob);
        keys.refund(0);
        assertEq(address(keys).balance, 0.01 ether);
    }

    function test_FreeTreasuryTokenCannotClaimRefund() public {
        _open(1);
        _buy(bob, 1);
        vm.prank(treasury);
        keys.treasuryMint(1, alice);
        vm.warp(end + 1);
        vm.prank(alice);
        vm.expectRevert("Token not eligible for refund");
        keys.refund(1);
        assertEq(keys.ownerOf(1), alice);
        assertEq(address(keys).balance, 0.01 ether);
    }

    function test_ThirdPartyCannotTriggerOrRedirectRefund() public {
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.startPrank(alice);
        vm.expectRevert("Not original minter");
        keys.refund(0);
        vm.expectRevert("Not original minter");
        keys.refundTo(0, payable(alice));
        vm.stopPrank();
        assertEq(address(keys).balance, 0.01 ether);
    }

    function test_RefundToRecipientAndZeroRecipientRejection() public {
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.startPrank(bob);
        vm.expectRevert("Zero refund recipient");
        keys.refundTo(0, payable(address(0)));
        keys.refundTo(0, payable(alice));
        vm.stopPrank();
        assertEq(alice.balance, 0.01 ether);
        assertTrue(keys.refunded(0));
    }

    function test_WithdrawCannotTakeRefundReserves() public {
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.prank(treasury);
        vm.expectRevert("Not all tokens minted");
        keys.withdraw();
        assertEq(address(keys).balance, 0.01 ether);
    }

    function test_SafeMintRejectsNonReceiverWithoutTakingPayment() public {
        _open(1);
        NonReceiverWallet wallet = new NonReceiverWallet();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(wallet)));
        wallet.buy{value: 0.01 ether}(keys);
        assertEq(address(keys).balance, 0);
        assertEq(keys.totalSupply(), 0);
        assertEq(keys.mintedAmount(address(wallet)), 0);
        assertEq(keys.originalMinter(0), address(0));
    }

    function test_RejectingNFTReceiverRollsBackTreasuryCounters() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        wallet.configure("", false, true);
        vm.prank(treasury);
        vm.expectRevert("NFT rejected");
        keys.treasuryMint(1, address(wallet));
        assertEq(keys.mintedByTreasury(), 0);
        assertEq(keys.totalSupply(), 0);
    }

    function test_MintCallbackCannotReenterAndSeesReservedState() public {
        _open(1);
        CallbackWallet wallet = new CallbackWallet(keys);
        wallet.configure(abi.encodeCall(keys.mint, (0)), false, false);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.01 ether}(1);
        assertTrue(wallet.attempted());
        assertFalse(wallet.reentered());
        assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(wallet.supplyInCallback(), 1);
        assertEq(wallet.minterInCallback(), address(wallet));
        assertEq(keys.mintedAmount(address(wallet)), 1);
    }

    function test_TreasuryCallbackCannotReenter() public {
        CallbackWallet wallet = new CallbackWallet(keys);
        keys.grantRole(keys.TREASURY_ROLE(), address(wallet));
        wallet.configure(abi.encodeCall(keys.treasuryMint, (1, address(wallet))), false, false);
        wallet.mintTreasury(1);
        assertFalse(wallet.reentered());
        assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(keys.mintedByTreasury(), 1);
    }

    function test_RefundCallbackCannotReenterAnotherPaidToken() public {
        _open(2);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.02 ether}(2);
        wallet.configure(abi.encodeCall(keys.refund, (1)), false, false);
        vm.warp(end + 1);
        wallet.claim(0);
        assertFalse(wallet.reentered());
        assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(keys.refunded(1));
        assertEq(address(wallet).balance, 0.01 ether);
        wallet.configure("", false, false);
        wallet.claim(1);
        assertEq(address(wallet).balance, 0.02 ether);
    }

    function test_RejectingEtherReceiverCanRetryRefundToAnotherAddress() public {
        _open(1);
        CallbackWallet wallet = new CallbackWallet(keys);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: 0.01 ether}(1);
        wallet.configure("", true, false);
        vm.warp(end + 1);
        vm.expectRevert("Failed to send Ether");
        wallet.claim(0);
        assertFalse(keys.refunded(0));
        assertEq(keys.ownerOf(0), address(wallet));
        assertEq(keys.totalSupply(), 1);
        assertEq(keys.totalRefunded(), 0);
        wallet.claimTo(0, payable(bob));
        assertEq(bob.balance, 0.01 ether);
    }

    function test_RejectingTreasuryCannotLoseProceeds() public {
        _sellOut();
        CallbackWallet wallet = new CallbackWallet(keys);
        keys.grantRole(keys.TREASURY_ROLE(), address(wallet));
        wallet.configure("", true, false);
        vm.expectRevert("Failed to send Ether");
        wallet.takeProceeds();
        assertEq(address(keys).balance, 59 ether);
        vm.prank(treasury);
        keys.withdraw();
        assertEq(address(keys).balance, 0);
    }

    function test_WithdrawCallbackCannotReenter() public {
        _sellOut();
        CallbackWallet wallet = new CallbackWallet(keys);
        keys.grantRole(keys.TREASURY_ROLE(), address(wallet));
        wallet.configure(abi.encodeCall(keys.withdraw, ()), false, false);
        wallet.takeProceeds();
        assertFalse(wallet.reentered());
        assertEq(wallet.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(address(wallet).balance, 59 ether);
    }

    function testFuzz_MintAccountingAndWalletLimit(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 40);
        _open(amount);
        _buy(bob, amount);
        assertEq(keys.totalSupply(), amount);
        assertEq(keys.mintedByUsers(), amount);
        assertEq(keys.balanceOf(bob), amount);
        assertEq(address(keys).balance, amount * keys.mintPrice());
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Max mint amount reached for address");
        keys.mint{value: 0.01 ether}(1);
    }

    function testFuzz_InvalidRefundIdsPreserveSolvency(uint256 id) public {
        id = bound(id, 1, type(uint256).max);
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.expectRevert("Token not eligible for refund");
        keys.refund(id);
        assertEq(address(keys).balance, 0.01 ether);
        assertEq(keys.totalRefunded(), 0);
    }

    function testFuzz_RefundOrderCannotExceedAmountPaid(uint256 first) public {
        first = bound(first, 0, 7);
        _open(8);
        _buy(bob, 8);
        vm.warp(end + 1);
        uint256 beforeBalance = bob.balance;
        vm.startPrank(bob);
        for (uint256 i; i < 8; i++) {
            keys.refund((first + i) % 8);
        }
        vm.stopPrank();
        assertEq(bob.balance - beforeBalance, 0.08 ether);
        assertEq(keys.totalRefunded(), 8);
        assertEq(keys.totalSupply(), 0);
        assertEq(address(keys).balance, 0);
    }

    function testFuzz_OnlyExactPaymentAccepted(uint256 paymentSeed, uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 20);
        uint256 payment = bound(paymentSeed, 0, 0.5 ether);
        vm.assume(payment != amount * keys.mintPrice());
        _open(20);
        vm.deal(bob, payment);
        vm.prank(bob);
        vm.expectRevert("Incorrect payment");
        keys.mint{value: payment}(amount);
        assertEq(address(keys).balance, 0);
        assertEq(keys.mintedByUsers(), 0);
    }

    function testFuzz_RefundCannotBeStolen(address thief) public {
        vm.assume(thief != bob);
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        vm.prank(thief);
        vm.expectRevert("Not original minter");
        keys.refundTo(0, payable(thief));
        assertEq(address(keys).balance, 0.01 ether);
        assertFalse(keys.refunded(0));
    }

    function testFuzz_DeadlineBoundary(uint256 durationSeed, uint256 offsetSeed) public {
        uint256 deadline = block.timestamp + bound(durationSeed, 1, 30 days);
        keys = new RyodanKeys(deadline, HIDDEN, address(this), treasury);
        _open(1);
        uint256 timestamp = deadline - 1 + bound(offsetSeed, 0, 3);
        vm.warp(timestamp);
        vm.deal(bob, 0.01 ether);
        vm.prank(bob);
        if (timestamp > deadline) {
            vm.expectRevert("Mint ended");
            keys.mint{value: 0.01 ether}(1);
            assertTrue(keys.refundsAvailable());
        } else {
            keys.mint{value: 0.01 ether}(1);
            assertFalse(keys.refundsAvailable());
        }
    }

    function testFuzz_UnauthorizedSaleAdministration(address account, bool active, uint256 limitSeed) public {
        vm.assume(account != address(this));
        uint256 limit = bound(limitSeed, 1, 5900);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, bytes32(0))
        );
        keys.setPublicMintActive(active, limit);
        assertFalse(keys.isPublicMintActive());
    }

    function test_RefundAfterApprovalClearsApprovalAndOwnership() public {
        _open(1);
        _buy(bob, 1);
        vm.prank(bob);
        keys.approve(alice, 0);
        vm.warp(end + 1);
        vm.prank(bob);
        keys.refund(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        keys.getApproved(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        keys.transferFrom(bob, alice, 0);
    }

    function test_ForcedEtherCannotChangeOutcomeOrRefundAmount() public {
        _open(1);
        _buy(bob, 1);
        vm.deal(address(keys), 1 ether);
        assertFalse(keys.soldOut());
        vm.warp(end + 1);
        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        keys.refund(0);
        assertEq(bob.balance - balanceBefore, 0.01 ether);
        assertEq(address(keys).balance, 0.99 ether);
        assertFalse(keys.soldOut());
    }

    function test_PausingOrChangingLimitsAfterExpiryCannotBlockRefunds() public {
        _open(1);
        _buy(bob, 1);
        vm.warp(end + 1);
        keys.setPublicMintActive(false, 100);
        keys.setWhitelistMintActive(true, 100);
        assertTrue(keys.refundsAvailable());
        vm.prank(bob);
        keys.refund(0);
        assertEq(keys.totalRefunded(), 1);
    }
}
