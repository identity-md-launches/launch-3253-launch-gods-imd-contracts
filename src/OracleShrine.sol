// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIntake} from "./interfaces/IIntake.sol";

/// @title GODS OF IMD Oracle Shrine
/// @notice The game's on-chain altar and treasury. It holds IMD (funded by the forge split, petitions and
/// commissions), buys oracle questions from the IMD Intake, verifies the signed EIP-712 attestations on-chain and
/// records the God's judgments. Attestations are signed in this contract's domain
/// ("IdentityMD Oracle", "2", chainId, address(this)).
///
/// It also runs the weekly rewards vault: the director proposes a Merkle root of `(account, amount)` rewards and
/// asks the IMD Oracle panel whether that published list follows the published rules. The reserved IMD can only
/// be claimed after the panel's signed answer is `true`.
contract OracleShrine is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types

    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType; // bool 0, address 1, bytes32 2, uint256 3, address[] 4, bytes32[] 5
        bytes answer; // abi.encode(value)
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    struct Pin {
        uint8 kind;
        uint64 pinnedAt;
        bool answered;
    }

    /// @dev ABI shape returned by `judgments(q)` / `judgmentOf(q)`.
    struct Judgment {
        bytes32 oracleRequestId;
        uint8 answerType;
        bytes answer;
        uint16 agreed;
        uint16 quorum;
        uint16 panelSize;
        uint64 issuedAt;
    }

    /// @dev Storage layout of a Judgment: the small fields share one slot so a callback writes one slot
    /// less (~22k gas) under the intake's 200k callback gas limit.
    struct StoredJudgment {
        bytes32 oracleRequestId;
        uint8 answerType;
        uint16 agreed;
        uint16 quorum;
        uint16 panelSize;
        uint64 issuedAt;
        bytes answer;
    }

    struct Anchor {
        bytes32 worldHash;
        bytes32 chronicleRoot;
        uint64 anchoredAt;
    }

    /// @notice None -> Proposed (askRewards) -> Active (finalizeRewards) -> Expired (expireRewards);
    /// Proposed -> Rejected (rejectRewards) or Cancelled (cancelRewards). Rejected/Cancelled weeks can be re-proposed.
    enum RewardStatus {
        None,
        Proposed,
        Active,
        Rejected,
        Cancelled,
        Expired
    }

    struct RewardWeek {
        bytes32 root; // StandardMerkleTree root of (address account, uint256 amount)
        bytes32 questionHash; // the oracle question that approves this list
        uint256 total; // IMD reserved for the week
        uint256 remaining; // still reserved (total minus claims; 0 once released)
        uint64 proposedAt;
        uint64 activatedAt;
        RewardStatus status;
    }

    // -------------------------------------------------------------- constants

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,"
        "uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,"
        "bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @notice Maximum number of questions in one ask (oracle.group).
    uint256 public constant MAX_QUESTIONS = 8;
    /// @notice Pin kind of reward-list questions. Reserved for `askRewards`; `ask` rejects it.
    uint8 public constant KIND_REWARDS = 4;
    /// @notice Default Intake action for rewards (one question, answered through `onOracleResult`).
    bytes32 public constant REWARDS_ACTION = "oracle.request@oracle-1";
    /// @notice After this long without a judgment, the owner may cancel a proposed week.
    uint256 public constant REWARD_JUDGMENT_TIMEOUT = 14 days;
    /// @notice After this long from activation, the owner may expire a week and release what was not claimed.
    uint256 public constant REWARD_CLAIM_WINDOW = 56 days;
    uint256 private constant BPS = 10_000;

    uint8 private constant VERDICT_NONE = 0;
    uint8 private constant VERDICT_TRUE = 1;
    uint8 private constant VERDICT_NOT_TRUE = 2; // false, or not a well-formed bool

    // ------------------------------------------------------------------ state

    IIntake public intake;
    IERC20 public immutable imd;
    address public oracleSigner;
    /// @notice Game server: asks questions, proposes weekly rewards and anchors daily world checkpoints.
    address public director;
    uint256 public pricePerQuestion = 0.5 ether;
    uint16 public minQuorum = 20;
    /// @notice Minimum signed panel size and agreement, for callbacks and permissionless relays alike.
    uint16 public minPanelSize = 30;
    uint16 public minAgreed = 20;
    /// @notice Owner may migrate rewards to a new Intake action without redeploying the vault.
    bytes32 public rewardsAction = REWARDS_ACTION;
    /// @notice A week's reward total may be at most this share of the free balance (2000 = 20%).
    uint16 public maxRewardBps = 2000;
    /// @notice IMD set aside for proposed and active reward weeks. `ask` and `withdraw` cannot spend it.
    uint256 public reserved;

    /// @notice Intake request ids awaiting a callback.
    mapping(bytes32 => bool) public pending;
    /// @notice Questions this shrine paid for, keyed by questionHash.
    mapping(bytes32 => Pin) public pins;
    /// @dev Verified answers, keyed by questionHash. Read with `judgments(q)` or `judgmentOf(q)`.
    mapping(bytes32 => StoredJudgment) private _judgments;
    /// @notice Daily world-state checkpoints.
    mapping(uint64 => Anchor) public anchors;
    /// @dev Read with `rewardWeek(week)`.
    mapping(uint64 => RewardWeek) private _rewardWeeks;
    mapping(uint64 => mapping(address => bool)) private _claimed;
    /// @dev Week whose proposal pinned this question (only meaningful for kind `KIND_REWARDS`).
    mapping(bytes32 => uint64) private _rewardWeekOfQuestion;

    // ----------------------------------------------------------------- events

    event Asked(bytes32 indexed requestId, bytes32 action, uint8 kind, bytes32[] questionHashes, uint256 paid);
    event Judged(
        bytes32 indexed questionHash,
        bytes32 indexed oracleRequestId,
        uint8 kind,
        uint8 answerType,
        bytes answer,
        uint16 agreed,
        uint16 quorum
    );
    event GroupCompleted(bytes32 indexed requestId, bytes32 resultHash, string uri);
    event AskFailed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event Unpinned(bytes32 indexed questionHash);
    event Anchored(uint64 indexed day, bytes32 worldHash, bytes32 chronicleRoot);

    event RewardsProposed(
        uint64 indexed week, bytes32 indexed questionHash, bytes32 indexed requestId, bytes32 root, uint256 total
    );
    event RewardsActivated(uint64 indexed week, bytes32 root, uint256 total);
    event RewardsRejected(uint64 indexed week, uint256 released);
    event RewardsCancelled(uint64 indexed week, uint256 released);
    event RewardClaimed(uint64 indexed week, address indexed account, uint256 amount);
    event RewardsExpired(uint64 indexed week, uint256 released);

    event IntakeUpdated(address indexed intake);
    event SignerUpdated(address indexed oracleSigner);
    event DirectorUpdated(address indexed director);
    event PriceUpdated(uint256 pricePerQuestion);
    event MinQuorumUpdated(uint16 minQuorum);
    event PanelMinimumsUpdated(uint16 minPanelSize, uint16 minAgreed);
    event RewardsActionUpdated(bytes32 action);
    event MaxRewardBpsUpdated(uint16 maxRewardBps);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    // ----------------------------------------------------------------- errors

    error ZeroAddress();
    error NotDirector(address caller);
    error NotIntake(address caller);
    error NotPending(bytes32 requestId);
    error BadQuestionCount(uint256 count);
    error ZeroQuestionHash();
    error ReservedKind(uint8 kind);
    error AlreadyPinned(bytes32 questionHash);
    error NotPinned(bytes32 questionHash);
    error AlreadyAnswered(bytes32 questionHash);
    error QuorumNotReached(uint16 agreed, uint16 quorum);
    error QuorumTooLow(uint16 quorum, uint16 minQuorum);
    error AttestationExpired(uint64 expiresAt);
    error InvalidSignature();
    error AnchorExists(uint64 day);
    error InvalidMinQuorum();
    error InvalidPanelMinimums();
    error PanelTooWeak(uint16 panelSize, uint16 agreed);
    error ZeroAction();
    error InvalidMaxRewardBps(uint16 maxRewardBps);
    error InsufficientFreeBalance(uint256 needed, uint256 available);
    error RewardWeekExists(uint64 week, RewardStatus status);
    error ZeroRoot();
    error ZeroRewardTotal();
    error RewardTotalTooHigh(uint256 total, uint256 cap);
    error BadRewardStatus(uint64 week, RewardStatus status);
    error NoJudgment(bytes32 questionHash);
    error RewardsNotApproved(uint64 week);
    error RewardsApproved(uint64 week);
    error JudgmentRecorded(uint64 week);
    error TooEarly(uint256 allowedAt);
    error AlreadyClaimed(uint64 week, address account);
    error InvalidProof();
    error ExceedsRewardRemaining(uint64 week, uint256 amount, uint256 remaining);

    // ------------------------------------------------------------- modifiers

    modifier onlyDirector() {
        if (msg.sender != director) revert NotDirector(msg.sender);
        _;
    }

    /// @dev Intake callbacks: only the intake, only for a request this shrine is still waiting on.
    modifier onlyIntakeCallback(bytes32 requestId) {
        if (msg.sender != address(intake)) revert NotIntake(msg.sender);
        if (!pending[requestId]) revert NotPending(requestId);
        delete pending[requestId];
        _;
    }

    // ----------------------------------------------------------- constructor

    constructor(address owner_, IIntake intake_, IERC20 imd_, address oracleSigner_, address director_)
        Ownable(owner_)
        EIP712("IdentityMD Oracle", "2")
    {
        if (
            address(intake_) == address(0) || address(imd_) == address(0) || oracleSigner_ == address(0)
                || director_ == address(0)
        ) revert ZeroAddress();
        intake = intake_;
        imd = imd_;
        oracleSigner = oracleSigner_;
        director = director_;
    }

    // -------------------------------------------------------------- director

    /// @notice Buy one oracle question (1 hash, answered by `onOracleResult`) or a group of up to 8
    /// (answered by `onResult`; the individual attestations are then relayed through `record`).
    /// Pays `pricePerQuestion * questionHashes.length` IMD from the free (unreserved) balance.
    function ask(bytes32 action, bytes calldata body, bytes32[] calldata questionHashes, uint8 kind)
        external
        onlyDirector
        returns (bytes32 requestId)
    {
        if (kind == KIND_REWARDS) revert ReservedKind(kind);
        uint256 n = questionHashes.length;
        if (n == 0 || n > MAX_QUESTIONS) revert BadQuestionCount(n);
        for (uint256 i; i < n; ++i) {
            _pin(questionHashes[i], kind); // also rejects duplicates within the batch
        }
        uint256 paid;
        (requestId, paid) = _buy(action, body, n);
        emit Asked(requestId, action, kind, questionHashes, paid);
    }

    /// @notice Propose a week's rewards and ask the IMD Oracle panel to approve them.
    /// Reserves `total` IMD (at most `maxRewardBps` of the free balance), pins `questionHash` with kind
    /// `KIND_REWARDS` and buys one single-question `rewardsAction` request from the intake; its answer arrives
    /// through `onOracleResult` (or `record`). `body` is the oracle question: it should ask whether the published
    /// reward list behind `root` follows the published rules, with `bool` as the answer type.
    /// A week can be proposed again only after it was rejected or cancelled (`unpin` of its question cancels it).
    /// @param root OpenZeppelin StandardMerkleTree root of (address account, uint256 amount).
    function askRewards(uint64 week, bytes32 root, uint256 total, bytes calldata body, bytes32 questionHash)
        external
        onlyDirector
        returns (bytes32 requestId)
    {
        RewardStatus s = _rewardWeeks[week].status;
        if (s != RewardStatus.None && s != RewardStatus.Rejected && s != RewardStatus.Cancelled) {
            revert RewardWeekExists(week, s);
        }
        if (root == bytes32(0)) revert ZeroRoot();
        if (total == 0) revert ZeroRewardTotal();
        uint256 cap = (availableBalance() * maxRewardBps) / BPS;
        if (total > cap) revert RewardTotalTooHigh(total, cap);

        _pin(questionHash, KIND_REWARDS);
        _rewardWeekOfQuestion[questionHash] = week;
        reserved += total;
        _rewardWeeks[week] = RewardWeek({ // overwrites a rejected/cancelled proposal (nothing was claimed from it)
            root: root,
            questionHash: questionHash,
            total: total,
            remaining: total,
            proposedAt: uint64(block.timestamp),
            activatedAt: 0,
            status: RewardStatus.Proposed
        });

        uint256 paid;
        bytes32 action = rewardsAction;
        (requestId, paid) = _buy(action, body, 1); // the question is paid from what is left free
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = questionHash;
        emit Asked(requestId, action, KIND_REWARDS, hashes, paid);
        emit RewardsProposed(week, questionHash, requestId, root, total);
    }

    /// @notice Release unanswered pins (e.g. after `AskFailed`) so the same questions can be asked again.
    /// Unpinning the question of a proposed reward week cancels that week and releases its reservation, so a
    /// proposed week's question is always pinned and no two weeks can ever share one question.
    function unpin(bytes32[] calldata questionHashes) external onlyDirector {
        for (uint256 i; i < questionHashes.length; ++i) {
            bytes32 h = questionHashes[i];
            Pin storage p = pins[h];
            if (p.pinnedAt == 0) revert NotPinned(h);
            if (p.answered) revert AlreadyAnswered(h);
            if (p.kind == KIND_REWARDS) {
                uint64 week = _rewardWeekOfQuestion[h];
                RewardWeek storage w = _rewardWeeks[week];
                if (w.status == RewardStatus.Proposed && w.questionHash == h) {
                    w.status = RewardStatus.Cancelled;
                    emit RewardsCancelled(week, _release(w));
                }
            }
            delete pins[h];
            emit Unpinned(h);
        }
    }

    /// @notice Daily world-state checkpoint. A day can be anchored only once.
    function anchor(uint64 day, bytes32 worldHash, bytes32 chronicleRoot) external onlyDirector {
        if (anchors[day].anchoredAt != 0) revert AnchorExists(day);
        anchors[day] = Anchor({worldHash: worldHash, chronicleRoot: chronicleRoot, anchoredAt: uint64(block.timestamp)});
        emit Anchored(day, worldHash, chronicleRoot);
    }

    // ------------------------------------------------------- intake callbacks

    /// @notice Single-question answer (selector 0x510379c7). Called by the intake with a 200k gas limit.
    /// @dev The answer bytes are stored (~22k gas per 32-byte word), so only short answers fit the limit:
    /// bool/address/bytes32/uint256 easily. Use `record` for lists longer than two elements. If the callback runs out
    /// of gas the intake swallows the revert, the request stays pending, and the attestation can still be
    /// relayed by anyone through `record`.
    function onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature)
        external
        onlyIntakeCallback(requestId)
    {
        _record(a, signature);
    }

    /// @notice Group / job result document (selector 0x4374622e).
    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri)
        external
        onlyIntakeCallback(requestId)
    {
        emit GroupCompleted(requestId, resultHash, uri);
    }

    /// @notice Failure notice (selector 0x5a0df71e). Unsigned, so it never moves value.
    function onFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes calldata /* signature */
    )
        external
        onlyIntakeCallback(requestId)
    {
        emit AskFailed(requestId, status, reason, agreed, answered);
    }

    // ------------------------------------------------------------------ relay

    /// @notice Anyone may relay a signed attestation for a question this shrine paid for
    /// (e.g. the individual answers of an oracle.group).
    function record(Attestation calldata a, bytes calldata signature) external {
        _record(a, signature);
    }

    // ---------------------------------------------------------------- rewards

    /// @notice Anyone: activate a proposed week once the oracle's recorded answer to its question is `true`.
    function finalizeRewards(uint64 week) external {
        RewardWeek storage w = _proposedWeek(week);
        uint8 v = _verdict(w.questionHash);
        if (v == VERDICT_NONE) revert NoJudgment(w.questionHash);
        if (v != VERDICT_TRUE) revert RewardsNotApproved(week);
        w.status = RewardStatus.Active;
        w.activatedAt = uint64(block.timestamp);
        emit RewardsActivated(week, w.root, w.total);
    }

    /// @notice Anyone: reject a proposed week whose recorded answer is `false` (or not a well-formed bool),
    /// releasing its reservation back to the free balance.
    function rejectRewards(uint64 week) external {
        RewardWeek storage w = _proposedWeek(week);
        uint8 v = _verdict(w.questionHash);
        if (v == VERDICT_NONE) revert NoJudgment(w.questionHash);
        if (v == VERDICT_TRUE) revert RewardsApproved(week);
        w.status = RewardStatus.Rejected;
        emit RewardsRejected(week, _release(w));
    }

    /// @notice Owner: cancel a proposed week that got no judgment within `REWARD_JUDGMENT_TIMEOUT` (14 days),
    /// releasing its reservation.
    function cancelRewards(uint64 week) external onlyOwner {
        RewardWeek storage w = _proposedWeek(week);
        if (_verdict(w.questionHash) != VERDICT_NONE) revert JudgmentRecorded(week);
        uint256 allowedAt = uint256(w.proposedAt) + REWARD_JUDGMENT_TIMEOUT;
        if (block.timestamp < allowedAt) revert TooEarly(allowedAt);
        w.status = RewardStatus.Cancelled;
        emit RewardsCancelled(week, _release(w));
    }

    /// @notice Anyone may submit a claim; the reward is always paid to `account`. One claim per (week, account).
    /// Leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount)))).
    function claim(uint64 week, address account, uint256 amount, bytes32[] calldata proof) external {
        RewardWeek storage w = _rewardWeeks[week];
        if (w.status != RewardStatus.Active) revert BadRewardStatus(week, w.status);
        if (_claimed[week][account]) revert AlreadyClaimed(week, account);
        if (!MerkleProof.verifyCalldata(proof, w.root, rewardLeaf(account, amount))) revert InvalidProof();
        uint256 left = w.remaining;
        if (amount > left) revert ExceedsRewardRemaining(week, amount, left);

        _claimed[week][account] = true;
        w.remaining = left - amount;
        reserved -= amount;
        imd.safeTransfer(account, amount);
        emit RewardClaimed(week, account, amount);
    }

    /// @notice Owner: after `REWARD_CLAIM_WINDOW` (56 days) from activation, release the unclaimed remainder.
    function expireRewards(uint64 week) external onlyOwner {
        RewardWeek storage w = _rewardWeeks[week];
        if (w.status != RewardStatus.Active) revert BadRewardStatus(week, w.status);
        uint256 allowedAt = uint256(w.activatedAt) + REWARD_CLAIM_WINDOW;
        if (block.timestamp < allowedAt) revert TooEarly(allowedAt);
        w.status = RewardStatus.Expired;
        emit RewardsExpired(week, _release(w));
    }

    // ----------------------------------------------------------------- owner

    function setIntake(IIntake intake_) external onlyOwner {
        if (address(intake_) == address(0)) revert ZeroAddress();
        intake = intake_;
        emit IntakeUpdated(address(intake_));
    }

    function setSigner(address oracleSigner_) external onlyOwner {
        if (oracleSigner_ == address(0)) revert ZeroAddress();
        oracleSigner = oracleSigner_;
        emit SignerUpdated(oracleSigner_);
    }

    function setDirector(address director_) external onlyOwner {
        if (director_ == address(0)) revert ZeroAddress();
        director = director_;
        emit DirectorUpdated(director_);
    }

    function setPrice(uint256 pricePerQuestion_) external onlyOwner {
        pricePerQuestion = pricePerQuestion_;
        emit PriceUpdated(pricePerQuestion_);
    }

    function setMinQuorum(uint16 minQuorum_) external onlyOwner {
        if (minQuorum_ == 0) revert InvalidMinQuorum();
        minQuorum = minQuorum_;
        emit MinQuorumUpdated(minQuorum_);
    }

    /// @notice Minimum panel and agreement accepted for every pinned question, independent of the body's panel.
    /// Set these and `minQuorum` to the required security level before the director asks questions.
    function setPanelMinimums(uint16 minPanelSize_, uint16 minAgreed_) external onlyOwner {
        if (minPanelSize_ < 2 || minAgreed_ == 0 || minAgreed_ > minPanelSize_) revert InvalidPanelMinimums();
        minPanelSize = minPanelSize_;
        minAgreed = minAgreed_;
        emit PanelMinimumsUpdated(minPanelSize_, minAgreed_);
    }

    function setRewardsAction(bytes32 action) external onlyOwner {
        if (action == bytes32(0)) revert ZeroAction();
        rewardsAction = action;
        emit RewardsActionUpdated(action);
    }

    /// @param maxRewardBps_ cap on a week's reward total as bps of the free balance (0 disables rewards).
    function setMaxRewardBps(uint16 maxRewardBps_) external onlyOwner {
        if (maxRewardBps_ > BPS) revert InvalidMaxRewardBps(maxRewardBps_);
        maxRewardBps = maxRewardBps_;
        emit MaxRewardBpsUpdated(maxRewardBps_);
    }

    /// @notice Withdraw tokens. For IMD, only the free balance (`availableBalance()`): reserved rewards stay.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(imd)) {
            uint256 free = availableBalance();
            if (amount > free) revert InsufficientFreeBalance(amount, free);
        }
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice IMD this shrine can spend on questions or withdraw: its balance minus the reward reservations.
    function availableBalance() public view returns (uint256) {
        uint256 bal = imd.balanceOf(address(this));
        uint256 r = reserved;
        return bal > r ? bal - r : 0;
    }

    function rewardWeek(uint64 week) external view returns (RewardWeek memory) {
        return _rewardWeeks[week];
    }

    function isClaimed(uint64 week, address account) external view returns (bool) {
        return _claimed[week][account];
    }

    /// @notice Reward leaf, OpenZeppelin StandardMerkleTree encoding for ["address", "uint256"].
    function rewardLeaf(address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    /// @notice Same outputs as an auto-generated getter for `mapping(bytes32 => Judgment) judgments`.
    function judgments(bytes32 questionHash)
        external
        view
        returns (
            bytes32 oracleRequestId,
            uint8 answerType,
            bytes memory answer,
            uint16 agreed,
            uint16 quorum,
            uint16 panelSize,
            uint64 issuedAt
        )
    {
        StoredJudgment storage j = _judgments[questionHash];
        return (j.oracleRequestId, j.answerType, j.answer, j.agreed, j.quorum, j.panelSize, j.issuedAt);
    }

    function judgmentOf(bytes32 questionHash) external view returns (Judgment memory) {
        StoredJudgment storage j = _judgments[questionHash];
        return Judgment({
            oracleRequestId: j.oracleRequestId,
            answerType: j.answerType,
            answer: j.answer,
            agreed: j.agreed,
            quorum: j.quorum,
            panelSize: j.panelSize,
            issuedAt: j.issuedAt
        });
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice EIP-712 digest the oracle signer signs for `a` in this shrine's domain.
    function attestationDigest(Attestation calldata a) external view returns (bytes32) {
        return _hashTypedDataV4(_hash(a));
    }

    // --------------------------------------------------------------- internal

    function _pin(bytes32 h, uint8 kind) private {
        if (h == bytes32(0)) revert ZeroQuestionHash();
        if (pins[h].pinnedAt != 0) revert AlreadyPinned(h);
        pins[h] = Pin({kind: kind, pinnedAt: uint64(block.timestamp), answered: false});
    }

    /// @dev Pays the intake for `n` questions from the free balance and registers the pending request.
    function _buy(bytes32 action, bytes calldata body, uint256 n) private returns (bytes32 requestId, uint256 amount) {
        amount = pricePerQuestion * n;
        uint256 free = availableBalance();
        if (amount > free) revert InsufficientFreeBalance(amount, free);
        IIntake intake_ = intake;
        imd.forceApprove(address(intake_), amount);
        bytes4 sel = n == 1 ? this.onOracleResult.selector : this.onResult.selector;
        requestId = intake_.requestWithFailure(
            action, body, IIntake.Callback(address(this), sel), this.onFailure.selector, address(imd), amount
        );
        pending[requestId] = true;
    }

    function _proposedWeek(uint64 week) private view returns (RewardWeek storage w) {
        w = _rewardWeeks[week];
        if (w.status != RewardStatus.Proposed) revert BadRewardStatus(week, w.status);
    }

    /// @dev Frees what is still reserved for `w`.
    function _release(RewardWeek storage w) private returns (uint256 released) {
        released = w.remaining;
        w.remaining = 0;
        reserved -= released;
    }

    /// @dev VERDICT_TRUE only for a recorded bool answer `abi.encode(true)`.
    function _verdict(bytes32 questionHash) private view returns (uint8) {
        if (!pins[questionHash].answered) return VERDICT_NONE;
        StoredJudgment storage j = _judgments[questionHash];
        if (j.answerType != 0) return VERDICT_NOT_TRUE;
        bytes memory answer = j.answer;
        if (answer.length != 32) return VERDICT_NOT_TRUE;
        return abi.decode(answer, (uint256)) == 1 ? VERDICT_TRUE : VERDICT_NOT_TRUE;
    }

    function _record(Attestation calldata a, bytes calldata signature) internal {
        Pin storage pin = pins[a.questionHash];
        if (pin.pinnedAt == 0) revert NotPinned(a.questionHash);
        if (pin.answered) revert AlreadyAnswered(a.questionHash);
        if (a.agreed < a.quorum) revert QuorumNotReached(a.agreed, a.quorum);
        uint16 minQ = minQuorum;
        if (a.quorum < minQ) revert QuorumTooLow(a.quorum, minQ);
        if (a.panelSize < minPanelSize || a.agreed < minAgreed || a.agreed > a.panelSize) {
            revert PanelTooWeak(a.panelSize, a.agreed);
        }
        if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt);
        if (!SignatureChecker.isValidSignatureNowCalldata(oracleSigner, _hashTypedDataV4(_hash(a)), signature)) {
            revert InvalidSignature();
        }

        pin.answered = true;
        _judgments[a.questionHash] = StoredJudgment({
            oracleRequestId: a.requestId,
            answerType: a.answerType,
            agreed: a.agreed,
            quorum: a.quorum,
            panelSize: a.panelSize,
            issuedAt: a.issuedAt,
            answer: a.answer
        });
        emit Judged(a.questionHash, a.requestId, pin.kind, a.answerType, a.answer, a.agreed, a.quorum);
    }

    function _hash(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }
}
