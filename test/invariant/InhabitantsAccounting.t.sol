// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GodsOfIMDInhabitants} from "src/GodsOfIMDInhabitants.sol";
import {OracleTestIMD} from "../helpers/OracleFixture.sol";

contract InhabitantsAccountingHandler is Test {
    GodsOfIMDInhabitants public immutable nft;
    OracleTestIMD public immutable imd;
    OracleTestIMD public immutable alt;
    address public constant OWNER = address(0xA11CE);
    address public constant SHRINE = address(0x5100);
    address public constant BURN = address(0xB000);
    address public constant PAYEE = address(0xFA11);
    address public constant PAYEE2 = address(0xFA12);
    uint256 public constant INITIAL = 1_000_000 ether;
    address[4] private players = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    bytes32[4] private leaves;
    uint256[] private ids;
    mapping(uint256 => address) public expectedOwner;
    mapping(uint256 => address) public minter;
    mapping(uint256 => bytes32) public originalSoul;
    mapping(uint256 => uint8) public expectedMark;
    mapping(uint256 => bool) public expectedMemorial;
    mapping(uint256 => bytes32) public expectedChronicle;
    mapping(address => uint256) public paidMints;
    mapping(address => uint256) public allowlistMints;
    mapping(address => uint256) public imdSpent;
    mapping(address => uint256) public altSpent;
    mapping(address => uint256) public imdReferred;
    mapping(address => uint256) public altReferred;
    mapping(address => uint256) public referrals;
    uint256 public paidCount;
    uint256 public reserveCount;
    uint256 public altCount;
    uint256 public burnPaid;
    uint256 public shrinePaid;
    uint256 public payeePaid;
    uint256 public payee2Paid;
    uint256 public altBurnPaid;
    uint256 public altPayeePaid;
    uint256 private nonce;
    uint8 public mintPhase = 2;
    bool public unexpectedRevert;
    bytes public lastFailure;
    uint256 public successfulCalls;

    constructor(GodsOfIMDInhabitants nft_, OracleTestIMD imd_, OracleTestIMD alt_) {
        nft = nft_;
        imd = imd_;
        alt = alt_;
        for (uint256 i; i < 4; ++i) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(players[i], uint256(25)))));
        }
    }

    function player(uint256 i) external view returns (address) {
        return players[i];
    }

    function tokenCount() external view returns (uint256) {
        return ids.length;
    }

    function tokenAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }

    function root() external view returns (bytes32) {
        return _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }

    function forgeSoul(uint256 actorSeed, uint8 mode, uint256 refSeed) external {
        uint256 index = actorSeed % 4;
        address actor = players[index];
        mode %= 3; // IMD, allowlist IMD, alternate token
        if (mintPhase == 0 || (mode != 1 && mintPhase != 2)) return;
        if (paidCount == 900 || paidMints[actor] >= (mode == 1 ? 25 : 20)) return;
        if (mode == 1 && allowlistMints[actor] == 25) return;
        if (mode == 2 && altCount == 67) return;
        address referrer = refSeed % 6 == 4 ? OWNER : refSeed % 6 == 5 ? address(0) : players[refSeed % 4];
        if (referrer == actor || !_ownsAny(referrer)) referrer = address(0);
        bytes32 soul = keccak256(abi.encode("stateful soul", ++nonce));
        bytes memory data;
        if (mode == 0) data = abi.encodeCall(nft.forge, (soul, referrer));
        else if (mode == 1) data = abi.encodeCall(nft.forgeAllowlist, (soul, referrer, uint256(25), _proof(index)));
        else data = abi.encodeCall(nft.forgeWithToken, (address(alt), soul, referrer));
        (bool ok, bytes memory result) = _call(actor, data);
        if (!ok) return;
        uint256 id = abi.decode(result, (uint256));
        ++paidCount;
        if (id != paidCount) unexpectedRevert = true;
        ++paidMints[actor];
        if (mode == 1) ++allowlistMints[actor];
        if (mode == 2) {
            ++altCount;
            _payAlternate(actor, referrer);
        } else {
            _payIMD(actor, mode == 1 ? 4 ether : 5 ether, referrer, false);
        }
        _track(id, actor, soul);
    }

    function forgeReserve(uint8 count) external {
        if (reserveCount == 100) return;
        uint256 n = bound(count, 1, 3);
        if (n > 100 - reserveCount) n = 100 - reserveCount;
        bytes32[] memory souls = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            souls[i] = keccak256(abi.encode("reserve soul", ++nonce));
        }
        (bool ok, bytes memory result) = _call(OWNER, abi.encodeCall(nft.forgeReservedMany, (souls)));
        if (!ok) return;
        uint256 first = abi.decode(result, (uint256));
        if (first != 901 + reserveCount) unexpectedRevert = true;
        for (uint256 i; i < n; ++i) {
            _track(first + i, OWNER, souls[i]);
        }
        reserveCount += n;
    }

    function transferSoul(uint256 seed, uint256 toSeed, bool operator) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address from = expectedOwner[id];
        address to = toSeed % 5 == 4 ? OWNER : players[toSeed % 4];
        address caller = from;
        if (operator) {
            caller = address(0x0F00);
            (bool approved,) = _call(from, abi.encodeCall(nft.approve, (caller, id)));
            if (!approved) return;
        }
        (bool ok,) = _call(caller, abi.encodeCall(nft.transferFrom, (from, to, id)));
        if (ok) expectedOwner[id] = to;
    }

    function buyService(uint256 seed, uint8 kind, uint96 amount) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address actor = expectedOwner[id];
        if (actor == OWNER) return; // owner is a reserve holder; only the four funded players buy services
        kind %= 3;
        if (kind != 1 && expectedMemorial[id]) return;
        uint256 paid = kind == 0 ? 0.75 ether : kind == 1 ? 1 ether : bound(amount, 1, 100 ether);
        bytes memory data = kind == 0
            ? abi.encodeCall(nft.petition, (id, keccak256("petition")))
            : kind == 1
                ? abi.encodeCall(nft.commission, (id, uint8(7), keccak256("commission")))
                : abi.encodeCall(nft.purchase, (id, keccak256("cosmetic"), paid));
        (bool ok,) = _call(actor, data);
        if (ok) _payIMD(actor, paid, address(0), kind != 2);
    }

    function memorialize(uint256 seed, bytes32 chronicle) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (expectedMemorial[id]) return;
        (bool ok,) = _call(OWNER, abi.encodeCall(nft.setMemorial, (id, chronicle)));
        if (ok) {
            expectedMemorial[id] = true;
            expectedChronicle[id] = chronicle;
        }
    }

    /// The model's reveal head: the earliest-tracked (forge-order) soul without a Mark, 0 if none.
    function head() public view returns (uint256) {
        for (uint256 i; i < ids.length; ++i) {
            if (expectedMark[ids[i]] == 0) return ids[i];
        }
        return 0;
    }

    function revealSoul(uint256 seed, uint16 delay) external {
        if (ids.length == 0) return;
        uint256 chosen = ids[seed % ids.length];
        uint256 id = head();
        if (id == 0) return;
        uint256 b = nft.revealBlock(id);
        uint256 next = vm.getBlockNumber() + bound(delay, 2, 300);
        vm.roll(next);
        if (chosen != id) {
            // Any soul other than the forge-order head is refused, revealed or not, and changes nothing.
            uint256 cb = nft.revealBlock(chosen);
            bytes memory expected = cb == 0 || next <= cb
                ? abi.encodeWithSelector(GodsOfIMDInhabitants.NotRevealable.selector, chosen)
                : abi.encodeWithSelector(GodsOfIMDInhabitants.RevealOutOfOrder.selector, chosen, id);
            vm.prank(address(0xBEEF));
            (bool okOut, bytes memory res) = address(nft).call(abi.encodeCall(nft.reveal, (chosen)));
            if (okOut || keccak256(res) != keccak256(expected)) unexpectedRevert = true;
            if (nft.revealBlock(chosen) != cb) unexpectedRevert = true;
        }
        if (next - b <= 256) vm.setBlockhash(b, keccak256(abi.encode("fixed historical block", b)));
        (bool ok,) = _call(address(0xBEEF), abi.encodeCall(nft.reveal, (id)));
        if (!ok) return;
        uint8 mark = uint8(nft.markOf(id));
        if (next - b <= 256) {
            if (mark == 0 || nft.revealBlock(id) != 0) unexpectedRevert = true;
            expectedMark[id] = mark;
        } else if (mark != 0 || nft.revealBlock(id) != next + 1) {
            unexpectedRevert = true;
        }
    }

    function setMintPhase(uint8 phase) external {
        phase %= 3;
        (bool ok,) = _call(OWNER, abi.encodeCall(nft.setPhase, (GodsOfIMDInhabitants.Phase(phase))));
        if (ok) mintPhase = phase;
    }

    function _track(uint256 id, address actor, bytes32 soul) private {
        ids.push(id);
        expectedOwner[id] = actor;
        minter[id] = actor;
        originalSoul[id] = soul;
    }

    function _payIMD(address actor, uint256 paid, address referrer, bool service) private {
        imdSpent[actor] += paid;
        uint256 burned = service ? 0 : paid / 5;
        uint256 treasury = service ? (paid < 0.5 ether ? paid : 0.5 ether) : paid / 10;
        uint256 referred = referrer == address(0) ? 0 : paid / 20;
        uint256 pool = paid - burned - treasury - referred;
        burnPaid += burned;
        shrinePaid += treasury;
        uint256 first = pool * 3 / 7;
        payeePaid += first;
        payee2Paid += pool - first;
        if (referrer != address(0)) {
            ++referrals[referrer];
            imdReferred[referrer] += referred;
        }
    }

    function _payAlternate(address actor, address referrer) private {
        altSpent[actor] += 7 ether;
        altBurnPaid += 2.1 ether;
        uint256 referred = referrer == address(0) ? 0 : 0.35 ether;
        altPayeePaid += 4.9 ether - referred;
        if (referrer != address(0)) {
            ++referrals[referrer];
            altReferred[referrer] += referred;
        }
    }

    function _ownsAny(address actor) private view returns (bool) {
        if (actor == address(0)) return false;
        for (uint256 i; i < ids.length; ++i) {
            if (expectedOwner[ids[i]] == actor) return true;
        }
        return false;
    }

    function _call(address actor, bytes memory data) private returns (bool ok, bytes memory result) {
        vm.prank(actor);
        (ok, result) = address(nft).call(data);
        if (!ok) {
            unexpectedRevert = true;
            lastFailure = result;
        } else {
            ++successfulCalls;
        }
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(uint256 i) private view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = leaves[i ^ 1];
        proof[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract InhabitantsAccountingInvariantTest is Test {
    GodsOfIMDInhabitants private nft;
    OracleTestIMD private imd;
    OracleTestIMD private alt;
    InhabitantsAccountingHandler private handler;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        imd = new OracleTestIMD();
        alt = new OracleTestIMD();
        nft = new GodsOfIMDInhabitants(address(0xA11CE), imd, address(0x5100), address(0xB000));
        handler = new InhabitantsAccountingHandler(nft, imd, alt);
        GodsOfIMDInhabitants.Payee[] memory payees = new GodsOfIMDInhabitants.Payee[](2);
        payees[0] = GodsOfIMDInhabitants.Payee(handler.PAYEE(), 3000);
        payees[1] = GodsOfIMDInhabitants.Payee(handler.PAYEE2(), 4000);
        bytes32 root = handler.root();
        address altPayee = handler.PAYEE();
        vm.startPrank(handler.OWNER());
        nft.setPayees(payees);
        nft.setForgeToken(address(alt), 7 ether, 67, 3000, altPayee);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        nft.setAllowlistRoot(root);
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            address actor = handler.player(i);
            imd.mint(actor, handler.INITIAL());
            alt.mint(actor, handler.INITIAL());
            vm.startPrank(actor);
            imd.approve(address(nft), type(uint256).max);
            alt.approve(address(nft), type(uint256).max);
            vm.stopPrank();
        }
        handler.forgeReserve(1);
        for (uint256 i; i < 4; ++i) {
            handler.forgeSoul(i, uint8(i % 3), 4);
        }
        handler.revealSoul(1, 2);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.forgeSoul.selector;
        selectors[1] = handler.forgeReserve.selector;
        selectors[2] = handler.transferSoul.selector;
        selectors[3] = handler.buyService.selector;
        selectors[4] = handler.memorialize.selector;
        selectors[5] = handler.revealSoul.selector;
        selectors[6] = handler.setMintPhase.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyOwnershipAndSoulIdentityAreConserved() public view {
        uint256 count = handler.tokenCount();
        assertEq(nft.totalForged(), count);
        assertEq(count, handler.paidCount() + handler.reserveCount());
        assertEq(nft.reservedForged(), handler.reserveCount());
        assertLe(handler.paidCount(), 900);
        assertLe(handler.reserveCount(), 100);
        assertLe(count, 1000);
        assertEq(nft.maxSupply(), 1000);
        uint256[5] memory balances;
        for (uint256 i; i < count; ++i) {
            uint256 id = handler.tokenAt(i);
            address expected = handler.expectedOwner(id);
            assertEq(nft.ownerOf(id), expected);
            assertEq(nft.getApproved(id), address(0), "transfer clears token approval");
            assertEq(nft.soulHashOf(id), handler.originalSoul(id));
            assertEq(nft.tokenOfSoul(keccak256(abi.encode(handler.minter(id), handler.originalSoul(id)))), id);
            assertEq(nft.memorial(id), handler.expectedMemorial(id));
            assertEq(nft.chronicleOf(id), handler.expectedChronicle(id));
            if (expected == handler.OWNER()) {
                ++balances[4];
            } else {
                for (uint256 j; j < 4; ++j) {
                    if (expected == handler.player(j)) ++balances[j];
                }
            }
        }
        uint256 minted;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.player(i);
            assertEq(nft.balanceOf(actor), balances[i]);
            assertEq(nft.mintedBy(actor), handler.paidMints(actor));
            assertEq(nft.allowlistMinted(actor), handler.allowlistMints(actor));
            assertLe(nft.mintedBy(actor), 25);
            minted += nft.mintedBy(actor);
        }
        assertEq(minted, handler.paidCount());
        assertEq(nft.balanceOf(handler.OWNER()), balances[4]);
        assertEq(nft.mintedBy(handler.OWNER()), 0);
        (,, uint256 altForged,,) = nft.forgeTokens(address(alt));
        assertEq(altForged, handler.altCount());
        assertLe(altForged, 67);
    }

    function invariant_marksAreImmutableAndTheFixedDeckIsNeverOverdrawn() public view {
        uint256[4] memory marks;
        for (uint256 i; i < handler.tokenCount(); ++i) {
            uint256 id = handler.tokenAt(i);
            uint8 m = uint8(nft.markOf(id));
            assertEq(m, handler.expectedMark(id));
            if (m == 0) {
                assertGt(nft.revealBlock(id), 0);
            } else {
                ++marks[m - 1];
                assertEq(nft.revealBlock(id), 0);
            }
        }
        uint256[4] memory caps = [uint256(640), 250, 100, 10];
        for (uint256 i; i < 4; ++i) {
            assertEq(nft.markCap(i), caps[i]);
            assertEq(nft.markRevealed(i), marks[i]);
            assertLe(marks[i], caps[i]);
        }
    }

    function invariant_paymentsAndReferralCountersMatchTheLedger() public view {
        assertEq(imd.balanceOf(handler.BURN()), handler.burnPaid());
        assertEq(imd.balanceOf(handler.SHRINE()), handler.shrinePaid());
        assertEq(imd.balanceOf(handler.PAYEE()), handler.payeePaid());
        assertEq(imd.balanceOf(handler.PAYEE2()), handler.payee2Paid());
        assertEq(alt.balanceOf(nft.DEAD()), handler.altBurnPaid());
        assertEq(alt.balanceOf(handler.PAYEE()), handler.altPayeePaid());
        for (uint256 i; i < 5; ++i) {
            address actor = i == 4 ? handler.OWNER() : handler.player(i);
            uint256 initial = i == 4 ? 0 : handler.INITIAL();
            assertEq(imd.balanceOf(actor), initial - handler.imdSpent(actor) + handler.imdReferred(actor));
            assertEq(alt.balanceOf(actor), initial - handler.altSpent(actor) + handler.altReferred(actor));
            assertEq(nft.referralCount(actor), handler.referrals(actor));
            assertEq(nft.referralEarned(actor), handler.imdReferred(actor));
        }
        assertEq(imd.balanceOf(address(nft)), 0, "no payment dust retained");
        assertEq(alt.balanceOf(address(nft)), 0, "no alternate payment dust retained");
    }

    function invariant_validActionsDoNotSilentlyRevert() public view {
        assertFalse(handler.unexpectedRevert(), "valid handler action reverted");
        assertGe(handler.successfulCalls(), 6);
    }

    /// Reveals follow forge order: the contract's head is the earliest-forged unrevealed soul in the model.
    function invariant_revealHeadIsTheEarliestForgedUnrevealedSoul() public view {
        assertEq(nft.nextToReveal(), handler.head());
    }

    function test_handlerExercisesTransfersMemorialsServicesAndStaleReveals() public {
        handler.transferSoul(1, 2, true);
        handler.buyService(1, 0, 0);
        handler.buyService(1, 1, 0);
        handler.buyService(1, 2, 1);
        handler.memorialize(1, keccak256("chronicle"));
        handler.transferSoul(1, 3, false);
        handler.revealSoul(2, 300);
        handler.revealSoul(2, 2);
        handler.setMintPhase(1);
        handler.forgeSoul(2, 1, 0);
        handler.setMintPhase(0);
        handler.forgeReserve(3);
        invariant_supplyOwnershipAndSoulIdentityAreConserved();
        invariant_marksAreImmutableAndTheFixedDeckIsNeverOverdrawn();
        invariant_paymentsAndReferralCountersMatchTheLedger();
        invariant_validActionsDoNotSilentlyRevert();
    }
}
