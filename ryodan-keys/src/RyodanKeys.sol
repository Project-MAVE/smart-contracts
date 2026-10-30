// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract RyodanKeys is AccessControl, ERC721, IERC4906, ReentrancyGuard {
    uint256 public constant MAX_PUBLIC_SUPPLY = 6166;
    uint256 public constant MAX_TREASURY_SUPPLY = 500;
    uint256 public constant MAX_SUPPLY = MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint256 public constant CONTRACT_VERSION = 4;
    uint256 public constant MAX_REFUND_BATCH = 50;
    uint8 public constant PIONEER = 1;
    uint8 public constant OPERATIVE = 2;
    uint8 public constant RECRUIT = 3;
    uint8 public constant CIVILIAN = 4;

    struct PhaseConfig {
        uint256 price;
        uint256 walletLimit;
        uint256 minted;
        uint256 members;
        uint256 reserved;
        uint256 maxWalletMinted;
    }

    mapping(uint8 => PhaseConfig) public phases;
    bytes32 public allowlistRoot;
    bytes32 public allowlistSnapshotHash;
    bool public allowlistConfigured;
    mapping(uint8 => uint256) public tierMembers;
    mapping(uint8 => uint256) public registeredMembers;
    mapping(address => uint8) public walletTier;
    mapping(uint8 => mapping(address => uint256)) public mintedInPhase;
    uint8 public currentPhase;
    bool public mintPaused = true;
    uint256 public totalGtdReserved;
    uint256 public mintEndTime;
    uint256 public totalSupply;
    uint256 public mintedByUsers;
    uint256 public mintedByTreasury;
    uint256 public totalRefunded;
    bool public revealed;
    string public hiddenMetadataURI;
    string public revealedBaseURI;

    mapping(address => uint256) public mintedAmount;
    mapping(uint256 => address) public originalMinter;
    mapping(uint256 => uint256) public mintPayment;
    mapping(uint256 => bool) public refunded;

    event PhaseConfigured(uint8 indexed phase, uint256 price, uint256 walletLimit);
    event PhaseAdvanced(uint8 indexed previousPhase, uint8 indexed newPhase, uint256 releasedReservation);
    event MintPausedUpdated(bool paused);
    event AllowlistConfigured(
        bytes32 indexed root, bytes32 indexed snapshotHash, uint256 pioneer, uint256 operative, uint256 recruit
    );
    event EligibilityRegistered(address indexed account, uint8 tier);
    event PaidMint(
        address indexed minter, uint8 indexed phase, uint256 firstTokenId, uint256 amount, uint256 unitPrice
    );
    event Refunded(uint256 indexed tokenId, address indexed minter, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event Revealed(string baseURI);
    event MintEndTimeUpdated(uint256 previousEndTime, uint256 newEndTime);

    constructor(uint256 endTime, string memory hiddenURI, address admin, address treasury) ERC721("RyodanKeys", "RK") {
        require(endTime > block.timestamp, "Deadline must be in the future");
        require(bytes(hiddenURI).length > 0, "Empty metadata URI");
        require(admin != address(0) && treasury != address(0), "Zero role address");
        phases[PIONEER] = PhaseConfig(0.025 ether, 4, 0, 0, 0, 0);
        phases[OPERATIVE] = PhaseConfig(0.04 ether, 10, 0, 0, 0, 0);
        phases[RECRUIT] = PhaseConfig(0.045 ether, 10, 0, 0, 0, 0);
        phases[CIVILIAN] = PhaseConfig(0.05 ether, 10, 0, 0, 0, 0);
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

    function mintPrice() public view returns (uint256) {
        return phases[currentPhase].price;
    }

    function remainingAllowance(uint8 phaseId, address account) public view returns (uint256) {
        if (phaseId < PIONEER || phaseId > CIVILIAN || phaseId < currentPhase) return 0;
        if (phaseId != CIVILIAN && !allowlisted(phaseId, account)) return 0;
        uint256 limit = phases[phaseId].walletLimit;
        uint256 used = mintedInPhase[phaseId][account];
        return used < limit ? limit - used : 0;
    }

    function mint(uint256 amount, uint8 expectedPhase, uint256 expectedUnitPrice) external payable nonReentrant {
        _mintPaid(amount, expectedPhase, expectedUnitPrice);
    }

    function mintWithProof(
        uint256 amount,
        uint8 expectedPhase,
        uint256 expectedUnitPrice,
        uint8 tier,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        require(currentPhase != 0, "Mint not active");
        require(verifyEligibility(msg.sender, tier, proof), "Invalid allowlist proof");
        if (walletTier[msg.sender] == 0) {
            require(registeredMembers[tier] < tierMembers[tier], "Tier member count exceeded");
            registeredMembers[tier]++;
            walletTier[msg.sender] = tier;
            emit EligibilityRegistered(msg.sender, tier);
        } else {
            require(walletTier[msg.sender] == tier, "Tier already registered");
        }
        _mintPaid(amount, expectedPhase, expectedUnitPrice);
    }

    function allowlisted(uint8 phaseId, address account) public view returns (bool) {
        uint8 tier = walletTier[account];
        return phaseId >= PIONEER && phaseId <= RECRUIT && tier != 0 && tier <= phaseId;
    }

    function verifyEligibility(address account, uint8 tier, bytes32[] calldata proof) public view returns (bool) {
        if (account == address(0) || tier < PIONEER || tier > RECRUIT || tierMembers[tier] == 0) return false;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, tier))));
        return MerkleProof.verifyCalldata(proof, allowlistRoot, leaf);
    }

    function remainingAllowanceWithProof(uint8 phaseId, address account, uint8 tier, bytes32[] calldata proof)
        external
        view
        returns (uint256)
    {
        if (phaseId == CIVILIAN) return remainingAllowance(phaseId, account);
        if (
            phaseId < currentPhase || phaseId < PIONEER || phaseId > RECRUIT || tier > phaseId
                || !verifyEligibility(account, tier, proof)
        ) return 0;
        uint256 used = mintedInPhase[phaseId][account];
        uint256 limit = phases[phaseId].walletLimit;
        return used < limit ? limit - used : 0;
    }

    function _mintPaid(uint256 amount, uint8 expectedPhase, uint256 expectedUnitPrice) private {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(currentPhase != 0 && !mintPaused, "Mint not active");
        uint8 phaseId = currentPhase;
        PhaseConfig storage config = phases[phaseId];
        uint256 price = config.price;
        require(expectedPhase == phaseId && expectedUnitPrice == price, "Mint quote changed");
        require(amount > 0, "Zero mint amount");
        require(phaseId != PIONEER || amount % 2 == 0, "Pioneer requires pairs");
        require(amount <= MAX_PUBLIC_SUPPLY - mintedByUsers, "Max supply reached");
        require(msg.value == price * amount, "Incorrect payment");
        require(phaseId == CIVILIAN || allowlisted(phaseId, msg.sender), "Not allowlisted");
        uint256 walletMinted = mintedInPhase[phaseId][msg.sender] + amount;
        require(walletMinted <= config.walletLimit, "Max mint amount reached for address");
        if (phaseId <= OPERATIVE) {
            config.reserved -= amount;
            totalGtdReserved -= amount;
        } else {
            require(amount <= MAX_PUBLIC_SUPPLY - mintedByUsers - totalGtdReserved, "Supply reserved for GTD");
        }
        mintedInPhase[phaseId][msg.sender] = walletMinted;
        config.minted += amount;
        if (walletMinted > config.maxWalletMinted) config.maxWalletMinted = walletMinted;
        uint256 firstTokenId = mintedByUsers + mintedByTreasury;
        mintedByUsers += amount;
        mintedAmount[msg.sender] += amount;
        totalSupply += amount;
        emit PaidMint(msg.sender, phaseId, firstTokenId, amount, price);
        for (uint256 i; i < amount; i++) {
            uint256 tokenId = firstTokenId + i;
            originalMinter[tokenId] = msg.sender;
            mintPayment[tokenId] = price;
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

    function configurePhase(uint8 phaseId, uint256 price, uint256 walletLimit)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        _requireEditablePhase(phaseId);
        require(price > 0 && price <= type(uint256).max / MAX_PUBLIC_SUPPLY, "Invalid price");
        require(walletLimit > 0 && walletLimit <= MAX_PUBLIC_SUPPLY, "Invalid wallet limit");
        require(phaseId != PIONEER || walletLimit % 2 == 0, "Pioneer limit must be even");
        PhaseConfig storage config = phases[phaseId];
        if (phaseId <= OPERATIVE) {
            require(walletLimit >= config.maxWalletMinted, "Limit below minted allocation");
            uint256 nextReserved = config.reserved + config.members * walletLimit - config.members * config.walletLimit;
            _setReservation(config, nextReserved);
        }
        config.price = price;
        config.walletLimit = walletLimit;
        emit PhaseConfigured(phaseId, price, walletLimit);
    }

    function configureAllowlist(bytes32 root, bytes32 snapshotHash, uint256 pioneer, uint256 operative, uint256 recruit)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(currentPhase == 0, "Allowlist frozen");
        uint256 members = pioneer + operative + recruit;
        require((root == bytes32(0)) == (members == 0), "Root and counts mismatch");
        require(snapshotHash != bytes32(0), "Empty snapshot hash");
        uint256 pioneerReserved = pioneer * phases[PIONEER].walletLimit;
        uint256 operativeReserved = (pioneer + operative) * phases[OPERATIVE].walletLimit;
        require(pioneerReserved + operativeReserved <= MAX_PUBLIC_SUPPLY - mintedByUsers, "Insufficient GTD supply");
        tierMembers[PIONEER] = pioneer;
        tierMembers[OPERATIVE] = operative;
        tierMembers[RECRUIT] = recruit;
        phases[PIONEER].members = pioneer;
        phases[OPERATIVE].members = pioneer + operative;
        phases[RECRUIT].members = members;
        phases[PIONEER].reserved = pioneerReserved;
        phases[OPERATIVE].reserved = operativeReserved;
        totalGtdReserved = pioneerReserved + operativeReserved;
        allowlistRoot = root;
        allowlistSnapshotHash = snapshotHash;
        allowlistConfigured = true;
        emit AllowlistConfigured(root, snapshotHash, pioneer, operative, recruit);
    }

    function advancePhase() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(!soldOut(), "All tokens minted");
        uint8 previous = currentPhase;
        require(allowlistConfigured, "Configure allowlist first");
        require(previous < CIVILIAN, "Final phase reached");
        uint256 released = phases[previous].reserved;
        if (released > 0) _setReservation(phases[previous], 0);
        currentPhase = previous + 1;
        // Every transition requires a separate resume after reviewing the new phase.
        mintPaused = true;
        emit PhaseAdvanced(previous, currentPhase, released);
        emit MintPausedUpdated(true);
    }

    function setMintPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(currentPhase != 0, "No active phase");
        mintPaused = paused;
        emit MintPausedUpdated(paused);
    }

    function _requireEditablePhase(uint8 phaseId) private view {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(!soldOut(), "All tokens minted");
        require(phaseId >= PIONEER && phaseId <= CIVILIAN, "Invalid phase");
        require(phaseId >= currentPhase, "Phase closed");
    }

    function _setReservation(PhaseConfig storage config, uint256 nextReserved) private {
        uint256 nextTotal = totalGtdReserved - config.reserved + nextReserved;
        require(nextTotal <= MAX_PUBLIC_SUPPLY - mintedByUsers, "Insufficient GTD supply");
        config.reserved = nextReserved;
        totalGtdReserved = nextTotal;
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
        _refund(tokenId, payable(originalMinter[tokenId]));
    }

    function refundBatch(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_REFUND_BATCH, "Invalid refund batch size");
        for (uint256 i; i < tokenIds.length; i++) {
            _refund(tokenIds[i], payable(originalMinter[tokenIds[i]]));
        }
    }

    function refundTo(uint256 tokenId, address payable recipient) external nonReentrant {
        require(msg.sender == originalMinter[tokenId], "Not original minter");
        _refund(tokenId, recipient);
    }

    // Default destinations are original minters; only that minter can use refundTo.
    // Batches are capped at 50 and atomic; a rejecting wallet can retry via refundTo.
    // slither-disable-next-line arbitrary-send-eth,calls-loop
    function _refund(uint256 tokenId, address payable recipient) private {
        require(block.timestamp > mintEndTime, "Mint not ended");
        require(!soldOut(), "All tokens minted");
        require(!refunded[tokenId], "Already refunded");
        address minter = originalMinter[tokenId];
        require(minter != address(0), "Token not eligible for refund");
        require(recipient != address(0), "Zero refund recipient");
        uint256 amount = mintPayment[tokenId];
        refunded[tokenId] = true;
        totalRefunded++;
        totalSupply--;
        _burn(tokenId);
        (bool sent,) = recipient.call{value: amount}("");
        require(sent, "Failed to send Ether");
        emit Refunded(tokenId, minter, recipient, amount);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && to != address(0)) {
            require(soldOut(), "RyodanKeys is not transferable since not all tokens have been minted");
        }
        return super._update(to, tokenId, auth);
    }
}
