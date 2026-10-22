// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract LegacyRyodanKeys is AccessControl, ERC721 {
    uint256 constant MAX_PUBLIC_SUPPLY = 5900;
    uint256 constant MAX_TREASURY_SUPPLY = 500;
    uint256 constant WL_MINT_AMOUNT = 1000;
    uint256 public MAX_MINT_AMOUNT = 1;
    uint256 public totalSupply = 0;
    uint256 public mintedByUsers = 0;
    uint256 public mintedByTreasury = 0;
    uint256 public mintedByWhitelist = 0;
    uint256 constant mintPrice = 0.01 ether;
    uint256 constant mintEndTime = 1767139200;
    string constant BASE_URI = "ipfs://QmZ/";
    string constant BASE_URI_SOULBOUND = "ipfs://QmZ/soulbound/";
    bool public isPublicMintActive = false;
    bool public isWhitelistMintActive = false;
    mapping(address => uint256) public mintedAmount;
    mapping(address => bool) public whitelisted;
    mapping(uint256 => address) public originalMinter;
    mapping(uint256 => bool) public refunded;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    constructor() ERC721("RyodanKeys", "RK") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function mint(uint256 amount) public payable {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(isPublicMintActive || isWhitelistMintActive, "Mint not active");
        require(mintedByUsers + amount <= MAX_PUBLIC_SUPPLY, "Max supply reached");
        require(msg.value >= mintPrice * amount, "Insufficient funds");
        require(mintedAmount[msg.sender] + amount <= MAX_MINT_AMOUNT, "Max mint amount reached for address");
        if (isWhitelistMintActive) {
            require(whitelisted[msg.sender], "Not whitelisted");
            require(mintedByWhitelist + amount <= WL_MINT_AMOUNT, "Max whitelist mint amount reached");
            mintedByWhitelist += amount;
        }
        for (uint256 i = 0; i < amount; i++) {
            _mint(msg.sender, totalSupply);
            originalMinter[totalSupply] = msg.sender;
            totalSupply++;
            mintedByUsers++;
        }
        mintedAmount[msg.sender] += amount;
    }

    function treasuryMint(uint256 amount, address to) public onlyRole(TREASURY_ROLE) {
        require(mintedByTreasury + amount <= MAX_TREASURY_SUPPLY, "Max supply reached while minting to treasury");
        require(block.timestamp <= mintEndTime, "Mint ended");
        for (uint256 i = 0; i < amount; i++) {
            _mint(to, totalSupply);
            totalSupply++;
            mintedByTreasury++;
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (totalSupply < MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY) {
            return BASE_URI_SOULBOUND;
        } else {
            return BASE_URI;
        }
    }

    function setPublicMintActive(bool active, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        isPublicMintActive = active;
        MAX_MINT_AMOUNT = amount;
    }

    function setWhitelistMintActive(bool active, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        isWhitelistMintActive = active;
        MAX_MINT_AMOUNT = amount;
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

    function withdraw() public onlyRole(TREASURY_ROLE) {
        require(address(this).balance > 0, "No balance to withdraw");
        require(totalSupply == MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY, "Not all tokens minted");
        (bool sent, bytes memory _data) = payable(msg.sender).call{value: address(this).balance}("");
        require(sent, "Failed to send Ether");
    }

    function refund(uint256 tokenId) public {
        require(block.timestamp > mintEndTime, "Mint not ended");
        require(totalSupply < MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY, "All tokens minted");
        require(!refunded[tokenId], "Already refunded");
        refunded[tokenId] = true;
        (bool sent, bytes memory _data) = payable(originalMinter[tokenId]).call{value: mintPrice}("");
        require(sent, "Failed to send Ether");
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (totalSupply < MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY) {
            require(
                _ownerOf(tokenId) == address(0), "RyodanKeys is not transferable since not all tokens have been minted"
            );
        }
        return super._update(to, tokenId, auth);
    }
}
