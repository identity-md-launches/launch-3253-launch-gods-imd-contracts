// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleShrine} from "../src/OracleShrine.sol";
import {OracleFixture, OracleTestIntake} from "./helpers/OracleFixture.sol";

contract OracleSecurityTest is OracleFixture {
    bytes32 internal constant H = keccak256("reward question");

    function test_defaultPanelPolicy() public view {
        assertEq(shrine.minPanelSize(), 30);
        assertEq(shrine.minQuorum(), 20);
        assertEq(shrine.minAgreed(), 20);
    }

    /// Regression for dd2b89d5ff3a: a three-seat answer cannot settle this week's pin, by callback or relay.
    function test_threeSeatRelayCannotActivateOrRejectRewards() public {
        bytes32 rid = _askRewards(1, H, 100 ether);
        OracleShrine.Attestation memory a = _attestation(H);
        a.panelSize = 3;
        a.quorum = 3;
        a.agreed = 3;
        bytes memory sig = _sign(a);
        assertFalse(intake.deliver(rid, a, sig));
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardsAnswerNotRelayable.selector, H));
        shrine.record(a, sig);
        a.answer = abi.encode(false);
        sig = _sign(a);
        assertFalse(intake.deliver(rid, a, sig));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, address(this)));
        shrine.record(a, sig);
        assertFalse(_answered(H));
        assertEq(shrine.reserved(), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NoJudgment.selector, H));
        shrine.finalizeRewards(1);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NoJudgment.selector, H));
        shrine.rejectRewards(1);
    }

    function test_smallPanelCannotBypassWithEnoughAgreement() public {
        _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        a.panelSize = 20;
        bytes memory sig = _sign(a);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.PanelTooWeak.selector, uint16(20), uint16(20)));
        shrine.record(a, sig);
    }

    function test_agreementFloorIsIndependentOfQuorum() public {
        _ask(H);
        vm.prank(owner);
        shrine.setMinQuorum(3);
        OracleShrine.Attestation memory a = _attestation(H);
        a.quorum = 3;
        a.agreed = 3;
        bytes memory sig = _sign(a);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.PanelTooWeak.selector, uint16(30), uint16(3)));
        shrine.record(a, sig);
    }

    function test_weakCallbackLeavesRequestPendingThenStrongCallbackSucceeds() public {
        bytes32 rid = _askRewards(1, H, 100 ether);
        OracleShrine.Attestation memory a = _attestation(H);
        a.panelSize = 20;
        assertFalse(intake.deliver(rid, a, _sign(a)));
        assertTrue(shrine.pending(rid));
        assertFalse(_answered(H));
        a.panelSize = 30;
        bytes memory sig = _sign(a);
        vm.cool(address(shrine));
        assertTrue(intake.deliver(rid, a, sig));
        assertFalse(shrine.pending(rid));
        shrine.finalizeRewards(1);
        shrine.claim(1, claimant, 100 ether, new bytes32[](0));
        assertEq(imd.balanceOf(claimant), 100 ether);
        assertEq(shrine.reserved(), 0);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AlreadyClaimed.selector, uint64(1), claimant));
        shrine.claim(1, claimant, 100 ether, new bytes32[](0));
    }

    function test_ownerCanRaisePolicyAndAcceptLargerPanel() public {
        vm.startPrank(owner);
        shrine.setPanelMinimums(50, 40);
        shrine.setMinQuorum(35);
        vm.stopPrank();
        _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        a.panelSize = 50;
        a.quorum = 35;
        a.agreed = 40;
        bytes memory sig = _sign(a);
        vm.prank(director);
        shrine.record(a, sig);
        assertTrue(_answered(H));
    }

    function test_onlyOwnerSetsPolicyAndAction() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        shrine.setPanelMinimums(3, 3);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, director));
        shrine.setRewardsAction(bytes32("oracle.request@oracle-2"));
    }

    function test_invalidPanelPoliciesAndZeroActionRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(OracleShrine.InvalidPanelMinimums.selector);
        shrine.setPanelMinimums(1, 1);
        vm.expectRevert(OracleShrine.InvalidPanelMinimums.selector);
        shrine.setPanelMinimums(30, 0);
        vm.expectRevert(OracleShrine.InvalidPanelMinimums.selector);
        shrine.setPanelMinimums(30, 31);
        vm.expectRevert(OracleShrine.ZeroAction.selector);
        shrine.setRewardsAction(bytes32(0));
        vm.stopPrank();
    }

    function testFuzz_panelFloorsApplyToEveryRelay(uint16 panel, uint16 quorum, uint16 agreed) public {
        panel = uint16(bound(panel, 1, 100));
        quorum = uint16(bound(quorum, 1, 100));
        agreed = uint16(bound(agreed, 0, 100));
        _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        bytes memory sig = _sign(a);
        bool acceptable = panel >= 30 && quorum >= 20 && agreed >= quorum && agreed >= 20 && agreed <= panel;
        vm.prank(director);
        (bool ok,) = address(shrine).call(abi.encodeCall(shrine.record, (a, sig)));
        assertEq(ok, acceptable);
        assertEq(_answered(H), acceptable);
    }

    /// Regression for 32ff888ca852: old and new requests survive an action migration.
    function test_ownerMigratesRewardsActionAfterRetirement() public {
        assertEq(shrine.REWARDS_ACTION(), bytes32("oracle.request@oracle-1"));
        assertEq(shrine.rewardsAction(), shrine.REWARDS_ACTION());
        bytes32 first = _askRewards(1, H, 100 ether);
        bytes32 nextAction = "oracle.request@oracle-2";
        intake.sell(nextAction);
        bytes32 nextHash = keccak256("week two");
        vm.expectRevert(abi.encodeWithSelector(OracleTestIntake.ActionNotSold.selector, shrine.REWARDS_ACTION()));
        _askRewards(2, nextHash, 100 ether);
        assertEq(shrine.reserved(), 100 ether);
        (uint8 kind, uint64 pinnedAt,) = shrine.pins(nextHash);
        assertEq(kind, 0);
        assertEq(pinnedAt, 0);
        vm.prank(owner);
        shrine.setRewardsAction(nextAction);
        bytes32 second = _askRewards(2, nextHash, 100 ether);
        assertEq(intake.lastAction(), nextAction);
        assertEq(intake.lastAmount(), 0.5 ether);
        assertEq(imd.allowance(address(shrine), address(intake)), 0);
        OracleShrine.Attestation memory a = _attestation(H);
        assertTrue(intake.deliver(first, a, _sign(a)));
        a = _attestation(nextHash);
        assertTrue(intake.deliver(second, a, _sign(a)));
        shrine.finalizeRewards(1);
        shrine.finalizeRewards(2);
        shrine.claim(2, claimant, 100 ether, new bytes32[](0));
        assertEq(shrine.reserved(), 100 ether);
        assertEq(imd.balanceOf(claimant), 100 ether);
    }

    function test_falseAnswerIsStoredUnderStipendAndReleasesRewards() public {
        bytes32 rid = _askRewards(1, H, 100 ether);
        OracleShrine.Attestation memory a = _attestation(H);
        a.answer = abi.encode(false);
        bytes memory sig = _sign(a);
        vm.cool(address(shrine));
        assertTrue(intake.deliver(rid, a, sig));
        shrine.rejectRewards(1);
        assertEq(shrine.reserved(), 0);
        assertEq(uint8(shrine.rewardWeek(1).status), uint8(OracleShrine.RewardStatus.Rejected));
    }

    function test_callbackRejectsWrongSenderUnknownAndSettledRequests() public {
        bytes32 rid = _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        bytes memory sig = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotIntake.selector, address(this)));
        shrine.onOracleResult(rid, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPending.selector, bytes32(0)));
        shrine.onOracleResult(bytes32(0), a, sig);
        assertTrue(intake.deliver(rid, a, sig));
        assertFalse(intake.deliver(rid, a, sig));
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AlreadyAnswered.selector, H));
        shrine.record(a, sig);
    }

    function test_unpinnedExpiredAndTamperedAnswersCannotSettle() public {
        OracleShrine.Attestation memory a = _attestation(H);
        bytes memory sig = _sign(a);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPinned.selector, H));
        shrine.record(a, sig);
        _ask(H);
        a.answer = abi.encode(false);
        vm.prank(director);
        vm.expectRevert(OracleShrine.InvalidSignature.selector);
        shrine.record(a, sig);
        a.expiresAt = uint64(block.timestamp - 1);
        sig = _sign(a);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AttestationExpired.selector, a.expiresAt));
        shrine.record(a, sig);
        assertFalse(_answered(H));
    }

    function test_failureMovesNoFundsAndUnansweredRewardsCanBeCancelled() public {
        bytes32 rid = _askRewards(1, H, 100 ether);
        uint256 balance = imd.balanceOf(address(shrine));
        assertTrue(intake.fail(rid));
        assertEq(imd.balanceOf(address(shrine)), balance);
        assertEq(shrine.reserved(), 100 ether);
        assertFalse(shrine.pending(rid));
        uint256 deadline = block.timestamp + shrine.REWARD_JUDGMENT_TIMEOUT();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.TooEarly.selector, deadline));
        shrine.cancelRewards(1);
        vm.warp(deadline);
        vm.prank(owner);
        shrine.cancelRewards(1);
        assertEq(shrine.reserved(), 0);
    }

    function test_ownerWithdrawsOnlyFreeBalance() public {
        _askRewards(1, H, 100 ether);
        uint256 free = shrine.availableBalance();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.InsufficientFreeBalance.selector, free + 1, free));
        shrine.withdraw(address(imd), owner, free + 1);
        shrine.withdraw(address(imd), owner, free);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(shrine)), 100 ether);
        assertEq(shrine.reserved(), 100 ether);
    }
}

contract OracleCallbackGasTest is OracleFixture {
    /// e128f904206e: measure a cold delivery; large list answers use the director's relay.
    function testFuzz_listDeliveryAndRecordRecovery(uint8 length, bool addressList) public {
        length = uint8(bound(length, 1, 8));
        bytes32 hash = keccak256(abi.encode(length, addressList));
        bytes32 rid = _ask(hash);
        OracleShrine.Attestation memory a = _attestation(hash);
        a.answerType = addressList ? 4 : 5;
        bytes32[] memory values = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            values[i] = bytes32(i + 1);
        }
        a.answer = abi.encode(values); // these words are also valid addresses
        bytes memory sig = _sign(a);
        vm.cool(address(shrine));
        bool delivered = intake.deliver(rid, a, sig);
        if (length <= 2) assertTrue(delivered, "short list fits stipend");
        else assertFalse(delivered, "long list needs relay");
        if (!delivered) {
            assertTrue(shrine.pending(rid));
            assertFalse(_answered(hash));
            vm.prank(director);
            shrine.record(a, sig);
        }
        assertTrue(_answered(hash));
        assertEq(shrine.judgmentOf(hash).answer, a.answer);
    }
}
