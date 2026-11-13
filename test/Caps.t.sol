// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";

contract CapsIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Wallet caps: 20 souls per wallet for everyone, 25 for Seers (IMD agent-seat holders, through their allowlist leaf).
contract CapsTest is Test {
    CapsIMD imd;
    GodsOfIMDInhabitants nft;
    address owner = address(0xA11CE);
    address player = address(0xBEEF);
    address seer = address(0x5EE5);
    address fan = address(0xFA11);
    uint256 n;

    function setUp() public {
        imd = new CapsIMD();
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), address(0x5A1), address(0xB0));
        for (uint256 i; i < 3; ++i) {
            address a = [player, seer, fan][i];
            imd.mint(a, 1_000 ether);
            vm.prank(a);
            imd.approve(address(nft), type(uint256).max);
        }
    }

    function _leaf(address a, uint256 maxMints) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, maxMints))));
    }

    /// root over two leaves (OpenZeppelin sorted-pair hashing), and the one-step proof for each
    function _root(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _list() internal {
        vm.prank(owner);
        nft.setAllowlistRoot(_root(_leaf(seer, 25), _leaf(fan, 1)));
    }

    function _proof(bytes32 other) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = other;
    }

    function _forge(address a) internal returns (uint256) {
        vm.prank(a);
        return nft.forge(keccak256(abi.encode("soul", ++n)), address(0));
    }

    function _forgeSeer(address a, uint256 maxMints, bytes32 sibling) internal returns (uint256) {
        vm.prank(a);
        return nft.forgeAllowlist(keccak256(abi.encode("soul", ++n)), address(0), maxMints, _proof(sibling));
    }

    function _phase(GodsOfIMDInhabitants.Phase p) internal {
        vm.prank(owner);
        nft.setPhase(p);
    }

    function test_twentyPerWalletIsBuiltIn() public view {
        assertEq(nft.maxPerWallet(), 20);
    }

    function test_publicStopsAtTwenty() public {
        _phase(GodsOfIMDInhabitants.Phase.Public);
        for (uint256 i; i < 20; ++i) {
            _forge(player);
        }
        assertEq(nft.mintedBy(player), 20);
        assertEq(nft.balanceOf(player), 20);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.WalletLimitReached.selector, player, 20));
        _forge(player);
    }

    function test_seerForgesTwentyFiveAtFour() public {
        _list();
        _phase(GodsOfIMDInhabitants.Phase.Allowlist);
        uint256 before = imd.balanceOf(seer);
        for (uint256 i; i < 25; ++i) {
            _forgeSeer(seer, 25, _leaf(fan, 1));
        }
        assertEq(nft.balanceOf(seer), 25);
        assertEq(before - imd.balanceOf(seer), 25 * 4 ether);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.AllowlistCapReached.selector, seer, 25));
        _forgeSeer(seer, 25, _leaf(fan, 1));
        // and the public door is shut for a wallet already past 20
        _phase(GodsOfIMDInhabitants.Phase.Public);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.WalletLimitReached.selector, seer, 20));
        _forge(seer);
    }

    function test_seerCapCountsEveryForge() public {
        _list();
        _phase(GodsOfIMDInhabitants.Phase.Public);
        for (uint256 i; i < 20; ++i) {
            _forge(seer);
        }
        for (uint256 i; i < 5; ++i) {
            _forgeSeer(seer, 25, _leaf(fan, 1));
        }
        assertEq(nft.mintedBy(seer), 25);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.WalletLimitReached.selector, seer, 25));
        _forgeSeer(seer, 25, _leaf(fan, 1));
    }

    function test_listSpotIsOneEarlySoulThenTwentyInAll() public {
        _list();
        _phase(GodsOfIMDInhabitants.Phase.Allowlist);
        _forgeSeer(fan, 1, _leaf(seer, 25));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.AllowlistCapReached.selector, fan, 1));
        _forgeSeer(fan, 1, _leaf(seer, 25));
        _phase(GodsOfIMDInhabitants.Phase.Public);
        for (uint256 i; i < 19; ++i) {
            _forge(fan);
        }
        assertEq(nft.balanceOf(fan), 20);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.WalletLimitReached.selector, fan, 20));
        _forge(fan);
    }

    function test_cannotClaimSeerSlotsWithoutTheLeaf() public {
        _list();
        _phase(GodsOfIMDInhabitants.Phase.Allowlist);
        vm.expectRevert(GodsOfIMDInhabitants.InvalidProof.selector);
        _forgeSeer(player, 25, _leaf(fan, 1));
    }
}
