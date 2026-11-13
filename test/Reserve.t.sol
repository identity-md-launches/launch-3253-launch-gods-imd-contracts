// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {TestIMD} from "./Marks.t.sol";

/// The creator's reserve: 100 of the 1000 souls, forged free by the owner as ids 901-1000; paid forges take ids 1-900.
contract ReserveTest is Test {
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
    GodsOfIMDInhabitants nft;
    address owner = address(0xA11CE);
    address shrine = address(0x5A1);
    address burn = address(0xB0);
    address player = address(0xBEEF);

    function setUp() public {
        imd = new TestIMD();
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), shrine, burn);
        imd.mint(player, 1_000 ether);
        vm.prank(player);
        imd.approve(address(nft), type(uint256).max);
    }

    function _reserve(uint256 i) internal returns (uint256 id) {
        vm.prank(owner);
        id = nft.forgeReserved(keccak256(abi.encode("reserved", i)));
    }

    function test_reserveIsAHundredOfTheThousand() public view {
        assertEq(nft.RESERVE(), 100);
        assertEq(nft.reservedForged(), 0);
        assertEq(nft.maxSupply(), 1000);
    }

    function test_onlyTheOwnerForgesReserved() public {
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, player));
        nft.forgeReserved(keccak256("x"));
    }

    function test_reservedIsFreeInAnyPhaseAndTakesTheLastIds() public {
        // the forge is still closed for players
        assertEq(uint8(nft.phase()), uint8(GodsOfIMDInhabitants.Phase.Closed));
        bytes32 h = keccak256(abi.encode("reserved", uint256(1)));
        vm.expectEmit(true, true, true, true, address(nft));
        emit SoulForged(901, owner, h, 0, 0, 0, 0, address(0), 0);
        uint256 id = _reserve(1);
        assertEq(id, 901);
        assertEq(nft.ownerOf(901), owner);
        assertEq(nft.totalForged(), 1);
        assertEq(nft.reservedForged(), 1);
        assertEq(nft.mintedBy(owner), 0, "outside every wallet cap");
        assertEq(imd.balanceOf(owner), 0, "nothing paid");
        assertEq(_reserve(2), 902);
    }

    function test_paidSoulsTakeIdsFromOne() public {
        _reserve(1);
        _reserve(2);
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        vm.prank(player);
        assertEq(nft.forge(keccak256("first paid"), address(0)), 1, "the first paid soul is still soul #1");
        assertEq(nft.totalForged(), 3);
        assertEq(_reserve(3), 903);
        vm.prank(player);
        assertEq(nft.forge(keccak256("second paid"), address(0)), 2);
    }

    function test_reservedSoulsAreUniqueAndReveal() public {
        uint256 id = _reserve(1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                GodsOfIMDInhabitants.SoulAlreadyForged.selector, keccak256(abi.encode("reserved", uint256(1))), id
            )
        );
        nft.forgeReserved(keccak256(abi.encode("reserved", uint256(1))));
        vm.roll(block.number + 2);
        nft.reveal(id);
        assertTrue(nft.markOf(id) != GodsOfIMDInhabitants.Mark.Unrevealed);
        vm.prank(owner);
        nft.setBaseURI("https://gods.example/metadata/");
        assertEq(nft.tokenURI(id), "https://gods.example/metadata/901");
    }

    function test_reserveStopsAtAHundred() public {
        for (uint256 i = 1; i <= 100; ++i) {
            assertEq(_reserve(i), 900 + i);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.ReserveExhausted.selector, 100));
        nft.forgeReserved(keccak256("101"));
        assertEq(nft.totalForged(), 100);
    }

    function test_manyInOneTransaction() public {
        bytes32[] memory hs = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            hs[i] = keccak256(abi.encode("batch", i));
        }
        vm.prank(owner);
        uint256 first = nft.forgeReservedMany(hs);
        assertEq(first, 901);
        assertEq(nft.ownerOf(903), owner);
        assertEq(nft.tokenOfSoul(keccak256(abi.encode(owner, hs[2]))), 903);
        assertEq(nft.reservedForged(), 3);
        // never past the reserve, and all or nothing
        bytes32[] memory big = new bytes32[](98);
        for (uint256 i; i < 98; ++i) {
            big[i] = keccak256(abi.encode("big", i));
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.ReserveExhausted.selector, 100));
        nft.forgeReservedMany(big);
        assertEq(nft.reservedForged(), 3);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, player));
        nft.forgeReservedMany(hs);
        vm.prank(owner);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAmount.selector);
        nft.forgeReservedMany(new bytes32[](0));
    }

    function test_fiftyInOneTransactionFitsABlock() public {
        bytes32[] memory hs = new bytes32[](50);
        for (uint256 i; i < 50; ++i) {
            hs[i] = keccak256(abi.encode("half", i));
        }
        uint256 g = gasleft();
        vm.prank(owner);
        nft.forgeReservedMany(hs);
        uint256 used = g - gasleft();
        emit log_named_uint("gas for 50 reserved souls", used);
        assertLt(used, 15_000_000);
        bytes32[] memory rest = new bytes32[](50);
        for (uint256 i; i < 50; ++i) {
            rest[i] = keccak256(abi.encode("rest", i));
        }
        vm.prank(owner);
        nft.forgeReservedMany(rest);
        assertEq(nft.reservedForged(), 100);
        assertEq(nft.ownerOf(1000), owner);
    }

    function test_aReservedSoulCanBeGivenAway() public {
        uint256 id = _reserve(1);
        vm.prank(owner);
        nft.transferFrom(owner, player, id);
        assertEq(nft.ownerOf(id), player);
    }
}
