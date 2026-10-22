// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RyodanKeys is AccessControl, ERC721, IERC4906, ReentrancyGuard {
    uint256 public constant MAX_PUBLIC_SUPPLY = 5900;
    uint256 public constant MAX_TREASURY_SUPPLY = 500;
    uint256 public constant MAX_SUPPLY = MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY;
    uint256 public constant WL_MINT_AMOUNT = 1000;
    uint256 public constant mintPrice = 0.01 ether;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint256 public constant CONTRACT_VERSION = 2;
    uint256 public mintEndTime;
    uint256 public MAX_MINT_AMOUNT = 1;
    uint256 public totalSupply;
    uint256 public mintedByUsers;
    uint256 public mintedByTreasury;
    uint256 public mintedByWhitelist;
    uint256 public totalRefunded;
    bool public isPublicMintActive;
    bool public isWhitelistMintActive;
    bool public revealed;
    string public hiddenMetadataURI;
    string public revealedBaseURI;

    mapping(address => uint256) public mintedAmount;
    mapping(address => bool) public whitelisted;
    mapping(uint256 => address) public originalMinter;
    mapping(uint256 => bool) public refunded;

    event MintPhaseUpdated(bool publicActive, bool whitelistActive, uint256 maxPerWallet);
    event WhitelistUpdated(address indexed account, bool allowed);
    event Refunded(uint256 indexed tokenId, address indexed minter, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event Revealed(string baseURI);
    event MintEndTimeUpdated(uint256 previousEndTime, uint256 newEndTime);

    constructor(uint256 endTime, string memory hiddenURI, address admin, address treasury) ERC721("RyodanKeys", "RK") {
        require(endTime > block.timestamp, "Deadline must be in the future");
        require(bytes(hiddenURI).length > 0, "Empty metadata URI");
        require(admin != address(0) && treasury != address(0), "Zero role address");
        mintEndTime = endTime;
        hiddenMetadataURI = hiddenURI;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TREASURY_ROLE, treasury);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl, IERC165) returns (bool) {
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }

    function soldOut() public view returns (bool) {
        return mintedByUsers + mintedByTreasury == MAX_SUPPLY;
    }

    function refundsAvailable() public view returns (bool) {
        return block.timestamp > mintEndTime && !soldOut();
    }

    function setMintEndTime(uint256 newEndTime) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(!soldOut(), "All tokens minted");
        require(newEndTime > block.timestamp, "Deadline must be in the future");
        uint256 previousEndTime = mintEndTime;
        mintEndTime = newEndTime;
        emit MintEndTimeUpdated(previousEndTime, newEndTime);
    }

    function mint(uint256 amount) external payable nonReentrant {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(isPublicMintActive || isWhitelistMintActive, "Mint not active");
        require(amount > 0, "Zero mint amount");
        require(amount <= MAX_PUBLIC_SUPPLY - mintedByUsers, "Max supply reached");
        require(msg.value == mintPrice * amount, "Incorrect payment");
        require(mintedAmount[msg.sender] + amount <= MAX_MINT_AMOUNT, "Max mint amount reached for address");
        if (isWhitelistMintActive) {
            require(whitelisted[msg.sender], "Not whitelisted");
            require(amount <= WL_MINT_AMOUNT - mintedByWhitelist, "Max whitelist mint amount reached");
            mintedByWhitelist += amount;
        }

        uint256 firstTokenId = mintedByUsers + mintedByTreasury;
        mintedByUsers += amount;
        mintedAmount[msg.sender] += amount;
        totalSupply += amount;
        for (uint256 i = 0; i < amount; i++) {
            uint256 tokenId = firstTokenId + i;
            originalMinter[tokenId] = msg.sender;
            _safeMint(msg.sender, tokenId);
        }
    }

    function treasuryMint(uint256 amount, address to) external onlyRole(TREASURY_ROLE) nonReentrant {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(amount > 0, "Zero mint amount");
        require(amount <= MAX_TREASURY_SUPPLY - mintedByTreasury, "Max supply reached while minting to treasury");
        uint256 firstTokenId = mintedByUsers + mintedByTreasury;
        mintedByTreasury += amount;
        totalSupply += amount;
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(to, firstTokenId + i);
        }
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        _requireOwned(tokenId);
        return revealed ? string.concat(revealedBaseURI, Strings.toString(tokenId), ".json") : hiddenMetadataURI;
    }

    function reveal(string calldata baseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(soldOut(), "Not all tokens minted");
        require(!revealed, "Already revealed");
        bytes memory uri = bytes(baseURI);
        require(uri.length > 0 && uri[uri.length - 1] == 0x2f, "Base URI must end with slash");
        revealed = true;
        revealedBaseURI = baseURI;
        emit Revealed(baseURI);
        emit BatchMetadataUpdate(0, MAX_SUPPLY - 1);
    }

    function setPublicMintActive(bool active, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Zero wallet limit");
        isPublicMintActive = active;
        if (active) isWhitelistMintActive = false;
        MAX_MINT_AMOUNT = amount;
        emit MintPhaseUpdated(isPublicMintActive, isWhitelistMintActive, amount);
    }

    function setWhitelistMintActive(bool active, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Zero wallet limit");
        isWhitelistMintActive = active;
        if (active) isPublicMintActive = false;
        MAX_MINT_AMOUNT = amount;
        emit MintPhaseUpdated(isPublicMintActive, isWhitelistMintActive, amount);
    }

    function addToWhitelist(address[] calldata addresses) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelisted[addresses[i]] = true;
            emit WhitelistUpdated(addresses[i], true);
        }
    }

    function removeFromWhitelist(address[] calldata addresses) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelisted[addresses[i]] = false;
            emit WhitelistUpdated(addresses[i], false);
        }
    }

    // Only authorized treasury callers receive successful sale proceeds.
    // slither-disable-next-line arbitrary-send-eth
    function withdraw() external onlyRole(TREASURY_ROLE) nonReentrant {
        require(soldOut(), "Not all tokens minted");
        uint256 amount = address(this).balance;
        require(amount > 0, "No balance to withdraw");
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send Ether");
        emit Withdrawn(msg.sender, amount);
    }

    function refund(uint256 tokenId) external nonReentrant {
        _refund(tokenId, payable(msg.sender));
    }

    function refundTo(uint256 tokenId, address payable recipient) external nonReentrant {
        _refund(tokenId, recipient);
    }

    function _refund(uint256 tokenId, address payable recipient) private {
        require(block.timestamp > mintEndTime, "Mint not ended");
        require(!soldOut(), "All tokens minted");
        require(!refunded[tokenId], "Already refunded");
        address minter = originalMinter[tokenId];
        require(minter != address(0), "Token not eligible for refund");
        require(msg.sender == minter, "Not original minter");
        require(recipient != address(0), "Zero refund recipient");
        refunded[tokenId] = true;
        totalRefunded++;
        totalSupply--;
        _burn(tokenId);
        (bool sent,) = recipient.call{value: mintPrice}("");
        require(sent, "Failed to send Ether");
        emit Refunded(tokenId, minter, recipient, mintPrice);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && to != address(0)) {
            require(soldOut(), "RyodanKeys is not transferable since not all tokens have been minted");
        }
        return super._update(to, tokenId, auth);
    }
}
