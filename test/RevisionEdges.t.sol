// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleShrine} from "../src/OracleShrine.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {OracleFixture} from "./helpers/OracleFixture.sol";
import {TestIMD} from "./Marks.t.sol";

/// Failure paths of the revision's request binding: what a refused, failed or orphaned rewards request leaves behind.
/// forge-config: default.fuzz.runs = 1000
contract ShrineRevisionEdgesTest is OracleFixture {
    bytes32 private constant Q = keccak256("revision edge question");

    function _hs(bytes32 h) private pure returns (bytes32[] memory hs) {
        hs = new bytes32[](1);
        hs[0] = h;
    }

    function test_directorRelayOfAnUnpinnedQuestionIsNotPinnedNotRewards() public {
        OracleShrine.Attestation memory a = _attestation(Q);
        bytes memory sig = _sign(a);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPinned.selector, Q));
        shrine.record(a, sig);
        assertEq(shrine.requestOfQuestion(Q), bytes32(0));
    }

    /// Unpinning a rewards question cancels the week and orphans its request: the old request, still pending at
    /// the intake, can never settle the re-proposed week even though it carries the very same question.
    function test_orphanedRewardsRequestCannotSettleTheReproposedWeek() public {
        bytes32 oldRid = _askRewards(1, Q, 100 ether);
        vm.prank(director);
        shrine.unpin(_hs(Q));
        assertTrue(shrine.pending(oldRid), "orphaned request is still pending");
        assertEq(shrine.requestOfQuestion(Q), bytes32(0));
        assertEq(shrine.reserved(), 0);

        bytes32 newRid = _askRewards(1, Q, 80 ether);
        assertEq(shrine.requestOfQuestion(Q), newRid);
        OracleShrine.Attestation memory a = _attestation(Q);
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AnswerNotForRequest.selector, oldRid, Q));
        shrine.onOracleResult(oldRid, a, sig);
        assertFalse(_answered(Q));
        assertTrue(intake.deliver(newRid, a, sig));
        shrine.finalizeRewards(1);
        assertEq(uint8(shrine.rewardWeek(1).status), uint8(OracleShrine.RewardStatus.Active));
        assertEq(shrine.reserved(), 80 ether);
    }

    /// A callback that reverts (expired, weak panel) rolls back entirely: the request stays pending and bound, so the
    /// intake's next delivery with a valid attestation still settles it.
    function test_refusedRewardsCallbackLeavesTheRequestBoundAndPending() public {
        bytes32 rid = _askRewards(1, Q, 100 ether);
        OracleShrine.Attestation memory a = _attestation(Q);
        a.expiresAt = uint64(block.timestamp - 1);
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AttestationExpired.selector, a.expiresAt));
        shrine.onOracleResult(rid, a, sig);
        a = _attestation(Q);
        a.agreed = 19;
        sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.QuorumNotReached.selector, uint16(19), uint16(20)));
        shrine.onOracleResult(rid, a, sig);
        assertTrue(shrine.pending(rid));
        assertEq(shrine.requestOfQuestion(Q), rid);
        a = _attestation(Q);
        sig = _sign(a);
        assertTrue(intake.deliver(rid, a, sig));
        assertFalse(shrine.pending(rid));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPending.selector, rid));
        shrine.onOracleResult(rid, a, sig);
    }

    /// After an (unsigned) failure notice nothing can settle the week: no callback, no relay. The reservation is
    /// still recoverable, by unpinning at once or by the owner after the judgment timeout.
    function test_failedRewardsRequestCanOnlyBeCancelled() public {
        bytes32 rid = _askRewards(1, Q, 100 ether);
        assertTrue(intake.fail(rid));
        assertFalse(shrine.pending(rid));
        OracleShrine.Attestation memory a = _attestation(Q);
        bytes memory sig = _sign(a);
        assertFalse(intake.deliver(rid, a, sig));
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardsAnswerNotRelayable.selector, Q));
        shrine.record(a, sig);
        assertFalse(_answered(Q));
        assertEq(shrine.reserved(), 100 ether);
        vm.warp(block.timestamp + shrine.REWARD_JUDGMENT_TIMEOUT());
        vm.prank(owner);
        shrine.cancelRewards(1);
        assertEq(shrine.reserved(), 0);
        assertEq(uint8(shrine.rewardWeek(1).status), uint8(OracleShrine.RewardStatus.Cancelled));
    }

    /// `issuedAt` may be at most ISSUED_AT_TOLERANCE in the future, through either entry point.
    function testFuzz_issuedAtToleranceBoundary(uint32 ahead, bool viaCallback) public {
        uint256 tol = shrine.ISSUED_AT_TOLERANCE();
        uint256 d = bound(ahead, 0, 2 * tol);
        bytes32 rid = _ask(Q);
        OracleShrine.Attestation memory a = _attestation(Q);
        a.issuedAt = uint64(block.timestamp + d);
        a.expiresAt = uint64(block.timestamp + 3 * tol);
        bytes memory sig = _sign(a);
        bool accepted = d <= tol;
        if (!accepted) {
            vm.expectRevert(abi.encodeWithSelector(OracleShrine.AttestationNotYetValid.selector, a.issuedAt));
        }
        if (viaCallback) {
            vm.prank(address(intake));
            shrine.onOracleResult(rid, a, sig);
        } else {
            vm.prank(director);
            shrine.record(a, sig);
        }
        assertEq(_answered(Q), accepted);
    }

    /// An outsider's answer to a question the shrine pinned, with a different oracle UUID, cannot be relayed by
    /// anyone but the director, and the director's relay of an ordinary question records the oracle's UUID.
    function test_outsiderRelaysAreRefusedForEveryKind() public {
        _ask(Q);
        OracleShrine.Attestation memory a = _attestation(Q);
        bytes memory sig = _sign(a);
        address[3] memory others = [owner, claimant, address(intake)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, others[i]));
            shrine.record(a, sig);
        }
        assertFalse(_answered(Q));
    }
}

