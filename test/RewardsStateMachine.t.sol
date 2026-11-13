// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleShrine} from "src/OracleShrine.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {OracleFixture, OracleTestIMD, OracleTestIntake} from "./helpers/OracleFixture.sol";

/// Rewards are tested against independent Merkle leaves and actual ERC20 balance changes.
/// forge-config: default.fuzz.runs = 1000
contract RewardsStateMachineTest is OracleFixture {
    bytes32 private constant H = keccak256("state machine question");
    address private constant SECOND = address(0xC1A2);

    function _leaf(address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _propose(uint64 week, bytes32 root, uint256 amount, bytes32 q) private returns (bytes32) {
        vm.prank(director);
        return shrine.askRewards(week, root, amount, "{}", q);
    }

    function _answer(bytes32 q, bool approved) private {
        OracleShrine.Attestation memory a = _attestation(q);
        a.answer = abi.encode(approved);
        shrine.record(a, _sign(a));
    }

    function _status(uint64 week, OracleShrine.RewardStatus expected, uint256 remaining) private view {
        OracleShrine.RewardWeek memory w = shrine.rewardWeek(week);
        assertEq(uint8(w.status), uint8(expected));
        assertEq(w.remaining, remaining);
    }

    function test_invalidProposalInputsLeaveNoReservation() public {
        vm.startPrank(director);
        vm.expectRevert(OracleShrine.ZeroRoot.selector);
        shrine.askRewards(1, bytes32(0), 1, "{}", H);
        vm.expectRevert(OracleShrine.ZeroRewardTotal.selector);
        shrine.askRewards(1, H, 0, "{}", H);
        vm.expectRevert(OracleShrine.ZeroQuestionHash.selector);
        shrine.askRewards(1, H, 1, "{}", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardTotalTooHigh.selector, 200 ether + 1, 200 ether));
        shrine.askRewards(1, H, 200 ether + 1, "{}", H);
        vm.stopPrank();
        assertEq(shrine.reserved(), 0);
        assertEq(imd.balanceOf(address(intake)), 0);
        _status(1, OracleShrine.RewardStatus.None, 0);
    }

    function test_reservingEverythingCannotSpendTheReservationOnTheFee() public {
        vm.prank(owner);
        shrine.setMaxRewardBps(10_000);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.InsufficientFreeBalance.selector, 0.5 ether, 0));
        _askRewards(1, H, 1_000 ether);
        assertEq(shrine.reserved(), 0);
        assertEq(shrine.availableBalance(), 1_000 ether);
        (, uint64 pinnedAt,) = shrine.pins(H);
        assertEq(pinnedAt, 0);
        _status(1, OracleShrine.RewardStatus.None, 0);
    }

    function test_capUsesFreeBalanceAndCannotDoubleReserveAWeekOrQuestion() public {
        _askRewards(0, H, 200 ether); // week zero is a valid mapping key
        uint256 cap = shrine.availableBalance() / 5;
        bytes32 q = keccak256("second question");
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardTotalTooHigh.selector, cap + 1, cap));
        _askRewards(1, q, cap + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleShrine.RewardWeekExists.selector, uint64(0), OracleShrine.RewardStatus.Proposed
            )
        );
        _askRewards(0, q, 1);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AlreadyPinned.selector, H));
        _askRewards(1, H, 1);
        _askRewards(1, q, cap);
        assertEq(shrine.reserved(), 200 ether + cap);
        assertEq(imd.balanceOf(address(intake)), 1 ether);
    }

    function test_twoLeafClaimsPayTheBeneficiaryAndProtectOtherWeeks() public {
        bytes32 first = _leaf(claimant, 40 ether);
        bytes32 second = _leaf(SECOND, 60 ether);
        _propose(1, _pair(first, second), 100 ether, H);
        _askRewards(2, keccak256("other week"), 50 ether);
        _answer(H, true);
        shrine.finalizeRewards(1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = second;
        vm.prank(SECOND); // anyone may relay, but cannot redirect another account's leaf
        shrine.claim(1, claimant, 40 ether, proof);
        assertEq(imd.balanceOf(claimant), 40 ether);
        assertEq(imd.balanceOf(SECOND), 0);
        assertEq(shrine.reserved(), 110 ether);
        assertTrue(shrine.isClaimed(1, claimant));
        assertFalse(shrine.isClaimed(2, claimant));
        _status(1, OracleShrine.RewardStatus.Active, 60 ether);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AlreadyClaimed.selector, uint64(1), claimant));
        shrine.claim(1, claimant, 40 ether, proof);
        proof[0] = first;
        shrine.claim(1, SECOND, 60 ether, proof);
        assertEq(shrine.reserved(), 50 ether);
        assertEq(imd.balanceOf(SECOND), 60 ether);
        _status(2, OracleShrine.RewardStatus.Proposed, 50 ether);
    }

    function test_invalidClaimCannotConsumeAClaimOrTheReservation() public {
        _askRewards(1, H, 100 ether);
        _answer(H, true);
        shrine.finalizeRewards(1);
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(OracleShrine.InvalidProof.selector);
        shrine.claim(1, SECOND, 100 ether, empty);
        vm.expectRevert(OracleShrine.InvalidProof.selector);
        shrine.claim(1, claimant, 100 ether - 1, empty);
        bytes32[] memory wrong = new bytes32[](1);
        wrong[0] = H;
        vm.expectRevert(OracleShrine.InvalidProof.selector);
        shrine.claim(1, claimant, 100 ether, wrong);
        assertFalse(shrine.isClaimed(1, claimant));
        assertFalse(shrine.isClaimed(1, SECOND));
        assertEq(shrine.reserved(), 100 ether);
        shrine.claim(1, claimant, 100 ether, empty);
        assertEq(imd.balanceOf(claimant), 100 ether);
    }

    function test_validLeafCannotSpendMoreThanTheWeekReserved() public {
        _propose(1, _leaf(claimant, 101 ether), 100 ether, H);
        _answer(H, true);
        shrine.finalizeRewards(1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleShrine.ExceedsRewardRemaining.selector, uint64(1), 101 ether, 100 ether)
        );
        shrine.claim(1, claimant, 101 ether, new bytes32[](0));
        assertFalse(shrine.isClaimed(1, claimant));
        assertEq(shrine.reserved(), 100 ether);
    }

    function test_failedRewardTransferRestoresClaimAndReservation() public {
        _askRewards(1, H, 100 ether);
        _answer(H, true);
        shrine.finalizeRewards(1);
        vm.mockCall(address(imd), abi.encodeCall(IERC20.transfer, (claimant, 100 ether)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        shrine.claim(1, claimant, 100 ether, new bytes32[](0));
        assertFalse(shrine.isClaimed(1, claimant));
        assertEq(shrine.reserved(), 100 ether);
        _status(1, OracleShrine.RewardStatus.Active, 100 ether);
        assertEq(imd.balanceOf(claimant), 0);
        vm.clearMockedCalls();
        shrine.claim(1, claimant, 100 ether, new bytes32[](0));
        assertEq(imd.balanceOf(claimant), 100 ether);
        assertEq(shrine.reserved(), 0);
    }

    function test_ordinaryQuestionCannotSpendReservedRewards() public {
        _askRewards(1, H, 200 ether);
        uint256 free = shrine.availableBalance();
        vm.prank(owner);
        shrine.setPrice(free + 1);
        bytes32 other = keccak256("unaffordable ordinary question");
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.InsufficientFreeBalance.selector, free + 1, free));
        _ask(other);
        (, uint64 pinnedAt,) = shrine.pins(other);
        assertEq(pinnedAt, 0);
        assertEq(shrine.reserved(), 200 ether);
        assertEq(imd.balanceOf(address(shrine)), 999.5 ether);
        vm.prank(owner);
        shrine.setPrice(free);
        _ask(other);
        assertEq(shrine.availableBalance(), 0);
        assertEq(imd.balanceOf(address(shrine)), 200 ether);
        _answer(H, true);
        shrine.finalizeRewards(1);
        shrine.claim(1, claimant, 200 ether, new bytes32[](0));
        assertEq(imd.balanceOf(address(shrine)), 0);
    }

    function testFuzz_weekIdentifiersAndClaimsAreIndependent(uint64 week) public {
        uint64 other = week ^ type(uint64).max;
        _askRewards(week, H, 100 ether);
        bytes32 q = keccak256("other identifier");
        _askRewards(other, q, 50 ether);
        _answer(H, true);
        _answer(q, true);
        shrine.finalizeRewards(week);
        shrine.finalizeRewards(other);
        shrine.claim(week, claimant, 100 ether, new bytes32[](0));
        assertFalse(shrine.isClaimed(other, claimant));
        shrine.claim(other, claimant, 50 ether, new bytes32[](0));
        assertEq(imd.balanceOf(claimant), 150 ether);
        assertEq(shrine.reserved(), 0);
    }

    function testFuzz_onlyCanonicalTrueActivatesRewards(uint8 encoding) public {
        encoding = uint8(bound(encoding, 0, 6));
        _askRewards(1, H, 100 ether);
        OracleShrine.Attestation memory a = _attestation(H);
        if (encoding == 0) a.answer = abi.encode(false);
        if (encoding == 1) a.answer = abi.encode(uint256(2));
        if (encoding == 2) a.answer = "";
        if (encoding == 3) a.answer = hex"01";
        if (encoding == 4) a.answer = abi.encode(true, true);
        if (encoding == 5) a.answerType = 3;
        shrine.record(a, _sign(a));
        if (encoding == 6) {
            vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardsApproved.selector, uint64(1)));
            shrine.rejectRewards(1);
            shrine.finalizeRewards(1);
            assertEq(shrine.reserved(), 100 ether);
        } else {
            vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardsNotApproved.selector, uint64(1)));
            shrine.finalizeRewards(1);
            shrine.rejectRewards(1);
            _status(1, OracleShrine.RewardStatus.Rejected, 0);
            assertEq(shrine.reserved(), 0);
        }
    }

    function test_noJudgmentCannotActivateOrRejectAndClaimRequiresActive() public {
        _askRewards(1, H, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NoJudgment.selector, H));
        shrine.finalizeRewards(1);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NoJudgment.selector, H));
        shrine.rejectRewards(1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleShrine.BadRewardStatus.selector, uint64(1), OracleShrine.RewardStatus.Proposed)
        );
        shrine.claim(1, claimant, 100 ether, new bytes32[](0));
        vm.expectRevert(
            abi.encodeWithSelector(OracleShrine.BadRewardStatus.selector, uint64(2), OracleShrine.RewardStatus.None)
        );
        shrine.finalizeRewards(2);
    }

    function test_timeoutBoundaryAndCancelledWeekCanBeReproposed() public {
        _askRewards(1, H, 100 ether);
        uint256 deadline = block.timestamp + shrine.REWARD_JUDGMENT_TIMEOUT();
        vm.warp(deadline - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.TooEarly.selector, deadline));
        shrine.cancelRewards(1);
        vm.warp(deadline);
        vm.prank(owner);
        shrine.cancelRewards(1);
        _status(1, OracleShrine.RewardStatus.Cancelled, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleShrine.BadRewardStatus.selector, uint64(1), OracleShrine.RewardStatus.Cancelled
            )
        );
        shrine.cancelRewards(1);
        _askRewards(1, keccak256("replacement"), 70 ether);
        _status(1, OracleShrine.RewardStatus.Proposed, 70 ether);
        assertEq(shrine.reserved(), 70 ether);
    }

    function test_recordedJudgmentPreventsTimeoutCancellation() public {
        _askRewards(1, H, 100 ether);
        _answer(H, false);
        vm.warp(block.timestamp + shrine.REWARD_JUDGMENT_TIMEOUT());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.JudgmentRecorded.selector, uint64(1)));
        shrine.cancelRewards(1);
        shrine.rejectRewards(1);
        _askRewards(1, keccak256("corrected proposal"), 10 ether);
        assertEq(shrine.reserved(), 10 ether);
    }

    function test_expiryReleasesOnlyTheUnclaimedRemainderAtTheBoundary() public {
        bytes32 first = _leaf(claimant, 40 ether);
        bytes32 second = _leaf(SECOND, 60 ether);
        _propose(1, _pair(first, second), 100 ether, H);
        _answer(H, true);
        shrine.finalizeRewards(1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = second;
        shrine.claim(1, claimant, 40 ether, proof);
        uint256 deadline = block.timestamp + shrine.REWARD_CLAIM_WINDOW();
        vm.warp(deadline - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.TooEarly.selector, deadline));
        shrine.expireRewards(1);
        vm.warp(deadline);
        uint256 freeBefore = shrine.availableBalance();
        vm.prank(owner);
        shrine.expireRewards(1);
        assertEq(shrine.availableBalance(), freeBefore + 60 ether);
        assertEq(shrine.reserved(), 0);
        _status(1, OracleShrine.RewardStatus.Expired, 0);
        proof[0] = first;
        vm.expectRevert(
            abi.encodeWithSelector(OracleShrine.BadRewardStatus.selector, uint64(1), OracleShrine.RewardStatus.Expired)
        );
        shrine.claim(1, SECOND, 60 ether, proof);
        vm.expectRevert(
            abi.encodeWithSelector(OracleShrine.RewardWeekExists.selector, uint64(1), OracleShrine.RewardStatus.Expired)
        );
        _askRewards(1, keccak256("cannot reopen"), 1);
    }

    function test_unpinBatchIsAtomicAndReleasesOnlyItsProposedWeek() public {
        _askRewards(1, H, 100 ether);
        bytes32 other = keccak256("other proposed week");
        _askRewards(2, other, 50 ether);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = H;
        hashes[1] = keccak256("unknown");
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPinned.selector, hashes[1]));
        shrine.unpin(hashes);
        _status(1, OracleShrine.RewardStatus.Proposed, 100 ether);
        assertEq(shrine.reserved(), 150 ether);
        hashes = new bytes32[](1);
        hashes[0] = H;
        vm.prank(director);
        shrine.unpin(hashes);
        _status(1, OracleShrine.RewardStatus.Cancelled, 0);
        _status(2, OracleShrine.RewardStatus.Proposed, 50 ether);
        assertEq(shrine.reserved(), 50 ether);
        _answer(other, true);
        hashes[0] = other;
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AlreadyAnswered.selector, other));
        shrine.unpin(hashes);
    }

    function testFuzz_partialClaimsThenExpireConserveAssets(uint96 first, uint96 second) public {
        uint256 a = bound(first, 1, 90 ether);
        uint256 b = bound(second, 1, 90 ether);
        bytes32 leafB = _leaf(SECOND, b);
        _propose(1, _pair(_leaf(claimant, a), leafB), a + b, H);
        _answer(H, true);
        shrine.finalizeRewards(1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        shrine.claim(1, claimant, a, proof);
        assertEq(shrine.reserved(), b);
        vm.warp(block.timestamp + shrine.REWARD_CLAIM_WINDOW());
        vm.prank(owner);
        shrine.expireRewards(1);
        uint256 free = shrine.availableBalance();
        vm.prank(owner);
        shrine.withdraw(address(imd), owner, free);
        assertEq(imd.balanceOf(claimant) + imd.balanceOf(owner) + imd.balanceOf(address(intake)), 1_000 ether);
        assertEq(imd.balanceOf(address(shrine)), 0);
        assertEq(shrine.reserved(), 0);
    }
}
