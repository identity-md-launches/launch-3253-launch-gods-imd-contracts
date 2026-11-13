// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";

contract TestIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// The Marks: a fixed deck of 1000 (640 Mortal, 250 Blessed, 100 Ascended, 10 Divine), drawn after the forge
/// from a block hash nobody knew at forge time, with better odds for the first souls.
contract MarksTest is Test {
    TestIMD imd;
    GodsOfIMDInhabitants nft;
    address owner = address(0xA11CE);
    address shrine = address(0x5A1);
    address burn = address(0xB0);
    address player = address(0xBEEF);
    uint16[4] caps = [uint16(640), 250, 100, 10];

    function setUp() public {
        imd = new TestIMD();
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), shrine, burn);
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        vm.prank(owner);
        nft.setMaxPerWallet(0); // these tests draw the whole deck from one wallet; the caps have their own tests
        imd.mint(player, 1_000_000 ether);
        vm.prank(player);
        imd.approve(address(nft), type(uint256).max);
    }

    function _forge(uint256 i) internal returns (uint256 id) {
        vm.prank(player);
        id = nft.forge(keccak256(abi.encode("soul", i)), address(0));
    }

    function test_genesisRulesAreBuiltIn() public view {
        assertEq(nft.maxSupply(), 1000);
        assertEq(nft.GENESIS_SUPPLY(), 1000);
        for (uint256 m; m < 4; ++m) {
            assertEq(nft.markCap(m), caps[m]);
        }
        assertEq(nft.mintPrice(), 5 ether);
        assertEq(nft.allowlistPrice(), 4 ether);
        GodsOfIMDInhabitants.Payee[] memory p = nft.payees();
        assertEq(p.length, 1);
        assertEq(p[0].account, owner);
        assertEq(p[0].bps, 7000);
        (address to, uint256 fee) = nft.royaltyInfo(1, 100 ether);
        assertEq(to, owner);
        assertEq(fee, 5 ether);
    }

    function test_cannotRevealBeforeTheHashExists() public {
        uint256 id = _forge(1);
        assertEq(uint8(nft.markOf(id)), uint8(GodsOfIMDInhabitants.Mark.Unrevealed));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, id));
        nft.reveal(id); // the forge block
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, id));
        nft.reveal(id); // the block whose hash decides: still unknown inside it
        vm.roll(block.number + 1);
        nft.reveal(id);
        assertTrue(nft.markOf(id) != GodsOfIMDInhabitants.Mark.Unrevealed);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, id));
        nft.reveal(id); // only once
    }

    function test_revealManySkipsWhatIsNotReady() public {
        uint256 a = _forge(1);
        vm.roll(block.number + 2);
        uint256 b = _forge(2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        nft.revealMany(ids);
        assertTrue(nft.markOf(a) != GodsOfIMDInhabitants.Mark.Unrevealed);
        assertEq(uint8(nft.markOf(b)), uint8(GodsOfIMDInhabitants.Mark.Unrevealed));
    }

    /// 900 paid souls (ids 1-900) and the 100 reserved ones (ids 901-1000) empty the deck exactly.
    function test_fullDeckComesOutExactly() public {
        uint256 total;
        for (uint256 i = 1; i <= 900; ++i) {
            vm.prevrandao(bytes32(i * 7919));
            uint256 id = _forge(i);
            assertEq(id, i);
            vm.roll(block.number + 2);
            nft.reveal(id);
            total++;
        }
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.MaxSupplyReached.selector, 900));
        _forge(901);
        for (uint256 i = 1; i <= 100; ++i) {
            vm.prank(owner);
            uint256 id = nft.forgeReserved(keccak256(abi.encode("reserved", i)));
            assertEq(id, 900 + i);
            vm.roll(block.number + 2);
            nft.reveal(id);
            total++;
        }
        assertEq(total, 1000);
        assertEq(nft.totalForged(), 1000);
        for (uint256 m; m < 4; ++m) {
            assertEq(nft.markRevealed(m), caps[m]);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.ReserveExhausted.selector, 100));
        nft.forgeReserved(keccak256("one more"));
    }

    /// The draw the contract makes, recomputed here: every slot left in the deck is as likely as any other, for the
    /// first soul as for the last (no early waves).
    function _expected(uint256 id) internal view returns (uint8) {
        uint256 b = nft.revealBlock(id);
        bytes32 h = blockhash(b);
        uint256 rand = uint256(keccak256(abi.encode(h, nft.soulHashOf(id), id)));
        uint256[4] memory w;
        uint256 sum;
        for (uint256 k; k < 4; ++k) {
            w[k] = caps[k] - nft.markRevealed(k);
            sum += w[k];
        }
        uint256 r = rand % sum;
        for (uint256 k = 4; k > 0;) {
            --k;
            if (r < w[k]) return uint8(k + 1);
            r -= w[k];
        }
        return 1;
    }

    function test_everySoulDrawsWithTheSameOdds() public {
        for (uint256 i = 1; i <= 60; ++i) {
            vm.prevrandao(bytes32(i * 104729));
            uint256 id = _forge(i);
            vm.roll(block.number + 2);
            uint8 want = _expected(id);
            nft.reveal(id);
            assertEq(uint8(nft.markOf(id)), want, "the plain draw from what is left of the deck");
        }
    }

    function test_noEarlyWaves() public {
        (bool ok,) = address(nft).staticcall(abi.encodeWithSignature("earlyBoost(uint256)", uint256(1)));
        assertFalse(ok, "there is no earlyBoost any more");
    }
}
