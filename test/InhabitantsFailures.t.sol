// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {GodsOfIMDInhabitants} from "src/GodsOfIMDInhabitants.sol";

contract FailingPaymentToken is ERC20 {
    address public refusedRecipient;
    constructor() ERC20("Payment test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function refuse(address recipient) external {
        refusedRecipient = recipient;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (to == refusedRecipient) return false;
        return super.transferFrom(from, to, value);
    }
}

contract ForgeReceiver is IERC721Receiver {
    GodsOfIMDInhabitants private immutable nft;
    bool private immutable reject;
    bool public nestedSucceeded;
    bytes public nestedError;

    constructor(GodsOfIMDInhabitants nft_, FailingPaymentToken token, bool reject_) {
        nft = nft_;
        reject = reject_;
        token.approve(address(nft_), type(uint256).max);
    }

    function forge() external returns (uint256) {
        return nft.forge(keccak256("receiver soul"), address(0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (reject) return bytes4(0);
        (nestedSucceeded, nestedError) =
            address(nft).call(abi.encodeCall(nft.forge, (keccak256("nested soul"), address(0))));
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract InhabitantsFailuresTest is Test {
    address private constant OWNER = address(0xA11CE);
    address private constant PLAYER = address(0x1001);
    address private constant FRIEND = address(0x1002);
    address private constant SHRINE = address(0x5100);
    address private constant BURN = address(0xB000);
    address private constant PAYEE1 = address(0xFA11);
    address private constant PAYEE2 = address(0xFA12);
    FailingPaymentToken private imd;
    FailingPaymentToken private alt;
    GodsOfIMDInhabitants private nft;

    function setUp() public {
        imd = new FailingPaymentToken();
        alt = new FailingPaymentToken();
        nft = new GodsOfIMDInhabitants(OWNER, imd, SHRINE, BURN);
        GodsOfIMDInhabitants.Payee[] memory payees = _payees(3000, 4000);
        vm.startPrank(OWNER);
        nft.setPayees(payees);
        nft.setPhase(GodsOfIMDInhabitants.Phase.Public);
        nft.setForgeToken(address(alt), 100 ether, 900, 3000, PAYEE2);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            address actor = i == 0 ? PLAYER : FRIEND;
            imd.mint(actor, 1_000 ether);
            alt.mint(actor, 1_000 ether);
            vm.startPrank(actor);
            imd.approve(address(nft), type(uint256).max);
            alt.approve(address(nft), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _payees(uint16 a, uint16 b) private pure returns (GodsOfIMDInhabitants.Payee[] memory p) {
        p = new GodsOfIMDInhabitants.Payee[](2);
        p[0] = GodsOfIMDInhabitants.Payee(PAYEE1, a);
        p[1] = GodsOfIMDInhabitants.Payee(PAYEE2, b);
    }

    function _forge(address actor, bytes32 soul) private returns (uint256 id) {
        vm.prank(actor);
        return nft.forge(soul, address(0));
    }

    function _emptySoul(address actor, bytes32 soul, uint256 id) private view {
        assertEq(nft.soulHashOf(id), bytes32(0));
        assertEq(nft.tokenOfSoul(keccak256(abi.encode(actor, soul))), 0);
        assertEq(nft.revealBlock(id), 0);
        assertEq(uint8(nft.markOf(id)), 0);
    }

    function testFuzz_latePaymentFailureRollsBackEveryMintPath(uint8 mode) public {
        mode = uint8(bound(mode, 0, 2));
        uint256 friendId = _forge(FRIEND, keccak256("referrer"));
        bytes32 soul = keccak256("failed soul");
        FailingPaymentToken payment = mode == 2 ? alt : imd;
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(PLAYER, uint256(25)))));
        vm.prank(OWNER);
        nft.setAllowlistRoot(root);
        uint256[6] memory balances = [
            payment.balanceOf(PLAYER),
            payment.balanceOf(FRIEND),
            payment.balanceOf(BURN),
            payment.balanceOf(SHRINE),
            payment.balanceOf(PAYEE1),
            payment.balanceOf(PAYEE2)
        ];
        uint256 deadBefore = payment.balanceOf(nft.DEAD());
        vm.prank(PLAYER);
        payment.approve(address(nft), 200 ether); // finite approval must roll back too
        payment.refuse(PAYEE2); // last transfer; the burn, treasury and referral transfers already ran
        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(payment)));
        if (mode == 0) nft.forge(soul, FRIEND);
        else if (mode == 1) nft.forgeAllowlist(soul, FRIEND, 25, new bytes32[](0));
        else nft.forgeWithToken(address(alt), soul, FRIEND);
        assertEq(payment.balanceOf(PLAYER), balances[0]);
        assertEq(payment.balanceOf(FRIEND), balances[1]);
        assertEq(payment.balanceOf(BURN), balances[2]);
        assertEq(payment.balanceOf(SHRINE), balances[3]);
        assertEq(payment.balanceOf(PAYEE1), balances[4]);
        assertEq(payment.balanceOf(PAYEE2), balances[5]);
        assertEq(payment.balanceOf(nft.DEAD()), deadBefore);
        assertEq(payment.allowance(PLAYER, address(nft)), 200 ether);
        assertEq(nft.totalForged(), 1);
        assertEq(nft.mintedBy(PLAYER), 0);
        assertEq(nft.allowlistMinted(PLAYER), 0);
        assertEq(nft.referralCount(FRIEND), 0);
        assertEq(nft.referralEarned(FRIEND), 0);
        (,, uint256 forged,,) = nft.forgeTokens(address(alt));
        assertEq(forged, 0);
        assertEq(nft.ownerOf(friendId), FRIEND);
        _emptySoul(PLAYER, soul, 2);
        payment.refuse(address(0));
        vm.prank(PLAYER);
        uint256 id = mode == 0
            ? nft.forge(soul, FRIEND)
            : mode == 1
                ? nft.forgeAllowlist(soul, FRIEND, 25, new bytes32[](0))
                : nft.forgeWithToken(address(alt), soul, FRIEND);
        assertEq(id, 2, "failed mint must not consume the next id");
    }

    function test_rejectingReceiverRollsBackTransfersAndRegistration() public {
        ForgeReceiver receiver = new ForgeReceiver(nft, imd, true);
        imd.mint(address(receiver), 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.forge();
        assertEq(imd.balanceOf(address(receiver)), 5 ether);
        assertEq(imd.balanceOf(BURN) + imd.balanceOf(SHRINE) + imd.balanceOf(PAYEE1) + imd.balanceOf(PAYEE2), 0);
        assertEq(nft.totalForged(), 0);
        assertEq(nft.balanceOf(address(receiver)), 0);
        assertEq(nft.mintedBy(address(receiver)), 0);
        _emptySoul(address(receiver), keccak256("receiver soul"), 1);
    }

    function test_receiverCannotReenterForgeButOuterMintSucceeds() public {
        ForgeReceiver receiver = new ForgeReceiver(nft, imd, false);
        imd.mint(address(receiver), 10 ether);
        assertEq(receiver.forge(), 1);
        assertFalse(receiver.nestedSucceeded());
        assertEq(receiver.nestedError(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(nft.totalForged(), 1);
        assertEq(nft.mintedBy(address(receiver)), 1);
        assertEq(imd.balanceOf(address(receiver)), 5 ether);
        _emptySoul(address(receiver), keccak256("nested soul"), 2);
    }

    function test_reservedBatchFailureDoesNotKeepEarlierMints() public {
        bytes32[] memory souls = new bytes32[](3);
        souls[0] = keccak256("reserved one");
        souls[1] = keccak256("reserved two");
        souls[2] = souls[0];
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.SoulAlreadyForged.selector, souls[0], uint256(901)));
        nft.forgeReservedMany(souls);
        assertEq(nft.reservedForged(), 0);
        assertEq(nft.totalForged(), 0);
        assertEq(nft.balanceOf(OWNER), 0);
        _emptySoul(OWNER, souls[0], 901);
        _emptySoul(OWNER, souls[1], 902);
        vm.prank(OWNER);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAmount.selector);
        nft.forgeReservedMany(new bytes32[](0));
    }

    function test_invalidPayeesAndSplitLeaveTheOriginalConfigurationIntact() public {
        GodsOfIMDInhabitants.Payee[] memory p = _payees(3000, 4000);
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.InvalidPayeeCount.selector, uint256(0)));
        nft.setPayees(new GodsOfIMDInhabitants.Payee[](0));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.InvalidPayeeCount.selector, uint256(11)));
        nft.setPayees(new GodsOfIMDInhabitants.Payee[](11));
        p[1].account = address(0);
        vm.expectRevert(GodsOfIMDInhabitants.ZeroAddress.selector);
        nft.setPayees(p);
        p[1].account = PAYEE1;
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.DuplicatePayee.selector, PAYEE1));
        nft.setPayees(p);
        p[1].account = PAYEE2;
        p[1].bps = 0;
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.ZeroPayeeBps.selector, uint256(1)));
        nft.setPayees(p);
        p[1].bps = 3999;
        vm.expectRevert(
            abi.encodeWithSelector(GodsOfIMDInhabitants.PayeeBpsMismatch.selector, uint256(6999), uint256(7000))
        );
        nft.setPayees(p);
        vm.expectRevert(
            abi.encodeWithSelector(GodsOfIMDInhabitants.InvalidSplit.selector, uint256(6000), uint256(4000))
        );
        nft.setSplit(6000, 4000, p);
        vm.expectRevert(
            abi.encodeWithSelector(GodsOfIMDInhabitants.InvalidReferralBps.selector, uint256(500), uint256(499))
        );
        nft.setSplit(9001, 500, p);
        vm.expectRevert(
            abi.encodeWithSelector(GodsOfIMDInhabitants.PayeeBpsMismatch.selector, uint256(6999), uint256(8000))
        );
        nft.setSplit(1000, 1000, p);
        vm.stopPrank();
        assertEq(nft.burnBps(), 2000);
        assertEq(nft.shrineBps(), 1000);
        p = nft.payees();
        assertEq(p.length, 2);
        assertEq(p[0].account, PAYEE1);
        assertEq(p[0].bps, 3000);
        assertEq(p[1].account, PAYEE2);
        assertEq(p[1].bps, 4000);
    }

    function testFuzz_forgeDistributesEveryWeiAcrossValidSplits(
        uint96 price,
        uint16 burned,
        uint16 treasury,
        bool referred
    ) public {
        uint256 paid = bound(price, 0, 100 ether);
        uint16 burnBps = uint16(bound(burned, 0, 9499));
        uint16 shrineBps = uint16(bound(treasury, 0, 9499 - burnBps));
        uint16 pool = 10_000 - burnBps - shrineBps;
        GodsOfIMDInhabitants.Payee[] memory p = _payees(pool / 2, pool - pool / 2);
        _forge(FRIEND, keccak256("friend"));
        vm.startPrank(OWNER);
        nft.setSplit(burnBps, shrineBps, p);
        nft.setPrices(paid, paid, 0.75 ether, 1 ether);
        vm.stopPrank();
        uint256[5] memory beforeBalances = [
            imd.balanceOf(BURN),
            imd.balanceOf(SHRINE),
            imd.balanceOf(PAYEE1),
            imd.balanceOf(PAYEE2),
            imd.balanceOf(FRIEND)
        ];
        vm.prank(PLAYER);
        nft.forge(keccak256("fuzz payment"), referred ? FRIEND : address(0));
        _assertPayment(paid, referred, beforeBalances);
    }

    function _assertPayment(uint256 paid, bool referred, uint256[5] memory beforeBalances) private view {
        uint256[5] memory delta = [
            imd.balanceOf(BURN) - beforeBalances[0],
            imd.balanceOf(SHRINE) - beforeBalances[1],
            imd.balanceOf(PAYEE1) - beforeBalances[2],
            imd.balanceOf(PAYEE2) - beforeBalances[3],
            imd.balanceOf(FRIEND) - beforeBalances[4]
        ];
        uint256 distributed;
        for (uint256 i; i < 5; ++i) {
            distributed += delta[i];
        }
        assertEq(distributed, paid, "payment conservation including dust");
        assertEq(imd.balanceOf(PLAYER), 1_000 ether - paid);
        assertEq(imd.balanceOf(address(nft)), 0);
        (uint256 b, uint256 s, uint256 payeesPaid, uint256 refPaid) = nft.previewSplit(paid, referred);
        assertEq(delta[0], b);
        assertEq(delta[1], s);
        assertEq(delta[4], refPaid);
        assertEq(delta[2] + delta[3], payeesPaid);
    }

    function test_oneWeiAndZeroPriceAreExact() public {
        vm.prank(OWNER);
        nft.setPrices(1, 0, 0, 0);
        _forge(PLAYER, keccak256("one wei"));
        assertEq(imd.balanceOf(PAYEE2), 1, "last payee receives rounding dust");
        assertEq(imd.balanceOf(BURN) + imd.balanceOf(SHRINE) + imd.balanceOf(PAYEE1), 0);
        vm.prank(OWNER);
        nft.setPrices(0, 0, 0, 0);
        uint256 id = _forge(PLAYER, keccak256("free soul"));
        vm.startPrank(PLAYER);
        imd.approve(address(nft), 0);
        nft.petition(id, bytes32(0));
        nft.commission(id, 0, bytes32(0));
        vm.stopPrank();
        assertEq(imd.balanceOf(PLAYER), 1_000 ether - 1);
        assertEq(nft.totalForged(), 2);
    }

    function testFuzz_serviceCostIsCappedByThePayment(uint96 price, uint96 cost, bool commission) public {
        uint256 paid = bound(price, 0, 100 ether);
        uint256 oracleCost = bound(cost, 0, 200 ether);
        uint256 id = _forge(PLAYER, keccak256("service soul"));
        vm.startPrank(OWNER);
        nft.setPrices(5 ether, 4 ether, paid, paid);
        nft.setOracleCost(oracleCost);
        vm.stopPrank();
        uint256 shrineBefore = imd.balanceOf(SHRINE);
        uint256 payeesBefore = imd.balanceOf(PAYEE1) + imd.balanceOf(PAYEE2);
        vm.prank(PLAYER);
        if (commission) nft.commission(id, 255, bytes32(0));
        else nft.petition(id, bytes32(0));
        uint256 treasuryDelta = imd.balanceOf(SHRINE) - shrineBefore;
        uint256 payeeDelta = imd.balanceOf(PAYEE1) + imd.balanceOf(PAYEE2) - payeesBefore;
        assertEq(treasuryDelta, paid < oracleCost ? paid : oracleCost);
        assertEq(treasuryDelta + payeeDelta, paid);
        assertEq(imd.balanceOf(PLAYER), 995 ether - paid);
    }

    function test_approvalDoesNotGrantGameOwnerRightsAndMemorialIsPermanent() public {
        uint256 id = _forge(PLAYER, keccak256("living soul"));
        vm.prank(PLAYER);
        nft.approve(FRIEND, id);
        vm.startPrank(FRIEND);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotTokenOwner.selector, id, FRIEND));
        nft.petition(id, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotTokenOwner.selector, id, FRIEND));
        nft.commission(id, 0, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.NotSteward.selector, FRIEND));
        nft.setMemorial(id, bytes32(0));
        vm.stopPrank();
        vm.prank(OWNER);
        nft.setMemorial(id, keccak256("chronicle"));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.AlreadyMemorial.selector, id));
        nft.setMemorial(id, bytes32(0));
        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.SoulIsMemorial.selector, id));
        nft.petition(id, bytes32(0));
        vm.prank(FRIEND);
        nft.transferFrom(PLAYER, FRIEND, id);
        assertTrue(nft.memorial(id));
        assertEq(nft.chronicleOf(id), keccak256("chronicle"));
        assertEq(nft.totalForged(), 1);
        assertEq(nft.ownerOf(id), FRIEND);
        vm.prank(FRIEND);
        nft.commission(id, 3, keccak256("memorial art"));
    }

    function test_ownerControlsRejectEveryPlayerCall() public {
        GodsOfIMDInhabitants.Payee[] memory p = _payees(3000, 4000);
        bytes[] memory calls = new bytes[](16);
        calls[0] = abi.encodeCall(nft.setPrices, (uint256(0), uint256(0), uint256(0), uint256(0)));
        calls[1] = abi.encodeCall(nft.setOracleCost, (uint256(0)));
        calls[2] = abi.encodeCall(nft.setRoyalty, (PLAYER, uint96(0)));
        calls[3] = abi.encodeCall(nft.setSplit, (uint16(2000), uint16(1000), p));
        calls[4] = abi.encodeCall(nft.setPayees, (p));
        calls[5] = abi.encodeCall(nft.setReferralBps, (uint16(0)));
        calls[6] = abi.encodeCall(nft.setAddresses, (PLAYER, PLAYER));
        calls[7] = abi.encodeCall(nft.setBaseURI, ("ipfs://changed/"));
        calls[8] = abi.encodeCall(nft.setSteward, (PLAYER));
        calls[9] = abi.encodeCall(nft.setPhase, (GodsOfIMDInhabitants.Phase.Closed));
        calls[10] = abi.encodeCall(nft.setAllowlistRoot, (bytes32(0)));
        calls[11] = abi.encodeCall(nft.setForgeToken, (address(alt), uint256(0), uint256(0), uint16(0), PLAYER));
        calls[12] = abi.encodeCall(nft.setMaxPerWallet, (uint256(0)));
        calls[13] = abi.encodeCall(nft.forgeReserved, (keccak256("stolen reserve")));
        calls[14] = abi.encodeCall(nft.transferOwnership, (PLAYER));
        calls[15] = abi.encodeCall(nft.renounceOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(PLAYER);
            (bool ok, bytes memory reason) = address(nft).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, PLAYER));
        }
        assertEq(nft.owner(), OWNER);
        assertEq(nft.steward(), OWNER);
        assertEq(nft.totalForged(), 0);
    }

    function test_metadataAndRoyaltiesRemainCompatibleWithTheirInterfaces() public {
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC2981
        assertTrue(nft.supportsInterface(0x49064906)); // ERC4906
        assertFalse(nft.supportsInterface(0xffffffff));
        uint256 id = _forge(PLAYER, keccak256("metadata soul"));
        assertEq(nft.tokenURI(id), "");
        vm.startPrank(OWNER);
        nft.setBaseURI("ipfs://test-metadata/");
        nft.setRoyalty(PAYEE1, 1000);
        vm.stopPrank();
        assertEq(nft.tokenURI(id), "ipfs://test-metadata/1");
        (address receiver, uint256 amount) = nft.royaltyInfo(id, 101);
        assertEq(receiver, PAYEE1);
        assertEq(amount, 10);
        assertEq(nft.royaltyReceiver(), PAYEE1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(2)));
        nft.tokenURI(2);
        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC2981.ERC2981InvalidDefaultRoyalty.selector, uint256(10_001), uint256(10_000))
        );
        nft.setRoyalty(PAYEE2, 10_001);
        vm.expectRevert(abi.encodeWithSelector(ERC2981.ERC2981InvalidDefaultRoyaltyReceiver.selector, address(0)));
        nft.setRoyalty(address(0), 500);
        vm.stopPrank();
        assertEq(nft.royaltyReceiver(), PAYEE1);
    }

    function test_allowlistRootChangesDoNotResetConsumedSlots() public {
        bytes32 one = keccak256(bytes.concat(keccak256(abi.encode(PLAYER, uint256(1)))));
        vm.prank(OWNER);
        nft.setAllowlistRoot(one);
        vm.prank(PLAYER);
        nft.forgeAllowlist(keccak256("first discounted soul"), address(0), 1, new bytes32[](0));
        vm.startPrank(OWNER);
        nft.setAllowlistRoot(bytes32(0));
        nft.setAllowlistRoot(one);
        vm.stopPrank();
        vm.prank(PLAYER);
        vm.expectRevert(abi.encodeWithSelector(GodsOfIMDInhabitants.AllowlistCapReached.selector, PLAYER, uint256(1)));
        nft.forgeAllowlist(keccak256("second discounted soul"), address(0), 1, new bytes32[](0));
        bytes32 two = keccak256(bytes.concat(keccak256(abi.encode(PLAYER, uint256(2)))));
        vm.prank(OWNER);
        nft.setAllowlistRoot(two);
        vm.prank(PLAYER);
        nft.forgeAllowlist(keccak256("second discounted soul"), address(0), 2, new bytes32[](0));
        assertEq(nft.allowlistMinted(PLAYER), 2);
        assertEq(imd.balanceOf(PLAYER), 992 ether);
    }
}
