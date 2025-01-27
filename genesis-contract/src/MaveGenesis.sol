// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract MaveGenesis is AccessControl, ERC721 {
    uint256 constant MAX_SUPPLY = 10000;
    uint256 public totalSupply = 0;
    uint256 constant mintPrice = 0.01 ether;
    uint256 constant mintStartTime = 1735689600;
    uint256 constant mintEndTime = 1767139200;
    string constant BASE_URI = "ipfs://QmZ/";
    mapping(uint256 => address) public originalMinter;
    mapping(uint256 => bool) public refunded;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    constructor() ERC721("MaveGenesis", "MAVE") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function mint(uint256 amount) public payable {
        require(block.timestamp >= mintStartTime, "Mint not started");
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(totalSupply + amount <= MAX_SUPPLY, "Max supply reached");
        require(msg.value >= mintPrice * amount, "Insufficient funds");

        for (uint256 i = 0; i < amount; i++) {
            _mint(msg.sender, totalSupply + i);
        }
        totalSupply += amount;
    }

    function tokenURI(
        uint256 tokenId
    ) public pure override returns (string memory) {
        return string.concat(BASE_URI, Strings.toString(tokenId), ".json");
    }

    function withdraw() public onlyRole(TREASURY_ROLE) {
        require(address(this).balance > 0, "No balance to withdraw");
        require(totalSupply == MAX_SUPPLY, "Not all tokens minted");
        payable(msg.sender).transfer(address(this).balance);
    }

    function refund(uint256 tokenId) public {
        require(block.timestamp > mintEndTime, "Mint not ended");
        require(totalSupply < MAX_SUPPLY, "All tokens minted");
        require(!refunded[tokenId], "Already refunded");
        require(
            originalMinter[tokenId] == msg.sender,
            "Not the original minter"
        );
        refunded[tokenId] = true;
        payable(msg.sender).transfer(mintPrice);
    }
}
