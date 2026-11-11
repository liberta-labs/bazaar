// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {LazerUpdate} from "../LazerUpdate.sol";

/// @notice How a pair resolves its price, given that Pyth Pro stores none on-chain: the
///         caller's update when one is supplied, verified and stored when newer; otherwise the
///         pair's own stored price while it is within MAX_PRICE_STALENESS; otherwise the stale
///         fallback on a pair that is not continuously traded, and a revert on one that is.
///         refreshPrice is the entry point used throughout, since it resolves the price and
///         nothing else stands between the call and the result.
contract PriceResolutionTest is IntegrationBase {
    uint256 constant WINDOW = BazaarTypes.MAX_PRICE_STALENESS;

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _stored(BazaarPair p) internal view returns (uint256 spot, uint256 updateTs) {
        (spot,, updateTs,,) = p.lastPairPrice();
    }

    // -------------------- The caller's update --------------------

    /// @notice A fresh update is stored, and a later one replaces it.
    function test_Update_StoredWhenNewer() public {
        uint64 t0 = _now();
        pair.refreshPrice(_priceUpdate(50_000, t0));
        (uint256 spot, uint256 updateTs) = _stored(pair);
        assertEq(spot, 50_000 * BAZAAR_SCALE);
        assertEq(updateTs, t0);

        vm.warp(t0 + 1);
        pair.refreshPrice(_priceUpdate(50_100, t0 + 1));
        (spot, updateTs) = _stored(pair);
        assertEq(spot, 50_100 * BAZAAR_SCALE);
        assertEq(updateTs, t0 + 1);
    }

    /// @notice An update generated before the stored price, or in the same second, moves nothing:
    ///         a caller can bring the price forward but cannot have a call judged at an older one.
    function test_Update_NotNewerThanTheStoredPrice_MovesNothing() public {
        uint64 t0 = _now();
        vm.warp(t0 + 2);
        pair.refreshPrice(_priceUpdate(50_000, t0 + 2));

        pair.refreshPrice(_priceUpdate(49_000, t0 + 1)); // still fresh, but older than the stored price
        pair.refreshPrice(_priceUpdate(51_000, t0 + 2)); // the stored price's own second
        (uint256 spot, uint256 updateTs) = _stored(pair);
        assertEq(spot, 50_000 * BAZAAR_SCALE, "the stored price stands");
        assertEq(updateTs, t0 + 2);
    }

    /// @notice Whatever order fresh updates arrive in, generated anywhere in the freshness window
    ///         on either side of the block, the stored price's stamp never moves back, and the
    ///         stored price changes only with an update that moves the stamp forward.
    function testFuzz_Update_StoredStampNeverMovesBack(uint256 seed) public {
        vm.warp(_now() + 10);
        uint256 lastTs;
        uint256 lastSpot;
        for (uint256 i = 0; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + (seed % 3));
            uint64 generated = uint64(vm.getBlockTimestamp() - WINDOW + ((seed >> 8) % (2 * WINDOW + 1)));
            uint256 priceUsd = 49_000 + ((seed >> 16) % 2_000);
            pair.refreshPrice(_priceUpdate(priceUsd, generated));

            (uint256 spot, uint256 updateTs) = _stored(pair);
            assertGe(updateTs, lastTs, "the stamp never moves back");
            if (updateTs == lastTs) {
                assertEq(spot, lastSpot, "an unmoved stamp keeps its price");
            } else {
                assertEq(updateTs, generated, "a moved stamp is the update's");
                assertEq(spot, priceUsd * BAZAAR_SCALE, "and carries its price");
            }
            lastTs = updateTs;
            lastSpot = spot;
        }
    }

    /// @notice A supplied update is always verified: a stale one reverts the call even while the
    ///         stored price is fresh enough to have served the call on its own.
    function test_Update_StaleOneRevertsEvenWhileTheStoredPriceIsFresh() public {
        uint64 t0 = _now();
        vm.warp(t0 + 10);
        pair.refreshPrice(_priceUpdate(50_000, t0 + 10));

        bytes[] memory stale = _priceUpdate(50_000, t0 + 10 - uint64(WINDOW) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__StalePrice.selector, BTC_USD_FEED_ID, uint256(t0) + 10 - WINDOW - 1
            )
        );
        pair.refreshPrice(stale);

        pair.refreshPrice(new bytes[](0)); // the same call without the update runs on the stored price
    }

    /// @notice The freshness bound is inclusive: a price generated exactly MAX_PRICE_STALENESS
    ///         before the block is stored, one a second older is refused.
    function test_Update_FreshnessBoundary() public {
        uint64 t0 = _now();
        vm.warp(t0 + 10);
        pair.refreshPrice(_priceUpdate(50_000, t0 + 10 - uint64(WINDOW)));
        (, uint256 updateTs) = _stored(pair);
        assertEq(updateTs, t0 + 10 - WINDOW);
    }

    /// @notice An update for another feed does not price the pair.
    function test_Update_ForAnotherFeed_Reverts() public {
        bytes[] memory other = _priceUpdateFor(AAPL_USD_FEED_ID, 200, _now());
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, BTC_USD_FEED_ID));
        pair.refreshPrice(other);
    }

    /// @notice An update requested without the confidence is refused, so the pair never acts on a
    ///         price whose confidence cap was not applied.
    function test_Update_WithoutConfidence_Reverts() public {
        uint64 us = _now() * LazerUpdate.MICROS;
        bytes memory body = LazerUpdate.rawPayload(
            us,
            LazerUpdate.CHANNEL_REAL_TIME,
            1,
            LazerUpdate.rawFeed(
                BTC_USD_FEED_ID,
                3,
                abi.encodePacked(
                    LazerUpdate.propPrice(50_000e8), LazerUpdate.propExponent(-8), LazerUpdate.propGenerated(us)
                )
            )
        );
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, BTC_USD_FEED_ID));
        pair.refreshPrice(LazerUpdate.one(LazerUpdate.sign(body)));
    }

    /// @notice Confidence above 2% of the price is refused on the live path.
    function test_Update_WideConfidence_Reverts() public {
        bytes[] memory wide = LazerUpdate.one(LazerUpdate.live(BTC_USD_FEED_ID, 50_000e8, 1_001e8, -8, _now()));
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector);
        pair.refreshPrice(wide);
    }

    /// @notice An update signed by a key Pyth's verifier does not trust is refused.
    function test_Update_FromAnUntrustedSigner_Reverts() public {
        uint64 us = _now() * LazerUpdate.MICROS;
        bytes memory body =
            LazerUpdate.payload(us, LazerUpdate.CHANNEL_REAL_TIME, LazerUpdate.feed(BTC_USD_FEED_ID, 1e8, 1e5, -8, us));
        bytes[] memory forged = LazerUpdate.one(LazerUpdate.sign(body, uint256(keccak256("an attacker's key"))));
        vm.expectRevert(bytes("invalid signer"));
        pair.refreshPrice(forged);
    }

    // -------------------- Without an update --------------------

    /// @notice A pair that has never stored a price cannot be priced without an update, whether or
    ///         not it is continuously traded.
    function test_NoUpdate_NeverPriced_Reverts() public {
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        pair.refreshPrice(new bytes[](0));
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        aaplPair.refreshPrice(new bytes[](0));
    }

    /// @notice A continuously traded pair serves a call without an update from its stored price
    ///         for MAX_PRICE_STALENESS after that price was generated, and not a second longer.
    function test_NoUpdate_ContinuousPair_StoredPriceServesInsideTheWindowOnly() public {
        uint64 t0 = _now();
        pair.refreshPrice(_priceUpdate(50_000, t0));

        vm.warp(t0 + WINDOW);
        pair.refreshPrice(new bytes[](0));
        (uint256 spot, uint256 updateTs) = _stored(pair);
        assertEq(spot, 50_000 * BAZAAR_SCALE, "read, not rewritten");
        assertEq(updateTs, t0);

        vm.warp(t0 + WINDOW + 1);
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        pair.refreshPrice(new bytes[](0));
    }

    /// @notice A pair that is not continuously traded keeps resolving its stored price past the
    ///         window, as the stale fallback, where a continuously traded pair reverts.
    function test_NoUpdate_SessionPair_FallsBackToTheStoredPrice() public {
        uint64 t0 = _now();
        aaplPair.refreshPrice(_priceUpdateFor(AAPL_USD_FEED_ID, 200, t0));

        vm.warp(t0 + 2 days);
        aaplPair.refreshPrice(new bytes[](0));
        (uint256 spot, uint256 updateTs) = _stored(aaplPair);
        assertEq(spot, 200 * BAZAAR_SCALE);
        assertEq(updateTs, t0, "the fallback reads the stored price and stores nothing");
    }

    /// @notice While a market is shut Pyth keeps issuing updates that carry the last price
    ///         forward. Such an update is stale however recently it was stamped, so a session pair
    ///         is refreshed across a closure with no update at all, never with a carried-forward one.
    function test_CarriedForwardUpdate_IsRefusedOnASessionPair() public {
        uint64 t0 = _now();
        aaplPair.refreshPrice(_priceUpdateFor(AAPL_USD_FEED_ID, 200, t0));

        vm.warp(t0 + 2 days);
        bytes memory body = LazerUpdate.payload(
            _now() * LazerUpdate.MICROS,
            LazerUpdate.CHANNEL_FIXED_RATE_200,
            LazerUpdate.feed(AAPL_USD_FEED_ID, 200e8, 0.2e8, -8, t0 * LazerUpdate.MICROS)
        );
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__StalePrice.selector, AAPL_USD_FEED_ID, uint256(t0))
        );
        aaplPair.refreshPrice(LazerUpdate.one(LazerUpdate.sign(body)));
    }

    // -------------------- Pyth's fee --------------------

    /// @notice The pair pays Pyth's fee for each update from the ETH sent and returns the rest; a
    ///         call that sends less than the fee reverts, and one without an update pays nothing.
    function test_Fee_PaidPerUpdateFromTheEthSent_RestRefunded() public {
        mockPyth.setVerificationFee(5);
        uint64 t0 = _now();
        bytes[] memory two = new bytes[](2);
        two[0] = _priceUpdate(50_000, t0)[0];
        two[1] = _priceUpdate(50_010, t0)[0];
        assertEq(oracle.getUpdateFee(two.length), 10);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BazaarPair.BazaarPair__InsufficientPythFee.selector);
        pair.refreshPrice{value: 9}(two);

        vm.prank(alice);
        pair.refreshPrice{value: 1_000}(two);
        assertEq(alice.balance, 1 ether - 10, "only the fee for two updates was kept");
        assertEq(address(mockPyth).balance, 10, "paid to the verifier");
        assertEq(address(oracle).balance, 0, "nothing left in the oracle");
        assertEq(address(pair).balance, 0, "nothing left in the pair");

        vm.prank(alice);
        pair.refreshPrice{value: 1_000}(new bytes[](0));
        assertEq(alice.balance, 1 ether - 10, "a call without an update pays no fee");
    }
}