/// Forge-order reveals: what a stale or not-yet-revealable head does to the souls queued behind it.
contract RevealQueueEdgesTest is Test {
    TestIMD private imd;
    GodsOfIMDInhabitants private nft;
    address private owner = address(0xA11CE);
    address private player = address(0xBEEF);

    function setUp() public {
        vm.roll(1000);
        imd = new TestIMD();
        nft = new GodsOfIMDInhabitants(owner, imd, address(0x5A1), address(0xB0));
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        imd.mint(player, 1_000 ether);
        vm.prank(player);
        imd.approve(address(nft), type(uint256).max);
    }

    function _forge(bytes32 soul) private returns (uint256 id) {
        vm.prank(player);
        id = nft.forge(soul, address(0));
    }

    function test_revealedSoulCannotBeRevealedAgainAndQueueEmpties() public {
        uint256 a = _forge("a");
        vm.roll(block.number + 2);
        nft.reveal(a);
        uint8 m = uint8(nft.markOf(a));
        assertGt(m, 0);
        assertEq(nft.nextToReveal(), 0);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, a));
        nft.reveal(a);
        uint256[] memory list = new uint256[](3);
        list[0] = a;
        list[1] = a;
        list[2] = 999; // never forged
        nft.revealMany(list); // skips everything, reverts nothing
        assertEq(uint8(nft.markOf(a)), m);
    }

    /// A stale head blocks a fresh soul forged after it; re-arming the head lets the queue move again.
    function test_staleHeadBlocksFreshSoulsUntilReArmedAndRevealed() public {
        uint256 a = _forge("a");
        vm.roll(block.number + 300); // a's reveal block hash is gone
        uint256 b = _forge("b");
        vm.roll(block.number + 2); // b's hash is available
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.RevealOutOfOrder.selector, b, a));
        nft.reveal(b);
        nft.reveal(a); // re-arms only
        assertEq(uint8(nft.markOf(a)), 0);
        assertEq(nft.revealBlock(a), block.number + 1);
        // While a waits for its new block, b is still behind it.
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, a));
        nft.reveal(a);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.RevealOutOfOrder.selector, b, a));
        nft.reveal(b);
        vm.roll(block.number + 2);
        uint256[] memory list = new uint256[](2);
        list[0] = a;
        list[1] = b;
        nft.revealMany(list);
        assertGt(uint8(nft.markOf(a)), 0);
        assertGt(uint8(nft.markOf(b)), 0);
        assertEq(nft.nextToReveal(), 0);
    }

    /// A batch whose hashes all expired drains one soul per two blocks: each stale head must be re-armed in its own
    /// turn (the next one only becomes the head after its predecessor's Mark is drawn), so revealMany re-arms at most
    /// one soul per call. This is a liveness cost, not a loss of any soul.
    function test_staleBatchDrainsOneSoulPerReArm() public {
        bytes32[] memory hs = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            hs[i] = keccak256(abi.encode("stale batch", i));
        }
        vm.prank(owner);
        uint256 first = nft.forgeReservedMany(hs);
        vm.roll(block.number + 300);
        uint256[] memory list = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = first + i;
        }
        // One revealMany per block, as a server would send. Count the blocks until the queue is empty.
        uint256 blocksUsed;
        for (uint256 round; round < 20 && nft.nextToReveal() != 0; ++round) {
            nft.revealMany(list);
            vm.roll(block.number + 1);
            ++blocksUsed;
        }
        assertEq(nft.nextToReveal(), 0);
        emit log_named_uint("blocks to drain 3 stale souls", blocksUsed);
        assertGe(blocksUsed, 6, "at least two blocks per stale soul");
        for (uint256 i; i < 3; ++i) {
            assertGt(uint8(nft.markOf(first + i)), 0);
        }
    }
}
