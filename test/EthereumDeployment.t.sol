// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleShrine} from "../src/OracleShrine.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

/// Test-only equivalent of the protected floor: both CREATE2 deployments in one call, zero value, no setup calls.
contract EthereumDeploymentProbe {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            require(code.length <= 49_152, "init code limit");
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length != 0, "deployment failed");
            deployed[i] = created;
        }
    }
}

contract EthereumDeploymentTest is Test {
    address constant OWNER = address(bytes20(hex"6c4c78f2c3bdf4c4318fe305fb1c8bc1694d19b5"));
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant DIRECTOR = 0xF0CED7f39217FFd0A26686CF660AFA39DfCc699A;
    address constant BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    OracleShrine private shrine;
    GodsOfIMDInhabitants private nft;
    EthereumDeploymentProbe private factory;

    function setUp() public {
        vm.chainId(1);
        // These are intentionally empty accounts: constructors cannot depend on live chain state.
        assertEq(INTAKE.code.length, 0);
        assertEq(IMD.code.length, 0);
        assertEq(SIGNER.code.length, 0);
        assertEq(DIRECTOR.code.length, 0);
        assertEq(BURN.code.length, 0);
        factory = new EthereumDeploymentProbe();
        bytes[] memory codes = new bytes[](2);
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = keccak256("OracleShrine launch rehearsal");
        salts[1] = keccak256("GodsOfIMDInhabitants launch rehearsal");
        codes[0] = bytes.concat(type(OracleShrine).creationCode, abi.encode(OWNER, INTAKE, IMD, SIGNER, DIRECTOR));
        address predictedShrine = _predict(salts[0], codes[0]);
        codes[1] = bytes.concat(type(GodsOfIMDInhabitants).creationCode, abi.encode(OWNER, IMD, predictedShrine, BURN));
        address predictedNFT = _predict(salts[1], codes[1]);
        vm.startStateDiffRecording();
        address[] memory deployed = factory.deployAll(codes, salts);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(deployed[0], predictedShrine);
        assertEq(deployed[1], predictedNFT);
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.accessor == predictedShrine || a.accessor == predictedNFT) {
                assertTrue(
                    a.kind != VmSafe.AccountAccessKind.Call && a.kind != VmSafe.AccountAccessKind.StaticCall
                        && a.kind != VmSafe.AccountAccessKind.DelegateCall
                        && a.kind != VmSafe.AccountAccessKind.CallCode && a.kind != VmSafe.AccountAccessKind.Create,
                    "constructor called or created another contract"
                );
            }
        }
        shrine = OracleShrine(deployed[0]);
        nft = GodsOfIMDInhabitants(deployed[1]);
    }

    function _predict(bytes32 salt, bytes memory code) private view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
            );
    }

    function test_exactEthereumArgumentsAndOwnerRoles() public view {
        assertEq(shrine.owner(), OWNER);
        assertEq(address(shrine.intake()), INTAKE);
        assertEq(address(shrine.imd()), IMD);
        assertEq(shrine.oracleSigner(), SIGNER);
        assertEq(shrine.director(), DIRECTOR);
        assertEq(nft.owner(), OWNER);
        assertEq(nft.steward(), OWNER);
        assertEq(nft.royaltyReceiver(), OWNER);
        assertEq(nft.payees()[0].account, OWNER);
        (,,,, address shiftPayee) = nft.forgeTokens(nft.SHIFT());
        assertEq(shiftPayee, OWNER);
        assertEq(address(nft.imd()), IMD);
        assertEq(nft.shrine(), address(shrine));
        assertEq(nft.burnSink(), BURN);
        assertEq(address(shrine).balance, 0);
        assertEq(address(nft).balance, 0);
        assertEq(nft.totalForged(), 0);
        assertEq(nft.GENESIS_SUPPLY(), 1000);
        assertEq(nft.maxSupply(), 1000);
        assertEq(nft.markCap(0), 640);
        assertEq(nft.markCap(1), 250);
        assertEq(nft.markCap(2), 100);
        assertEq(nft.markCap(3), 10);
        assertEq(uint8(nft.phase()), uint8(GodsOfIMDInhabitants.Phase.Closed));
        assertEq(nft.baseURI(), "");
    }

    function test_factoryHasNoOwnerPowers() public {
        vm.startPrank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        shrine.setDirector(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        vm.stopPrank();
    }

    function test_everyConstructorAddressRejectsZero() public {
        address[5] memory args = [OWNER, INTAKE, IMD, SIGNER, DIRECTOR];
        for (uint256 i; i < args.length; ++i) {
            address original = args[i];
            args[i] = address(0);
            vm.expectRevert();
            new OracleShrine(args[0], IIntake(args[1]), IERC20(args[2]), args[3], args[4]);
            args[i] = original;
        }
        address[4] memory nftArgs = [OWNER, IMD, address(shrine), BURN];
        for (uint256 i; i < nftArgs.length; ++i) {
            address original = nftArgs[i];
            nftArgs[i] = address(0);
            vm.expectRevert();
            new GodsOfIMDInhabitants(nftArgs[0], IERC20(nftArgs[1]), nftArgs[2], nftArgs[3]);
            nftArgs[i] = original;
        }
    }

    function test_runtimesMeetProtectedSizeAndOpcodeRules() public view {
        _checkRuntime(address(shrine));
        _checkRuntime(address(nft));
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170 runtime limit");
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
