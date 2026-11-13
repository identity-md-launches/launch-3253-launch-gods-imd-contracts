// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OracleShrine} from "../src/OracleShrine.sol";
import {OracleFixture} from "./helpers/OracleFixture.sol";

/// Protocol vector from the supplied OracleConsumerConformance.t.sol, with the deployment adapted to this shrine.
contract OracleConformanceTest is OracleFixture {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    bytes32 private rid;

    function setUp() public override {
        super.setUp();
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        deployCodeTo(
            "OracleShrine.sol:OracleShrine",
            abi.encode(owner, address(intake), address(imd), SIGNER, director),
            VECTOR_CONSUMER
        );
        shrine = OracleShrine(VECTOR_CONSUMER);
        // Only this test accepts the vector's smaller panel. Production defaults stay 30/20/20.
        vm.startPrank(owner);
        shrine.setPanelMinimums(5, 5);
        shrine.setMinQuorum(4);
        vm.stopPrank();
        imd.mint(address(shrine), 1 ether);
        rid = _ask(vector().questionHash);
    }

    function vector() internal pure returns (OracleShrine.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleShrine.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(shrine.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(shrine.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function test_acceptsTheProtocolSignatureUnderStipend() public {
        OracleShrine.Attestation memory a = vector();
        vm.cool(address(shrine));
        assertTrue(intake.deliver(rid, a, VECTOR_SIGNATURE), "protocol callback fits 200,000 gas");
        assertTrue(_answered(a.questionHash));
        assertEq(shrine.judgmentOf(a.questionHash).oracleRequestId, a.requestId);
        assertEq(shrine.judgmentOf(a.questionHash).answer, a.answer);
    }

    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        OracleShrine.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        assertTrue(intake.deliver(rid, a, _sign(a)));
        assertTrue(_answered(a.questionHash));
    }
}
