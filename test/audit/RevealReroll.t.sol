// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GodsOfIMDInhabitants} from "src/GodsOfIMDInhabitants.sol";

contract ProofIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Once the block after the forge is older than 256 blocks, `reveal` draws from `blockhash(block.number - 1)`,
/// a value the caller chooses by choosing the block in which to call `reveal`. The same soul then gets a different
/// Mark depending on the reveal block: a re-roll per block until the deck's Divine comes out.
contract RevealRerollTest is Test {
    ProofIMD imd;
    GodsOfIMDInhabitants nft;
    address owner = address(0xA11CE);
    address player = address(0xBEEF);

    function setUp() public {
        imd = new ProofIMD();
        nft = new GodsOfIMDInhabitants(owner, IERC20(address(imd)), address(0x5A1), address(0xB0));
        vm.prank(owner);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        imd.mint(player, 100 ether);
        vm.prank(player);
        imd.approve(address(nft), type(uint256).max);
        vm.roll(1000);
    }

    /// The draw the contract makes under the stale-hash fallback at the current block.
    function _drawAtThisBlock(uint256 id) internal view returns (GodsOfIMDInhabitants.Mark) {
        bytes32 h = blockhash(block.number - 1);
        uint256 rand = uint256(keccak256(abi.encode(h, nft.soulHashOf(id), id)));
        uint256[4] memory w = [uint256(640), 250, 100, 10]; // nothing revealed yet
        uint256 r = rand % 1000;
        for (uint256 k = 4; k > 0;) {
            --k;
            if (r < w[k]) return GodsOfIMDInhabitants.Mark(k + 1);
            r -= w[k];
        }
        return GodsOfIMDInhabitants.Mark.Mortal;
    }

    function _revealAndRead(uint256 id) internal returns (GodsOfIMDInhabitants.Mark) {
        (bool ok,) = address(nft).call(abi.encodeWithSelector(nft.reveal.selector, id));
        ok; // a fix may also refuse the stale reveal: then the Mark stays Unrevealed on both paths
        return nft.markOf(id);
    }

    function test_theRevealBlockDoesNotChooseTheMark() public {
        vm.prank(player);
        uint256 id = nft.forge(keccak256("soul"), address(0));
        uint256 b = nft.revealBlock(id);
        assertEq(b, block.number + 1);

        // Nobody revealed for 257 blocks: blockhash(b) is gone and the fallback kicks in.
        vm.roll(b + 257);
        assertEq(blockhash(b), bytes32(0), "the forge block hash must be stale for this test");

        // Walk forward until a block where the fallback draws Divine, and one where it draws Mortal.
        uint256 divineBlock;
        uint256 mortalBlock;
        for (uint256 i; i < 5000 && (divineBlock == 0 || mortalBlock == 0); ++i) {
            GodsOfIMDInhabitants.Mark m = _drawAtThisBlock(id);
            if (m == GodsOfIMDInhabitants.Mark.Divine && divineBlock == 0) divineBlock = block.number;
            if (m == GodsOfIMDInhabitants.Mark.Mortal && mortalBlock == 0) mortalBlock = block.number;
            vm.roll(block.number + 1);
        }
        assertTrue(divineBlock != 0 && mortalBlock != 0, "no steering blocks found");

        uint256 snap = vm.snapshotState();
        vm.roll(divineBlock);
        GodsOfIMDInhabitants.Mark atDivine = _revealAndRead(id);
        vm.revertToState(snap);
        vm.roll(mortalBlock);
        GodsOfIMDInhabitants.Mark atMortal = _revealAndRead(id);

        emit log_named_uint("mark when revealed at the chosen block", uint8(atDivine));
        emit log_named_uint("mark when revealed at another block", uint8(atMortal));
        assertEq(uint8(atDivine), uint8(atMortal), "the caller chose the Mark by choosing the reveal block");
    }
}
