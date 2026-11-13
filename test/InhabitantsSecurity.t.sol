// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {TestIMD} from "./Marks.t.sol";

contract InhabitantsSecurityTest is Test {
    TestIMD private imd;
    TestIMD private alternate;
    GodsOfIMDInhabitants private nft;
    address private owner = address(0xA11CE);
    address private player = address(0xBEEF);
    address private copier = address(0xBAD);

    event RevealRearmed(uint256 indexed tokenId, uint256 revealBlock);

    function setUp() public {
        vm.roll(1000);
        imd = new TestIMD();
        alternate = new TestIMD();
        nft = new GodsOfIMDInhabitants(owner, imd, address(0x5A1), address(0xB0));
        bytes32 root = nft.allowlistLeaf(player, 20);
        vm.startPrank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        nft.setForgeToken(address(alternate), 10 ether, 900, 3000, owner);
        nft.setAllowlistRoot(root);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? player : copier;
            imd.mint(who, 100 ether);
            alternate.mint(who, 100 ether);
            vm.startPrank(who);
            imd.approve(address(nft), type(uint256).max);
            alternate.approve(address(nft), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _forge(bytes32 soul) private returns (uint256 id) {
        vm.prank(player);
        return nft.forge(soul, address(0));
    }

    function _key(address minter, bytes32 soul) private pure returns (bytes32) {
        return keccak256(abi.encode(minter, soul));
    }

    /// 0a96368412f2: no known previous-block fallback; the re-arm must persist (a revert would undo it).
    function test_staleRevealRearmsAndLaterRevealsExactlyOnce() public {
        uint256 id = _forge(keccak256("stale soul"));
        uint256 original = nft.revealBlock(id);
        vm.roll(original + 257);
        uint256 next = block.number + 1;
        vm.expectEmit(true, false, false, true, address(nft));
        emit RevealRearmed(id, next);
        nft.reveal(id);
        assertEq(nft.revealBlock(id), next);
        assertEq(uint8(nft.markOf(id)), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(nft.markRevealed(i), 0);
        }
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, id));
        nft.reveal(id);
        vm.roll(next);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, id));
        nft.reveal(id);
        vm.roll(next + 1);
        nft.reveal(id);
        assertGt(uint8(nft.markOf(id)), 0);
        assertEq(nft.revealBlock(id), 0);
        uint256 drawn;
        for (uint256 i; i < 4; ++i) {
            drawn += nft.markRevealed(i);
        }
        assertEq(drawn, 1);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, id));
        nft.reveal(id);
    }

    function test_hashAt256BlocksStillReveals() public {
        uint256 id = _forge(keccak256("last valid block"));
        uint256 target = nft.revealBlock(id);
        vm.roll(target + 256);
        vm.setBlockhash(target, keccak256("retained hash"));
        nft.reveal(id);
        assertGt(uint8(nft.markOf(id)), 0);
        assertEq(nft.revealBlock(id), 0);
    }

    function test_revealManyProcessesFreshAndStaleSoulsAndSkipsDuplicates() public {
        uint256 stale = _forge(keccak256("old"));
        vm.roll(nft.revealBlock(stale) + 257);
        uint256 fresh = _forge(keccak256("fresh"));
        vm.roll(block.number + 2);
        uint256 waiting = _forge(keccak256("waiting"));
        uint256[] memory ids = new uint256[](5);
        ids[0] = stale;
        ids[1] = fresh;
        ids[2] = waiting;
        ids[3] = stale;
        ids[4] = 999;
        nft.revealMany(ids);
        assertEq(nft.revealBlock(stale), block.number + 1);
        assertEq(uint8(nft.markOf(stale)), 0);
        assertGt(uint8(nft.markOf(fresh)), 0);
        assertEq(uint8(nft.markOf(waiting)), 0);
    }

    function testFuzz_staleRevealNeverDrawsFromKnownFallback(uint256 delay, bytes32 previousHash) public {
        delay = bound(delay, 257, 1_000_000);
        uint256 id = _forge(keccak256("stale fuzz"));
        vm.roll(nft.revealBlock(id) + delay);
        vm.setBlockhash(block.number - 1, previousHash);
        nft.reveal(id);
        assertEq(uint8(nft.markOf(id)), 0);
        assertEq(nft.revealBlock(id), block.number + 1);
    }

    /// 77392183468b: another wallet may copy content but cannot consume the designer's mint identity.
    function testFuzz_copyCannotBlockAnyForgePath(bytes32 soul, uint8 path) public {
        vm.assume(soul != bytes32(0));
        path = uint8(bound(path, 0, 4));
        vm.prank(copier);
        uint256 copiedId = nft.forge(soul, address(0));
        address designer = path >= 3 ? owner : player;
        uint256 id;
        vm.prank(designer);
        if (path == 0) {
            id = nft.forge(soul, address(0));
        } else if (path == 1) {
            id = nft.forgeAllowlist(soul, address(0), 20, new bytes32[](0));
        } else if (path == 2) {
            id = nft.forgeWithToken(address(alternate), soul, address(0));
        } else if (path == 3) {
            id = nft.forgeReserved(soul);
        } else {
            bytes32[] memory souls = new bytes32[](1);
            souls[0] = soul;
            id = nft.forgeReservedMany(souls);
        }
        assertNotEq(id, copiedId);
        assertEq(nft.ownerOf(id), designer);
        assertEq(nft.ownerOf(copiedId), copier);
        assertEq(nft.soulHashOf(id), soul, "character hash is unchanged");
        assertEq(nft.soulHashOf(copiedId), soul);
        assertEq(nft.tokenOfSoul(_key(designer, soul)), id);
        assertEq(nft.tokenOfSoul(_key(copier, soul)), copiedId);
        assertEq(nft.totalForged(), 2);
    }

    function test_duplicateCannotSwitchPaymentPathsOrBeResetByTransfer() public {
        bytes32 soul = keccak256("same designer");
        uint256 id = _forge(soul);
        vm.prank(player);
        nft.transferFrom(player, copier, id);
        vm.startPrank(player);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.SoulAlreadyForged.selector, soul, id));
        nft.forge(soul, address(0));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.SoulAlreadyForged.selector, soul, id));
        nft.forgeAllowlist(soul, address(0), 20, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.SoulAlreadyForged.selector, soul, id));
        nft.forgeWithToken(address(alternate), soul, address(0));
        vm.stopPrank();
        assertEq(nft.tokenOfSoul(_key(player, soul)), id);
        assertEq(nft.mintedBy(player), 1);
        assertEq(nft.allowlistMinted(player), 0);
        (,, uint256 forged,,) = nft.forgeTokens(address(alternate));
        assertEq(forged, 0);
        assertEq(alternate.balanceOf(player), 100 ether);
    }

    function test_zeroSoulStillRejectedBeforeNamespacing() public {
        vm.prank(player);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroSoulHash.selector);
        nft.forge(bytes32(0), address(0));
        assertEq(nft.totalForged(), 0);
    }
}
