// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RyodanKeys is AccessControl, ERC721, ReentrancyGuard {
    uint256 public constant MAX_PUBLIC_SUPPLY = 5900;
    uint256 public constant MAX_TREASURY_SUPPLY = 500;
    uint256 public constant MAX_TOTAL_SUPPLY = MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY;
    uint256 public constant WL_MINT_AMOUNT = 1000;
    uint256 public constant MINT_PRICE = 0.01 ether;
    uint256 public constant REFUND_PERIOD = 90 days;

    string constant BASE_URI = "ipfs://QmZ/";
    string constant BASE_URI_SOULBOUND = "ipfs://QmZ/soulbound/";

    uint256 public maxPublicMintAmount = 1;
    uint256 public maxWhitelistMintAmount = 1;

    uint256 public totalSupply = 0;
    uint256 public mintedByUsers = 0;
    uint256 public mintedByTreasury = 0;
    uint256 public mintedByWhitelist = 0;
    uint256 public refundPool = 0;

    uint256 public immutable mintEndTime;
    uint256 public immutable refundEndTime;

    bool public isPublicMintActive = false;
    bool public isWhitelistMintActive = false;
    mapping(address => uint256) public mintedAmount;
    mapping(address => bool) public whitelisted;
    mapping(uint256 => address) public originalMinter;
    mapping(uint256 => bool) public refunded;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    event Minted(address indexed to, uint256 indexed tokenId, bool whitelist);
    event TreasuryMinted(address indexed to, uint256 amount);
    event Refunded(uint256 indexed tokenId, address indexed minter);
    event MintPhaseUpdated(bool publicActive, bool whitelistActive);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(uint256 mintEndTime_) ERC721("RyodanKeys", "RK") {
        require(mintEndTime_ > block.timestamp, "Mint end must be in the future");
        mintEndTime = mintEndTime_;
        refundEndTime = mintEndTime_ + REFUND_PERIOD;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function mint(uint256 amount) public payable {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(isPublicMintActive || isWhitelistMintActive, "Mint not active");
        require(amount > 0, "Amount must be greater than 0");
        require(msg.value == MINT_PRICE * amount, "Incorrect payment");
        require(mintedByUsers + amount <= MAX_PUBLIC_SUPPLY, "Max supply reached");

        bool whitelistMint = false;
        uint256 maxAmount = maxPublicMintAmount;
        if (isWhitelistMintActive) {
            require(whitelisted[msg.sender], "Not whitelisted");
            require(mintedByWhitelist + amount <= WL_MINT_AMOUNT, "Max whitelist mint amount reached");
            mintedByWhitelist += amount;
            maxAmount = maxWhitelistMintAmount;
            whitelistMint = true;
        }
        require(mintedAmount[msg.sender] + amount <= maxAmount, "Max mint amount reached for address");

        refundPool += MINT_PRICE * amount;
        for (uint256 i = 0; i < amount; i++) {
            uint256 tokenId = totalSupply;
            _mint(msg.sender, tokenId);
            originalMinter[tokenId] = msg.sender;
            totalSupply++;
            mintedByUsers++;
            emit Minted(msg.sender, tokenId, whitelistMint);
        }
        mintedAmount[msg.sender] += amount;
    }

    function treasuryMint(uint256 amount, address to) public onlyRole(TREASURY_ROLE) {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(mintedByTreasury + amount <= MAX_TREASURY_SUPPLY, "Max supply reached while minting to treasury");
        for (uint256 i = 0; i < amount; i++) {
            _mint(to, totalSupply);
            totalSupply++;
            mintedByTreasury++;
        }
        emit TreasuryMinted(to, amount);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (totalSupply < MAX_TOTAL_SUPPLY) {
            return BASE_URI_SOULBOUND;
        } else {
            return BASE_URI;
        }
    }

    function setPublicMintActive(bool active, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        isPublicMintActive = active;
        maxPublicMintAmount = amount;
        emit MintPhaseUpdated(isPublicMintActive, isWhitelistMintActive);
    }

    function setWhitelistMintActive(bool active, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        isWhitelistMintActive = active;
        maxWhitelistMintAmount = amount;
        emit MintPhaseUpdated(isPublicMintActive, isWhitelistMintActive);
    }

    function addToWhitelist(address[] calldata addresses) public onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelisted[addresses[i]] = true;
        }
    }

    function removeFromWhitelist(address[] calldata addresses) public onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelisted[addresses[i]] = false;
        }
    }

    function withdraw() public onlyRole(TREASURY_ROLE) nonReentrant {
        uint256 available = address(this).balance - refundReserve();
        require(available > 0, "No balance to withdraw");
        (bool sent,) = payable(msg.sender).call{value: available}("");
        require(sent, "Failed to send Ether");
        emit Withdrawn(msg.sender, available);
    }

    function refund(uint256 tokenId) public nonReentrant {
        require(block.timestamp > mintEndTime, "Mint not ended");
        require(block.timestamp <= refundEndTime, "Refund period ended");
        require(totalSupply < MAX_TOTAL_SUPPLY, "All tokens minted");
        require(!refunded[tokenId], "Already refunded");

        address minter = originalMinter[tokenId];
        require(minter != address(0), "Token not minted");
        require(msg.sender == minter, "Only the original minter can refund");

        refunded[tokenId] = true;
        refundPool -= MINT_PRICE;
        _burn(tokenId);

        (bool sent,) = payable(minter).call{value: MINT_PRICE}("");
        require(sent, "Failed to send Ether");
        emit Refunded(tokenId, minter);
    }

    /// @notice ETH that must stay in the contract to honour pending refunds.
    ///         Released to the treasury only once refunds are permanently closed,
    ///         i.e. when the collection is sold out or the refund period expired.
    function refundReserve() public view returns (uint256) {
        if (totalSupply == MAX_TOTAL_SUPPLY || block.timestamp > refundEndTime) {
            return 0;
        }
        return refundPool;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            require(
                totalSupply == MAX_TOTAL_SUPPLY, "RyodanKeys is not transferable since not all tokens have been minted"
            );
        }
        return super._update(to, tokenId, auth);
    }
}
