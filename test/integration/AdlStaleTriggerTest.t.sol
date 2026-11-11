// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BucketStore} from "../BucketStore.sol";
import {VaultStore} from "../VaultStore.sol";

/// @title AdlStaleTriggerTest
/// @notice Opening an ADL window requires a fresh price. What an auction is judged by is fixed
///         when it opens — the 24h termination clock and the epoch its deposit tags are keyed to —
///         so a window opened against a stale mark would deleverage profitable counterparties in
///         response to exposure that may no longer exist.
///
///         A seizure on the stale fallback still commits, into the vault's bucket on the estate's
///         own side. Both of a batch's legs rank their cohort at the price the batch resolves, so
///         a bucket seeded on the side opposite the inventory while a window is open changes
///         nothing about that window: no epoch bump, no decay restart, no clock moved.
///
///         The tests hand the vault an identical deep-underwater inheritance on the
///         non-continuously-traded AAPL pair (the only kind that can resolve a stale price at all).
///         Where a test pairs a stale call with a fresh one, the single difference is the price's
///         freshness, which isolates the suppression from the size of the exposure.
contract AdlStaleTriggerTest is IntegrationBase {
    uint256 constant MARK = 150; // recorded AAPL mark, whole dollars
    uint256 constant POS_SIZE = 100 * BAZAAR_SCALE;
    uint256 constant POS_COLLATERAL = 10 * BAZAAR_SCALE;
    uint256 constant ADL_TERMINATION_GRACE = BazaarTypes.ADL_TERMINATION_GRACE;

    function _aaplInsurance() internal view returns (uint256 b) {
        (,,,,, b,,,,,,) = aaplPair.pairVault();
    }

    function _aaplInventorySize() internal view returns (uint256 s) {
        s = VaultStore.inventorySize(address(aaplPair));
    }

    /// @dev The AAPL vault's two buckets.
    function _aaplBuckets() internal view returns (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) {
        (,,,,,,,,,, l, s) = aaplPair.pairVault();
    }

    /// @dev What netting the two buckets' overlap would cost the fund beyond the two netted
    ///      slices' seizure (RiskParamsLib.overlap): the gap between the sides' entry bases on the
    ///      overlap plus the offset of their entry clocks, less the seizure pro rata. 0 when the
    ///      netting is a gain or either bucket is empty.
    function _overlapUncovered() internal view returns (uint256) {
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _aaplBuckets();
        uint256 o = l.size < s.size ? l.size : s.size;
        if (o == 0) return 0;
        int256 pnl = int256(Math.mulDiv(s.entryNotional, o, s.size)) - int256(Math.mulDiv(l.entryNotional, o, l.size))
            + (l.entryFundingIndex - s.entryFundingIndex) * int256(o) / int256(BAZAAR_SCALE);
        int256 net = pnl + int256(Math.mulDiv(l.seized, o, l.size) + Math.mulDiv(s.seized, o, s.size));
        return net < 0 ? uint256(-net) : 0;
    }

    function _aaplCollateral(address user) internal view returns (uint256 c) {
        (,,, c,,,) = aaplPair.positionBuckets(user);
    }

    /// @dev Store `priceUsd`, stamped now, as the AAPL pair's price.
    function _warmAapl(uint256 priceUsd) internal {
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        aaplPair.refreshPrice(pu);
    }

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev A long so far underwater that the vault inherits it above the mark. entryValue is sized
    ///      off the live insurance balance so the inherited loss clears the ADL trigger with room
    ///      to spare: bankruptcy notional is (entryValue - collateral), so the gap over the mark
    ///      notional lands at ~2x the fund regardless of the fixture's seed.
    function _writeDeepUnderwaterLong(address user) internal returns (uint256 expectedLoss) {
        _depositAapl(user, POS_COLLATERAL);
        uint256 markNotional = POS_SIZE * MARK;
        uint256 entryValue = markNotional + POS_COLLATERAL + 2 * _aaplInsurance();

        BucketStore.setIsLong(address(aaplPair), user, true);
        BucketStore.setSize(address(aaplPair), user, POS_SIZE);
        BucketStore.setEntryValue(address(aaplPair), user, entryValue);
        expectedLoss = entryValue - POS_COLLATERAL - markNotional;
    }

    /// @dev A short whose loss beyond its collateral is twice the fund. Netting it against a long
    ///      the vault holds cannot fit: the overlap's loss is the gap between the two entry bases,
    ///      and free capital above the reserve plus the two slices' seizure is less than the fund,
    ///      let alone twice it. Its seizure therefore seeds the short bucket.
    function _writeDeepUnderwaterShort(address user) internal {
        _depositAapl(user, POS_COLLATERAL);
        uint256 markNotional = POS_SIZE * MARK;
        uint256 past = POS_COLLATERAL + 2 * _aaplInsurance();
        assertLt(past, markNotional, "fixture: the short's entry stays positive");

        BucketStore.setIsLong(address(aaplPair), user, false);
        BucketStore.setSize(address(aaplPair), user, POS_SIZE);
        BucketStore.setEntryValue(address(aaplPair), user, markNotional - past);
    }

    /// @dev Liquidate `user` as bob, carrying a fresh AAPL update at MARK.
    function _liquidateFresh(address user) internal returns (uint256 count) {
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        count = aaplPair.liquidate{value: 0.01 ether}(_arr1(user), freshPu);
    }

    /// @dev Liquidate `user` as bob on a stale mark: Pyth's latest update, issued now, carrying MARK
    ///      generated 30 s ago with nothing newer since. That is past MAX_PRICE_STALENESS, so the call
    ///      runs as stale, and within the minute a liquidation may be judged on.
    function _liquidateStale(address user) internal returns (uint256 count) {
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        bytes[] memory latest = _tickUpdateFor(AAPL_USD_FEED_ID, MARK, nowTs, nowTs - 30);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        count = aaplPair.liquidate{value: 0.01 ether}(_arr1(user), latest);
    }

    /// The stale fallback must not open a window, even though the inherited exposure is far past
    /// the trigger. The liquidation itself still commits — only the ADL latch is withheld.
    function test_staleMark_doesNotOpenAdlWindow() public {
        _warmAapl(MARK);
        uint256 expectedLoss = _writeDeepUnderwaterLong(dave);

        // Precondition: the exposure genuinely clears the trigger, so a suppressed latch can only
        // be the freshness gate and not an undersized fixture.
        assertGt(expectedLoss, _aaplInsurance(), "fixture clears the whole fund, let alone the fund above its reserve");

        vm.warp(vm.getBlockTimestamp() + 30);

        assertEq(_liquidateStale(dave), 1, "liquidation commits on the stale mark");

        assertGt(_aaplInventorySize(), 0, "vault inherited the position");
        assertFalse(aaplPair.isAdlPending(), "stale mark must not open an ADL window");
    }

    /// Control: the identical exposure DOES open the window when the liquidator supplies a fresh
    /// price, proving the suppression above is the freshness gate rather than the fixture.
    function test_freshMark_opensAdlWindow() public {
        _warmAapl(MARK);
        uint256 expectedLoss = _writeDeepUnderwaterLong(dave);
        assertGt(expectedLoss, _aaplInsurance(), "fixture clears the whole fund, let alone the fund above its reserve");

        vm.warp(vm.getBlockTimestamp() + 30);

        assertEq(_liquidateFresh(dave), 1, "liquidation commits on the fresh mark");

        assertGt(_aaplInventorySize(), 0, "vault inherited the position");
        assertTrue(aaplPair.isAdlPending(), "fresh mark opens the ADL window");
    }

    /// A seizure on a stale mark commits into the estate's own bucket although no window is
    /// stored. The vault holds a long at the mark, covered by the fund, so nothing opens a window
    /// until alice's loss beyond her collateral is held opposite it; netting her against the long
    /// would cost the fund more than it may spend, so she is seized into the short bucket, and the
    /// stale mark withholds the window her loss calls for. The inline unload fills nothing on the
    /// stale mark, so the long she sits opposite is still there. The fresh mark opens the window
    /// over both buckets.
    function test_staleMark_seizureSeedsTheOppositeBucket_freshMarkOpensItsWindow() public {
        _warmAapl(MARK);
        uint256 seized = 1_000 * BAZAAR_SCALE;
        assertGt(_aaplInsurance(), seized, "fixture: the fund holds the seizure it earmarks");
        _stageHeldInventory(aaplPair, true, POS_SIZE, POS_SIZE * MARK, seized);
        _writeDeepUnderwaterShort(alice);

        vm.warp(vm.getBlockTimestamp() + 30);
        assertEq(_liquidateStale(alice), 1, "alice seized on the stale mark");

        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _aaplBuckets();
        assertEq(l.size, POS_SIZE, "the long is still held");
        assertEq(s.size, POS_SIZE, "alice's short seeds the opposite bucket");
        assertGt(
            _overlapUncovered(),
            _aaplInsurance() - l.seized - s.seized,
            "netting the overlap costs more than the fund's free capital, so both buckets stand"
        );
        assertFalse(aaplPair.isAdlPending(), "stale mark must not open the window the exposure calls for");

        vm.warp(vm.getBlockTimestamp() + 30);
        _warmAapl(MARK);

        assertTrue(aaplPair.isAdlPending(), "the fresh mark opens it");
        (l, s) = _aaplBuckets();
        assertEq(l.size, POS_SIZE, "with the long bucket standing for its auction");
        assertEq(s.size, POS_SIZE, "and the short bucket alongside");
    }

    /// @dev Opens a window against a fresh mark, then ages past ADL_TIMEOUT_DURATION so the
    ///      termination clock is expired for the timeout tests below.
    function _openWindowThenExpireClock() internal {
        _warmAapl(MARK);
        _writeDeepUnderwaterLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        _liquidateFresh(dave);
        assertTrue(aaplPair.isAdlPending(), "window open before the clock is aged");

        vm.warp(vm.getBlockTimestamp() + 25 hours);
    }

    /// A timed-out window's runway arms on the first fresh price stored, not on Pyth's latest price
    /// a liquidation stores after the feed went quiet: ADL cannot run on that price, so a runway
    /// started then would spend itself while the market is shut.
    function test_staleLatestPriceStore_doesNotArmTheRunway() public {
        _openWindowThenExpireClock();
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "fixture: the runway is not armed");

        uint64 nowTs = uint64(vm.getBlockTimestamp());
        bytes[] memory latest = _tickUpdateFor(AAPL_USD_FEED_ID, MARK, nowTs, nowTs - 30);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        assertEq(aaplPair.liquidate{value: 0.01 ether}(_arr1(carol), latest), 0, "nothing to seize");
        (,, uint256 storedTs,,) = aaplPair.lastPairPrice();
        assertEq(storedTs, nowTs - 30, "the latest price is stored");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "a stale store arms nothing");

        vm.warp(vm.getBlockTimestamp() + 1);
        _warmAapl(MARK);
        assertEq(
            lens.adlTerminationTs(address(aaplPair)),
            vm.getBlockTimestamp() + BazaarTypes.ADL_TERMINATION_GRACE,
            "the first fresh price arms it"
        );
    }

    /// @dev Call executeAdl with a fresh mark and an empty winner set. Which revert comes back
    ///      identifies the health verdict: AdlLib's submission guard means reason 1 (auction still
    ///      live, execution attempted), while reason 2 skips executeAdlCore entirely and the call
    ///      succeeds. Reverting rolls the transaction back, so this probes state without arming
    ///      anything — the runway is armed by a stored price, in _warmAapl.
    function _executeAdlFresh() internal {
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), new address[](0), freshPu);
    }

    /// ADL refuses the stale fallback outright. Every price-driven decision downstream — the health
    /// gate, AdlLib's batch sizing and the executor reward — would otherwise run against whichever
    /// real tick was last recorded, and on a closed venue that mark is hours old with no bound.
    function test_staleMark_executeAdlReverts() public {
        _openWindowThenExpireClock();

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__AdlPriceStale.selector);
        aaplPair.executeAdl(new address[](0), new address[](0), new bytes[](0));

        assertEq(aaplPair.settlementPriceFixedTs(), 0, "stale mark must not fix a settlement price");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "stale mark must not arm the termination clock");
    }

    /// The first price stored past the timeout arms the runway instead of terminating. ADL and the
    /// timeout are both fresh-gated, so a closed market blocks them together and they would
    /// otherwise unblock in the same block at reopen — a race the auction loses, at exactly the
    /// moment its threshold has fully decayed and it is most able to resolve the exposure.
    function test_expiredClock_firstFreshMark_armsRunwayWithoutTerminating() public {
        _openWindowThenExpireClock();

        uint256 armedAt = vm.getBlockTimestamp();
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(armedAt));

        vm.expectEmit(true, false, false, true, address(aaplPair));
        emit BazaarPair.AdlTerminationArmed(aaplPair.pairId(), armedAt + ADL_TERMINATION_GRACE);
        aaplPair.refreshPrice(pu);

        assertEq(
            lens.adlTerminationTs(address(aaplPair)),
            armedAt + ADL_TERMINATION_GRACE,
            "runway armed off the stored price"
        );
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "arming must not terminate in the same block");
        assertTrue(aaplPair.isAdlPending(), "the auction is still the live path");

        // Reason 1, not 2: inside the runway the health check still reports a live auction, so
        // execution is attempted and fails on the empty winner set rather than being skipped.
        // That is what the runway buys — the auction stays the callable path throughout it.
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), new address[](0), freshPu);
    }

    /// Set-once: further stored prices inside the runway leave the deadline where it is. Refreshing
    /// it per price would make it a snooze button — the refresh bounty pays keepers to store a
    /// price every few minutes while the vault holds inventory, as it does through a window, so
    /// honest upkeep alone would defer termination forever.
    function test_runway_isNotExtendedByFurtherFreshMarks() public {
        _openWindowThenExpireClock();

        _warmAapl(MARK);
        uint256 deadline = lens.adlTerminationTs(address(aaplPair));
        assertGt(deadline, 0, "armed");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _warmAapl(MARK);
        assertEq(lens.adlTerminationTs(address(aaplPair)), deadline, "a later stored price must not move the deadline");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _warmAapl(MARK);
        assertEq(lens.adlTerminationTs(address(aaplPair)), deadline, "repeated refreshes must not move the deadline");
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "still inside the runway");
    }

    // ---------------------------------------------------------------------------------------
    //                    auction decay restart across a market discontinuity
    // ---------------------------------------------------------------------------------------

    /// @dev Opens a window against a fresh mark and returns the instant it opened. Unlike
    ///      _openWindowThenExpireClock this leaves the 24h clock unexpired, so the auction under
    ///      test is an ordinary live one.
    function _openWindow() internal returns (uint256 openedAt) {
        _warmAapl(MARK);
        _writeDeepUnderwaterLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        _liquidateFresh(dave);
        assertTrue(aaplPair.isAdlPending(), "window open");
        return vm.getBlockTimestamp();
    }

    /// A closure must not spend the auction's Dutch decay. ADL cannot run without a fresh price, so
    /// the threshold would otherwise descend across the shut venue against attempts nobody could
    /// make — and the first keeper at the reopen would meet a fully decayed gate, free to
    /// deleverage any profitable account rather than the worst-ranked ones the curve exists to
    /// reach first.
    function test_discontinuity_restartsAuctionDecay() public {
        uint256 openedAt = _openWindow();
        assertEq(aaplPair.adlAuctionStartTs(), openedAt, "decay starts with the window");

        // Past the full auction duration the gate is wide open: everything profitable qualifies.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "decayed to the floor before the gap");

        // A closure longer than the pair's own discontinuity threshold, ended by a stored price.
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REOPEN_GAP_MIN_STALENESS + 1);
        uint256 reopenAt = vm.getBlockTimestamp();
        _warmAapl(MARK);

        assertEq(aaplPair.adlAuctionStartTs(), reopenAt, "the reopen restarts the decay");
        assertEq(
            lens.getAdlScoreThreshold(address(aaplPair)), BazaarTypes.ADL_MAX_SCORE + 1, "threshold back at the ceiling"
        );
        assertEq(aaplPair.adlPendingSince(), openedAt, "the termination clock is untouched by the restart");
    }

    /// The restart is keyed to a genuine discontinuity, not to any refresh: a gap under the
    /// threshold is ordinary call sparsity, which the refresh bounty's cadence is calibrated to
    /// exclude. Restarting on those would let routine upkeep hold the gate at its ceiling forever.
    function test_shortGap_doesNotRestartAuctionDecay() public {
        uint256 openedAt = _openWindow();

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REOPEN_GAP_MIN_STALENESS - 1 minutes);
        _warmAapl(MARK);

        assertEq(aaplPair.adlAuctionStartTs(), openedAt, "a sub-threshold gap leaves the decay running");
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "still fully decayed");
    }

    /// The restarted decay must run the same curve from its new origin, not sit pinned at the
    /// ceiling — otherwise a reopen would convert the auction from selective to unexecutable.
    function test_restartedDecay_descendsAgain() public {
        _openWindow();

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REOPEN_GAP_MIN_STALENESS + 1);
        _warmAapl(MARK);
        uint256 atCeiling = lens.getAdlScoreThreshold(address(aaplPair));

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION / 2);
        uint256 midway = lens.getAdlScoreThreshold(address(aaplPair));
        assertLt(midway, atCeiling, "the restarted curve descends");

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION);
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "and reaches the floor a second time");
    }

    /// Control: once the runway elapses the same expired clock terminates on the next fresh mark, so
    /// the grace defers termination rather than withdrawing it. executeAdl returns without
    /// reverting — reason 2 skips executeAdlCore, so the empty winner set is never inspected.
    function test_expiredClock_afterRunway_terminates() public {
        _openWindowThenExpireClock();

        _warmAapl(MARK);
        vm.warp(lens.adlTerminationTs(address(aaplPair)));

        _executeAdlFresh();

        assertGt(aaplPair.settlementPriceFixedTs(), 0, "fresh mark past the runway fires the expired timeout");

        // Fixing the price only opens the settlement window; the auction is retired at finalize, so
        // every ADL clock is still standing here.
        assertTrue(aaplPair.isAdlPending(), "the latch outlives the price fix");
        assertGt(lens.adlTerminationTs(address(aaplPair)), 0, "runway still set until finalize");
        assertGt(aaplPair.adlAuctionStartTs(), 0, "decay clock still set until finalize");
    }

    /// The withdrawal quote goes to 0 for an account the pair prices once the runway has run out:
    /// that account's withdrawal runs the verdict that fires the expired timeout, which fixes the
    /// settlement price and refuses it. An account with neither a position nor orders reads no
    /// price, is judged on the USDC balance alone, and keeps its quote.
    function test_runwayRunOut_withdrawalQuoteZeroForPricedAccountsOnly() public {
        _warmAapl(MARK);
        _depositAapl(carol, 1_000 * BAZAAR_SCALE); // flat, no orders
        _depositAapl(alice, 1_000 * BAZAAR_SCALE);
        vm.prank(alice); // a deep bid resting from before the window halts trading
        aaplPair.createOrder(
            _limitSpec(true, BAZAAR_SCALE, 100 * BAZAAR_SCALE), _hintsNone(), new bytes[](0), 0, 0, 0, "", ""
        );

        _openWindowThenExpireClock();
        _warmAapl(MARK);
        uint256 deadline = lens.adlTerminationTs(address(aaplPair));
        assertGt(deadline, 0, "runway armed");
        assertGt(lens.getMaxWithdrawable(address(aaplPair), alice, 0), 0, "inside the runway alice can withdraw");

        vm.warp(deadline);
        assertEq(lens.getMaxWithdrawable(address(aaplPair), alice, 0), 0, "past the runway: priced account quotes 0");
        assertEq(
            lens.getMaxWithdrawable(address(aaplPair), carol, 0),
            1_000 * BAZAAR_SCALE,
            "unpriced account keeps its quote"
        );

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        aaplPair.withdrawCollateral{value: 0.01 ether}(BAZAAR_SCALE, freshPu, 0, 0, 0, "");

        vm.prank(carol);
        aaplPair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
    }

    /// The runway belongs to the window it was measured for. A deadline that outlived its auction
    /// would be inherited by the pair's next window as an instant already in the past, making that
    /// window terminable on its first block with no chance to deleverage at all — the failure the
    /// grace exists to prevent, reintroduced by the mechanism meant to prevent it.
    function test_resolvedWindow_clearsRunway_andNextWindowArmsAfresh() public {
        _openWindowThenExpireClock();
        _warmAapl(MARK);
        assertGt(lens.adlTerminationTs(address(aaplPair)), 0, "first window armed");

        // Drain the inherited inventory so nothing is left to finish inside the band; the next
        // health check then releases the latch, which is the transition the clear hangs off.
        VaultStore.clear(_stdstore, address(aaplPair), true);

        vm.warp(vm.getBlockTimestamp() + 30);
        _warmAapl(MARK);

        assertFalse(aaplPair.isAdlPending(), "auction resolved");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "runway cleared with the window it measured");

        // Open a second window on the same pair and confirm it starts unarmed.
        _writeDeepUnderwaterLong(alice);
        vm.warp(vm.getBlockTimestamp() + 30);
        _liquidateFresh(alice);

        assertTrue(aaplPair.isAdlPending(), "second window open");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "second window unarmed until its own clock expires");
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "second window is not instantly terminable");
    }

    // ---------------------------------------------------------------------------------------
    //                    a bucket seeded on the other side mid-window
    // ---------------------------------------------------------------------------------------

    /// @dev Seizes alice into the short bucket while a window is open on dave's long, on a fresh
    ///      mark or on a stale one (_liquidateStale), and checks both buckets
    ///      stand under the one window. Her netting against the long cannot fit: the overlap's
    ///      loss is the gap between the two entry bases, about four times the fund, against free
    ///      capital above the reserve plus the two slices' seizure.
    function _seizeAliceIntoTheShortBucket(bool freshMark) internal {
        if (freshMark) {
            assertEq(_liquidateFresh(alice), 1, "alice seized on the fresh mark");
        } else {
            assertEq(_liquidateStale(alice), 1, "alice seized on the stale mark");
        }
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _aaplBuckets();
        assertEq(l.size, POS_SIZE, "dave's long is still held");
        assertEq(s.size, POS_SIZE, "alice's short seeds the opposite bucket");
        assertGt(_overlapUncovered(), _aaplInsurance(), "fixture: the overlap's loss is beyond the whole fund");
        assertTrue(aaplPair.isAdlPending(), "the window stays open over both buckets");
    }

    /// @dev Stage `user` as a long — the cohort the short bucket is closed against — whose entire
    ///      collateral was deposited DURING the open window, so the deposit carries a live epoch
    ///      tag. A trader in this shape is the worst case for the tag: with it subtracted the
    ///      ranking denominator floors to 1 wei, which ranks a pure-profit claim at the very front
    ///      of the queue.
    function _stageTaggedLong(address user, uint256 amount) internal {
        assertTrue(aaplPair.isAdlPending(), "tag only lands while a window is open");
        _depositAapl(user, amount);
        BucketStore.setIsLong(address(aaplPair), user, true);
        BucketStore.setSize(address(aaplPair), user, 1 * BAZAAR_SCALE);
        BucketStore.setEntryValue(address(aaplPair), user, 1 * (MARK * 2 / 3) * BAZAAR_SCALE);
        assertEq(aaplPair.adlScoreDeposit(user), amount, "deposit tagged to the live ranking epoch");
    }

    /// The epoch keys the window's deposit tags, and it moves only when a window opens. A bucket
    /// seeded on the other side opens nothing — the window is already open — so the live tags
    /// stand, and they apply to the cohort the new bucket brings in range exactly as to the one
    /// already ranked: one tag rule for both legs.
    function test_oppositeBucketSeededMidWindow_bumpsNoEpoch_keepsTags() public {
        _openWindow();
        _writeDeepUnderwaterShort(alice);
        uint256 topUp = 20 * BAZAAR_SCALE;
        _stageTaggedLong(carol, topUp);
        assertEq(lens.adlEpoch(address(aaplPair)), 1, "window opened at epoch 1");
        (uint256 scoreBefore,) = lens.getAdlScore(address(aaplPair), carol);
        assertEq(scoreBefore, 0, "a long is no candidate while the short bucket is empty");

        vm.warp(vm.getBlockTimestamp() + 30);
        _seizeAliceIntoTheShortBucket(true);

        assertEq(lens.adlEpoch(address(aaplPair)), 1, "a bucket seeded on the other side bumps no epoch");
        assertEq(aaplPair.adlScoreDeposit(carol), topUp, "the live tags stand");
        (uint256 score,) = lens.getAdlScore(address(aaplPair), carol);
        assertGt(score, 0, "the short bucket puts carol, a long, in range as its cohort");
        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(aaplPair), carol, MARK * BAZAAR_SCALE);
        assertEq(
            score,
            Math.mulDiv(uint256(st.totalPnl), BAZAAR_SCALE, AdlLib._scoreCollateral(_aaplCollateral(carol), topUp)),
            "ranked on her collateral less the tag, like any cohort"
        );
    }

    /// The Dutch decay descends only as an auction fails to turn up eligible accounts, and it
    /// restarts only when a window opens or a stored price ends a market discontinuity. A bucket
    /// seeded on the other side is neither: the gate keeps the decay it earned, and the cohort the
    /// new bucket brings in range is judged by that same gate.
    function test_oppositeBucketSeededMidWindow_restartsNoDecay() public {
        uint256 openedAt = _openWindow();
        _writeDeepUnderwaterShort(alice);

        // Run the gate to its floor, short of REOPEN_GAP_MIN_STALENESS so the price store's own
        // discontinuity restart cannot be what moves the clock below.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "gate fully decayed before the seizure");

        _seizeAliceIntoTheShortBucket(true);

        assertEq(aaplPair.adlAuctionStartTs(), openedAt, "a bucket seeded on the other side restarts no decay");
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "the gate keeps the decay it earned");

        // The cohort the short bucket brings in range meets the gate as it stands.
        _stageTaggedLong(carol, 20 * BAZAAR_SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(aaplPair), carol);
        assertGt(score, 0, "carol is a candidate against the short bucket");
        assertTrue(eligible, "and passes the decayed gate at once");
    }

    /// Neither termination clock moves: the 24h timeout stays monotone and the runway armed off
    /// it is never re-armed. A seizure is caller-induced, so a clock it moved could be pushed back
    /// indefinitely by liquidating opposite-side accounts one at a time. The auction stays the
    /// callable path throughout, with either bucket's cohort submittable.
    function test_oppositeBucketSeededMidWindow_movesNoClock() public {
        _openWindowThenExpireClock();
        _warmAapl(MARK); // arms the runway; a stored price ending a 25h gap also restarts the decay
        _writeDeepUnderwaterShort(alice);

        uint256 deadline = lens.adlTerminationTs(address(aaplPair));
        uint256 pendingSince = aaplPair.adlPendingSince();
        uint256 decayStart = aaplPair.adlAuctionStartTs();
        assertGt(deadline, 0, "runway armed before the seizure");

        vm.warp(vm.getBlockTimestamp() + 30);
        _seizeAliceIntoTheShortBucket(true);

        assertEq(lens.adlTerminationTs(address(aaplPair)), deadline, "the seizure must not re-arm the runway");
        assertEq(aaplPair.adlPendingSince(), pendingSince, "nor rewind the 24h clock");
        assertEq(aaplPair.adlAuctionStartTs(), decayStart, "nor move the decay clock");
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "and must not terminate inside the runway");

        // Reason 1, not 2: execution is attempted and fails on the empty submission rather than
        // being skipped for termination.
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), new address[](0), freshPu);
    }

    /// The same seizure on the stale fallback: it commits, seeds the bucket, and moves nothing
    /// about the window either. executeAdl cannot be reached on that mark — it refuses the stale
    /// price whichever cohort is submitted — so the batch waits for a fresh print.
    function test_oppositeBucketSeededMidWindow_staleMark_seedsItAndMovesNothing() public {
        _openWindow();
        _writeDeepUnderwaterShort(alice);
        uint256 topUp = 20 * BAZAAR_SCALE;
        _stageTaggedLong(carol, topUp);

        // Part-way down the decay; the seizure runs on Pyth's latest price, generated 30 s before it.
        vm.warp(vm.getBlockTimestamp() + 8 minutes);
        uint256 clockBefore = aaplPair.adlAuctionStartTs();
        uint256 gateBefore = lens.getAdlScoreThreshold(address(aaplPair));
        assertLt(gateBefore, 1 + BazaarTypes.ADL_MAX_SCORE, "gate has descended from max");
        assertGt(gateBefore, 1, "and has not yet bottomed out");

        _seizeAliceIntoTheShortBucket(false);

        assertEq(lens.adlEpoch(address(aaplPair)), 1, "no epoch advance");
        assertEq(aaplPair.adlScoreDeposit(carol), topUp, "the live tags stand");
        assertEq(aaplPair.adlAuctionStartTs(), clockBefore, "no decay restart");
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), gateBefore, "gate keeps the decay it earned");

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__AdlPriceStale.selector);
        aaplPair.executeAdl(new address[](0), _arr1(carol), new bytes[](0));
    }

    /// An ordinary re-evaluation of an open window moves neither the epoch nor the gate: nothing
    /// about the cohort changed.
    function test_pendingReevaluation_leavesEpochAndGateAlone() public {
        _openWindow();

        uint64 epochBefore = lens.adlEpoch(address(aaplPair));
        uint256 clockBefore = aaplPair.adlAuctionStartTs();

        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        _warmAapl(MARK);

        assertTrue(aaplPair.isAdlPending(), "window still open across the re-evaluation");
        assertEq(lens.adlEpoch(address(aaplPair)), epochBefore, "no epoch advance");
        assertEq(aaplPair.adlAuctionStartTs(), clockBefore, "no decay restart");
        assertLt(lens.getAdlScoreThreshold(address(aaplPair)), 1 + BazaarTypes.ADL_MAX_SCORE, "gate kept decaying");
    }
}
