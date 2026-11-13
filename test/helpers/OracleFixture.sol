// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleShrine} from "../../src/OracleShrine.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

contract OracleTestIMD is ERC20 {
    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Test-only Intake: pulls the exact price, remembers the callback, and swallows failed delivery.
contract OracleTestIntake is IIntake {
    bytes32 public soldAction = "oracle.request@oracle-1";
    bytes32 public lastAction;
    bytes public lastBody;
    uint256 public lastAmount;
    uint256 private nonce;
    mapping(bytes32 => Callback) private callbacks;
    mapping(bytes32 => bytes4) private failures;

    error ActionNotSold(bytes32 action);

    function sell(bytes32 action) external {
        soldAction = action;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId) {
        if (action != soldAction) revert ActionNotSold(action);
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        lastAction = action;
        lastBody = body;
        lastAmount = amount;
        requestId = keccak256(abi.encode(address(this), ++nonce));
        callbacks[requestId] = callback;
        failures[requestId] = onFailure;
    }

    function deliver(bytes32 requestId, OracleShrine.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok)
    {
        Callback memory callback = callbacks[requestId];
        (ok,) = callback.target.call{gas: 200_000}(abi.encodeWithSelector(callback.selector, requestId, a, signature));
    }

    function fail(bytes32 requestId) external returns (bool ok) {
        (ok,) = callbacks[requestId].target.call{gas: 200_000}(
            abi.encodeWithSelector(
                failures[requestId], requestId, uint8(2), bytes32("disagreed"), uint16(0), uint16(0), bytes("")
            )
        );
    }
}

abstract contract OracleFixture is Test {
    // Test-only signing key, never a deployment input.
    uint256 internal constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address internal owner = address(0xA11CE);
    address internal director = address(0xD1);
    address internal claimant = address(0xC1A1);
    OracleTestIMD internal imd;
    OracleTestIntake internal intake;
    OracleShrine internal shrine;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        imd = new OracleTestIMD();
        intake = new OracleTestIntake();
        shrine = new OracleShrine(owner, intake, imd, vm.addr(SIGNER_KEY), director);
        imd.mint(address(shrine), 1_000 ether);
    }

    function _ask(bytes32 hash) internal returns (bytes32 rid) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;
        vm.prank(director);
        return shrine.ask(bytes32("oracle.request@oracle-1"), "{}", hashes, 1);
    }

    function _askRewards(uint64 week, bytes32 hash, uint256 amount) internal returns (bytes32 rid) {
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(claimant, amount))));
        vm.prank(director);
        return shrine.askRewards(week, root, amount, bytes('{"panelSize":30,"quorum":20}'), hash);
    }

    function _attestation(bytes32 hash) internal view returns (OracleShrine.Attestation memory a) {
        a = OracleShrine.Attestation({
            requestId: keccak256(abi.encode("oracle UUID", hash)),
            chainId: block.chainid,
            questionHash: hash,
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: keccak256("panel job"),
            panelSize: 30,
            quorum: 20,
            agreed: 20,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _sign(OracleShrine.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, shrine.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answered(bytes32 hash) internal view returns (bool answered) {
        (,, answered) = shrine.pins(hash);
    }
}
