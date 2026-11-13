// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleShrine} from "src/OracleShrine.sol";
import {OracleTestIMD, OracleTestIntake} from "../helpers/OracleFixture.sol";

/// A small independent ledger: proposal totals come from inputs, and paid amounts from claims,
/// never by copying reserved/remaining from the implementation. Reverts on valid actions are sticky failures.
contract RewardAccountingHandler is Test {
    struct WeekModel {
        OracleShrine.RewardStatus status;
        bytes32 question;
        bytes32 request;
        bytes32 root;
        uint256 total;
        uint256 remaining;
        uint64 proposedAt;
        uint64 activatedAt;
        uint8 verdict;
        bool firstClaimed;
        bool secondClaimed;
    }

    uint256 private constant KEY = 0x123456;
    address public constant OWNER = address(0xA11CE);
    address public constant DIRECTOR = address(0xD1);
    address public constant FIRST = address(0xC1A1);
    address public constant SECOND = address(0xC1A2);
    address private constant RELAYER = address(0xBEEF);
    OracleShrine public immutable shrine;
    OracleTestIMD public immutable imd;
    OracleTestIntake public immutable intake;
    WeekModel[8] private weekModels;
    uint256 private nonce;
    uint256 public funded;
    uint256 public fees;
    uint256 public withdrawn;
    uint256 public firstPaid;
    uint256 public secondPaid;
    uint256 public successfulCalls;
    bool public unexpectedRevert;
    bytes public lastFailure;

    constructor(OracleShrine shrine_, OracleTestIMD imd_, OracleTestIntake intake_) {
        shrine = shrine_;
        imd = imd_;
        intake = intake_;
        funded = imd_.balanceOf(address(shrine_));
    }

    function model(uint256 i) external view returns (WeekModel memory) {
        return weekModels[i];
    }

    function donate(uint96 amount) external {
        uint256 value = bound(amount, 1, 1_000 ether);
        imd.mint(address(shrine), value);
        funded += value;
        ++successfulCalls;
    }

    function propose(uint256 seed, uint96 amount) external {
        uint64 i = uint64(seed % 8);
        WeekModel storage w = weekModels[i];
        if (
            w.status != OracleShrine.RewardStatus.None && w.status != OracleShrine.RewardStatus.Cancelled
                && w.status != OracleShrine.RewardStatus.Rejected
        ) return;
        uint256 free = imd.balanceOf(address(shrine)) - _reserved();
        uint256 price = shrine.pricePerQuestion();
        if (free <= price + 2) return;
        uint256 cap = free / 5;
        if (cap > free - price) cap = free - price;
        if (cap < 2) return;
        uint256 total = bound(amount, 2, cap);
        bytes32 root = _pair(_leaf(FIRST, total / 2), _leaf(SECOND, total - total / 2));
        bytes32 q = keccak256(abi.encode("reward invariant", ++nonce));
        (bool ok, bytes memory result) =
            _call(DIRECTOR, abi.encodeCall(shrine.askRewards, (i, root, total, bytes("{}"), q)));
        if (!ok) return;
        weekModels[i] = WeekModel({
            status: OracleShrine.RewardStatus.Proposed,
            question: q,
            request: abi.decode(result, (bytes32)),
            root: root,
            total: total,
            remaining: total,
            proposedAt: uint64(block.timestamp),
            activatedAt: 0,
            verdict: 0,
            firstClaimed: false,
            secondClaimed: false
        });
        fees += price;
    }

    function recordVerdict(uint256 seed, bool approved, bool callback) external {
        WeekModel storage w = weekModels[seed % 8];
        if (w.status != OracleShrine.RewardStatus.Proposed || w.verdict != 0) return;
        OracleShrine.Attestation memory a;
        a.requestId = keccak256(abi.encode("oracle UUID", w.question));
        a.chainId = 1;
        a.questionHash = w.question;
        a.answer = abi.encode(approved);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = bytes32(uint256(7));
        a.panelJobId = keccak256("invariant panel");
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 20;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, shrine.attestationDigest(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        bool ok;
        if (callback && shrine.pending(w.request)) {
            ok = intake.deliver(w.request, a, sig);
            if (!ok) unexpectedRevert = true;
            else ++successfulCalls;
        } else {
            (ok,) = _call(RELAYER, abi.encodeCall(shrine.record, (a, sig)));
        }
        if (ok) w.verdict = approved ? 1 : 2;
    }

    function settle(uint256 seed) external {
        uint64 i = uint64(seed % 8);
        WeekModel storage w = weekModels[i];
        if (w.status != OracleShrine.RewardStatus.Proposed || w.verdict == 0) return;
        bool approved = w.verdict == 1;
        (bool ok,) = _call(
            RELAYER, approved ? abi.encodeCall(shrine.finalizeRewards, (i)) : abi.encodeCall(shrine.rejectRewards, (i))
        );
        if (!ok) return;
        w.status = approved ? OracleShrine.RewardStatus.Active : OracleShrine.RewardStatus.Rejected;
        if (approved) w.activatedAt = uint64(block.timestamp);
        else w.remaining = 0;
    }

    function claimReward(uint256 seed, bool second) external {
        uint64 i = uint64(seed % 8);
        WeekModel storage w = weekModels[i];
        if (w.status != OracleShrine.RewardStatus.Active) return;
        if (second ? w.secondClaimed : w.firstClaimed) return;
        uint256 first = w.total / 2;
        uint256 amount = second ? w.total - first : first;
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = second ? _leaf(FIRST, first) : _leaf(SECOND, w.total - first);
        (bool ok,) = _call(RELAYER, abi.encodeCall(shrine.claim, (i, second ? SECOND : FIRST, amount, proof)));
        if (!ok) return;
        w.remaining -= amount;
        if (second) {
            w.secondClaimed = true;
            secondPaid += amount;
        } else {
            w.firstClaimed = true;
            firstPaid += amount;
        }
    }

    function release(uint256 seed, bool unpin) external {
        uint64 i = uint64(seed % 8);
        WeekModel storage w = weekModels[i];
        if (w.status != OracleShrine.RewardStatus.Proposed || w.verdict != 0) return;
        bool ok;
        if (unpin) {
            bytes32[] memory hashes = new bytes32[](1);
            hashes[0] = w.question;
            (ok,) = _call(DIRECTOR, abi.encodeCall(shrine.unpin, (hashes)));
        } else {
            if (block.timestamp < uint256(w.proposedAt) + 14 days) return;
            (ok,) = _call(OWNER, abi.encodeCall(shrine.cancelRewards, (i)));
        }
        if (ok) {
            w.status = OracleShrine.RewardStatus.Cancelled;
            w.remaining = 0;
        }
    }

    function expire(uint256 seed) external {
        uint64 i = uint64(seed % 8);
        WeekModel storage w = weekModels[i];
        if (w.status != OracleShrine.RewardStatus.Active || block.timestamp < uint256(w.activatedAt) + 56 days) return;
        (bool ok,) = _call(OWNER, abi.encodeCall(shrine.expireRewards, (i)));
        if (ok) {
            w.status = OracleShrine.RewardStatus.Expired;
            w.remaining = 0;
        }
    }

    function withdrawFree(uint256 amount, bool all) external {
        uint256 free = imd.balanceOf(address(shrine)) - _reserved();
        amount = all ? free : bound(amount, 0, free);
        (bool ok,) = _call(OWNER, abi.encodeCall(shrine.withdraw, (address(imd), OWNER, amount)));
        if (ok) withdrawn += amount;
    }

    function buyQuestions(uint8 count) external {
        uint256 n = bound(count, 1, 8);
        uint256 price = shrine.pricePerQuestion() * n;
        if (imd.balanceOf(address(shrine)) - _reserved() < price) return;
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            hashes[i] = keccak256(abi.encode("ordinary", ++nonce));
        }
        (bool ok,) = _call(
            DIRECTOR, abi.encodeCall(shrine.ask, (bytes32("oracle.request@oracle-1"), bytes("{}"), hashes, uint8(1)))
        );
        if (ok) fees += price;
    }

    function failRequest(uint256 seed) external {
        WeekModel storage w = weekModels[seed % 8];
        if (w.request == bytes32(0) || !shrine.pending(w.request)) return;
        if (!intake.fail(w.request)) unexpectedRevert = true;
        else ++successfulCalls;
        // Failure is unsigned. It must not change our model of balances, reservations, or judgments.
    }

    function elapse(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 15 days));
    }

    function _call(address actor, bytes memory data) private returns (bool ok, bytes memory result) {
        vm.prank(actor);
        (ok, result) = address(shrine).call(data);
        if (!ok) {
            unexpectedRevert = true;
            lastFailure = result;
        } else {
            ++successfulCalls;
        }
    }

    function _reserved() private view returns (uint256 total) {
        for (uint256 i; i < 8; ++i) {
            total += weekModels[i].remaining;
        }
    }

    function _leaf(address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract RewardAccountingInvariantTest is Test {
    OracleShrine private shrine;
    OracleTestIMD private imd;
    OracleTestIntake private intake;
    RewardAccountingHandler private handler;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        imd = new OracleTestIMD();
        intake = new OracleTestIntake();
        shrine = new OracleShrine(address(0xA11CE), intake, imd, vm.addr(0x123456), address(0xD1));
        imd.mint(address(shrine), 1_000 ether);
        handler = new RewardAccountingHandler(shrine, imd, intake);
        // Every campaign starts with a live partially claimed week and a pending proposal.
        handler.propose(0, 100 ether);
        handler.recordVerdict(0, true, true);
        handler.settle(0);
        handler.claimReward(0, false);
        handler.propose(1, 50 ether);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.propose.selector;
        selectors[2] = handler.recordVerdict.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.claimReward.selector;
        selectors[5] = handler.release.selector;
        selectors[6] = handler.expire.selector;
        selectors[7] = handler.withdrawFree.selector;
        selectors[8] = handler.buyQuestions.selector;
        selectors[9] = handler.failRequest.selector;
        selectors[10] = handler.elapse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_reservationsMatchEveryWeekAndRemainSolvent() public view {
        uint256 liabilities;
        for (uint256 i; i < 8; ++i) {
            RewardAccountingHandler.WeekModel memory m = handler.model(i);
            OracleShrine.RewardWeek memory w = shrine.rewardWeek(uint64(i));
            assertEq(uint8(w.status), uint8(m.status), "state transition diverged");
            assertEq(w.total, m.total);
            assertEq(w.remaining, m.remaining);
            assertEq(w.questionHash, m.question);
            assertEq(w.root, m.root);
            assertEq(w.proposedAt, m.proposedAt);
            assertEq(w.activatedAt, m.activatedAt);
            assertEq(shrine.isClaimed(uint64(i), handler.FIRST()), m.firstClaimed);
            assertEq(shrine.isClaimed(uint64(i), handler.SECOND()), m.secondClaimed);
            assertLe(w.remaining, w.total);
            liabilities += m.remaining;
        }
        assertEq(shrine.reserved(), liabilities, "reservation ledger");
        uint256 balance = imd.balanceOf(address(shrine));
        assertLe(liabilities, balance, "insolvent rewards");
        assertEq(shrine.availableBalance() + liabilities, balance);
    }

    function invariant_allFundedTokensAreAccountedFor() public view {
        assertEq(imd.balanceOf(address(intake)), handler.fees());
        assertEq(imd.balanceOf(handler.OWNER()), handler.withdrawn());
        assertEq(imd.balanceOf(handler.FIRST()), handler.firstPaid());
        assertEq(imd.balanceOf(handler.SECOND()), handler.secondPaid());
        assertEq(
            imd.balanceOf(address(shrine)) + handler.fees() + handler.withdrawn() + handler.firstPaid()
                + handler.secondPaid(),
            handler.funded()
        );
        assertEq(imd.allowance(address(shrine), address(intake)), 0, "fee approval fully spent");
    }

    function invariant_validActionsDoNotSilentlyRevert() public view {
        assertFalse(handler.unexpectedRevert(), "valid handler action reverted");
        assertGe(handler.successfulCalls(), 5, "seeded paths must execute");
    }

    function test_handlerExercisesEveryRewardExitAndReproposal() public {
        handler.failRequest(1);
        handler.release(1, true);
        handler.propose(1, 50 ether);
        handler.recordVerdict(1, false, false);
        handler.settle(1);
        handler.propose(1, 20 ether);
        handler.elapse(uint32(14 days));
        handler.release(1, false);
        handler.elapse(uint32(15 days));
        handler.elapse(uint32(15 days));
        handler.elapse(uint32(15 days));
        handler.expire(0);
        handler.donate(17);
        handler.buyQuestions(8);
        handler.withdrawFree(0, true);
        invariant_reservationsMatchEveryWeekAndRemainSolvent();
        invariant_allFundedTokensAreAccountedFor();
        invariant_validActionsDoNotSilentlyRevert();
        assertEq(uint8(shrine.rewardWeek(0).status), uint8(OracleShrine.RewardStatus.Expired));
        assertEq(uint8(shrine.rewardWeek(1).status), uint8(OracleShrine.RewardStatus.Cancelled));
    }
}
