// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract RyodanKeys is AccessControlDefaultAdminRules, ERC721, IERC4906, ReentrancyGuard {
    uint256 public constant MAX_PUBLIC_SUPPLY = 6166;
    uint256 public constant MAX_TREASURY_SUPPLY = 500;
    uint256 public constant MAX_SUPPLY = MAX_PUBLIC_SUPPLY + MAX_TREASURY_SUPPLY;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint256 public constant CONTRACT_VERSION = 7;
    /// After an unsuccessful expiry, only original minters may keep or refund their keys during this window.
    uint256 public constant CHOICE_WINDOW = 4 days;
    /// Gas given to each recipient inside refundBatch: enough for wallets and multisigs, too little to stall a batch.
    uint256 public constant BATCH_REFUND_GAS = 50_000;
    uint256 public constant MAX_REFUND_BATCH = 50;
    /// Token IDs run from 1 to 6666, so key #0042 is token 42.
    uint256 public constant FIRST_TOKEN_ID = 1;
    uint8 public constant PIONEER = 1;
    uint8 public constant OPERATIVE = 2;
    uint8 public constant RECRUIT = 3;
    uint8 public constant CIVILIAN = 4;

    struct PhaseConfig {
        uint256 price;
        uint256 walletLimit;
        uint256 minted;
        uint256 members;
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
    /// Guaranteed keys a wallet has minted across PIONEER and OPERATIVE together.
    mapping(address => uint256) public gtdMinted;
    uint8 public currentPhase;
    bool public mintPaused = true;
    /// The single reservation for every guaranteed key still unminted: Pioneers and Operatives share it, it is not
    /// split by phase, and it is released only when RECRUIT opens.
    uint256 public totalGtdReserved;
    /// Fixed at deploy: no function can move it, so refunds always open right after it.
    uint256 public immutable mintEndTime;
    uint256 public totalSupply;
    uint256 public mintedByUsers;
    uint256 public mintedByTreasury;
    uint256 public totalRefunded;
    // v5: two numbered metadata sets, both fixed at deploy (<base><id>.json, one file per key, e.g. "Gatebreaker #0042").
    // Locked keys (soulbound) read the SBT set; keys that become NFTs (sellout, or kept after an unsuccessful sale)
    // switch to the NFT set by themselves. No reveal transaction.
    string public sbtBaseURI;
    string public nftBaseURI;
    uint256 public totalBurned;

    mapping(address => uint256) public mintedAmount;
    mapping(uint256 => address) public originalMinter;
    mapping(uint256 => uint256) public mintPayment;
    mapping(uint256 => bool) public refunded;

    // KEEP OR REFUND (v5): without a sellout, an original minter may keep chosen keys as transferable NFTs.
    mapping(uint256 => bool) public kept;
    uint256 public totalKept;
    uint256 public keptFunds;
    uint256 public keptWithdrawn;
    // Batch refunds never revert on a rejecting recipient: the amount waits here until the minter pulls it.
    mapping(address => uint256) public pendingRefund;
    uint256 public totalPendingRefund;

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
    event Kept(uint256 indexed tokenId, address indexed minter, uint256 amount);
    event RefundDeferred(uint256 indexed tokenId, address indexed minter, uint256 amount);
    event PendingRefundClaimed(address indexed minter, address indexed recipient, uint256 amount);
    event TreasuryKeyBurned(uint256 indexed tokenId);

    constructor(uint256 endTime, string memory sbtBase, string memory nftBase, address admin, address treasury)
        ERC721("RyodanKeys", "RK")
        AccessControlDefaultAdminRules(0, admin)
    {
        require(endTime > block.timestamp, "Deadline must be in the future");
        require(_isBase(sbtBase) && _isBase(nftBase), "Base URI must end with slash");
        require(admin != address(0) && treasury != address(0), "Zero role address");
        phases[PIONEER] = PhaseConfig(0.0075 ether, 4, 0, 0, 0);
        phases[OPERATIVE] = PhaseConfig(0.012 ether, 4, 0, 0, 0);
        phases[RECRUIT] = PhaseConfig(0.0135 ether, 10, 0, 0, 0);
        phases[CIVILIAN] = PhaseConfig(0.015 ether, 20, 0, 0, 0);
        mintEndTime = endTime;
        sbtBaseURI = sbtBase;
        nftBaseURI = nftBase;
        _grantRole(TREASURY_ROLE, treasury);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControlDefaultAdminRules, IERC165)
        returns (bool)
    {
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }

    function soldOut() public view returns (bool) {
        return mintedByUsers + mintedByTreasury == MAX_SUPPLY;
    }

    function refundsAvailable() public view returns (bool) {
        return block.timestamp > mintEndTime && !soldOut();
    }

    function mintPrice() public view returns (uint256) {
        return phases[currentPhase].price;
    }

    function remainingAllowance(uint8 phaseId, address account) public view returns (uint256) {
        if (phaseId < PIONEER || phaseId > CIVILIAN || phaseId < currentPhase) return 0;
        if (phaseId != CIVILIAN && !allowlisted(phaseId, account)) return 0;
        return _remaining(phaseId, account, walletTier[account]);
    }

    /// Limits restart in every phase. PIONEER and OPERATIVE also share one guaranteed allocation per wallet: the
    /// limit of the wallet's own tier, counted once across both phases by gtdMinted.
    function _remaining(uint8 phaseId, address account, uint8 tier) private view returns (uint256) {
        uint256 limit = phases[phaseId].walletLimit;
        uint256 used = mintedInPhase[phaseId][account];
        uint256 left = used < limit ? limit - used : 0;
        if (phaseId <= OPERATIVE) {
            uint256 gtdLimit = phases[tier].walletLimit;
            uint256 gtdUsed = gtdMinted[account];
            uint256 gtdLeft = gtdUsed < gtdLimit ? gtdLimit - gtdUsed : 0;
            if (gtdLeft < left) left = gtdLeft;
        }
        return left;
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
        return _remaining(phaseId, account, tier);
    }

    function _mintPaid(uint256 amount, uint8 expectedPhase, uint256 expectedUnitPrice) private {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(currentPhase != 0 && !mintPaused, "Mint not active");
        uint8 phaseId = currentPhase;
        PhaseConfig storage config = phases[phaseId];
        uint256 price = config.price;
        require(expectedPhase == phaseId && expectedUnitPrice == price, "Mint quote changed");
        require(amount > 0, "Zero mint amount");
        require(amount <= MAX_PUBLIC_SUPPLY - mintedByUsers, "Max supply reached");
        require(msg.value == price * amount, "Incorrect payment");
        require(phaseId == CIVILIAN || allowlisted(phaseId, msg.sender), "Not allowlisted");
        require(
            amount <= _remaining(phaseId, msg.sender, walletTier[msg.sender]), "Max mint amount reached for address"
        );
        uint256 walletMinted = mintedInPhase[phaseId][msg.sender] + amount;
        if (phaseId <= OPERATIVE) {
            // Every guaranteed mint draws on the wallet's own allocation inside the single reservation.
            gtdMinted[msg.sender] += amount;
            totalGtdReserved -= amount;
        } else {
            require(amount <= MAX_PUBLIC_SUPPLY - mintedByUsers - totalGtdReserved, "Supply reserved for GTD");
        }
        mintedInPhase[phaseId][msg.sender] = walletMinted;
        config.minted += amount;
        if (walletMinted > config.maxWalletMinted) config.maxWalletMinted = walletMinted;
        uint256 firstTokenId = FIRST_TOKEN_ID + mintedByUsers + mintedByTreasury;
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
        _announceSellout();
    }

    function treasuryMint(uint256 amount, address to) external onlyRole(TREASURY_ROLE) nonReentrant {
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(amount > 0, "Zero mint amount");
        require(amount <= MAX_TREASURY_SUPPLY - mintedByTreasury, "Max supply reached while minting to treasury");
        uint256 firstTokenId = FIRST_TOKEN_ID + mintedByUsers + mintedByTreasury;
        mintedByTreasury += amount;
        totalSupply += amount;
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(to, firstTokenId + i);
        }
        _announceSellout();
    }

    /// The mint that completes the sale tells marketplaces that every key switched to the NFT metadata.
    function _announceSellout() private {
        if (soldOut()) emit BatchMetadataUpdate(FIRST_TOKEN_ID, MAX_SUPPLY);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        _requireOwned(tokenId);
        string memory base = soldOut() || kept[tokenId] ? nftBaseURI : sbtBaseURI;
        return string.concat(base, Strings.toString(tokenId), ".json");
    }

    function _isBase(string memory uri) private pure returns (bool) {
        bytes memory b = bytes(uri);
        return b.length > 1 && b[b.length - 1] == 0x2f;
    }

    /// @notice Burn an unlocked key (after a sellout, or a kept key). Owner or approved operator, e.g. the future
    /// burn-to-redeem contract.
    function burn(uint256 tokenId) external {
        require(soldOut() || kept[tokenId], "Key is locked");
        totalSupply--;
        totalBurned++;
        _update(address(0), tokenId, _msgSender());
    }

    function configurePhase(uint8 phaseId, uint256 price, uint256 walletLimit)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        // Prices and limits are final once the first phase opens: no role can reprice or resize a running sale.
        require(currentPhase == 0, "Phases locked");
        require(block.timestamp <= mintEndTime, "Mint ended");
        require(phaseId >= PIONEER && phaseId <= CIVILIAN, "Invalid phase");
        require(price > 0 && price <= type(uint256).max / MAX_PUBLIC_SUPPLY, "Invalid price");
        require(walletLimit > 0 && walletLimit <= MAX_PUBLIC_SUPPLY, "Invalid wallet limit");
        PhaseConfig storage config = phases[phaseId];
        config.price = price;
        config.walletLimit = walletLimit;
        if (allowlistConfigured) _reserveGtd(tierMembers[PIONEER], tierMembers[OPERATIVE]);
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
        _reserveGtd(pioneer, operative);
        tierMembers[PIONEER] = pioneer;
        tierMembers[OPERATIVE] = operative;
        tierMembers[RECRUIT] = recruit;
        phases[PIONEER].members = pioneer;
        phases[OPERATIVE].members = pioneer + operative;
        phases[RECRUIT].members = members;
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
        // Unused guarantees stay reserved through OPERATIVE; the reservation ends when RECRUIT opens.
        uint256 released = previous == OPERATIVE ? totalGtdReserved : 0;
        if (previous == OPERATIVE) {
            totalGtdReserved = 0;
        }
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

    /// Guaranteed keys: each Pioneer once (Pioneer limit, shared by PIONEER and OPERATIVE), each Operative once.
    function _reserveGtd(uint256 pioneer, uint256 operative) private {
        uint256 reserved = pioneer * phases[PIONEER].walletLimit + operative * phases[OPERATIVE].walletLimit;
        require(reserved <= MAX_PUBLIC_SUPPLY - mintedByUsers, "Insufficient GTD supply");
        totalGtdReserved = reserved;
    }

    // Only authorized treasury callers receive successful sale proceeds.
    // slither-disable-next-line arbitrary-send-eth
    function withdraw() external onlyRole(TREASURY_ROLE) nonReentrant {
        require(soldOut(), "Not all tokens minted");
        // Proceeds of a sellout leave only after the deadline: a sellout cannot be bought with borrowed funds and
        // repaid from the same withdrawal.
        require(block.timestamp > mintEndTime, "Mint not ended");
        uint256 amount = address(this).balance;
        require(amount > 0, "No balance to withdraw");
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send Ether");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Keep some keys and refund the others in one transaction. Only during the choice window after an
    /// unsuccessful expiry, only for keys still held by their original minter.
    function settle(uint256[] calldata keepIds, uint256[] calldata refundIds) external nonReentrant {
        require(choiceWindowOpen(), "Choice window closed");
        uint256 count = keepIds.length + refundIds.length;
        require(count > 0 && count <= MAX_REFUND_BATCH, "Invalid settle size");
        for (uint256 i; i < keepIds.length; i++) {
            uint256 id = keepIds[i];
            require(originalMinter[id] == msg.sender && _ownerOf(id) == msg.sender, "Not original minter");
            require(!refunded[id] && !kept[id], "Already decided");
            kept[id] = true;
            totalKept++;
            keptFunds += mintPayment[id];
            emit Kept(id, msg.sender, mintPayment[id]);
            emit MetadataUpdate(id);
        }
        for (uint256 i; i < refundIds.length; i++) {
            _refund(refundIds[i], payable(msg.sender), false);
        }
    }

    function refund(uint256 tokenId) external nonReentrant {
        _refund(tokenId, payable(originalMinter[tokenId]), false);
    }

    /// @notice Anyone may batch refunds after the choice window (during it, only the minter for their own keys).
    /// A recipient that rejects ETH does not block the batch: its amount waits in pendingRefund.
    function refundBatch(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_REFUND_BATCH, "Invalid refund batch size");
        for (uint256 i; i < tokenIds.length; i++) {
            _refund(tokenIds[i], payable(originalMinter[tokenIds[i]]), true);
        }
    }

    function refundTo(uint256 tokenId, address payable recipient) external nonReentrant {
        require(msg.sender == originalMinter[tokenId], "Not original minter");
        _refund(tokenId, recipient, false);
    }

    function claimPendingRefund(address payable recipient) external nonReentrant {
        uint256 amount = pendingRefund[msg.sender];
        require(amount > 0, "Nothing pending");
        require(recipient != address(0), "Zero refund recipient");
        pendingRefund[msg.sender] = 0;
        totalPendingRefund -= amount;
        (bool sent,) = recipient.call{value: amount}("");
        require(sent, "Failed to send Ether");
        emit PendingRefundClaimed(msg.sender, recipient, amount);
    }

    function choiceWindowOpen() public view returns (bool) {
        return refundsAvailable() && block.timestamp <= mintEndTime + CHOICE_WINDOW;
    }

    /// @notice Without a sellout the treasury withdraws only what kept keys paid; refundable funds stay untouched.
    // slither-disable-next-line arbitrary-send-eth
    function withdrawKept() external onlyRole(TREASURY_ROLE) nonReentrant {
        require(refundsAvailable(), "Refunds not available");
        uint256 amount = keptFunds - keptWithdrawn;
        require(amount > 0, "No balance to withdraw");
        keptWithdrawn = keptFunds;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send Ether");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Without a sellout, treasury keys are burned once the choice window has closed.
    function burnTreasuryKeys(uint256[] calldata tokenIds) external onlyRole(TREASURY_ROLE) nonReentrant {
        require(refundsAvailable() && !choiceWindowOpen(), "Choice window not closed");
        require(tokenIds.length > 0 && tokenIds.length <= MAX_REFUND_BATCH, "Invalid burn batch size");
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            require(_ownerOf(id) != address(0) && originalMinter[id] == address(0), "Not a treasury key");
            totalSupply--;
            totalBurned++;
            _burn(id);
            emit TreasuryKeyBurned(id);
        }
    }

    // Default destinations are original minters; only that minter can use refundTo.
    // During the choice window only the minter can refund their own keys, so nobody can refund a key before its
    // minter had the chance to keep it. Kept keys are never refundable.
    // slither-disable-next-line arbitrary-send-eth,calls-loop
    function _refund(uint256 tokenId, address payable recipient, bool deferOnFailure) private {
        require(block.timestamp > mintEndTime, "Mint not ended");
        require(!soldOut(), "All tokens minted");
        require(!refunded[tokenId], "Already refunded");
        require(!kept[tokenId], "Key kept");
        address minter = originalMinter[tokenId];
        require(minter != address(0), "Token not eligible for refund");
        require(!choiceWindowOpen() || msg.sender == minter, "Choice window open");
        require(recipient != address(0), "Zero refund recipient");
        uint256 amount = mintPayment[tokenId];
        refunded[tokenId] = true;
        totalRefunded++;
        totalSupply--;
        _burn(tokenId);
        bool sent;
        if (deferOnFailure) {
            // Capped gas and no return data copy: a hostile recipient cannot burn the batch's gas or return-bomb it.
            uint256 gasCap = BATCH_REFUND_GAS;
            assembly ("memory-safe") {
                sent := call(gasCap, recipient, amount, 0, 0, 0, 0)
            }
        } else {
            (sent,) = recipient.call{value: amount}("");
        }
        if (!sent) {
            require(deferOnFailure, "Failed to send Ether");
            pendingRefund[minter] += amount;
            totalPendingRefund += amount;
            emit RefundDeferred(tokenId, minter, amount);
            return;
        }
        emit Refunded(tokenId, minter, recipient, amount);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && to != address(0)) {
            require(soldOut() || kept[tokenId], "RyodanKeys is not transferable since not all tokens have been minted");
        }
        return super._update(to, tokenId, auth);
    }
}
