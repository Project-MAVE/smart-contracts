// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";

/// @notice Regression suite for the vulnerabilities found in RyodanKeys.sol.
///         Each test asserts that the exploit is now blocked and that the
///         intended behaviour (refund, withdraw, transfers) still works.
contract RyodanKeysSecurityTest is Test {
    RyodanKeys public nft;

    address internal treasury = makeAddr("treasury");
    address internal bob = makeAddr("bob");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant MINT_END = 1767139200;
    uint256 internal constant REFUND_END = MINT_END + 90 days;
    uint256 internal constant PRICE = 0.01 ether;
    uint256 internal constant MAX_TOTAL = 6400; // 5900 public + 500 treasury

    function setUp() public {
        nft = new RyodanKeys(MINT_END);
        nft.grantRole(nft.TREASURY_ROLE(), treasury);
    }

    function _mintOne(address who) internal {
        vm.prank(who);
        nft.mint{value: PRICE}(1);
    }

    /*//////////////////////////////////////////////////////////////
      F-01  refund() on a tokenId that was never minted used to send
            ETH to address(0) and drain the contract.
    //////////////////////////////////////////////////////////////*/

    function test_F01_refundOnUnmintedTokenIsRejected() public {
        nft.setPublicMintActive(true, 1);

        address[10] memory users;
        for (uint256 i = 0; i < 10; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            vm.deal(users[i], PRICE);
            _mintOne(users[i]);
        }
        assertEq(address(nft).balance, 10 * PRICE);

        vm.warp(MINT_END + 1);

        vm.prank(attacker);
        vm.expectRevert("Token not minted");
        nft.refund(10);

        assertEq(address(nft).balance, 10 * PRICE, "pool intact");
        assertEq(address(0).balance, 0, "nothing burned to the zero address");

        // Honest refunds still work.
        vm.prank(users[0]);
        nft.refund(0);
        assertEq(users[0].balance, PRICE);
    }

    /*//////////////////////////////////////////////////////////////
      F-02  treasuryMint() does not record a payer, so its tokens are
            no longer refundable at all.
    //////////////////////////////////////////////////////////////*/

    function test_F02_refundOnTreasuryTokenIsRejected() public {
        nft.treasuryMint(1, treasury); // tokenId 0, no payment
        assertEq(nft.originalMinter(0), address(0));

        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        _mintOne(bob); // tokenId 1

        assertEq(address(nft).balance, PRICE);
        vm.warp(MINT_END + 1);

        vm.prank(attacker);
        vm.expectRevert("Token not minted");
        nft.refund(0);

        assertEq(address(nft).balance, PRICE, "bob's ETH untouched");
        assertEq(address(0).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
      F-03  refund() now burns the NFT, so the minter cannot keep the
            token and get the money back.
    //////////////////////////////////////////////////////////////*/

    function test_F03_refundBurnsTheNFT() public {
        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        uint256 startBalance = bob.balance;

        _mintOne(bob);
        assertEq(nft.ownerOf(0), bob);

        vm.warp(MINT_END + 1);
        vm.prank(bob);
        nft.refund(0);

        assertEq(bob.balance, startBalance, "refunded");
        vm.expectRevert();
        nft.ownerOf(0); // burned
        assertEq(nft.balanceOf(bob), 0);
        assertEq(nft.refundPool(), 0, "reserve released");

        // Cannot be refunded twice.
        vm.prank(bob);
        vm.expectRevert("Already refunded");
        nft.refund(0);
    }

    /*//////////////////////////////////////////////////////////////
      F-04  refund() is now restricted to the original minter.
    //////////////////////////////////////////////////////////////*/

    function test_F04_onlyOriginalMinterCanRefund() public {
        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        _mintOne(bob);

        vm.warp(MINT_END + 1);
        uint256 bobBefore = bob.balance;

        vm.prank(attacker);
        vm.expectRevert("Only the original minter can refund");
        nft.refund(0);

        assertFalse(nft.refunded(0));
        assertEq(bob.balance, bobBefore);
        assertEq(nft.ownerOf(0), bob);
    }

    /*//////////////////////////////////////////////////////////////
      F-05  the public and whitelist phases no longer share a single
            max-mint-per-address slot.
    //////////////////////////////////////////////////////////////*/

    function test_F05_mintCapsAreIndependent() public {
        nft.setWhitelistMintActive(true, 10);
        nft.setPublicMintActive(true, 1);

        assertEq(nft.maxWhitelistMintAmount(), 10, "whitelist cap preserved");
        assertEq(nft.maxPublicMintAmount(), 1, "public cap preserved");

        address[] memory wl = new address[](1);
        wl[0] = bob;
        nft.addToWhitelist(wl);

        // Whitelisted bob gets his 10, not the public cap of 1.
        vm.deal(bob, 10 * PRICE);
        vm.prank(bob);
        nft.mint{value: 10 * PRICE}(10);
        assertEq(nft.balanceOf(bob), 10);

        // Public phase, whitelist off: alice is capped at 1.
        nft.setWhitelistMintActive(false, 0);
        vm.deal(alice, 2 * PRICE);
        vm.prank(alice);
        nft.mint{value: PRICE}(1);
        vm.prank(alice);
        vm.expectRevert("Max mint amount reached for address");
        nft.mint{value: PRICE}(1);
    }

    /*//////////////////////////////////////////////////////////////
      F-06  tokenURI() validates token existence.
    //////////////////////////////////////////////////////////////*/

    function test_F06_tokenURIValidatesExistence() public {
        vm.expectRevert();
        nft.tokenURI(9999);

        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        _mintOne(bob);
        assertEq(nft.tokenURI(0), "ipfs://QmZ/soulbound/");
    }

    /*//////////////////////////////////////////////////////////////
      F-07  mint() rejects amount == 0 and non-exact payment.
    //////////////////////////////////////////////////////////////*/

    function test_F07_mintRejectsZeroAmountAndWrongPayment() public {
        nft.setPublicMintActive(true, 1);
        vm.deal(bob, 1 ether);

        vm.prank(bob);
        vm.expectRevert("Amount must be greater than 0");
        nft.mint{value: 0}(0);

        vm.prank(bob);
        vm.expectRevert("Incorrect payment");
        nft.mint{value: 0.5 ether}(1);

        vm.prank(bob);
        vm.expectRevert("Incorrect payment");
        nft.mint{value: 0}(1);

        assertEq(bob.balance, 1 ether, "no ETH lost");
        assertEq(address(nft).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
      F-08  the refund reserve is released once refunds close, so the
            treasury is never permanently locked out of the proceeds.
    //////////////////////////////////////////////////////////////*/

    function test_F08_refundReserveIsReleased() public {
        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        _mintOne(bob);

        vm.warp(MINT_END + 1);
        assertEq(nft.refundReserve(), PRICE, "reserved while refunds are open");

        // While refunds are open the reserve cannot be withdrawn.
        vm.prank(treasury);
        vm.expectRevert("No balance to withdraw");
        nft.withdraw();

        // Once the refund period closes, the leftover reserve is withdrawable.
        vm.warp(REFUND_END + 1);
        assertEq(nft.refundReserve(), 0);
        vm.prank(treasury);
        nft.withdraw();
        assertEq(treasury.balance, PRICE);
        assertEq(address(nft).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
      F-09  the refund window is now bounded and the mint end time is
            a validated, future constructor argument.
    //////////////////////////////////////////////////////////////*/

    function test_F09_refundWindowIsBounded() public {
        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        _mintOne(bob);

        vm.warp(REFUND_END + 1);
        vm.prank(bob);
        vm.expectRevert("Refund period ended");
        nft.refund(0);
    }

    function test_F09_constructorRejectsPastMintEnd() public {
        vm.expectRevert("Mint end must be in the future");
        new RyodanKeys(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
      F-10  a malicious minter cannot re-enter refund() to double spend
            the ETH reserve.
    //////////////////////////////////////////////////////////////*/

    function test_F10_reentrancyOnRefundIsBlocked() public {
        nft.setPublicMintActive(true, 2);

        ReentrantMinter malicious = new ReentrantMinter(nft);
        vm.deal(address(malicious), 2 * PRICE);
        malicious.mintOne{value: PRICE}();
        malicious.mintOne{value: PRICE}();
        assertEq(address(nft).balance, 2 * PRICE);

        vm.warp(MINT_END + 1);
        vm.expectRevert("Failed to send Ether");
        malicious.attack(0);

        // The whole transaction rolled back: nothing burned, nothing paid out.
        assertEq(address(nft).balance, 2 * PRICE);
        assertEq(nft.ownerOf(0), address(malicious));
        assertFalse(nft.refunded(0));
    }

    /*//////////////////////////////////////////////////////////////
      Regression: the original soulbound design still holds.
    //////////////////////////////////////////////////////////////*/

    function test_regression_transfersBlockedUntilSoldOut() public {
        nft.setPublicMintActive(true, 1);
        vm.deal(bob, PRICE);
        _mintOne(bob);

        vm.prank(bob);
        vm.expectRevert("RyodanKeys is not transferable since not all tokens have been minted");
        nft.transferFrom(bob, alice, 0);

        // Burning through refund() must remain possible.
        vm.warp(MINT_END + 1);
        vm.prank(bob);
        nft.refund(0);
        assertEq(nft.totalSupply(), 1, "id counter untouched by burns");
    }

    function test_regression_treasuryMintRejectsZeroAddress() public {
        vm.expectRevert("Invalid recipient");
        nft.treasuryMint(1, address(0));
    }

    function test_regression_refundPoolNeverExceedsBalance() public {
        nft.setPublicMintActive(true, 10);
        vm.deal(bob, 10 * PRICE);
        vm.prank(bob);
        nft.mint{value: 10 * PRICE}(10);
        assertEq(nft.refundPool(), 10 * PRICE);
        assertEq(address(nft).balance, nft.refundPool());

        vm.warp(MINT_END + 1);
        vm.startPrank(bob);
        nft.refund(0);
        nft.refund(3);
        vm.stopPrank();

        assertEq(nft.refundPool(), 8 * PRICE);
        assertEq(address(nft).balance, 8 * PRICE);
        assertLt(nft.totalSupply(), MAX_TOTAL);
    }
}

contract ReentrantMinter {
    RyodanKeys private immutable nft;

    constructor(RyodanKeys nft_) {
        nft = nft_;
    }

    function mintOne() external payable {
        nft.mint{value: msg.value}(1);
    }

    function attack(uint256 tokenId) external {
        nft.refund(tokenId);
    }

    receive() external payable {
        nft.refund(0);
    }
}
