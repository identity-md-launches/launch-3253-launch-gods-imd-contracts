// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title GODS OF IMD Inhabitants
/// @notice One ERC-721 "soul" per character designed in the off-chain character creator.
/// The game server hashes the canonical character JSON into a `soulHash`; the player forges it here for IMD.
///
/// Every forge is split by basis points of the price paid:
///  - `burnBps` is burned (sent to `burnSink`),
///  - `shrineBps` funds the {OracleShrine}, the game treasury that buys oracle questions and pays weekly rewards,
///  - the rest (`payeePoolBps()`) is split across the public `payees()` list by their bps.
/// If the forge names a valid referrer (an address that already owns a soul, other than the minter), `referralBps`
/// of the price goes to the referrer, taken out of the payees' share.
///
/// Petitions and commissions pay the IMD network's cost (`oracleCost`) to the shrine and the rest to the payees.
/// The Bazaar (`purchase`) sells looks only, never stats; each purchase is split like a forge without a referrer.
/// Secondary sales carry an ERC-2981 royalty to `royaltyReceiver`.
/// Death in the game never burns the NFT: the steward marks it as a memorial instead.
///
/// The Marks: every soul gets one Mark from a fixed deck (`markCap`: Mortal, Blessed, Ascended, Divine; it sums to
/// `maxSupply`). `reveal` draws it from the hash of the block after the forge. If that hash expires, reveal schedules
/// a new future block instead of drawing from a known recent hash. Timely permissionless reveals are still needed:
/// block producers and callers controlling reveal order can influence a blockhash-based draw from a shared deck.
///
/// Forging with other tokens: a soul can also be paid in a token the owner lists (`forgeWithToken`, `setForgeToken`):
/// its price, how many souls it may buy, the share burned, and one payee for the rest after a valid referrer's
/// `referralBps` (the IMD payees share IMD only). $SHIFT, NIGHTSHIFT's token, is listed at deploy: 200,000 a soul, 30%
/// burned. It takes the next paid id, under the same wallet cap, like a forge in IMD. New ways to pay need no new NFT.
///
/// The creator's reserve: `RESERVE` of the `maxSupply` souls are forged free by the owner (`forgeReserved`), as the
/// last token ids (901-1000). Every other forge takes the next id from 1 to 900. Reserved souls draw their Mark from the
/// same deck, with the same odds.
contract GodsOfIMDInhabitants is IERC4906, ERC721, ERC2981, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types

    /// @notice A recipient of the payee share. `bps` is of the full price paid.
    struct Payee {
        address account;
        uint16 bps;
    }

    /// @notice Closed: nobody can forge. Allowlist: only `forgeAllowlist`. Public: `forge` and `forgeAllowlist`.
    enum Phase {
        Closed,
        Allowlist,
        Public
    }

    /// @notice A soul's Mark. `Unrevealed` until `reveal` draws it.
    enum Mark {
        Unrevealed,
        Mortal,
        Blessed,
        Ascended,
        Divine
    }

    /// @dev How one forge payment is divided (see `previewSplit`).
    struct Split {
        uint256 burned;
        uint256 toShrine;
        uint256 toPayees;
        uint256 toReferrer;
    }

    // -------------------------------------------------------------- constants

    uint16 public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 10;
    /// @notice $SHIFT, NIGHTSHIFT's token on Ethereum: listed as a forge token at deploy.
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    /// @notice Where the burned share of a forge token goes: nobody holds its key.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 private constant ERC4906_INTERFACE_ID = bytes4(0x49064906);

    // ------------------------------------------------------------------ state

    IERC20 public immutable imd;
    address public shrine;
    address public burnSink;
    /// @notice Game server: memorials and metadata refresh notifications.
    address public steward;
    /// @notice ERC-2981 royalty receiver (defaults to the first payee).
    address public royaltyReceiver;

    uint256 public mintPrice;
    uint256 public allowlistPrice;
    uint256 public petitionPrice = 0.75 ether;
    uint256 public commissionPrice = 1 ether;
    /// @notice Part of each petition/commission forwarded to the shrine: what one IMD action costs (0.5 IMD).
    uint256 public oracleCost = 0.5 ether;
    uint16 public burnBps = 2000;
    uint16 public shrineBps = 1000;
    /// @notice Paid to a valid referrer out of the payees' share. Never above `payeePoolBps()`.
    uint16 public referralBps = 500;

    Phase public phase;
    /// @notice `GENESIS_SUPPLY`, the sum of `markCap`.
    uint256 public maxSupply;
    /// @notice Most souls one wallet may forge (`mintedBy`, every forge counts): 20 at deploy. 0 = unlimited.
    /// A Seer's allowlist leaf can raise it for that wallet (25 for IMD agent-seat holders).
    uint256 public maxPerWallet;
    /// @notice Souls forged so far, paid and reserved together.
    uint256 public totalForged;
    /// @notice Souls kept for the creator inside `maxSupply`: the last `RESERVE` token ids, forged free by the owner.
    uint256 public constant RESERVE = 100;
    /// @notice Reserved souls forged so far (at most `RESERVE`).
    uint256 public reservedForged;

    /// @notice A token a soul can be paid in besides IMD. `price` 0 turns it off; `cap` is the most souls it may buy;
    /// `burnBps` of the price is burned (sent to `DEAD`); `payee` gets the rest after a valid referrer's share.
    struct ForgeToken {
        uint256 price;
        uint256 cap;
        uint256 forged;
        uint16 burnBps;
        address payee;
    }

    /// @notice The forge tokens by address, and every token ever listed (`forgeTokenList`).
    mapping(address => ForgeToken) public forgeTokens;
    address[] private _forgeTokenList;
    /// @notice Root of an OpenZeppelin StandardMerkleTree of `(address account, uint256 maxMints)`.
    bytes32 public allowlistRoot;

    Payee[] private _payees;

    /// @notice Souls of each Mark in the deck, by `Mark - 1` (Mortal, Blessed, Ascended, Divine). Fixed at deploy.
    uint16[4] public markCap;
    /// @notice Souls of each Mark revealed so far, by `Mark - 1`.
    uint16[4] public markRevealed;
    mapping(uint256 => Mark) public markOf;
    /// @notice The block whose hash draws the soul's Mark; 0 once revealed.
    mapping(uint256 => uint256) public revealBlock;

    mapping(uint256 => bytes32) public soulHashOf;
    /// @notice Soul lookup by keccak256(abi.encode(originalMinter, soulHash)); copying another minter's hash
    /// cannot occupy their soul. `soulHashOf` and `SoulForged` keep the original character JSON hash.
    mapping(bytes32 => uint256) public tokenOfSoul;
    mapping(uint256 => bool) public memorial;
    /// @notice Hash of the chronicle recorded when the soul fell (0 while alive).
    mapping(uint256 => bytes32) public chronicleOf;
    /// @notice Souls forged by each wallet, public and allowlist together.
    mapping(address => uint256) public mintedBy;
    /// @notice Allowlist forges per wallet (at `allowlistPrice`, capped by the `maxMints` in the allowlist leaf).
    mapping(address => uint256) public allowlistMinted;
    /// @notice Souls forged with this address as a valid referrer.
    mapping(address => uint256) public referralCount;
    /// @notice IMD paid to this address as referrer.
    mapping(address => uint256) public referralEarned;

    string private _baseTokenURI;

    // ----------------------------------------------------------------- events

    event SoulForged(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 indexed soulHash,
        uint256 price,
        uint256 burned,
        uint256 toShrine,
        uint256 toPayees,
        address referrer,
        uint256 toReferrer
    );
    event Referred(address indexed referrer, uint256 indexed tokenId, uint256 amount);
    event Petitioned(uint256 indexed tokenId, address indexed by, bytes32 indexed petitionHash, uint256 paid);
    event Commissioned(
        uint256 indexed tokenId, address indexed by, uint8 kind, bytes32 indexed briefHash, uint256 paid
    );
    event Memorialized(uint256 indexed tokenId, bytes32 chronicleHash);
    /// @notice A cosmetic bought in the Bazaar for a soul. `itemId` names the item in the game's catalogue.
    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        bytes32 indexed itemId,
        uint256 amount,
        uint256 burned,
        uint256 toShrine,
        uint256 toPayees
    );

    event PricesUpdated(uint256 mintPrice, uint256 allowlistPrice, uint256 petitionPrice, uint256 commissionPrice);
    event SplitUpdated(uint16 burnBps, uint16 shrineBps);
    event PayeesUpdated(Payee[] payees);
    event ReferralBpsUpdated(uint16 referralBps);
    event AddressesUpdated(address shrine, address burnSink);
    event BaseURIUpdated(string baseURI);
    event StewardUpdated(address indexed previousSteward, address indexed newSteward);
    event PhaseUpdated(Phase phase);
    event AllowlistRootUpdated(bytes32 root);
    event MarkRevealed(uint256 indexed tokenId, Mark mark);
    event RevealRearmed(uint256 indexed tokenId, uint256 revealBlock);
    event MaxPerWalletUpdated(uint256 maxPerWallet);
    event OracleCostUpdated(uint256 oracleCost);
    /// @notice A soul paid in a forge token (its `SoulForged` shows a price of 0 IMD): what was paid, burned and shared.
    event ForgedWithToken(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed token,
        uint256 amount,
        uint256 burned,
        uint256 toPayee,
        address referrer,
        uint256 toReferrer
    );
    event ForgeTokenUpdated(address indexed token, uint256 price, uint256 cap, uint16 burnBps, address payee);
    event RoyaltyUpdated(address receiver, uint96 bps);

    // ----------------------------------------------------------------- errors

    error ZeroAddress();
    error NotSteward(address caller);
    error NotTokenOwner(uint256 tokenId, address caller);
    error ForgeClosed();
    error AllowlistOnly();
    error ZeroSoulHash();
    error SoulAlreadyForged(bytes32 soulHash, uint256 tokenId);
    error MaxSupplyReached(uint256 maxSupply);
    error NotRevealable(uint256 tokenId);
    error WalletLimitReached(address account, uint256 maxPerWallet);
    error InvalidProof();
    error AllowlistCapReached(address account, uint256 maxMints);
    error SoulIsMemorial(uint256 tokenId);
    error AlreadyMemorial(uint256 tokenId);
    error InvalidSplit(uint256 burnBps, uint256 shrineBps);
    error InvalidPayeeCount(uint256 count);
    error ZeroPayeeBps(uint256 index);
    error DuplicatePayee(address account);
    error PayeeBpsMismatch(uint256 sum, uint256 expected);
    error InvalidReferralBps(uint256 referralBps, uint256 payeePoolBps);
    error ZeroAmount();
    error ReserveExhausted(uint256 reserve);
    error TokenForgeOff(address token);
    error TokenCapReached(address token, uint256 cap);

    // ------------------------------------------------------------- modifiers

    modifier onlySteward() {
        if (msg.sender != steward) revert NotSteward(msg.sender);
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId, msg.sender);
        _;
    }

    // ----------------------------------------------------------- constructor

    /// @notice Genesis: 1000 souls, ever. The deck (Mortal, Blessed, Ascended, Divine) is fixed with it.
    uint256 public constant GENESIS_SUPPLY = 1000;

    /// @dev Only addresses, so IMD's launch can deploy it as is (`$owner`, `$contract:OracleShrine`). The Genesis
    /// rules are built in: 1000 souls, the deck 640 / 250 / 100 / 10, 5 IMD public and 4 IMD allowlist, 20 souls per
    /// wallet (Seers 25). Until the owner calls `setPayees`, the payee share and the 5% royalty go to the owner; `setBaseURI` points the
    /// metadata at the game. Starts in `Phase.Closed`; the owner opens it with `setPhase`.
    constructor(address owner_, IERC20 imd_, address shrine_, address burnSink_)
        ERC721("GODS OF IMD Inhabitants", "SOUL")
        Ownable(owner_)
    {
        if (address(imd_) == address(0) || shrine_ == address(0) || burnSink_ == address(0)) revert ZeroAddress();
        imd = imd_;
        shrine = shrine_;
        burnSink = burnSink_;
        steward = owner_;
        maxSupply = GENESIS_SUPPLY;
        markCap = [uint16(640), 250, 100, 10];
        mintPrice = 5 ether;
        allowlistPrice = 4 ether;
        maxPerWallet = 20;
        _setForgeToken(SHIFT, 200_000 ether, GENESIS_SUPPLY - RESERVE, 3000, owner_);
        Payee[] memory initial = new Payee[](1);
        initial[0] = Payee(owner_, uint16(payeePoolBps()));
        _setPayees(initial);
        royaltyReceiver = owner_;
        _setDefaultRoyalty(owner_, 500); // 5% on secondary sales
    }

    // ---------------------------------------------------------------- player

    /// @notice Forge a soul at `mintPrice` (Public phase only). Pulls the price in IMD from the caller
    /// (approve this contract first) and mints the next token id to the caller.
    /// @param referrer optional; paid `referralBps` if it owns a soul and is not the caller, otherwise ignored.
    function forge(bytes32 soulHash, address referrer) external nonReentrant returns (uint256 tokenId) {
        Phase p = phase;
        if (p != Phase.Public) {
            if (p == Phase.Closed) revert ForgeClosed();
            revert AllowlistOnly();
        }
        uint256 limit = maxPerWallet;
        uint256 minted = mintedBy[msg.sender];
        if (limit != 0 && minted >= limit) revert WalletLimitReached(msg.sender, limit);
        mintedBy[msg.sender] = minted + 1;
        tokenId = _forge(soulHash, referrer, mintPrice);
    }

    /// @notice Forge a soul at `allowlistPrice` with an allowlist slot (IMD agent-seat holders, the "Seers").
    /// Works in the Allowlist and Public phases. The caller must be in the allowlist tree with `maxMints` slots;
    /// leaf = keccak256(bytes.concat(keccak256(abi.encode(account, maxMints)))).
    function forgeAllowlist(bytes32 soulHash, address referrer, uint256 maxMints, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (phase == Phase.Closed) revert ForgeClosed();
        if (!MerkleProof.verifyCalldata(proof, allowlistRoot, allowlistLeaf(msg.sender, maxMints))) {
            revert InvalidProof();
        }
        uint256 used = allowlistMinted[msg.sender];
        if (used >= maxMints) revert AllowlistCapReached(msg.sender, maxMints);
        // the wallet cap counts every forge; a Seer's leaf may lift it (20 for everyone, 25 for Seers)
        uint256 limit = maxPerWallet;
        if (limit != 0 && maxMints > limit) limit = maxMints;
        uint256 minted = mintedBy[msg.sender];
        if (limit != 0 && minted >= limit) revert WalletLimitReached(msg.sender, limit);
        mintedBy[msg.sender] = minted + 1;
        allowlistMinted[msg.sender] = used + 1;
        tokenId = _forge(soulHash, referrer, allowlistPrice);
    }

    /// @notice Forge a soul with a forge token at its price (Public phase only, at most its `cap` souls). Pulls the
    /// token from the caller (approve this contract on it first): `burnBps` burned, a valid referrer's `referralBps`,
    /// the token's payee the rest. The next paid id, the same odds, the same wallet cap as a forge in IMD.
    function forgeWithToken(address token, bytes32 soulHash, address referrer)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        ForgeToken storage t = forgeTokens[token];
        if (t.price == 0) revert TokenForgeOff(token);
        Phase p = phase;
        if (p != Phase.Public) {
            if (p == Phase.Closed) revert ForgeClosed();
            revert AllowlistOnly();
        }
        if (t.forged >= t.cap) revert TokenCapReached(token, t.cap);
        t.forged += 1;
        _countWalletForge();
        tokenId = _nextPaidId();
        _registerSoul(soulHash, tokenId);
        if (!isValidReferrer(referrer, msg.sender)) referrer = address(0);
        _payToken(token, tokenId, referrer);
        _safeMint(msg.sender, tokenId);
        emit SoulForged(tokenId, msg.sender, soulHash, 0, 0, 0, 0, referrer, 0);
    }

    /// @dev One more soul for the caller under `maxPerWallet` (forges in IMD and in forge tokens count alike).
    function _countWalletForge() private {
        uint256 limit = maxPerWallet;
        uint256 minted = mintedBy[msg.sender];
        if (limit != 0 && minted >= limit) revert WalletLimitReached(msg.sender, limit);
        mintedBy[msg.sender] = minted + 1;
    }

    /// @dev Pulls the forge token's price from the caller: the burned share, the referrer's share, the payee the rest.
    function _payToken(address token, uint256 tokenId, address referrer) private {
        ForgeToken storage t = forgeTokens[token];
        uint256 price = t.price;
        uint256 burned = (price * t.burnBps) / BPS;
        uint256 toReferrer = referrer != address(0) ? (price * referralBps) / BPS : 0;
        uint256 toPayee = price - burned - toReferrer;
        if (referrer != address(0)) referralCount[referrer] += 1;
        IERC20 erc = IERC20(token);
        if (burned != 0) erc.safeTransferFrom(msg.sender, DEAD, burned);
        if (toReferrer != 0) erc.safeTransferFrom(msg.sender, referrer, toReferrer);
        if (toPayee != 0) erc.safeTransferFrom(msg.sender, t.payee, toPayee);
        emit ForgedWithToken(tokenId, msg.sender, token, price, burned, toPayee, referrer, toReferrer);
    }

    /// @notice The owner forges one of the `RESERVE` souls kept for the creator: free, in any phase, outside every
    /// wallet cap. It takes the next id from `maxSupply - RESERVE + 1` (901) up, and its Mark is drawn from the same
    /// deck with the same odds as any other soul's. `SoulForged` shows it with a price of 0.
    function forgeReserved(bytes32 soulHash) external onlyOwner nonReentrant returns (uint256 tokenId) {
        tokenId = _forgeReserved(soulHash);
    }

    /// @notice `forgeReserved` for several souls in one transaction, in order.
    function forgeReservedMany(bytes32[] calldata soulHashes)
        external
        onlyOwner
        nonReentrant
        returns (uint256 firstId)
    {
        uint256 n = soulHashes.length;
        if (n == 0) revert ZeroAmount();
        firstId = _forgeReserved(soulHashes[0]);
        for (uint256 i = 1; i < n; ++i) {
            _forgeReserved(soulHashes[i]);
        }
    }

    /// @notice Petition the God on behalf of a living soul you own. Pays `petitionPrice` IMD:
    /// `oracleCost` to the shrine (one oracle question), the rest to the payees.
    function petition(uint256 tokenId, bytes32 petitionHash) external nonReentrant onlyTokenOwner(tokenId) {
        if (memorial[tokenId]) revert SoulIsMemorial(tokenId);
        uint256 paid = petitionPrice;
        _collectService(paid);
        emit Petitioned(tokenId, msg.sender, petitionHash, paid);
    }

    /// @notice Commission work (art, lore, ...) for a soul you own. Pays `commissionPrice` IMD:
    /// `oracleCost` to the shrine (one IMD job), the rest to the payees.
    function commission(uint256 tokenId, uint8 kind, bytes32 briefHash) external nonReentrant onlyTokenOwner(tokenId) {
        uint256 paid = commissionPrice;
        _collectService(paid);
        emit Commissioned(tokenId, msg.sender, kind, briefHash, paid);
    }

    /// @notice Buy a cosmetic in the Bazaar for a living soul you own: looks only, never stats, odds or rewards.
    /// Pulls `amount` IMD and splits it exactly like a forge with no referrer: `burnBps` burned, `shrineBps` to the
    /// shrine (oracle questions and the weekly rewards), the rest to the payees by their bps. The game server reads
    /// the `Purchased` event and grants `itemId` to the soul if `amount` covers its catalogue price; the item then
    /// belongs to the soul and follows the token to every new owner. Memorial souls cannot buy (like petitions):
    /// they rest as graves in the world, and what they bought while alive stays on their card.
    function purchase(uint256 tokenId, bytes32 itemId, uint256 amount) external nonReentrant onlyTokenOwner(tokenId) {
        if (memorial[tokenId]) revert SoulIsMemorial(tokenId);
        if (amount == 0) revert ZeroAmount();
        (uint256 burned, uint256 toShrine, uint256 toPayees,) = previewSplit(amount, false);
        _collect(burnSink, burned);
        _collect(shrine, toShrine);
        _payPayees(toPayees);
        emit Purchased(tokenId, msg.sender, itemId, amount, burned, toShrine, toPayees);
    }

    // ------------------------------------------------------------------ marks

    /// @notice Reveal a forged soul's Mark. Anyone may call it from the second block after the forge (the game
    /// server does it at once). The Mark is drawn from the deck that is left, every slot as likely as any other, using
    /// the hash of the block after the forge. If that hash expired, this call only schedules a new future block
    /// and emits `RevealRearmed`; call again after that block. No Mark is drawn from an already known fallback.
    function reveal(uint256 tokenId) public {
        uint256 b = revealBlock[tokenId];
        if (b == 0 || block.number <= b) revert NotRevealable(tokenId);
        bytes32 h = blockhash(b);
        if (h == bytes32(0)) {
            uint256 next = block.number + 1;
            revealBlock[tokenId] = next;
            emit RevealRearmed(tokenId, next);
            return; // Reverting here would undo the new reveal block.
        }
        delete revealBlock[tokenId];
        Mark m = _draw(uint256(keccak256(abi.encode(h, soulHashOf[tokenId], tokenId))));
        markOf[tokenId] = m;
        unchecked {
            ++markRevealed[uint8(m) - 1];
        }
        emit MarkRevealed(tokenId, m);
        emit MetadataUpdate(tokenId);
    }

    /// @notice `reveal` for every listed soul that can be revealed now; the others are skipped.
    function revealMany(uint256[] calldata tokenIds) external {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 b = revealBlock[tokenIds[i]];
            if (b != 0 && block.number > b) reveal(tokenIds[i]);
        }
    }

    // --------------------------------------------------------------- steward

    /// @notice Mark a fallen soul as a memorial. The NFT is never burned.
    function setMemorial(uint256 tokenId, bytes32 chronicleHash) external onlySteward {
        _requireOwned(tokenId);
        if (memorial[tokenId]) revert AlreadyMemorial(tokenId);
        memorial[tokenId] = true;
        chronicleOf[tokenId] = chronicleHash;
        emit Memorialized(tokenId, chronicleHash);
        emit MetadataUpdate(tokenId);
    }

    function refresh(uint256 tokenId) external onlySteward {
        _requireOwned(tokenId);
        emit MetadataUpdate(tokenId);
    }

    function refreshAll() external onlySteward {
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    // ----------------------------------------------------------------- owner

    function setPrices(uint256 mintPrice_, uint256 allowlistPrice_, uint256 petitionPrice_, uint256 commissionPrice_)
        external
        onlyOwner
    {
        mintPrice = mintPrice_;
        allowlistPrice = allowlistPrice_;
        petitionPrice = petitionPrice_;
        commissionPrice = commissionPrice_;
        emit PricesUpdated(mintPrice_, allowlistPrice_, petitionPrice_, commissionPrice_);
    }

    function setOracleCost(uint256 oracleCost_) external onlyOwner {
        oracleCost = oracleCost_;
        emit OracleCostUpdated(oracleCost_);
    }

    /// @param bps royalty in basis points (500 = 5%), paid by marketplaces that honor ERC-2981.
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        _setDefaultRoyalty(receiver, bps);
        royaltyReceiver = receiver;
        emit RoyaltyUpdated(receiver, bps);
    }

    /// @notice Change burn and shrine bps together with the payee list, in one call, so the payees always sum to
    /// exactly `BPS - burnBps - shrineBps`. `referralBps` must still fit in the new payee pool.
    function setSplit(uint16 burnBps_, uint16 shrineBps_, Payee[] calldata payees_) external onlyOwner {
        if (uint256(burnBps_) + uint256(shrineBps_) >= BPS) revert InvalidSplit(burnBps_, shrineBps_);
        uint256 pool = BPS - uint256(burnBps_) - uint256(shrineBps_);
        if (referralBps > pool) revert InvalidReferralBps(referralBps, pool);
        burnBps = burnBps_;
        shrineBps = shrineBps_;
        emit SplitUpdated(burnBps_, shrineBps_);
        _setPayees(payees_);
    }

    /// @notice Replace the payee list. The bps must sum to exactly `payeePoolBps()`.
    function setPayees(Payee[] calldata payees_) external onlyOwner {
        _setPayees(payees_);
    }

    function setReferralBps(uint16 referralBps_) external onlyOwner {
        uint256 pool = payeePoolBps();
        if (referralBps_ > pool) revert InvalidReferralBps(referralBps_, pool);
        referralBps = referralBps_;
        emit ReferralBpsUpdated(referralBps_);
    }

    function setAddresses(address shrine_, address burnSink_) external onlyOwner {
        if (shrine_ == address(0) || burnSink_ == address(0)) revert ZeroAddress();
        shrine = shrine_;
        burnSink = burnSink_;
        emit AddressesUpdated(shrine_, burnSink_);
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    function setSteward(address steward_) external onlyOwner {
        if (steward_ == address(0)) revert ZeroAddress();
        emit StewardUpdated(steward, steward_);
        steward = steward_;
    }

    function setPhase(Phase phase_) external onlyOwner {
        phase = phase_;
        emit PhaseUpdated(phase_);
    }

    /// @notice Allowlist tree root (OpenZeppelin StandardMerkleTree, leaf types ["address", "uint256"]).
    /// Slots already used (`allowlistMinted`) carry over when the root changes.
    function setAllowlistRoot(bytes32 root) external onlyOwner {
        allowlistRoot = root;
        emit AllowlistRootUpdated(root);
    }

    /// @notice List a token souls can be paid in, or change one: its price (0 turns it off), the most souls it may
    /// buy, the share burned (in bps, leaving room for a referrer) and who receives the rest. IMD itself is not one.
    function setForgeToken(address token, uint256 price, uint256 cap, uint16 burnBps_, address payee)
        external
        onlyOwner
    {
        _setForgeToken(token, price, cap, burnBps_, payee);
    }

    /// @notice Every token ever listed with `setForgeToken` (some may be off: price 0).
    function forgeTokenList() external view returns (address[] memory) {
        return _forgeTokenList;
    }

    /// @param maxPerWallet_ most souls one wallet may forge (every forge counts); 0 = unlimited.
    function setMaxPerWallet(uint256 maxPerWallet_) external onlyOwner {
        maxPerWallet = maxPerWallet_;
        emit MaxPerWalletUpdated(maxPerWallet_);
    }

    // ------------------------------------------------------------------ views

    function payees() external view returns (Payee[] memory) {
        return _payees;
    }

    function payeeCount() external view returns (uint256) {
        return _payees.length;
    }

    /// @notice Bps of the price that goes to the payees (before any referral): `BPS - burnBps - shrineBps`.
    function payeePoolBps() public view returns (uint256) {
        return uint256(BPS) - burnBps - shrineBps;
    }

    /// @notice How a forge at `price` is split. Rounding dust of burn/shrine stays in the payees' share.
    function previewSplit(uint256 price, bool referred)
        public
        view
        returns (uint256 burned, uint256 toShrine, uint256 toPayees, uint256 toReferrer)
    {
        burned = (price * burnBps) / BPS;
        toShrine = (price * shrineBps) / BPS;
        toPayees = price - burned - toShrine;
        if (referred) {
            toReferrer = (price * referralBps) / BPS; // <= toPayees because referralBps <= payeePoolBps()
            toPayees -= toReferrer;
        }
    }

    /// @notice A referrer is paid when it is non-zero, is not the minter and owns at least one soul.
    function isValidReferrer(address referrer, address minter) public view returns (bool) {
        return referrer != address(0) && referrer != minter && balanceOf(referrer) != 0;
    }

    /// @notice Allowlist leaf, OpenZeppelin StandardMerkleTree encoding for ["address", "uint256"].
    function allowlistLeaf(address account, uint256 maxMints) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, maxMints))));
    }

    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /// @dev `tokenURI(id)` (inherited) = baseURI + decimal id; reverts for nonexistent tokens.
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981, IERC165) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    // --------------------------------------------------------------- internal

    function _setForgeToken(address token, uint256 price, uint256 cap, uint16 burnBps_, address payee) private {
        if (token == address(0) || token == address(imd) || payee == address(0)) revert ZeroAddress();
        if (uint256(burnBps_) + referralBps > BPS) revert InvalidSplit(burnBps_, referralBps);
        ForgeToken storage t = forgeTokens[token];
        if (t.payee == address(0)) _forgeTokenList.push(token);
        t.price = price;
        t.cap = cap;
        t.burnBps = burnBps_;
        t.payee = payee;
        emit ForgeTokenUpdated(token, price, cap, burnBps_, payee);
    }

    /// @dev Paid souls (IMD or a forge token) take ids 1 .. maxSupply - RESERVE in order; the reserve has the ids after.
    function _nextPaidId() private view returns (uint256) {
        uint256 cap = maxSupply - RESERVE;
        uint256 paid = totalForged - reservedForged;
        if (paid >= cap) revert MaxSupplyReached(cap);
        return paid + 1;
    }

    function _forge(bytes32 soulHash, address referrer, uint256 price) private returns (uint256 tokenId) {
        tokenId = _nextPaidId();
        _registerSoul(soulHash, tokenId);
        // Invalid referrers are ignored, not rejected.
        if (!isValidReferrer(referrer, msg.sender)) referrer = address(0);

        Split memory s;
        (s.burned, s.toShrine, s.toPayees, s.toReferrer) = previewSplit(price, referrer != address(0));
        if (referrer != address(0)) {
            referralCount[referrer] += 1;
            referralEarned[referrer] += s.toReferrer;
        }

        _collect(burnSink, s.burned);
        _collect(shrine, s.toShrine);
        _collect(referrer, s.toReferrer);
        _payPayees(s.toPayees);

        _safeMint(msg.sender, tokenId);
        emit SoulForged(tokenId, msg.sender, soulHash, price, s.burned, s.toShrine, s.toPayees, referrer, s.toReferrer);
        if (s.toReferrer != 0) emit Referred(referrer, tokenId, s.toReferrer);
    }

    /// @dev The next reserved id (from `maxSupply - RESERVE + 1`), minted free to the owner.
    function _forgeReserved(bytes32 soulHash) private returns (uint256 tokenId) {
        uint256 n = reservedForged;
        if (n >= RESERVE) revert ReserveExhausted(RESERVE);
        reservedForged = n + 1;
        tokenId = maxSupply - RESERVE + n + 1;
        _registerSoul(soulHash, tokenId);
        _safeMint(msg.sender, tokenId);
        emit SoulForged(tokenId, msg.sender, soulHash, 0, 0, 0, 0, address(0), 0);
    }

    /// @dev Checks the soul hash, counts the soul and books `tokenId` for it (the callers check their own cap).
    function _registerSoul(bytes32 soulHash, uint256 tokenId) private {
        if (soulHash == bytes32(0)) revert ZeroSoulHash();
        bytes32 key = keccak256(abi.encode(msg.sender, soulHash));
        uint256 existing = tokenOfSoul[key];
        if (existing != 0) revert SoulAlreadyForged(soulHash, existing);
        ++totalForged;
        soulHashOf[tokenId] = soulHash;
        tokenOfSoul[key] = tokenId;
        revealBlock[tokenId] = block.number + 1;
    }

    /// @dev Draws a Mark from what is left of the deck: every slot left is as likely as any other. The deck always has
    /// at least as many slots left as souls waiting for a reveal, so `total` is never 0.
    function _draw(uint256 rand) private view returns (Mark) {
        uint256[4] memory w;
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            w[i] = markCap[i] - markRevealed[i];
            total += w[i];
        }
        uint256 r = rand % total;
        for (uint256 i = 4; i > 0;) {
            unchecked {
                --i;
            }
            if (r < w[i]) return Mark(i + 1);
            r -= w[i];
        }
        return Mark.Mortal;
    }

    function _collect(address to, uint256 amount) private {
        if (amount != 0) imd.safeTransferFrom(msg.sender, to, amount);
    }

    function _collectService(uint256 paid) private {
        uint256 toShrine = paid < oracleCost ? paid : oracleCost;
        _collect(shrine, toShrine);
        _payPayees(paid - toShrine);
    }

    /// @dev Splits `amount` IMD across the payees pro rata by bps; the last payee receives the rounding dust.
    function _payPayees(uint256 amount) private {
        IERC20 token = imd;
        if (amount == 0) return;
        uint256 pool = payeePoolBps();
        uint256 last = _payees.length - 1;
        uint256 left = amount;
        for (uint256 i; i < last; ++i) {
            Payee memory p = _payees[i];
            uint256 share = (amount * p.bps) / pool;
            left -= share;
            if (share != 0) token.safeTransferFrom(msg.sender, p.account, share);
        }
        if (left != 0) token.safeTransferFrom(msg.sender, _payees[last].account, left);
    }

    function _setPayees(Payee[] memory payees_) private {
        uint256 n = payees_.length;
        if (n == 0 || n > MAX_PAYEES) revert InvalidPayeeCount(n);
        delete _payees;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            Payee memory p = payees_[i];
            if (p.account == address(0)) revert ZeroAddress();
            if (p.bps == 0) revert ZeroPayeeBps(i);
            for (uint256 k; k < i; ++k) {
                if (payees_[k].account == p.account) revert DuplicatePayee(p.account);
            }
            sum += p.bps;
            _payees.push(p);
        }
        uint256 pool = payeePoolBps();
        if (sum != pool) revert PayeeBpsMismatch(sum, pool);
        emit PayeesUpdated(payees_);
    }
}
