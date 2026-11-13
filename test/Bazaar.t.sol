// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";

contract BazaarIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// The Bazaar: `purchase` sells looks for a soul. Only the soul's owner may buy, the IMD is split exactly like a
/// forge with no referrer (burn, shrine, payees by bps), the `Purchased` event carries what the game server checks,
/// and memorial souls cannot buy.
contract BazaarTest is Test {
    BazaarIMD imd;
    GodsOfIMDInhabitants nft;
    address owner = address(0xA11CE);
    address shrine = address(0x5A1);
    address burnSink = address(0xB0);
    address player = address(0xBEEF);
    address stranger = address(0x5712);
    address buyer = address(0xB0B);
    address[4] team = [address(0xF0), address(0xF1), address(0xF2), address(0xF3)];
    bytes32 constant CAPE = bytes32("cape-sunburst");
    uint256 soul;

    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        bytes32 indexed itemId,
        uint256 amount,
        uint256 burned,
        uint256 toShrine,
        uint256 toPayees
    );

    function setUp() public {
        imd = new BazaarIMD();
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), shrine, burnSink);
        // the founder and three team wallets, as in the README (7000 bps in all)
        GodsOfIMDInhabitants.Payee[] memory p = new GodsOfIMDInhabitants.Payee[](4);
        p[0] = GodsOfIMDInhabitants.Payee(team[0], 2000);
        p[1] = GodsOfIMDInhabitants.Payee(team[1], 1667);
        p[2] = GodsOfIMDInhabitants.Payee(team[2], 1667);
        p[3] = GodsOfIMDInhabitants.Payee(team[3], 1666);
        vm.startPrank(owner);
        nft.setPayees(p);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            address a = [player, stranger, buyer][i];
            imd.mint(a, 1_000 ether);
            vm.prank(a);
            imd.approve(address(nft), type(uint256).max);
        }
        vm.prank(player);
        soul = nft.forge(keccak256("a soul"), address(0));
    }

    function _balances() internal view returns (uint256[7] memory b) {
        b[0] = imd.balanceOf(player);
        b[1] = imd.balanceOf(burnSink);
        b[2] = imd.balanceOf(shrine);
        for (uint256 i; i < 4; ++i) {
            b[3 + i] = imd.balanceOf(team[i]);
        }
    }

    function _checkSplit(uint256 amount) internal {
        uint256[7] memory before = _balances();
        vm.prank(player);
        nft.purchase(soul, CAPE, amount);
        uint256[7] memory afterB = _balances();
        (uint256 burned, uint256 toShrine, uint256 toPayees, uint256 toReferrer) = nft.previewSplit(amount, false);
        assertEq(toReferrer, 0);
        assertEq(burned, (amount * 2000) / 10_000, "20% burned");
        assertEq(toShrine, (amount * 1000) / 10_000, "10% to the shrine");
        assertEq(before[0] - afterB[0], amount, "the buyer pays exactly the amount");
        assertEq(afterB[1] - before[1], burned, "burn sink");
        assertEq(afterB[2] - before[2], toShrine, "shrine");
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            uint256 got = afterB[3 + i] - before[3 + i];
            assertEq(got, (toPayees * [uint256(2000), 1667, 1667][i]) / 7000, "payee share by bps");
            paid += got;
        }
        paid += afterB[6] - before[6]; // the last payee takes the rounding dust
        assertEq(paid, toPayees, "the payees get the rest, to the wei");
        assertEq(burned + toShrine + toPayees, amount, "nothing is lost or kept");
        assertEq(imd.balanceOf(address(nft)), 0, "the contract keeps nothing");
    }

    function test_splitIsExactlyTheForgeSplit() public {
        _checkSplit(1 ether);
    }

    function test_splitIsExactWithRoundingDust() public {
        _checkSplit(0.75 ether + 7);
    }

    function testFuzz_splitIsExact(uint256 amount) public {
        amount = bound(amount, 1, 900 ether);
        _checkSplit(amount);
    }

    function test_splitFollowsSetSplit() public {
        GodsOfIMDInhabitants.Payee[] memory p = new GodsOfIMDInhabitants.Payee[](1);
        p[0] = GodsOfIMDInhabitants.Payee(team[0], 6000);
        vm.prank(owner);
        nft.setSplit(2500, 1500, p);
        uint256 b0 = imd.balanceOf(burnSink);
        uint256 s0 = imd.balanceOf(shrine);
        uint256 t0 = imd.balanceOf(team[0]);
        vm.prank(player);
        nft.purchase(soul, CAPE, 2 ether);
        assertEq(imd.balanceOf(burnSink) - b0, 0.5 ether);
        assertEq(imd.balanceOf(shrine) - s0, 0.3 ether);
        assertEq(imd.balanceOf(team[0]) - t0, 1.2 ether);
    }

    function test_emitsPurchased() public {
        (uint256 burned, uint256 toShrine, uint256 toPayees,) = nft.previewSplit(1.25 ether, false);
        vm.expectEmit(true, true, true, true, address(nft));
        emit Purchased(soul, player, CAPE, 1.25 ether, burned, toShrine, toPayees);
        vm.prank(player);
        nft.purchase(soul, CAPE, 1.25 ether);
    }

    function test_onlyTheOwnerMayBuy() public {
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotTokenOwner.selector, soul, stranger));
        vm.prank(stranger);
        nft.purchase(soul, CAPE, 1 ether);
    }

    function test_unknownSoulReverts() public {
        vm.expectRevert();
        vm.prank(player);
        nft.purchase(999, CAPE, 1 ether);
    }

    function test_itemsFollowTheTokenToItsNewOwner() public {
        vm.prank(player);
        nft.transferFrom(player, buyer, soul);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotTokenOwner.selector, soul, player));
        vm.prank(player);
        nft.purchase(soul, CAPE, 1 ether);
        vm.expectEmit(true, true, true, false, address(nft));
        emit Purchased(soul, buyer, CAPE, 1 ether, 0, 0, 0);
        vm.prank(buyer);
        nft.purchase(soul, CAPE, 1 ether);
    }

    function test_zeroAmountReverts() public {
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAmount.selector);
        vm.prank(player);
        nft.purchase(soul, CAPE, 0);
    }

    function test_memorialSoulCannotBuy() public {
        vm.prank(owner); // the steward is the owner until setSteward
        nft.setMemorial(soul, keccak256("fell at the river"));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.SoulIsMemorial.selector, soul));
        vm.prank(player);
        nft.purchase(soul, CAPE, 1 ether);
    }

    function test_needsTheAllowance() public {
        vm.prank(player);
        imd.approve(address(nft), 0.5 ether);
        vm.expectRevert();
        vm.prank(player);
        nft.purchase(soul, CAPE, 1 ether);
    }
}
