// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleShrine} from "src/OracleShrine.sol";
import {IIntake} from "src/interfaces/IIntake.sol";

contract ProofIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Records what the shrine asks and pulls the price, like the real intake.
contract ProofIntake is IIntake {
    uint256 public nonce;

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requestId = keccak256(abi.encode("intake request", ++nonce));
    }
}

/// The shrine accepts, through the permissionless `record`, an attestation for a pinned reward question whose
/// panel is 3 seats with a quorum of 3, although the director paid for a panel of 30 with a quorum of 20. Anyone
/// may buy an oracle answer to the same question document (the hash does not cover panelSize/quorum) signed in
/// the shrine's domain, so the weakest panel the shrine tolerates decides a week worth 20% of the treasury.
contract WeakPanelRecordTest is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address signer = vm.addr(SIGNER_KEY);
    address owner = address(0xA11CE);
    address director = address(0xD1);
    address attacker = address(0xBAD);
    address claimant = address(0xC1A1);

    ProofIMD imd;
    ProofIntake intake;
    OracleShrine shrine;

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new ProofIMD();
        intake = new ProofIntake();
        shrine = new OracleShrine(owner, intake, imd, signer, director);
        imd.mint(address(shrine), 1_000 ether);
    }

    function _sign(OracleShrine.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, shrine.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _attestation(bytes32 questionHash, uint16 panelSize, uint16 quorum, uint16 agreed)
        internal
        view
        returns (OracleShrine.Attestation memory a)
    {
        a = OracleShrine.Attestation({
            requestId: keccak256("attacker's own oracle request"),
            chainId: block.chainid,
            questionHash: questionHash,
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: keccak256("panel job"),
            panelSize: panelSize,
            quorum: quorum,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function test_aThreeSeatPanelCannotApproveARewardWeekAskedOfThirty() public {
        // The director asks the panel of 30 (quorum 20) whether the week-1 list behind `root` follows the rules.
        bytes32 root = keccak256(abi.encode(claimant, uint256(100 ether)));
        root = keccak256(bytes.concat(root)); // single-leaf StandardMerkleTree
        bytes32 questionHash = keccak256("canonical question document for week 1");
        bytes memory body = bytes('{"v":1,"question":"...","panelSize":30,"quorum":20}');
        vm.prank(director);
        shrine.askRewards(1, root, 100 ether, body, questionHash);
        assertEq(shrine.reserved(), 100 ether);

        // Anyone buys the same question document from the intake with panelSize 3 / quorum 3 and the shrine named
        // as consumer; the oracle signs the answer in the shrine's domain. The relay is permissionless.
        OracleShrine.Attestation memory a = _attestation(questionHash, 3, 3, 3);
        bytes memory sig = _sign(a);

        vm.prank(attacker);
        vm.expectRevert(); // expected: a panel smaller than the one paid for is refused
        shrine.record(a, sig);

        // If the line above did not revert, the week is activated by the 3-seat verdict and claims pay out.
        (bytes32 orid,,,,,,) = shrine.judgments(questionHash);
        assertEq(orid, bytes32(0), "a 3-of-3 panel's verdict was recorded for a 30-seat question");
    }
}
