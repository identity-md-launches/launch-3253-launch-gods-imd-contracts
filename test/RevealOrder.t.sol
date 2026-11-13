// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {TestIMD} from "./Marks.t.sol";

/// 2090b1ef868d: reveals consume souls in forge order, so no revealer can choose which pending soul draws next.
contract RevealForgeOrderTest is Test {
    TestIMD private imd;
    TestIMD private alternate;
    GodsOfIMDInhabitants private nft;
    address private owner = address(0xA11CE);
    address private player = address(0xBEEF);
    address private friend = address(0xF00D);

    function setUp() public {
        vm.roll(1000);
        imd = new TestIMD();
        alternate = new TestIMD();
        nft = new GodsOfIMDInhabitants(owner, imd, address(0x5A1), address(0xB0));
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        imd.mint(player, 1_000 ether);
        vm.prank(player);
        imd.approve(address(nft), type(uint256).max);
    }

    function _reserved(uint256 n, string memory tag) private returns (uint256 first) {
        bytes32[] memory hs = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            hs[i] = keccak256(abi.encode(tag, i));
        }
        vm.prank(owner);
        first = nft.forgeReservedMany(hs);
    }

    /// The contract's draw, recomputed from public state.
    function _predict(uint256 id) private view returns (uint8) {
        bytes32 h = blockhash(nft.revealBlock(id));
        uint256 rand = uint256(keccak256(abi.encode(h, nft.soulHashOf(id), id)));
        uint256[4] memory w;
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            w[i] = nft.markCap(i) - nft.markRevealed(i);
            total += w[i];
        }
        uint256 r = rand % total;
        for (uint256 i = 4; i > 0;) {
            --i;
            if (r < w[i]) return uint8(i + 1);
            r -= w[i];
        }
        return 1;
    }

    function test_nextToRevealFollowsForgeOrderAcrossIdRanges() public {
        assertEq(nft.nextToReveal(), 0);
        uint256 reservedId = _reserved(1, "r"); // id 901, forged first
        vm.prank(player);
        uint256 paidId = nft.forge(keccak256("paid"), address(0)); // id 1, forged second
        assertEq(reservedId, 901);
        assertEq(paidId, 1);
        assertEq(nft.nextToReveal(), 901);
        vm.roll(block.number + 2);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.RevealOutOfOrder.selector, uint256(1), 901));
        nft.reveal(1);
        nft.reveal(901);
        assertEq(nft.nextToReveal(), 1);
        nft.reveal(1);
        assertEq(nft.nextToReveal(), 0);
        assertGt(uint8(nft.markOf(1)), 0);
        assertGt(uint8(nft.markOf(901)), 0);
    }

    function test_notYetRevealableStillRevertsNotRevealable() public {
        _reserved(1, "r");
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, uint256(901)));
        nft.reveal(901);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, uint256(5)));
        nft.reveal(5);
    }

    function test_revealManyInAnyListOrderGivesTheSameMarks() public {
        uint256 snap = vm.snapshotState();
        uint256 first = _reserved(20, "same");
        vm.roll(block.number + 2);
        vm.setBlockhash(block.number - 1, keccak256("hash"));
        uint256[] memory forward = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            forward[i] = first + i;
        }
        nft.revealMany(forward);
        uint8[20] memory marks;
        for (uint256 i; i < 20; ++i) {
            marks[i] = uint8(nft.markOf(first + i));
            assertGt(marks[i], 0);
        }
        vm.revertToState(snap);

        first = _reserved(20, "same");
        vm.roll(block.number + 2);
        vm.setBlockhash(block.number - 1, keccak256("hash"));
        uint256[] memory backward = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            backward[i] = first + 19 - i;
        }
        // Reversed lists reveal one soul per call (the head); keep calling until every soul is done.
        for (uint256 k; k < 20; ++k) {
            nft.revealMany(backward);
        }
        for (uint256 i; i < 20; ++i) {
            assertEq(uint8(nft.markOf(first + i)), marks[i], "a soul's Mark depended on the caller's order");
        }
    }

    /// The reviewer's greedy attack: reveal whichever pending soul draws Divine now. Only the head can be revealed,
    /// so the greedy choice is ignored and the reserve draws like any 100 souls.
    function test_greedyRevealerCannotCollectDivines() public {
        uint256 first = _reserved(100, "reserved");
        vm.roll(block.number + 2);
        vm.setBlockhash(block.number - 1, keccak256("an ordinary block hash"));
        for (uint256 k; k < 100; ++k) {
            uint256 pick = type(uint256).max;
            for (uint256 i; i < 100; ++i) {
                uint256 id = first + i;
                if (nft.markOf(id) == GodsOfIMDInhabitants.Mark.Unrevealed && _predict(id) == 4) {
                    pick = id;
                    break;
                }
            }
            uint256 head = nft.nextToReveal();
            if (pick != type(uint256).max && pick != head) {
                vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.RevealOutOfOrder.selector, pick, head));
                nft.reveal(pick);
            }
            nft.reveal(head);
        }
        assertEq(nft.nextToReveal(), 0);
        assertLe(nft.markRevealed(3), 4);
    }

    /// Referral share plus a listed token's burn share must stay within the price (advisory 1e664af9).
    function test_referralSettersRespectListedForgeTokens() public {
        vm.startPrank(owner);
        nft.setForgeToken(address(alternate), 100 ether, 900, 9500, owner);
        GodsOfIMDInhabitants.Payee[] memory payees = new GodsOfIMDInhabitants.Payee[](1);
        payees[0] = GodsOfIMDInhabitants.Payee(owner, 7000);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.InvalidSplit.selector, uint256(9500), 1000));
        nft.setReferralBps(1000);
        nft.setReferralBps(500);
        nft.setSplit(2000, 1000, payees);
        vm.stopPrank();
        assertEq(nft.referralBps(), 500);
    }
}
