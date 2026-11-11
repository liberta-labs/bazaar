// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {BucketStore} from "../BucketStore.sol";
import {LazerUpdate} from "../LazerUpdate.sol";

/// @notice Which price liquidate() judges a non-continuously traded pair at. A stored price older
///         than MAX_PRICE_STALENESS decides a seizure only when it is newer than the price the
///         call's update brings, so a liquidator cannot pick, between an aged stored price and the
///         live one, whichever condemns an account. The call brings
///         Pyth's latest update instead: issued within MAX_PRICE_STALENESS of the block, carrying
///         the latest price, generated no more than MAX_LIQUIDATION_PRICE_AGE (one minute) before
///         the call, inside the confidence cap.
///
///         AAPL warmup margins: IMR 40% (WARMUP 20% x 2 non-continuous), MMR = IMR/2 = 20%. A
///         1-AAPL long entered at $190 with $50 collateral is solvent at $200 (equity 60 against a
///         requirement of 40) and insolvent at $150 (equity 10 against 30).
contract LiquidationLatestPriceTest is IntegrationBase {
    uint256 constant DIP_PRICE = 150;
    uint256 constant LIVE_PRICE = 200;
    uint256 constant LIQUIDATION_PRICE_AGE = 1 minutes; // mirror of BazaarPair.MAX_LIQUIDATION_PRICE_AGE

    function _aaplPosSize(address u) internal view returns (uint256 s) {
        (, s,,,,,) = aaplPair.positionBuckets(u);
    }

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    /// @dev Store `priceUsd`, generated now, as the AAPL pair's price.
    function _store(uint256 priceUsd) internal {
        vm.deal(address(this), 1 ether);
        aaplPair.refreshPrice(_priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, _now()));
    }

    function _writeLong(address user) internal {
        _depositAapl(user, 50 * BAZAAR_SCALE);
        BucketStore.setIsLong(address(aaplPair), user, true);
        BucketStore.setSize(address(aaplPair), user, 1 * BAZAAR_SCALE);
        BucketStore.setEntryValue(address(aaplPair), user, 190 * BAZAAR_SCALE);
    }

    /// @dev Pyth's latest update for AAPL, issued at `issuedTs`, carrying `priceUsd` generated at `generatedTs`.
    function _latest(uint256 priceUsd, uint64 issuedTs, uint64 generatedTs) internal pure returns (bytes[] memory) {
        return _tickUpdateFor(AAPL_USD_FEED_ID, priceUsd, issuedTs, generatedTs);
    }

    function _liquidate(address user, bytes[] memory pu) internal returns (uint256) {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        return aaplPair.liquidate{value: 0.01 ether}(_arr1(user), pu);
    }

    /// @notice Once the stored price has aged past MAX_PRICE_STALENESS, a call without an update
    ///         cannot liquidate, even inside the minute: the stored dip no longer decides anything.
    function test_agedStoredPrice_noUpdateCannotLiquidate() public {
        _store(DIP_PRICE);
        _writeLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__LiquidationPriceTooOld.selector);
        aaplPair.liquidate(_arr1(dave), new bytes[](0));
        assertEq(_aaplPosSize(dave), 1 * BAZAAR_SCALE, "position untouched");
    }

    /// @notice A stored price inside MAX_PRICE_STALENESS still serves a call without an update.
    function test_freshStoredPrice_noUpdateStillLiquidates() public {
        _store(DIP_PRICE);
        _writeLong(dave);

        vm.prank(bob);
        assertEq(aaplPair.liquidate(_arr1(dave), new bytes[](0)), 1, "seized on the fresh stored price");
    }

    /// @notice While the feed is live, Pyth's latest update carries the live price, so a position
    ///         the market recovered from the stored dip is judged solvent: the dip cannot be chosen.
    function test_liveFeed_judgedAtTheLivePrice() public {
        _store(DIP_PRICE);
        _writeLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        assertEq(_liquidate(dave, _latest(LIVE_PRICE, _now(), _now())), 0, "solvent at the live price");
        assertEq(_aaplPosSize(dave), 1 * BAZAAR_SCALE, "position untouched");
        (uint256 stored,, uint256 storedTs,,) = aaplPair.lastPairPrice();
        assertEq(stored, LIVE_PRICE * BAZAAR_SCALE, "the live price is stored");
        assertEq(storedTs, _now());
    }

    /// @notice After a close the latest update carries the last price before it, and a position
    ///         insolvent at that price is seized for a minute after it was generated.
    function test_quietFeed_latestPriceSeizes() public {
        _store(DIP_PRICE);
        uint64 closedAt = _now();
        _writeLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        assertEq(_liquidate(dave, _latest(DIP_PRICE, _now(), closedAt)), 1, "seized at the last price");
        assertEq(_aaplPosSize(dave), 0, "position seized");
    }

    /// @notice A latest price newer than the stored one, though older than MAX_PRICE_STALENESS, is
    ///         the price the seizure is judged at, and it is stored, so the mark describes the
    ///         seizure's instant.
    function test_latestPriceNewerThanStored_isJudgedAndStored() public {
        _store(LIVE_PRICE);
        _writeLong(dave);
        uint64 dipAt = _now() + 20;
        vm.warp(vm.getBlockTimestamp() + 50);

        assertEq(_liquidate(dave, _latest(DIP_PRICE, _now(), dipAt)), 1, "seized at the newer latest price");
        (uint256 stored,, uint256 storedTs,,) = aaplPair.lastPairPrice();
        assertEq(stored, DIP_PRICE * BAZAAR_SCALE, "the latest price is stored");
        assertEq(storedTs, dipAt, "dated when it was generated");
    }

    /// @notice A stored price newer than the price an update brings is judged instead. The stored
    ///         price here was generated two seconds ahead of the block, by a feed clock running
    ///         ahead, and the update, issued at the block, still carries the price before it: the
    ///         account is judged solvent at the newer stored price, and nothing is stored.
    function test_storedPriceNewerThanTheUpdate_isJudgedInstead() public {
        uint64 t0 = _now();
        vm.deal(address(this), 1 ether);
        aaplPair.refreshPrice(_tickUpdateFor(AAPL_USD_FEED_ID, LIVE_PRICE, t0 + 2, t0 + 2));
        _writeLong(dave);

        assertEq(_liquidate(dave, _latest(DIP_PRICE, t0, t0 - 5)), 0, "solvent at the newer stored price");
        assertEq(_aaplPosSize(dave), 1 * BAZAAR_SCALE, "position untouched");
        (uint256 stored,, uint256 storedTs,,) = aaplPair.lastPairPrice();
        assertEq(stored, LIVE_PRICE * BAZAAR_SCALE, "the stored price is unchanged");
        assertEq(storedTs, t0 + 2);
    }

    /// @notice The latest price may be exactly a minute old and no older: after that the position
    ///         waits for the next price.
    function test_latestPriceAgeBound() public {
        _store(DIP_PRICE);
        uint64 closedAt = _now();
        _writeLong(dave);
        _writeLong(carol);

        vm.warp(uint256(closedAt) + LIQUIDATION_PRICE_AGE + 1);
        bytes[] memory tooOld = _latest(DIP_PRICE, _now(), closedAt);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__StalePrice.selector, AAPL_USD_FEED_ID, uint256(closedAt))
        );
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), tooOld);
        assertEq(_aaplPosSize(dave), 1 * BAZAAR_SCALE, "position waits");

        vm.warp(uint256(closedAt) + LIQUIDATION_PRICE_AGE);
        assertEq(_liquidate(carol, _latest(DIP_PRICE, _now(), closedAt)), 1, "a minute old still seizes");
    }

    /// @notice An update issued more than MAX_PRICE_STALENESS before the block is no proof of the
    ///         latest price, and is refused.
    function test_updateIssuedTooLongAgo_refused() public {
        _store(DIP_PRICE);
        uint64 closedAt = _now();
        _writeLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory old = _latest(DIP_PRICE, _now() - 4, closedAt);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__StaleUpdate.selector, uint64(_now() - 4) * 1e6)
        );
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), old);
    }

    /// @notice A latest price wider than the confidence cap is refused, and the stored price does not
    ///         stand in for it: the liquidation waits until Pyth's publishers agree again.
    function test_wideLatestPrice_refused() public {
        _store(LIVE_PRICE);
        _writeLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory wide = LazerUpdate.one(
            LazerUpdate.tick(AAPL_USD_FEED_ID, int64(int256(DIP_PRICE * 1e8)), 6e8, -8, _now(), _now() - 1)
        );

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), wide);

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__LiquidationPriceTooOld.selector);
        aaplPair.liquidate(_arr1(dave), new bytes[](0));
        assertEq(_aaplPosSize(dave), 1 * BAZAAR_SCALE, "position untouched");
    }

    /// @notice A continuously traded pair still needs a fresh price: Pyth's latest update carrying an
    ///         older price is refused there.
    function test_continuousPair_needsAFreshPrice() public {
        pair.refreshPrice(_freshPrice());
        _setupInsolventAlice();
        vm.warp(vm.getBlockTimestamp() + 30);
        uint64 nowTs = _now();
        bytes[] memory carried = _tickUpdateFor(BTC_USD_FEED_ID, 50_000, nowTs, nowTs - 30);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__StalePrice.selector, BTC_USD_FEED_ID, uint256(nowTs - 30))
        );
        pair.liquidate{value: 0.01 ether}(_arr1(alice), carried);
    }

    /// @notice The minute is measured from when the price was generated, so neither a recent store
    ///         of an older price nor the call's own timing can stretch it.
    function test_minuteCountsFromGeneration() public {
        assertEq(BazaarTypes.MAX_PRICE_STALENESS, 3, "fixture: the issue window");
        _store(DIP_PRICE);
        uint64 closedAt = _now();
        _writeLong(dave);
        vm.warp(uint256(closedAt) + LIQUIDATION_PRICE_AGE + 30);

        bytes[] memory issuedNow = _latest(DIP_PRICE, _now(), closedAt);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__StalePrice.selector, AAPL_USD_FEED_ID, uint256(closedAt))
        );
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), issuedNow);
    }

    /// @notice A latest price generated in the stored price's own second is not stored, but it is the
    ///         price the seizure is judged at, not the earlier one the pair stored in that second.
    function test_sameSecondLatestPrice_isTheOneJudged() public {
        uint64 t0 = _now();
        _store(LIVE_PRICE);
        _writeLong(dave);
        vm.warp(uint256(t0) + 10);

        bytes memory body = LazerUpdate.payload(
            _now() * 1e6,
            LazerUpdate.CHANNEL_FIXED_RATE_200,
            LazerUpdate.feed(AAPL_USD_FEED_ID, int64(int256(DIP_PRICE * 1e8)), 0.15e8, -8, uint64(t0) * 1e6 + 500_000)
        );
        assertEq(
            _liquidate(dave, LazerUpdate.one(LazerUpdate.sign(body))), 1, "judged at the later price of that second"
        );
        (uint256 stored,, uint256 storedTs,,) = aaplPair.lastPairPrice();
        assertEq(stored, LIVE_PRICE * BAZAAR_SCALE, "the stored price is unchanged");
        assertEq(storedTs, t0);
    }

    /// @notice The latest-price path charges exactly Pyth's fee and refunds the rest, and refuses a
    ///         call that sends less than the fee.
    function test_latestPath_feeAndRefund() public {
        _store(DIP_PRICE);
        uint64 closedAt = _now();
        vm.warp(vm.getBlockTimestamp() + 30);
        mockPyth.setVerificationFee(5);
        bytes[] memory latest = _latest(DIP_PRICE, _now(), closedAt);

        vm.deal(bob, 100);
        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__InsufficientPythFee.selector);
        aaplPair.liquidate{value: 4}(_arr1(carol), latest);

        uint256 verifierBefore = address(mockPyth).balance;
        vm.prank(bob);
        aaplPair.liquidate{value: 100}(_arr1(carol), latest);
        assertEq(bob.balance, 95, "everything but the fee came back");
        assertEq(address(mockPyth).balance - verifierBefore, 5, "the fee reached the verifier");
        assertEq(address(aaplPair).balance, 0, "nothing rests in the pair");
        assertEq(address(oracle).balance, 0, "nothing rests in the oracle");
    }
}
