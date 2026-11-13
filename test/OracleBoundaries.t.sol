// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleShrine} from "src/OracleShrine.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {OracleFixture, OracleTestIMD, OracleTestIntake} from "./helpers/OracleFixture.sol";

contract SelectiveContractSigner {
    bytes32 private immutable allowedDigest;
    bytes32 private immutable allowedSignatureHash;

    constructor(bytes32 digest, bytes memory signature) {
        allowedDigest = digest;
        allowedSignatureHash = keccak256(signature);
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return digest == allowedDigest && keccak256(signature) == allowedSignatureHash
            ? bytes4(0x1626ba7e)
            : bytes4(0xffffffff);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract OracleBoundariesTest is OracleFixture {
    bytes32 private constant H = keccak256("boundary question");

    function test_invalidQuestionBatchesAreAtomic() public {
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.BadQuestionCount.selector, uint256(0)));
        shrine.ask(bytes32("oracle.request@oracle-1"), "{}", new bytes32[](0), 1);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.BadQuestionCount.selector, uint256(9)));
        shrine.ask(bytes32("oracle.request@oracle-1"), "{}", new bytes32[](9), 1);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = H;
        hashes[1] = H;
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AlreadyPinned.selector, H));
        shrine.ask(bytes32("oracle.request@oracle-1"), "{}", hashes, 1);
        hashes[1] = bytes32(0);
        vm.prank(director);
        vm.expectRevert(OracleShrine.ZeroQuestionHash.selector);
        shrine.ask(bytes32("oracle.request@oracle-1"), "{}", hashes, 1);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.ReservedKind.selector, uint8(4)));
        shrine.ask(bytes32("oracle.request@oracle-1"), "{}", hashes, 4);
        (, uint64 pinnedAt,) = shrine.pins(H);
        assertEq(pinnedAt, 0);
        assertEq(imd.balanceOf(address(shrine)), 1_000 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(imd.allowance(address(shrine), address(intake)), 0);
    }

    function test_failedIntakePurchaseRollsBackPinsAndApproval() public {
        intake.sell(bytes32("retired action"));
        vm.expectRevert(
            abi.encodeWithSelector(OracleTestIntake.ActionNotSold.selector, bytes32("oracle.request@oracle-1"))
        );
        _ask(H);
        (, uint64 pinnedAt,) = shrine.pins(H);
        assertEq(pinnedAt, 0);
        assertEq(imd.balanceOf(address(shrine)), 1_000 ether);
        assertEq(imd.allowance(address(shrine), address(intake)), 0);
    }

    function test_groupCompletionDoesNotInventJudgmentsAndRelaysRemainAvailable() public {
        bytes32[] memory hashes = new bytes32[](8);
        for (uint256 i; i < 8; ++i) {
            hashes[i] = keccak256(abi.encode(i));
        }
        vm.prank(director);
        bytes32 rid = shrine.ask(bytes32("oracle.request@oracle-1"), hex"123456", hashes, 2);
        assertEq(intake.lastBody(), hex"123456");
        assertEq(intake.lastAmount(), 4 ether);
        assertEq(imd.balanceOf(address(shrine)), 996 ether);
        vm.prank(address(intake));
        shrine.onResult(rid, keccak256("results"), "ipfs://test-group");
        assertFalse(shrine.pending(rid));
        for (uint256 i; i < 8; ++i) {
            assertFalse(_answered(hashes[i]));
            OracleShrine.Attestation memory a = _attestation(hashes[i]);
            shrine.record(a, _sign(a));
            assertTrue(_answered(hashes[i]));
        }
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPending.selector, rid));
        shrine.onResult(rid, bytes32(0), "");
    }

    function test_resultAndFailureCallbacksRejectWrongSendersAndUnknownIds() public {
        bytes32 rid = _ask(H);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotIntake.selector, address(this)));
        shrine.onResult(rid, bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotIntake.selector, address(this)));
        shrine.onFailure(rid, 2, bytes32("disagreed"), 0, 0, "");
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPending.selector, bytes32(0)));
        shrine.onResult(bytes32(0), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotPending.selector, bytes32(0)));
        shrine.onFailure(bytes32(0), 2, bytes32("disagreed"), 0, 0, "");
        vm.stopPrank();
        assertTrue(shrine.pending(rid));
        assertFalse(_answered(H));
    }

    function testFuzz_everyAttestationFieldIsAuthenticated(uint8 field) public {
        field = uint8(bound(field, 0, 14));
        bytes32 rid = _ask(H);
        bytes32 other = keccak256("second pinned question");
        _ask(other);
        OracleShrine.Attestation memory a = _attestation(H);
        a.agreed = 25;
        bytes memory sig = _sign(a);
        if (field == 0) a.requestId = keccak256("different UUID");
        else if (field == 1) ++a.chainId;
        else if (field == 2) a.questionHash = other;
        else if (field == 3) a.answerType = 3;
        else if (field == 4) a.answer = abi.encode(false);
        else if (field == 5) ++a.figure;
        else if (field == 6) ++a.fromBlock;
        else if (field == 7) ++a.toBlock;
        else if (field == 8) a.blockHash = keccak256("different block");
        else if (field == 9) a.panelJobId = keccak256("different panel job");
        else if (field == 10) ++a.panelSize;
        else if (field == 11) ++a.quorum;
        else if (field == 12) ++a.agreed;
        else if (field == 13) ++a.issuedAt;
        else ++a.expiresAt;
        vm.prank(address(intake));
        vm.expectRevert(OracleShrine.InvalidSignature.selector);
        shrine.onOracleResult(rid, a, sig);
        assertTrue(shrine.pending(rid));
        assertFalse(_answered(H));
        assertFalse(_answered(other));
        a = _attestation(H);
        a.agreed = 25;
        assertTrue(intake.deliver(rid, a, sig), "untampered signature still works");
    }

    function test_signaturesCannotCrossConsumerOrDomainChain() public {
        _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        bytes memory sig = _sign(a);
        OracleShrine twin = new OracleShrine(owner, intake, imd, vm.addr(SIGNER_KEY), director);
        imd.mint(address(twin), 1 ether);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = H;
        vm.prank(director);
        twin.ask(bytes32("oracle.request@oracle-1"), "{}", hashes, 1);
        vm.expectRevert(OracleShrine.InvalidSignature.selector);
        twin.record(a, sig);
        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        vm.expectRevert(OracleShrine.InvalidSignature.selector);
        shrine.record(a, sig);
        vm.chainId(originalChain);
        shrine.record(a, sig);
        assertTrue(_answered(H));
    }

    function test_exactExpiryIsAcceptedButOneSecondLaterIsNot() public {
        _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        bytes memory sig = _sign(a);
        vm.warp(uint256(a.expiresAt) + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AttestationExpired.selector, a.expiresAt));
        shrine.record(a, sig);
        vm.warp(a.expiresAt);
        shrine.record(a, sig);
        assertTrue(_answered(H));
    }

    function test_contractSignerChecksDigestAndSignatureAndRotationRevokesOldKey() public {
        _ask(H);
        OracleShrine.Attestation memory a = _attestation(H);
        bytes memory oldSignature = _sign(a);
        bytes memory contractSignature = hex"aabbcc";
        SelectiveContractSigner signer = new SelectiveContractSigner(shrine.attestationDigest(a), contractSignature);
        vm.prank(owner);
        shrine.setSigner(address(signer));
        vm.expectRevert(OracleShrine.InvalidSignature.selector);
        shrine.record(a, oldSignature);
        vm.expectRevert(OracleShrine.InvalidSignature.selector);
        shrine.record(a, hex"aabbcd");
        shrine.record(a, contractSignature);
        assertTrue(_answered(H));
    }

    function test_ownerAndDirectorPrivilegesAreSeparate() public {
        bytes[] memory admin = new bytes[](13);
        admin[0] = abi.encodeCall(shrine.setIntake, (IIntake(address(0xBEEF))));
        admin[1] = abi.encodeCall(shrine.setSigner, (address(0xBEEF)));
        admin[2] = abi.encodeCall(shrine.setDirector, (address(0xBEEF)));
        admin[3] = abi.encodeCall(shrine.setPrice, (uint256(0)));
        admin[4] = abi.encodeCall(shrine.setMinQuorum, (uint16(1)));
        admin[5] = abi.encodeCall(shrine.setPanelMinimums, (uint16(2), uint16(1)));
        admin[6] = abi.encodeCall(shrine.setRewardsAction, (H));
        admin[7] = abi.encodeCall(shrine.setMaxRewardBps, (uint16(10_000)));
        admin[8] = abi.encodeCall(shrine.withdraw, (address(imd), director, uint256(1)));
        admin[9] = abi.encodeCall(shrine.cancelRewards, (uint64(0)));
        admin[10] = abi.encodeCall(shrine.expireRewards, (uint64(0)));
        admin[11] = abi.encodeCall(shrine.transferOwnership, (director));
        admin[12] = abi.encodeCall(shrine.renounceOwnership, ());
        for (uint256 i; i < admin.length; ++i) {
            vm.prank(director);
            (bool ok, bytes memory data) = address(shrine).call(admin[i]);
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, director));
        }
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = H;
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, owner));
        shrine.ask(bytes32("oracle.request@oracle-1"), "{}", hashes, 1);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, owner));
        shrine.askRewards(0, H, 1, "{}", H);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, owner));
        shrine.unpin(hashes);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, owner));
        shrine.anchor(0, H, H);
        vm.stopPrank();
        assertEq(shrine.owner(), owner);
        assertEq(shrine.director(), director);
    }

    function test_invalidOwnerSettingsAndDisabledRewards() public {
        vm.startPrank(owner);
        vm.expectRevert(OracleShrine.ZeroAddress.selector);
        shrine.setIntake(IIntake(address(0)));
        vm.expectRevert(OracleShrine.ZeroAddress.selector);
        shrine.setSigner(address(0));
        vm.expectRevert(OracleShrine.ZeroAddress.selector);
        shrine.setDirector(address(0));
        vm.expectRevert(OracleShrine.InvalidMinQuorum.selector);
        shrine.setMinQuorum(0);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.InvalidMaxRewardBps.selector, uint16(10_001)));
        shrine.setMaxRewardBps(10_001);
        vm.expectRevert(OracleShrine.ZeroAddress.selector);
        shrine.withdraw(address(imd), address(0), 1);
        shrine.setMaxRewardBps(0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.RewardTotalTooHigh.selector, 1, 0));
        _askRewards(1, H, 1);
    }

    function test_directorRotationAndAnchorsAreWriteOnce() public {
        vm.prank(director);
        shrine.anchor(0, H, keccak256("chronicle"));
        (bytes32 world, bytes32 chronicle, uint64 anchoredAt) = shrine.anchors(0);
        assertEq(world, H);
        assertEq(chronicle, keccak256("chronicle"));
        assertEq(anchoredAt, block.timestamp);
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.AnchorExists.selector, uint64(0)));
        shrine.anchor(0, bytes32(0), bytes32(0));
        vm.prank(owner);
        shrine.setDirector(SECOND_DIRECTOR());
        vm.prank(director);
        vm.expectRevert(abi.encodeWithSelector(OracleShrine.NotDirector.selector, director));
        shrine.anchor(1, H, H);
        vm.prank(SECOND_DIRECTOR());
        shrine.anchor(1, H, H);
    }

    function SECOND_DIRECTOR() private pure returns (address) {
        return address(0xD2);
    }
}
