// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "../src/GodsOfIMDInhabitants.sol";
import {OracleShrine} from "../src/OracleShrine.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

contract LaunchIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// The deploy exactly as IMD's launch manifest does it: OracleShrine($owner, intake, imd, signer, director), then
/// GodsOfIMDInhabitants($owner, imd, $contract:OracleShrine, burnSink), from a factory that is not the owner, in a
/// fresh EVM where the intake and the signer hold no code. Then the owner's wiring and a first forge.
contract LaunchTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address owner = address(0xA11CE);
    address director = address(0xD1);
    address burnSink = address(0xB0);
    address factory = address(0xFAC);
    address player = address(0xBEEF);
    LaunchIMD imd;
    OracleShrine shrine;
    GodsOfIMDInhabitants nft;

    function setUp() public {
        imd = new LaunchIMD();
        vm.startPrank(factory);
        shrine = new OracleShrine(owner, IIntake(INTAKE), IERC20(address(imd)), SIGNER, director);
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), address(shrine), burnSink);
        vm.stopPrank();
    }

    function test_constructorsGiveTheOwnerEverything() public view {
        assertEq(shrine.owner(), owner);
        assertEq(nft.owner(), owner);
        assertEq(nft.steward(), owner);
        assertEq(nft.royaltyReceiver(), owner);
        GodsOfIMDInhabitants.Payee[] memory p = nft.payees();
        assertEq(p.length, 1);
        assertEq(p[0].account, owner);
        assertEq(p[0].bps, 7000);
    }

    function test_constructorsWireTheTwoContracts() public view {
        assertEq(address(shrine.intake()), INTAKE);
        assertEq(address(shrine.imd()), address(imd));
        assertEq(shrine.oracleSigner(), SIGNER);
        assertEq(shrine.director(), director);
        assertEq(address(nft.imd()), address(imd));
        assertEq(nft.shrine(), address(shrine));
        assertEq(nft.burnSink(), burnSink);
    }

    function test_genesisRulesAreBuiltIn() public view {
        assertEq(nft.maxSupply(), 1000);
        assertEq(nft.GENESIS_SUPPLY(), 1000);
        assertEq(nft.mintPrice(), 5 ether);
        assertEq(nft.allowlistPrice(), 4 ether);
        assertEq(uint8(nft.phase()), uint8(GodsOfIMDInhabitants.Phase.Closed));
        assertEq(bytes(nft.baseURI()).length, 0);
        uint256 deck;
        for (uint256 i; i < 4; ++i) {
            deck += nft.markCap(i);
        }
        assertEq(deck, 1000);
    }

    function test_constructorsRejectZeroAddresses() public {
        vm.expectRevert(OracleShrine.ZeroAddress.selector);
        new OracleShrine(owner, IIntake(address(0)), IERC20(address(imd)), SIGNER, director);
        vm.expectRevert(OracleShrine.ZeroAddress.selector);
        new OracleShrine(owner, IIntake(INTAKE), IERC20(address(imd)), SIGNER, address(0));
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAddress.selector);
        new GodsOfIMDInhabitants(owner, IERC20(address(imd)), address(0), burnSink);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAddress.selector);
        new GodsOfIMDInhabitants(owner, IERC20(address(imd)), address(shrine), address(0));
    }

    function test_onlyTheOwnerWires() public {
        vm.expectRevert();
        nft.setSteward(director);
        vm.expectRevert();
        nft.setBaseURI("https://example.com/metadata/");
        vm.expectRevert();
        shrine.setDirector(address(0xBAD));
    }

    function test_ownerWiringThenAFirstForgeSplitsThePrice() public {
        vm.startPrank(owner);
        nft.setSteward(director);
        nft.setBaseURI("https://gods.getnightshift.tech/metadata/");
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        vm.stopPrank();
        assertEq(nft.steward(), director);

        imd.mint(player, 5 ether);
        vm.startPrank(player);
        imd.approve(address(nft), 5 ether);
        uint256 id = nft.forge(keccak256("first soul"), address(0));
        vm.stopPrank();

        assertEq(id, 1);
        assertEq(nft.ownerOf(1), player);
        assertEq(nft.tokenURI(1), "https://gods.getnightshift.tech/metadata/1");
        assertEq(imd.balanceOf(burnSink), 1 ether); // 20% burned
        assertEq(imd.balanceOf(address(shrine)), 0.5 ether); // 10% to the game treasury
        assertEq(imd.balanceOf(owner), 3.5 ether); // 70% to the team (the owner until setPayees)
        assertEq(shrine.availableBalance(), 0.5 ether);

        // the steward is now the game server: it can refresh metadata, the owner no longer can
        vm.prank(director);
        nft.refresh(1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotSteward.selector, owner));
        nft.refresh(1);
    }
}
