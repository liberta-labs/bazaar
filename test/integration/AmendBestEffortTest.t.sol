// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AmendTestBase} from "./AmendTestBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {OrderBookLib} from "../../src/libraries/OrderBookLib.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {OrderView} from "../OrderView.sol";

/// @title AmendBestEffortTest
/// @notice A best-effort amendment (bit 192 of its id word) is skipped, and reported by
///         OrderAmendSkipped, when it fails one of five checks — its order is filled, canceled or
///         out of the book; it has expired; the size asked for is at or below what has filled; that
///         size leaves a remainder under the floor; the new price would cross — and the rest of the
///         batch goes through. A skip leaves the order as it was, whoever tripped the check. Every
///         other refusal, and the margin verdict on the set the batch leaves, reverts the batch
///         whatever the flag; the flag is part of the signed word.
contract AmendBestEffortTest is AmendTestBase {
    function _flagged(uint256 orderId) internal pure returns (uint256) {
        return orderId | BazaarTypes.AMEND_BEST_EFFORT_BIT;
    }

    /// @dev Alice's two bids and one ask, all well funded.
    function _ladder() internal returns (uint256 bidHigh, uint256 bidLow, uint256 ask) {
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        bidHigh = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        bidLow = _placeLimit(alice, true, SIZE, 48_000 * BAZAAR_SCALE);
        ask = _placeLimit(alice, false, SIZE, 51_000 * BAZAAR_SCALE);
    }

    /// @dev Bob sells `size` into alice's best bid.
    function _bobSells(uint256 size) internal {
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        _roll(1);
        _placeLimit(bob, false, size, 47_000 * BAZAAR_SCALE);
    }

    function _skips(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == BazaarTypes.OrderAmendSkipped.selector) ++n;
        }
    }

    function _skipReason(Vm.Log[] memory logs, uint256 orderId) internal returns (BazaarTypes.AmendSkipReason r) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != BazaarTypes.OrderAmendSkipped.selector) continue;
            if (uint256(logs[i].topics[2]) != orderId) continue;
            assertEq(address(uint160(uint256(logs[i].topics[3]))), alice, "skip names the owner");
            r = abi.decode(logs[i].data, (BazaarTypes.AmendSkipReason));
            ++n;
        }
        assertEq(n, 1, "exactly one skip reported for the order");
    }

    function _amended(Vm.Log[] memory logs, uint256 orderId) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == BazaarTypes.OrderAmended.selector && uint256(logs[i].topics[2]) == orderId) ++n;
        }
    }

    /// @dev Everything an amendment could change about an order, as one word.
    function _fingerprint(uint256 orderId) internal view returns (bytes32) {
        BazaarTypes.Order memory o = OrderView.order(pair, orderId);
        return keccak256(
            abi.encode(
                o.limitPrice,
                o.size,
                o.prioritySeq,
                o.restedBlock,
                o.restedPremiumPpm,
                o.prevInBook,
                o.nextInBook,
                o.inBook
            )
        );
    }

    // ---------------------------- crossing ----------------------------

    /// @notice The ask is moved down first, then a bid is moved through it: with the flag the bid
    ///         is skipped and the two other amendments apply.
    function test_crossing_flagged_skipsThatOrderAndAppliesTheRest() public {
        (uint256 bidHigh, uint256 bidLow, uint256 ask) = _ladder();
        bytes32 before = _fingerprint(bidLow);
        uint256 counter = lens.nextOrderId(address(pair));

        Batch memory b = _batch(3);
        _set(b, 0, _flagged(ask), 50_900 * BAZAAR_SCALE, SIZE);
        _set(b, 1, _flagged(bidHigh), 49_100 * BAZAAR_SCALE, SIZE);
        _set(b, 2, _flagged(bidLow), 51_500 * BAZAAR_SCALE, SIZE); // through the ask just moved to 50,900
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(OrderView.order(pair, ask).limitPrice, 50_900 * BAZAAR_SCALE, "the ask moved");
        assertEq(OrderView.order(pair, bidHigh).limitPrice, 49_100 * BAZAAR_SCALE, "the high bid moved");
        assertEq(_fingerprint(bidLow), before, "the crossing bid stands exactly as it was");
        assertEq(uint8(_skipReason(logs, bidLow)), uint8(BazaarTypes.AmendSkipReason.WouldCross), "reason");
        assertEq(_skips(logs), 1, "one skip");
        assertEq(_amended(logs, bidLow), 0, "no OrderAmended for the skipped order");
        assertEq(_amended(logs, ask) + _amended(logs, bidHigh), 2, "the two applied amendments reported");
        assertEq(lens.nextOrderId(address(pair)), counter + 2, "a skip draws no queue position");

        BazaarTypes.RestingTally memory t = lens.restingTally(address(pair), alice);
        assertEq(t.bidLimitNotional, (49_100 + 48_000) * SIZE, "the tally holds the applied bid and the untouched one");
        assertEq(t.askLimitNotional, 50_900 * SIZE, "and the moved ask");
        _assertSideWellFormed(true, 2);
        _assertSideWellFormed(false, 1);
    }

    /// @notice Without the flag the same batch reverts whole and nothing moves.
    function test_crossing_unflagged_revertsTheBatch() public {
        (uint256 bidHigh, uint256 bidLow, uint256 ask) = _ladder();
        Batch memory b = _batch(3);
        _set(b, 0, ask, 50_900 * BAZAAR_SCALE, SIZE);
        _set(b, 1, bidHigh, 49_100 * BAZAAR_SCALE, SIZE);
        _set(b, 2, bidLow, 51_500 * BAZAAR_SCALE, SIZE);
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__AmendWouldCross.selector);
        pair.amendOrders(b.words, pu, 0, 0, 0, "", "");
        assertEq(OrderView.order(pair, ask).limitPrice, 51_000 * BAZAAR_SCALE, "nothing moved");
        assertEq(OrderView.order(pair, bidHigh).limitPrice, 49_000 * BAZAAR_SCALE, "nothing moved");
    }

    // ---------------------------- the other four checks ----------------------------

    /// @notice An order a taker filled before the batch landed is skipped as inactive.
    function test_filled_flagged_skipped() public {
        (uint256 bidHigh, uint256 bidLow,) = _ladder();
        _bobSells(SIZE);
        assertGt(OrderView.order(pair, bidHigh).filledBlock, 0, "fixture: the high bid filled");

        Batch memory b = _batch(2);
        _set(b, 0, _flagged(bidHigh), 48_900 * BAZAAR_SCALE, SIZE);
        _set(b, 1, _flagged(bidLow), 47_900 * BAZAAR_SCALE, SIZE);
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(_skipReason(logs, bidHigh)), uint8(BazaarTypes.AmendSkipReason.Inactive), "reason");
        assertEq(OrderView.order(pair, bidLow).limitPrice, 47_900 * BAZAAR_SCALE, "the live bid moved");
    }

    /// @notice An order canceled before the batch landed is skipped as inactive.
    function test_canceled_flagged_skipped() public {
        (uint256 bidHigh, uint256 bidLow,) = _ladder();
        uint256[] memory ids = new uint256[](1);
        ids[0] = bidHigh;
        vm.prank(alice);
        pair.cancelOrders(ids, 0, 0, 0, "", "");

        Batch memory b = _batch(2);
        _set(b, 0, _flagged(bidHigh), 48_900 * BAZAAR_SCALE, SIZE);
        _set(b, 1, _flagged(bidLow), 47_900 * BAZAAR_SCALE, SIZE);
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(_skipReason(logs, bidHigh)), uint8(BazaarTypes.AmendSkipReason.Inactive), "reason");
        assertEq(OrderView.order(pair, bidHigh).limitPrice, 49_000 * BAZAAR_SCALE, "the canceled order stands");
        assertEq(OrderView.order(pair, bidLow).limitPrice, 47_900 * BAZAAR_SCALE, "the live bid moved");
    }

    /// @notice An order filled to or past the size the amendment asks for is skipped; the same
    ///         amendment unflagged reverts. A skip cancels nothing, so what remains still rests at
    ///         its old price, more than the shrink asked to leave open.
    function test_sizeAtOrBelowFilled_flagged_skipped() public {
        (uint256 bidHigh,,) = _ladder();
        _bobSells(SIZE * 6 / 10);
        assertEq(OrderView.order(pair, bidHigh).filledSize, SIZE * 6 / 10, "fixture: 60% filled");
        bytes32 before = _fingerprint(bidHigh);

        Batch memory b = _single(_flagged(bidHigh), 49_000 * BAZAAR_SCALE, SIZE / 2);
        vm.recordLogs();
        _amendAs(alice, b);
        assertEq(uint8(_skipReason(vm.getRecordedLogs(), bidHigh)), uint8(BazaarTypes.AmendSkipReason.SizeFilled));
        assertEq(_fingerprint(bidHigh), before, "the order stands exactly as it was");
        assertTrue(OrderView.order(pair, bidHigh).inBook, "the remainder still rests");

        b = _single(_flagged(bidHigh), 49_000 * BAZAAR_SCALE, SIZE * 6 / 10);
        vm.recordLogs();
        _amendAs(alice, b);
        assertEq(
            uint8(_skipReason(vm.getRecordedLogs(), bidHigh)),
            uint8(BazaarTypes.AmendSkipReason.SizeFilled),
            "exactly what has filled is skipped too"
        );

        b = _single(bidHigh, 49_000 * BAZAAR_SCALE, SIZE / 2);
        _amendExpect(
            alice,
            b,
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__AmendSizeNotAboveFilled.selector, bidHigh)
        );
    }

    /// @notice A fill that leaves less than the floor above what has filled, at the size the batch
    ///         asks for, is skipped; the same amendment unflagged reverts. The remainder is what
    ///         would be written, and a skip writes nothing.
    function test_remainderUnderTheFloor_flagged_skipped() public {
        (uint256 bidHigh,,) = _ladder();
        _bobSells(SIZE - SIZE / 1_000); // 0.0999 of 0.1: $4.90 left at 49k, under the $5 floor
        assertEq(OrderView.order(pair, bidHigh).filledSize, SIZE - SIZE / 1_000, "fixture: 99.9% filled");
        bytes32 before = _fingerprint(bidHigh);

        Batch memory b = _single(_flagged(bidHigh), 48_900 * BAZAAR_SCALE, SIZE);
        vm.recordLogs();
        _amendAs(alice, b);
        assertEq(uint8(_skipReason(vm.getRecordedLogs(), bidHigh)), uint8(BazaarTypes.AmendSkipReason.BelowMinimum));
        assertEq(_fingerprint(bidHigh), before, "the order stands exactly as it was");

        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__NotionalBelowMinimum.selector);
        pair.amendOrders(_single(bidHigh, 48_900 * BAZAAR_SCALE, SIZE).words, pu, 0, 0, 0, "", "");
    }

    /// @notice An order whose expiry passed is skipped; the batch's other amendment applies.
    function test_expired_flagged_skipped() public {
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s = _limitSpec(true, SIZE, 49_000 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 dying = _lastCreatedOrderId(pair);
        uint256 living = _placeLimit(alice, true, SIZE, 48_000 * BAZAAR_SCALE);
        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);

        Batch memory b = _batch(2);
        _set(b, 0, _flagged(dying), 48_900 * BAZAAR_SCALE, SIZE);
        _set(b, 1, _flagged(living), 47_900 * BAZAAR_SCALE, SIZE);
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(_skipReason(logs, dying)), uint8(BazaarTypes.AmendSkipReason.Expired), "reason");
        assertEq(OrderView.order(pair, dying).limitPrice, 49_000 * BAZAAR_SCALE, "the expired order stands");
        assertTrue(OrderView.order(pair, dying).inBook, "still linked: the bound cleared, so nothing pruned");
        assertEq(OrderView.order(pair, living).limitPrice, 47_900 * BAZAAR_SCALE, "the live one moved");
    }

    /// @notice A skip reports the amendment, not the order's last state in the transaction: when
    ///         the bound does not clear, the margin gate prunes the order just skipped as expired.
    function test_expired_skippedThenPrunedByTheGate() public {
        (uint256 imrBp,,,) = pair.marginRequirements();
        _deposit(alice, imrBp * (SIZE * 160_000) / BazaarTypes.BP_SCALE);
        BazaarTypes.OrderSpec memory s = _limitSpec(true, 2 * SIZE, 49_000 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 dying = _lastCreatedOrderId(pair);
        uint256 living = _placeLimit(alice, true, SIZE, 48_000 * BAZAAR_SCALE);
        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);

        // The tally still holds the expired 2 x 49k, so the grown 1.5 x 48k takes the bound past
        // what the deposit covers and the gate reads the set instead.
        Batch memory b = _batch(2);
        _set(b, 0, _flagged(dying), 48_900 * BAZAAR_SCALE, 2 * SIZE);
        _set(b, 1, _flagged(living), 48_000 * BAZAAR_SCALE, SIZE * 3 / 2);
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(_skipReason(logs, dying)), uint8(BazaarTypes.AmendSkipReason.Expired), "reason");
        assertEq(_amended(logs, dying), 0, "the skip applied nothing");
        assertFalse(OrderView.order(pair, dying).inBook, "the gate pruned it");
        assertEq(OrderView.order(pair, dying).limitPrice, 49_000 * BAZAAR_SCALE, "at the price it had");
        assertEq(OrderView.order(pair, living).size, SIZE * 3 / 2, "the live one grew");
        assertEq(
            lens.restingTally(address(pair), alice).bidLimitNotional, 48_000 * SIZE * 3 / 2, "the tally reads the set"
        );
    }

    // ---------------------------- whoever tripped the check ----------------------------

    /// @notice An owner's own sub-floor size skips when flagged, with no fill involved: the check
    ///         does not ask who tripped it. Unflagged it reverts.
    function test_ownSubFloor_flagged_skipped() public {
        (uint256 bidHigh,,) = _ladder();
        bytes32 before = _fingerprint(bidHigh);
        uint256 subFloor = BTC / 100_000; // $0.49 at 49k

        vm.recordLogs();
        _amendAs(alice, _single(_flagged(bidHigh), 49_000 * BAZAAR_SCALE, subFloor));
        assertEq(uint8(_skipReason(vm.getRecordedLogs(), bidHigh)), uint8(BazaarTypes.AmendSkipReason.BelowMinimum));
        assertEq(_fingerprint(bidHigh), before, "the order stands exactly as it was");

        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__NotionalBelowMinimum.selector);
        pair.amendOrders(_single(bidHigh, 49_000 * BAZAAR_SCALE, subFloor).words, pu, 0, 0, 0, "", "");
    }

    /// @notice A flagged size of zero is not a cancel: it skips and the order goes on resting.
    function test_zeroSize_flagged_skippedAndCancelsNothing() public {
        (uint256 bidHigh,,) = _ladder();
        bytes32 before = _fingerprint(bidHigh);

        vm.recordLogs();
        _amendAs(alice, _single(_flagged(bidHigh), 49_000 * BAZAAR_SCALE, 0));
        assertEq(uint8(_skipReason(vm.getRecordedLogs(), bidHigh)), uint8(BazaarTypes.AmendSkipReason.SizeFilled));
        assertEq(_fingerprint(bidHigh), before, "the order stands exactly as it was");
        assertTrue(OrderView.order(pair, bidHigh).inBook, "and still rests");
    }

    /// @notice The full-close exemption holds with the flag set: a sub-floor remainder equal to the
    ///         opposite position applies, and one that does not close it whole is skipped.
    function test_fullCloseExemption_flagged() public {
        uint256 tiny = BTC / 1_000;
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, tiny, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, tiny, 47_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, tiny, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(alice, false, tiny * 91 / 100, 47_000 * BAZAAR_SCALE);
        uint256 left = tiny * 9 / 100; // $4.59 at 51k, under the floor
        assertEq(_posSize(alice), left, "fixture: alice long what is left");
        uint256 ask = _placeLimit(alice, false, tiny, 51_000 * BAZAAR_SCALE);

        vm.recordLogs();
        _amendAs(alice, _single(_flagged(ask), 51_000 * BAZAAR_SCALE, tiny * 8 / 100));
        assertEq(uint8(_skipReason(vm.getRecordedLogs(), ask)), uint8(BazaarTypes.AmendSkipReason.BelowMinimum));
        assertEq(OrderView.order(pair, ask).size, tiny, "a partial close under the floor is skipped");

        vm.recordLogs();
        _amendAs(alice, _single(_flagged(ask), 51_000 * BAZAAR_SCALE, left));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_skips(logs), 0, "a full close is not skipped");
        assertEq(_amended(logs, ask), 1, "it applies");
        assertEq(OrderView.order(pair, ask).size, left, "at the position's size");
    }

    // ---------------------------- batches of skips ----------------------------

    /// @notice Each amendment is judged when the batch reaches it: one skipped as crossing can apply
    ///         later in the same batch, once the ask has moved out of its way.
    function test_duplicateId_skippedThenApplied() public {
        (uint256 bidHigh,, uint256 ask) = _ladder();
        Batch memory b = _batch(3);
        _set(b, 0, _flagged(bidHigh), 51_500 * BAZAAR_SCALE, SIZE); // through the ask at 51,000
        _set(b, 1, _flagged(ask), 52_000 * BAZAAR_SCALE, SIZE);
        _set(b, 2, _flagged(bidHigh), 51_500 * BAZAAR_SCALE, SIZE);
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            uint8(_skipReason(logs, bidHigh)), uint8(BazaarTypes.AmendSkipReason.WouldCross), "the first is skipped"
        );
        assertEq(_amended(logs, bidHigh), 1, "the second applies");
        assertEq(OrderView.order(pair, bidHigh).limitPrice, 51_500 * BAZAAR_SCALE, "at the new price");
        _assertSideWellFormed(true, 2);
        _assertSideWellFormed(false, 1);
    }

    /// @notice A batch whose every amendment is skipped succeeds and moves nothing.
    function test_allSkipped_changesNothing() public {
        (uint256 bidHigh, uint256 bidLow, uint256 ask) = _ladder();
        bytes32 high = _fingerprint(bidHigh);
        bytes32 low = _fingerprint(bidLow);
        bytes32 asked = _fingerprint(ask);
        bytes32 links = _links();
        uint256 counter = lens.nextOrderId(address(pair));
        BazaarTypes.RestingTally memory t0 = lens.restingTally(address(pair), alice);

        Batch memory b = _batch(3);
        _set(b, 0, _flagged(bidLow), 51_500 * BAZAAR_SCALE, SIZE); // crosses
        _set(b, 1, _flagged(bidHigh), 49_000 * BAZAAR_SCALE, 0);
        _set(b, 2, _flagged(ask), 51_000 * BAZAAR_SCALE, BTC / 100_000); // under the floor
        vm.recordLogs();
        _amendAs(alice, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_skips(logs), 3, "all three skipped");
        assertEq(_amended(logs, bidHigh) + _amended(logs, bidLow) + _amended(logs, ask), 0, "none applied");
        assertEq(_fingerprint(bidHigh), high, "the high bid stands");
        assertEq(_fingerprint(bidLow), low, "the low bid stands");
        assertEq(_fingerprint(ask), asked, "the ask stands");
        assertEq(_links(), links, "the book's links stand");
        assertEq(lens.nextOrderId(address(pair)), counter, "no queue position drawn");
        BazaarTypes.RestingTally memory t1 = lens.restingTally(address(pair), alice);
        assertEq(t1.bidLimitNotional, t0.bidLimitNotional, "the bid tally stands");
        assertEq(t1.askLimitNotional, t0.askLimitNotional, "the ask tally stands");
    }

    // ---------------------------- what the flag does not excuse ----------------------------

    /// @notice A refusal outside the five reverts the batch with the flag set: an unknown order,
    ///         another owner's order, a price outside the band, a zero price, a move too close to
    ///         expiry.
    function test_otherRefusals_flagged_stillRevert() public {
        (uint256 bidHigh,,) = _ladder();
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        uint256 bobs = _placeLimit(bob, true, SIZE, 47_000 * BAZAAR_SCALE);

        _amendExpect(
            alice,
            _single(_flagged(999_999), 46_900 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderNotFound.selector, 999_999)
        );
        _amendExpect(
            alice,
            _single(_flagged(bobs), 46_900 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__RequestorIsNotOrderOwner.selector, bobs, alice
            )
        );
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__LimitPriceOutsidePlacementBand.selector);
        pair.amendOrders(_single(_flagged(bidHigh), 10_000 * BAZAAR_SCALE, SIZE).words, pu, 0, 0, 0, "", "");
        _amendExpect(
            alice,
            _single(_flagged(bidHigh), 0, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__ZeroLimitPrice.selector)
        );

        BazaarTypes.OrderSpec memory s = _limitSpec(true, SIZE, 48_500 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 shortLived = _lastCreatedOrderId(pair);
        _roll(1);
        pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__AmendTooCloseToExpiry.selector);
        pair.amendOrders(_single(_flagged(shortLived), 48_400 * BAZAAR_SCALE, SIZE).words, pu, 0, 0, 0, "", "");
    }

    /// @notice A move the hint walk cannot reach reverts with the flag set: the walk gives up after
    ///         the unlink, and the revert leaves the order where it was.
    function test_hintWalkExhausted_flagged_stillReverts() public {
        (uint256 a,) = _ladderBelowAlice();
        _amendExpect(
            alice,
            _single(_flagged(a), 48_000 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderBookLib.OrderBookLib__HintRepairExhausted.selector, a)
        );
        assertEq(_bidHead(), uint64(a), "still resting at the head");
    }

    /// @notice The margin verdict on the set the batch leaves is not skipped.
    function test_marginGate_flagged_stillReverts() public {
        (uint256 imrBp,,,) = pair.marginRequirements();
        // Enough for one bid at 49k, not for twice its size.
        _deposit(alice, imrBp * (SIZE * 49_000) / BazaarTypes.BP_SCALE * 3 / 2);
        uint256 bid = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector);
        pair.amendOrders(_single(_flagged(bid), 49_000 * BAZAAR_SCALE, 2 * SIZE).words, pu, 0, 0, 0, "", "");
    }

    /// @notice The verdict judges the set the batch leaves, not the set it asked for: a skipped
    ///         shrink stays in that set at its old size, so it can refuse the grow beside it. With
    ///         the shrink applied the same batch passes.
    function test_marginGate_skippedShrinkCountsAtItsOldSize() public {
        (uint256 imrBp,,,) = pair.marginRequirements();
        _deposit(alice, imrBp * (SIZE * 170_000) / BazaarTypes.BP_SCALE);
        uint256 big = _placeLimit(alice, true, 2 * SIZE, 49_000 * BAZAAR_SCALE);
        uint256 small = _placeLimit(alice, true, SIZE, 48_000 * BAZAAR_SCALE);
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        uint256 bobsAsk = _placeLimit(bob, false, SIZE, 49_500 * BAZAAR_SCALE);

        Batch memory b = _batch(2);
        _set(b, 0, _flagged(big), 49_600 * BAZAAR_SCALE, SIZE); // the shrink, priced through bob's ask
        _set(b, 1, _flagged(small), 48_000 * BAZAAR_SCALE, 2 * SIZE);
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector);
        pair.amendOrders(b.words, pu, 0, 0, 0, "", "");
        assertEq(OrderView.order(pair, small).size, SIZE, "the revert undid the grow");

        uint256[] memory ids = new uint256[](1);
        ids[0] = bobsAsk;
        vm.prank(bob);
        pair.cancelOrders(ids, 0, 0, 0, "", "");
        _amendAs(alice, b);
        assertEq(OrderView.order(pair, big).size, SIZE, "the shrink applied");
        assertEq(OrderView.order(pair, small).size, 2 * SIZE, "and the grow beside it");
    }

    /// @notice Bits above the flag have no meaning.
    function test_idWord_bitsAboveTheFlag_refused() public {
        (uint256 bidHigh,,) = _ladder();
        bytes memory err = abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__InvalidAmendBatch.selector);
        Batch memory b = _single(bidHigh, 48_500 * BAZAAR_SCALE, SIZE);
        b.words[0] = _flagged(bidHigh) | (uint256(1) << 193);
        _amendExpect(alice, b, err);
        b.words[0] = bidHigh | (uint256(1) << 255);
        _amendExpect(alice, b, err);
    }

    // ---------------------------- relayed ----------------------------

    function _structHash(Batch memory b, uint256 nonce, uint256 deadline, uint256 fee) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(MetaTxLib.AMEND_ORDERS_TYPEHASH, keccak256(abi.encodePacked(b.words)), nonce, deadline, fee)
        );
    }

    function _sign(Batch memory b, uint256 pk, uint256 nonce, uint256 deadline, uint256 fee)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), _structHash(b, nonce, deadline, fee));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev A funded signer with one resting bid at 49k and one ask at 51k.
    function _signerWithQuotes() internal returns (address signer, uint256 pk, uint256 bid, uint256 ask) {
        (signer, pk) = makeAddrAndKey("maker");
        usdc.mint(signer, 1_000_000 * USDC_SCALE);
        _deposit(signer, 100_000 * BAZAAR_SCALE);
        bid = _placeLimit(signer, true, SIZE, 49_000 * BAZAAR_SCALE);
        ask = _placeLimit(signer, false, SIZE, 51_000 * BAZAAR_SCALE);
    }

    /// @notice As signed, a relayed crossing amendment is skipped, the one beside it applies, and
    ///         the nonce is consumed.
    function test_relayed_flagged_skipsAndConsumesTheNonce() public {
        (address signer, uint256 pk, uint256 bid, uint256 ask) = _signerWithQuotes();

        Batch memory batch = _batch(2);
        _set(batch, 0, _flagged(ask), 50_900 * BAZAAR_SCALE, SIZE);
        _set(batch, 1, _flagged(bid), 51_500 * BAZAAR_SCALE, SIZE); // crosses the moved ask
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig = _sign(batch, pk, nonce, deadline, 0);

        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(seq);
        pair.amendOrders(batch.words, pu, nonce, deadline, 0, sig, "");
        assertEq(OrderView.order(pair, ask).limitPrice, 50_900 * BAZAAR_SCALE, "the ask moved for the signer");
        assertEq(OrderView.order(pair, bid).limitPrice, 49_000 * BAZAAR_SCALE, "the crossing bid stands");
        assertEq(_skips(vm.getRecordedLogs()), 1, "one skip reported");
        assertEq(pair.metaTxNonces(signer), nonce + 1, "the nonce is consumed by the batch that went through");
    }

    /// @notice A relayed batch whose every amendment is skipped still consumes the nonce and pays
    ///         the relayer: the fee is for carrying the batch, not for its effect.
    function test_relayed_allSkipped_paysTheFeeAndConsumesTheNonce() public {
        (address signer, uint256 pk, uint256 bid,) = _signerWithQuotes();
        bytes32 before = _fingerprint(bid);

        Batch memory batch = _single(_flagged(bid), 51_500 * BAZAAR_SCALE, SIZE); // crosses the ask
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        uint256 fee = BAZAAR_SCALE / 2;
        bytes memory sig = _sign(batch, pk, nonce, deadline, fee);
        vm.prank(signer);
        usdc.approve(address(pair), fee * USDC_SCALE / BAZAAR_SCALE);
        uint256 walletBefore = usdc.balanceOf(signer);

        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(seq);
        pair.amendOrders(batch.words, pu, nonce, deadline, fee, sig, "");

        assertEq(_skips(vm.getRecordedLogs()), 1, "the one amendment skipped");
        assertEq(_fingerprint(bid), before, "the order stands exactly as it was");
        assertEq(walletBefore - usdc.balanceOf(signer), fee * USDC_SCALE / BAZAAR_SCALE, "fee pulled from the wallet");
        assertEq(_escrowOwed(seq), fee, "and owed to the relayer");
        assertEq(pair.metaTxNonces(signer), nonce + 1, "nonce consumed");
    }

    /// @notice A batch signed with the flag cannot have it cleared by its relayer: the words no
    ///         longer match the signature, so a different signer recovers, who owns none of the
    ///         orders. The amendment would apply either way, so the signature is what refuses it.
    function test_relayed_flagCannotBeCleared() public {
        (address signer, uint256 pk, uint256 bid,) = _signerWithQuotes();

        Batch memory batch = _single(_flagged(bid), 48_900 * BAZAAR_SCALE, SIZE);
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig = _sign(batch, pk, nonce, deadline, 0);

        batch.words[0] = bid;
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__RequestorIsNotOrderOwner.selector);
        pair.amendOrders(batch.words, pu, nonce, deadline, 0, sig, "");
        assertEq(OrderView.order(pair, bid).limitPrice, 49_000 * BAZAAR_SCALE, "nothing moved");
    }

    /// @notice A batch signed without the flag cannot be given one by its relayer, for the same
    ///         reason.
    function test_relayed_flagCannotBeAdded() public {
        (address signer, uint256 pk, uint256 bid,) = _signerWithQuotes();

        Batch memory batch = _single(bid, 48_900 * BAZAAR_SCALE, SIZE);
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig = _sign(batch, pk, nonce, deadline, 0);

        batch.words[0] = _flagged(bid);
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__RequestorIsNotOrderOwner.selector);
        pair.amendOrders(batch.words, pu, nonce, deadline, 0, sig, "");
        assertEq(OrderView.order(pair, bid).limitPrice, 49_000 * BAZAAR_SCALE, "nothing moved");
    }

    // ---------------------------- lens ----------------------------

    function test_lens_bestEffortAmendIdWord() public view {
        assertEq(lens.bestEffortAmendIdWord(7, 3, 0), _word(7, 3, 0) | BazaarTypes.AMEND_BEST_EFFORT_BIT);
        assertEq(lens.bestEffortAmendIdWord(7, 3, 0) >> 192, 1, "exactly the flag above the hints");
        assertEq(lens.amendIdWord(7, 3, 0) >> 192, 0, "the plain word carries no flag");
    }
}
