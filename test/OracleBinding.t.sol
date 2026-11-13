// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OracleShrine} from "../src/OracleShrine.sol";
import {OracleFixture} from "./helpers/OracleFixture.sol";

/// 01bb6567d337 and f8c5c365f259: an answer settles a pin only through the request that pinned it; relays are the
/// director's, never for a rewards question. 8ec68b94c65a: future-dated attestations are refused.
contract OracleBindingTest is OracleFixture {
    bytes32 internal constant Q = keccak256("week 1 reward list question");
    address internal outsider = address(0xBAD);

    function test_outsiderCannotRelayAnyAnswer() public {
        _ask(Q);
        OracleShrine.Attestation memory a = _attestation(Q);
        bytes memory sig = _sign(a);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, outsider));
        shrine.record(a, sig);
        assertFalse(_answered(Q));
    }

    function test_foreignAnswerCannotPreemptRewardsThenOwnAnswerActivates() public {
        bytes32 rid = _askRewards(1, Q, 100 ether);
        assertEq(shrine.requestOfQuestion(Q), rid);
        OracleShrine.Attestation memory foreign = _attestation(Q);
        foreign.requestId = bytes32("outsider-uuid");
        foreign.answer = abi.encode(false);
        bytes memory sig = _sign(foreign);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, outsider));
        shrine.record(foreign, sig);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardsAnswerNotRelayable.selector, Q));
        shrine.record(foreign, sig);
        assertFalse(_answered(Q));

        OracleShrine.Attestation memory own = _attestation(Q);
        assertTrue(intake.deliver(rid, own, _sign(own)));
        shrine.finalizeRewards(1);
        shrine.claim(1, claimant, 100 ether, new bytes32[](0));
        assertEq(imd.balanceOf(claimant), 100 ether);
    }

    /// The director pins a hash the shrine's own request does not answer: the answer that comes back for the paid
    /// body carries the body's question hash, which the request did not pin, so nothing activates.
    function test_answerToAnotherQuestionIsRefusedByTheCallback() public {
        bytes32 rid = _askRewards(1, Q, 100 ether);
        bytes32 other = keccak256("Is 1 + 1 = 2?");
        _ask(other); // pinned, but by another request
        OracleShrine.Attestation memory a = _attestation(other);
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AnswerNotForRequest.selector, rid, other));
        shrine.onOracleResult(rid, a, sig);
        assertFalse(intake.deliver(rid, a, sig));
        assertFalse(_answered(other));
        assertFalse(_answered(Q));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NoJudgment.selector, Q));
        shrine.finalizeRewards(1);
    }

    function test_unpinnedRequestCannotSettleARepinnedQuestion() public {
        bytes32 first = _ask(Q);
        bytes32[] memory hs = new bytes32[](1);
        hs[0] = Q;
        vm.prank(director);
        shrine.unpin(hs);
        assertEq(shrine.requestOfQuestion(Q), bytes32(0));
        bytes32 second = _ask(Q);
        OracleShrine.Attestation memory a = _attestation(Q);
        bytes memory sig = _sign(a);
        assertFalse(intake.deliver(first, a, sig));
        assertFalse(_answered(Q));
        assertTrue(intake.deliver(second, a, sig));
        assertTrue(_answered(Q));
    }

    function test_directorRelaysGroupAnswers() public {
        bytes32[] memory hs = new bytes32[](2);
        hs[0] = keccak256("g0");
        hs[1] = keccak256("g1");
        intake.sell(bytes32("oracle.group@oracle-1"));
        vm.prank(director);
        bytes32 rid = shrine.ask(bytes32("oracle.group@oracle-1"), "{}", hs, 1);
        assertEq(shrine.requestOfQuestion(hs[0]), rid);
        assertEq(shrine.requestOfQuestion(hs[1]), rid);
        for (uint256 i; i < 2; ++i) {
            OracleShrine.Attestation memory a = _attestation(hs[i]);
            bytes memory sig = _sign(a);
            vm.prank(director);
            shrine.record(a, sig);
            assertTrue(_answered(hs[i]));
        }
    }

    function test_futureDatedAttestationRefused() public {
        bytes32 rid = _ask(Q);
        OracleShrine.Attestation memory a = _attestation(Q);
        a.issuedAt = uint64(block.timestamp + shrine.ISSUED_AT_TOLERANCE() + 1);
        bytes memory sig = _sign(a);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AttestationNotYetValid.selector, a.issuedAt));
        shrine.record(a, sig);
        assertFalse(intake.deliver(rid, a, sig));
        a.issuedAt = uint64(block.timestamp + shrine.ISSUED_AT_TOLERANCE());
        sig = _sign(a);
        assertTrue(intake.deliver(rid, a, sig));
        assertTrue(_answered(Q));
    }
}
