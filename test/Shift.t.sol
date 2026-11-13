// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {TestIMD} from "./Marks.t.sol";

/// Forge tokens: a soul can be paid in a token the owner lists, besides IMD. $SHIFT, NIGHTSHIFT's token, is listed at
/// deploy (200,000 a soul, 30% burned, the rest to the owner); any token can be listed later (a "$GODS", say).
/// $SHIFT lives at its mainnet address, so the tests put a plain ERC-20 there.
contract ShiftTest is Test {
    event ForgedWithToken(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed token,
        uint256 amount,
        uint256 burned,
        uint256 toPayee,
        address referrer,
        uint256 toReferrer
    );
    event SoulForged(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 indexed soulHash,
        uint256 price,
        uint256 burned,
        uint256 toShrine,
        uint256 toPayees,
        address referrer,
        uint256 toReferrer
    );

    TestIMD imd;
    TestIMD shift;
    GodsOfIMDInhabitants nft;
    address constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address owner = address(0xA11CE);
    address shrine = address(0x5A1);
    address burn = address(0xB0);
    address player = address(0xBEEF);
    address friend = address(0xF00D);
    address dead = 0x000000000000000000000000000000000000dEaD;
    uint256 constant PRICE = 200_000 ether;

    function setUp() public {
        imd = new TestIMD();
        vm.etch(SHIFT, address(new TestIMD()).code);
        shift = TestIMD(SHIFT);
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), shrine, burn);
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? player : friend;
            shift.mint(a, 10_000_000 ether);
            imd.mint(a, 1_000 ether);
            vm.startPrank(a);
            shift.approve(address(nft), type(uint256).max);
            imd.approve(address(nft), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _shiftForge(address who, uint256 i, address ref) internal returns (uint256 id) {
        vm.prank(who);
        id = nft.forgeWithToken(SHIFT, keccak256(abi.encode("shift", who, i)), ref);
    }

    function _token(address t)
        internal
        view
        returns (uint256 price, uint256 cap, uint256 forged, uint16 burnBps, address payee)
    {
        (price, cap, forged, burnBps, payee) = nft.forgeTokens(t);
    }

    function test_shiftIsListedAtDeploy() public view {
        assertEq(nft.SHIFT(), SHIFT);
        (uint256 price, uint256 cap, uint256 forged, uint16 burnBps, address payee) = _token(SHIFT);
        assertEq(price, PRICE);
        assertEq(cap, 900, "every paid place");
        assertEq(forged, 0);
        assertEq(burnBps, 3000, "30% burned");
        assertEq(payee, owner, "the owner receives the rest");
        address[] memory list = nft.forgeTokenList();
        assertEq(list.length, 1);
        assertEq(list[0], SHIFT);
    }

    function test_aSoulForTwoHundredThousandShift() public {
        bytes32 h = keccak256(abi.encode("shift", player, uint256(1)));
        vm.expectEmit(true, true, true, true, address(nft));
        emit ForgedWithToken(1, player, SHIFT, PRICE, 60_000 ether, 140_000 ether, address(0), 0);
        vm.expectEmit(true, true, true, true, address(nft));
        emit SoulForged(1, player, h, 0, 0, 0, 0, address(0), 0);
        uint256 id = _shiftForge(player, 1, address(0));
        assertEq(id, 1, "the next paid id");
        assertEq(nft.ownerOf(1), player);
        assertEq(shift.balanceOf(dead), 60_000 ether, "30% burned");
        assertEq(shift.balanceOf(owner), 140_000 ether, "the rest to the payee");
        assertEq(shift.balanceOf(player), 10_000_000 ether - PRICE);
        assertEq(imd.balanceOf(player), 1_000 ether, "no IMD taken");
        assertEq(imd.balanceOf(shrine), 0, "nothing for the shrine: the Oracle takes IMD");
        assertEq(nft.mintedBy(player), 1);
        (,, uint256 forged,,) = _token(SHIFT);
        assertEq(forged, 1);
    }

    function test_idsAreSharedWithForgesInImd() public {
        vm.prank(player);
        assertEq(nft.forge(keccak256("imd one"), address(0)), 1);
        assertEq(_shiftForge(player, 1, address(0)), 2);
        vm.prank(owner);
        assertEq(nft.forgeReserved(keccak256("reserved")), 901);
        assertEq(_shiftForge(player, 2, address(0)), 3);
    }

    function test_aReferrerGetsFivePercent() public {
        _shiftForge(friend, 1, address(0)); // the friend owns a soul, so may refer
        uint256 before = shift.balanceOf(friend);
        vm.expectEmit(true, true, true, true, address(nft));
        emit ForgedWithToken(2, player, SHIFT, PRICE, 60_000 ether, 130_000 ether, friend, 10_000 ether);
        _shiftForge(player, 1, friend);
        assertEq(shift.balanceOf(friend) - before, 10_000 ether);
        assertEq(nft.referralCount(friend), 1);
        assertEq(nft.referralEarned(friend), 0, "referralEarned counts IMD only");
    }

    function test_onlyInThePublicPhase() public {
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Allowlist);
        vm.prank(player);
        vm.expectRevert(GodsOfIMDInhabitants.AllowlistOnly.selector);
        nft.forgeWithToken(SHIFT, keccak256("a"), address(0));
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Closed);
        vm.prank(player);
        vm.expectRevert(GodsOfIMDInhabitants.ForgeClosed.selector);
        nft.forgeWithToken(SHIFT, keccak256("a"), address(0));
    }

    function test_theOwnerSetsPriceCapBurnAndPayee() public {
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, player));
        nft.setForgeToken(SHIFT, 1, 1, 0, player);
        address cold = address(0xC01D);
        vm.prank(owner);
        nft.setForgeToken(SHIFT, 300_000 ether, 2, 5000, cold);
        _shiftForge(player, 1, address(0));
        assertEq(shift.balanceOf(dead), 150_000 ether, "50% burned now");
        assertEq(shift.balanceOf(cold), 150_000 ether);
        _shiftForge(player, 2, address(0));
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.TokenCapReached.selector, SHIFT, 2));
        nft.forgeWithToken(SHIFT, keccak256("third"), address(0));
        // forges in IMD go on
        vm.prank(player);
        assertEq(nft.forge(keccak256("imd"), address(0)), 3);
        // price 0: off
        vm.prank(owner);
        nft.setForgeToken(SHIFT, 0, 900, 3000, owner);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.TokenForgeOff.selector, SHIFT));
        nft.forgeWithToken(SHIFT, keccak256("off"), address(0));
        assertEq(nft.forgeTokenList().length, 1, "listed once");
    }

    function test_badSettingsAreRefused() public {
        vm.startPrank(owner);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAddress.selector);
        nft.setForgeToken(address(0), 1, 1, 0, owner);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAddress.selector);
        nft.setForgeToken(address(imd), 1, 1, 0, owner);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAddress.selector);
        nft.setForgeToken(SHIFT, 1, 1, 0, address(0));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.InvalidSplit.selector, 9600, 500));
        nft.setForgeToken(SHIFT, 1, 1, 9600, owner);
        vm.stopPrank();
    }

    /// A token listed later (a "$GODS" on a v4 hook, say): its own price, burn and payee, no new NFT.
    function test_aNewTokenCanBeListedLater() public {
        TestIMD gods = new TestIMD();
        gods.mint(player, 1_000 ether);
        vm.prank(player);
        gods.approve(address(nft), type(uint256).max);
        address treasury = address(0x7EA5);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.TokenForgeOff.selector, address(gods)));
        nft.forgeWithToken(address(gods), keccak256("early"), address(0));
        vm.prank(owner);
        nft.setForgeToken(address(gods), 100 ether, 50, 1000, treasury);
        vm.prank(player);
        uint256 id = nft.forgeWithToken(address(gods), keccak256("gods"), address(0));
        assertEq(id, 1);
        assertEq(gods.balanceOf(dead), 10 ether);
        assertEq(gods.balanceOf(treasury), 90 ether);
        assertEq(nft.forgeTokenList().length, 2);
    }

    function test_theWalletCapCountsBoth() public {
        for (uint256 i; i < 10; ++i) {
            vm.prank(player);
            nft.forge(keccak256(abi.encode("imd", i)), address(0));
        }
        for (uint256 i; i < 10; ++i) {
            _shiftForge(player, i, address(0));
        }
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.WalletLimitReached.selector, player, 20));
        nft.forgeWithToken(SHIFT, keccak256("21st"), address(0));
    }

    function test_needsTheTokenAllowance() public {
        address stranger = address(0xCAFE);
        shift.mint(stranger, PRICE);
        vm.prank(stranger);
        vm.expectRevert();
        nft.forgeWithToken(SHIFT, keccak256("no approval"), address(0));
        assertEq(nft.totalForged(), 0);
    }

    /// Five payees share the IMD of a forge; the $SHIFT goes to its payee alone.
    function test_imdIsSharedAndShiftGoesToItsPayeeAlone() public {
        address[4] memory partners = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
        GodsOfIMDInhabitants.Payee[] memory ps = new GodsOfIMDInhabitants.Payee[](5);
        ps[0] = GodsOfIMDInhabitants.Payee(owner, 1400);
        for (uint256 i; i < 4; ++i) {
            ps[i + 1] = GodsOfIMDInhabitants.Payee(partners[i], 1400);
        }
        vm.prank(owner);
        nft.setPayees(ps);
        // a forge in IMD: 5 IMD, 1 burned, 0.5 to the shrine, 0.7 to each of the five
        vm.prank(player);
        nft.forge(keccak256("imd"), address(0));
        assertEq(imd.balanceOf(owner), 0.7 ether);
        for (uint256 i; i < 4; ++i) {
            assertEq(imd.balanceOf(partners[i]), 0.7 ether);
        }
        // a forge in $SHIFT: 60,000 burned, 140,000 to its payee (the owner), nothing to the partners
        _shiftForge(player, 1, address(0));
        assertEq(shift.balanceOf(owner), 140_000 ether);
        for (uint256 i; i < 4; ++i) {
            assertEq(shift.balanceOf(partners[i]), 0);
        }
    }

    function test_withoutTheTokenOnThisChainItReverts() public {
        vm.etch(SHIFT, "");
        vm.prank(player);
        vm.expectRevert();
        nft.forgeWithToken(SHIFT, keccak256("nowhere"), address(0));
    }
}
