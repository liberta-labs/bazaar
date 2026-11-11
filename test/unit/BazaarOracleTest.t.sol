// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {LazerPayloadLib} from "../../src/libraries/LazerPayloadLib.sol";
import {MockPythLazer} from "../mocks/MockPythLazer.sol";
import {LazerUpdate} from "../LazerUpdate.sol";

/// @notice Unit tests for BazaarOracle against a Pyth Pro verifier: the composite registry and
///         feed ID forms, the live price out of caller-supplied updates (freshness on the feed
///         update timestamp, the confidence cap, the properties an update must carry), the two
///         settlement readers, and the fee each verification costs.
contract BazaarOracleTest is Test {
    // Arbitrary leg feed IDs (Pyth Pro feed IDs in production)
    bytes32 constant ASSET_JPY_FEED = bytes32(uint256(9001));
    bytes32 constant USD_JPY_FEED = bytes32(uint256(9002));
    bytes32 constant ASSET_GBP_FEED = bytes32(uint256(9003));
    bytes32 constant GBP_USD_FEED = bytes32(uint256(9004));

    int16 constant EXPO = -8;
    uint256 constant FEE = 3; // wei per verified update
    uint256 constant MAX_AGE = 60;
    uint64 constant MICROS = 1e6;

    MockPythLazer pythLazer;
    BazaarOracle oracle;
    uint64 nowTs;

    function setUp() public {
        vm.warp(1_700_000_000);
        nowTs = uint64(block.timestamp);
        pythLazer = new MockPythLazer(FEE);
        pythLazer.updateTrustedSigner(LazerUpdate.signer(), type(uint256).max);
        oracle = new BazaarOracle(address(pythLazer));
        vm.deal(address(this), 1 ether);
    }

    // ==================== Helpers ====================

    function _live(bytes32 id, int64 price, uint64 conf, uint64 generatedTs) internal pure returns (bytes memory) {
        return LazerUpdate.live(id, price, conf, EXPO, generatedTs);
    }

    function _tick(bytes32 id, int64 price, uint64 conf, uint64 tickTs, uint64 generatedTs)
        internal
        pure
        returns (bytes memory)
    {
        return LazerUpdate.tick(id, price, conf, EXPO, tickTs, generatedTs);
    }

    /// @dev One update carrying both JPY legs, generated now.
    function _jpyPair(int64 basePrice, uint64 baseConf, int64 quotePrice, uint64 quoteConf)
        internal
        view
        returns (bytes[] memory)
    {
        return LazerUpdate.one(
            LazerUpdate.livePair(
                LazerUpdate.feed(ASSET_JPY_FEED, basePrice, baseConf, EXPO, nowTs * MICROS),
                LazerUpdate.feed(USD_JPY_FEED, quotePrice, quoteConf, EXPO, nowTs * MICROS),
                nowTs
            )
        );
    }

    /// @dev A signed real-time update stamped now whose single feed carries `count` properties.
    function _custom(bytes32 id, uint8 count, bytes memory properties) internal view returns (bytes[] memory) {
        return LazerUpdate.one(
            LazerUpdate.sign(
                LazerUpdate.rawPayload(
                    nowTs * MICROS, LazerUpdate.CHANNEL_REAL_TIME, 1, LazerUpdate.rawFeed(id, count, properties)
                )
            )
        );
    }

    function _fetch(bytes32 id, bytes[] memory updates)
        internal
        returns (uint256 spot, uint256 low, uint256 high, uint256 publishTime)
    {
        return oracle.verifyAndFetchPrice{value: FEE * updates.length}(id, updates, MAX_AGE);
    }

    function _registerJpyComposite() internal returns (bytes32) {
        return oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
    }

    function _registerGbpComposite() internal returns (bytes32) {
        return oracle.registerComposite(ASSET_GBP_FEED, GBP_USD_FEED, false);
    }

    // ==================== Wiring ====================

    function test_Constructor_RevertsOnZeroVerifier() public {
        vm.expectRevert(BazaarOracle.BazaarOracle__ZeroAddress.selector);
        new BazaarOracle(address(0));
    }

    function test_PythLazer_IsTheVerifier() public view {
        assertEq(address(oracle.pythLazer()), address(pythLazer));
    }

    // ==================== Feed ID forms and the registry ====================

    function test_IsRawFeedId_NonZeroAndWithin32Bits() public view {
        assertFalse(oracle.isRawFeedId(bytes32(0)), "zero is no feed");
        assertTrue(oracle.isRawFeedId(bytes32(uint256(1))));
        assertTrue(oracle.isRawFeedId(bytes32(uint256(type(uint32).max))));
        assertFalse(oracle.isRawFeedId(bytes32(uint256(type(uint32).max) + 1)), "past 32 bits");
        assertFalse(oracle.isRawFeedId(keccak256("anything")), "a hash is not a raw ID");
    }

    function test_RegisterComposite_DeterministicIdAndStorage() public {
        bytes32 id = _registerJpyComposite();

        assertEq(id, keccak256(abi.encodePacked(ASSET_JPY_FEED, USD_JPY_FEED, true)));
        assertEq(id, oracle.getCompositeId(ASSET_JPY_FEED, USD_JPY_FEED, true));
        assertFalse(oracle.isRawFeedId(id), "a composite ID is never a raw ID");

        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = oracle.composites(id);
        assertEq(baseId, ASSET_JPY_FEED);
        assertEq(quoteId, USD_JPY_FEED);
        assertTrue(invertQuote);
    }

    function test_RegisterComposite_InvertFlagChangesId() public {
        bytes32 idInverted = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes32 idStraight = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, false);
        assertTrue(idInverted != idStraight);
    }

    function test_RegisterComposite_Idempotent() public {
        bytes32 id1 = _registerJpyComposite();
        bytes32 id2 = _registerJpyComposite(); // must not revert
        assertEq(id1, id2);
    }

    function test_RegisterComposite_RevertsOnInvalidLegs() public {
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, bytes32(0), USD_JPY_FEED)
        );
        oracle.registerComposite(bytes32(0), USD_JPY_FEED, true);

        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, ASSET_JPY_FEED, bytes32(0))
        );
        oracle.registerComposite(ASSET_JPY_FEED, bytes32(0), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, ASSET_JPY_FEED, ASSET_JPY_FEED
            )
        );
        oracle.registerComposite(ASSET_JPY_FEED, ASSET_JPY_FEED, true);
    }

    /// @notice A leg must be a raw feed ID, which rules out a composite as a leg and any other ID
    ///         past 32 bits.
    function test_RegisterComposite_RevertsOnLegThatIsNotARawFeedId() public {
        bytes32 compositeId = _registerJpyComposite();

        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, compositeId, GBP_USD_FEED)
        );
        oracle.registerComposite(compositeId, GBP_USD_FEED, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, ASSET_GBP_FEED, compositeId
            )
        );
        oracle.registerComposite(ASSET_GBP_FEED, compositeId, false);

        bytes32 tooWide = bytes32(uint256(type(uint32).max) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, tooWide, GBP_USD_FEED)
        );
        oracle.registerComposite(tooWide, GBP_USD_FEED, false);
    }

    /// @notice An ID that is neither a raw feed ID nor a registered composite prices nothing.
    function test_UnknownFeedId_Reverts() public {
        bytes32 unregistered = oracle.getCompositeId(ASSET_GBP_FEED, GBP_USD_FEED, false);
        bytes[] memory updates = LazerUpdate.one(_live(ASSET_GBP_FEED, 150e8, 1, nowTs));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidFeedId.selector, unregistered));
        oracle.verifyAndFetchPrice{value: FEE}(unregistered, updates, MAX_AGE);
    }

    // ==================== Fees ====================

    function test_GetUpdateFee_IsTheVerifiersFeePerUpdate() public {
        assertEq(oracle.getUpdateFee(0), 0);
        assertEq(oracle.getUpdateFee(1), FEE);
        assertEq(oracle.getUpdateFee(5), 5 * FEE);
        pythLazer.setVerificationFee(0);
        assertEq(oracle.getUpdateFee(5), 0, "follows the verifier's fee");
    }

    /// @notice The call must carry exactly the fee of its updates: Pyth returns any excess to the
    ///         oracle, which could not pass it on, so less and more are both refused.
    function test_Fee_MustMatchExactly_NothingLeftInTheOracle() public {
        bytes[] memory updates =
            LazerUpdate.two(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs - 1), _live(ASSET_JPY_FEED, 3001e8, 1, nowTs));

        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeeMismatch.selector, 2 * FEE - 1, 2 * FEE));
        oracle.verifyAndFetchPrice{value: 2 * FEE - 1}(ASSET_JPY_FEED, updates, MAX_AGE);
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeeMismatch.selector, 2 * FEE + 1, 2 * FEE));
        oracle.verifyAndFetchPrice{value: 2 * FEE + 1}(ASSET_JPY_FEED, updates, MAX_AGE);

        oracle.verifyAndFetchPrice{value: 2 * FEE}(ASSET_JPY_FEED, updates, MAX_AGE);
        assertEq(address(oracle).balance, 0, "the oracle keeps nothing");
        assertEq(address(pythLazer).balance, 2 * FEE, "the verifier was paid per update");
    }

    // ==================== Signatures ====================

    function test_UpdateFromAnUntrustedSigner_Reverts() public {
        bytes memory body =
            LazerUpdate.payload(nowTs * MICROS, 1, LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 3e8, EXPO, nowTs * MICROS));
        bytes[] memory updates = LazerUpdate.one(LazerUpdate.sign(body, uint256(keccak256("someone else"))));
        vm.expectRevert(bytes("invalid signer"));
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, updates, MAX_AGE);
    }

    function test_UpdateFromASignerWhoseTrustExpired_Reverts() public {
        bytes[] memory updates = LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs));
        pythLazer.updateTrustedSigner(LazerUpdate.signer(), block.timestamp);
        vm.expectRevert(bytes("invalid signer"));
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, updates, MAX_AGE);
    }

    /// @notice Changing one byte of a signed payload changes who it recovers to.
    function test_TamperedPayload_Reverts() public {
        bytes memory update = _live(ASSET_JPY_FEED, 3000e8, 1, nowTs);
        update[update.length - 1] = bytes1(uint8(update[update.length - 1]) ^ 0x01);
        vm.expectRevert();
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, LazerUpdate.one(update), MAX_AGE);
    }

    function test_MalformedPayloadSignedByPyth_Reverts() public {
        bytes memory body = abi.encodePacked(
            LazerUpdate.payload(nowTs * MICROS, 1, LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 3e8, EXPO, nowTs * MICROS)),
            uint8(0)
        );
        vm.expectRevert(LazerPayloadLib.LazerPayloadLib__Malformed.selector);
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, LazerUpdate.one(LazerUpdate.sign(body)), MAX_AGE);
    }

    // ==================== Live price: single feed ====================

    function test_Live_SingleFeed_NormalizedWithBracket() public {
        (uint256 spot, uint256 low, uint256 high, uint256 publishTime) =
            _fetch(ASSET_JPY_FEED, LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 30e8, nowTs - 2)));
        assertEq(spot, 3000e18);
        assertEq(low, 2970e18);
        assertEq(high, 3030e18);
        assertEq(publishTime, nowTs - 2, "the second the price was generated in");
    }

    /// @notice The exponent comes from the update: the same $3000 at five and at twelve decimals.
    function test_Live_ExponentFromTheUpdate() public {
        (uint256 spot,,,) =
            _fetch(ASSET_JPY_FEED, LazerUpdate.one(LazerUpdate.live(ASSET_JPY_FEED, 3000e5, 1, -5, nowTs)));
        assertEq(spot, 3000e18);
        (spot,,,) = _fetch(ASSET_JPY_FEED, LazerUpdate.one(LazerUpdate.live(ASSET_JPY_FEED, 3000e12, 1, -12, nowTs)));
        assertEq(spot, 3000e18);
    }

    /// @notice Sub-second generation times round down to their second.
    function test_Live_PublishTimeIsTheGenerationSecond() public {
        bytes memory body = LazerUpdate.payload(
            nowTs * MICROS + 900_000, 1, LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 1, EXPO, nowTs * MICROS + 850_000)
        );
        (,,, uint256 publishTime) = _fetch(ASSET_JPY_FEED, LazerUpdate.one(LazerUpdate.sign(body)));
        assertEq(publishTime, nowTs);
    }

    /// @notice An update for an unrelated feed is ignored, and extra properties the oracle does not
    ///         read are stepped over wherever they sit.
    function test_Live_OtherFeedsAndExtraPropertiesAreSkipped() public {
        bytes memory extras = abi.encodePacked(
            LazerUpdate.propPublisherCount(9),
            LazerUpdate.propMarketSession(3),
            LazerUpdate.propPrice(3000e8),
            LazerUpdate.propBestBid(2999e8),
            LazerUpdate.propFunding(6, true, 123),
            LazerUpdate.propFunding(7, false, 0),
            LazerUpdate.propExponent(EXPO),
            LazerUpdate.propBestAsk(3001e8),
            LazerUpdate.propEmaPrice(2990e8),
            LazerUpdate.propConfidence(30e8),
            LazerUpdate.propEmaConfidence(31e8),
            LazerUpdate.propFunding(8, true, 28_800_000_000),
            LazerUpdate.propGenerated(nowTs * MICROS)
        );
        bytes memory body = LazerUpdate.rawPayload(
            nowTs * MICROS,
            LazerUpdate.CHANNEL_FIXED_RATE_200,
            2,
            abi.encodePacked(
                LazerUpdate.encodeFeed(LazerUpdate.feed(GBP_USD_FEED, 1.25e8, 0.001e8, EXPO, nowTs * MICROS)),
                LazerUpdate.rawFeed(ASSET_JPY_FEED, 13, extras)
            )
        );
        (uint256 spot, uint256 low, uint256 high,) = _fetch(ASSET_JPY_FEED, LazerUpdate.one(LazerUpdate.sign(body)));
        assertEq(spot, 3000e18);
        assertEq(low, 2970e18);
        assertEq(high, 3030e18);
    }

    /// @notice Of several updates for the feed, the most recently generated price is the one read,
    ///         wherever it sits in the list.
    function test_Live_MostRecentlyGeneratedUpdateWins() public {
        bytes[] memory updates =
            LazerUpdate.two(_live(ASSET_JPY_FEED, 3001e8, 1, nowTs), _live(ASSET_JPY_FEED, 2999e8, 1, nowTs - 2));
        (uint256 spot,,, uint256 publishTime) = _fetch(ASSET_JPY_FEED, updates);
        assertEq(spot, 3001e18);
        assertEq(publishTime, nowTs);
    }

    function test_Live_FeedNotInAnyUpdate_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, ASSET_JPY_FEED));
        oracle.verifyAndFetchPrice{value: FEE}(
            ASSET_JPY_FEED, LazerUpdate.one(_live(GBP_USD_FEED, 1.25e8, 1, nowTs)), MAX_AGE
        );

        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, ASSET_JPY_FEED));
        oracle.verifyAndFetchPrice(ASSET_JPY_FEED, new bytes[](0), MAX_AGE);
    }

    // ---- Freshness ----

    /// @notice A price is fresh while the second it was generated in lies within the bound of the
    ///         block, behind it or ahead of it; a second further either way is stale.
    function test_Live_FreshnessBoundIsInclusiveBothWays() public {
        _fetch(ASSET_JPY_FEED, LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs - uint64(MAX_AGE))));
        _fetch(ASSET_JPY_FEED, LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs + uint64(MAX_AGE))));

        bytes[] memory old = LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs - uint64(MAX_AGE) - 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__StalePrice.selector, ASSET_JPY_FEED, uint256(nowTs) - MAX_AGE - 1
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, old, MAX_AGE);

        bytes[] memory ahead = LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs + uint64(MAX_AGE) + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__StalePrice.selector, ASSET_JPY_FEED, uint256(nowTs) + MAX_AGE + 1
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, ahead, MAX_AGE);
    }

    /// @notice Age is measured from when the price was generated, not from the update's own
    ///         timestamp: an update stamped now that carries an hour-old price forward is stale.
    function test_Live_CarriedForwardPriceIsStale() public {
        bytes memory body = LazerUpdate.payload(
            nowTs * MICROS, 1, LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 1, EXPO, (nowTs - 3600) * MICROS)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__StalePrice.selector, ASSET_JPY_FEED, uint256(nowTs) - 3600
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, LazerUpdate.one(LazerUpdate.sign(body)), MAX_AGE);
    }

    // ---- Properties an update must carry ----

    /// @notice An update requested without one of the four properties is refused rather than
    ///         priced without it: dropping the confidence must not drop the confidence cap, and
    ///         dropping the feed update timestamp must not drop the freshness bound.
    function test_Live_UpdateMissingAProperty_Reverts() public {
        bytes memory price = LazerUpdate.propPrice(3000e8);
        bytes memory expo = LazerUpdate.propExponent(EXPO);
        bytes memory conf = LazerUpdate.propConfidence(30e8);
        bytes memory generated = LazerUpdate.propGenerated(nowTs * MICROS);
        bytes memory refusal =
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED);

        bytes[] memory noConfidence = _custom(ASSET_JPY_FEED, 3, abi.encodePacked(price, expo, generated));
        vm.expectRevert(refusal);
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, noConfidence, MAX_AGE);

        bytes[] memory noExponent = _custom(ASSET_JPY_FEED, 3, abi.encodePacked(price, conf, generated));
        vm.expectRevert(refusal);
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, noExponent, MAX_AGE);

        bytes[] memory noTimestamp = _custom(ASSET_JPY_FEED, 3, abi.encodePacked(price, expo, conf));
        vm.expectRevert(refusal);
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, noTimestamp, MAX_AGE);

        bytes[] memory noPrice = _custom(ASSET_JPY_FEED, 3, abi.encodePacked(expo, conf, generated));
        vm.expectRevert(refusal);
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, noPrice, MAX_AGE);
    }

    /// @notice A feed that has never produced a price carries its timestamp property unset, and
    ///         one with no price at the update's timestamp carries a zero price: neither prices.
    function test_Live_FeedWithNoPrice_Reverts() public {
        bytes[] memory neverPriced = LazerUpdate.one(
            LazerUpdate.sign(LazerUpdate.payload(nowTs * MICROS, 1, LazerUpdate.feed(ASSET_JPY_FEED, 0, 0, EXPO, 0)))
        );
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED));
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, neverPriced, MAX_AGE);

        bytes[] memory noPriceNow = LazerUpdate.one(_live(ASSET_JPY_FEED, 0, 1, nowTs));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, ASSET_JPY_FEED, int64(0), int32(EXPO)
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, noPriceNow, MAX_AGE);
    }

    function test_Live_NegativePrice_Reverts() public {
        bytes[] memory updates = LazerUpdate.one(_live(ASSET_JPY_FEED, -1e8, 1, nowTs));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, ASSET_JPY_FEED, int64(-1e8), int32(EXPO)
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, updates, MAX_AGE);
    }

    // ---- Confidence cap ----

    /// @notice A single-feed base whose confidence exceeds 2% of price is rejected — the path
    ///         every non-composite pair takes. conf 61 on price 3000 = 2.03% > 2%.
    function test_Live_SingleFeed_ConfidenceTooHigh_Reverts() public {
        bytes[] memory updates = LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 61e8, nowTs));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector, uint256(61e18), uint256(3000e18)
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, updates, MAX_AGE);
    }

    /// @notice Confidence exactly at 2% (conf 60 on price 3000) passes — pins the strict-`>` boundary.
    function test_Live_SingleFeed_ConfidenceExactly2pct_Passes() public {
        (uint256 spot,,,) = _fetch(ASSET_JPY_FEED, LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 60e8, nowTs)));
        assertEq(spot, 3000e18, "exactly 2% confidence is accepted");
    }

    /// @notice A zero confidence is how Pyth writes one it has no value for, so it is refused like
    ///         a confidence that was never requested: the cap is not passed by a price Pyth could
    ///         not bound. The smallest confidence there is prices normally.
    function test_Live_ZeroConfidence_Reverts() public {
        bytes[] memory unbounded = LazerUpdate.one(LazerUpdate.live(ASSET_JPY_FEED, 3000e8, 0, EXPO, nowTs));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED));
        oracle.verifyAndFetchPrice{value: FEE}(ASSET_JPY_FEED, unbounded, MAX_AGE);

        (uint256 spot, uint256 low, uint256 high,) =
            _fetch(ASSET_JPY_FEED, LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs)));
        assertEq(spot, 3000e18);
        assertEq(low, 3000e18 - 1e10);
        assertEq(high, 3000e18 + 1e10);
    }

    // ==================== Live price: composites ====================

    function test_Composite_DividePath() public {
        // 3000 JPY stock, USD/JPY = 150 (inverted) => $20
        bytes32 compositeId = _registerJpyComposite();
        (uint256 spot, uint256 low, uint256 high, uint256 publishTime) =
            _fetch(compositeId, _jpyPair(3000e8, 1, 150e8, 1));
        assertEq(spot, 20e18);
        assertEq(low, uint256(3000e18 - 1e10) * 1e18 / (150e18 + 1e10));
        assertEq(high, uint256(3000e18 + 1e10) * 1e18 / (150e18 - 1e10));
        assertEq(publishTime, nowTs);
    }

    function test_Composite_MultiplyPath() public {
        // 150 GBP stock, GBP/USD = 1.25 => $187.50
        bytes32 compositeId = _registerGbpComposite();
        bytes[] memory updates =
            LazerUpdate.two(_live(ASSET_GBP_FEED, 150e8, 1, nowTs), _live(GBP_USD_FEED, 1.25e8, 1, nowTs));
        (uint256 spot,,,) = _fetch(compositeId, updates);
        assertEq(spot, 187.5e18);
    }

    function test_Composite_MultiplyBracketIsConservative() public {
        // base 150 +/- 1 GBP, fx 1.25 +/- 0.01 USD/GBP (both within 2%)
        bytes32 compositeId = _registerGbpComposite();
        bytes[] memory updates =
            LazerUpdate.two(_live(ASSET_GBP_FEED, 150e8, 1e8, nowTs), _live(GBP_USD_FEED, 1.25e8, 0.01e8, nowTs));
        (uint256 spot, uint256 low, uint256 high,) = _fetch(compositeId, updates);
        assertEq(spot, 187.5e18);
        assertEq(low, 149e18 * 1.24e18 / 1e18); // 184.76
        assertEq(high, 151e18 * 1.26e18 / 1e18); // 190.26
        assertLt(low, spot);
        assertGt(high, spot);
    }

    function test_Composite_DivideBracketIsConservative() public {
        // base 3000 +/- 30 JPY, fx 150 +/- 1 JPY/USD (inverted) (both within 2%)
        bytes32 compositeId = _registerJpyComposite();
        (uint256 spot, uint256 low, uint256 high,) = _fetch(compositeId, _jpyPair(3000e8, 30e8, 150e8, 1e8));
        assertEq(spot, 20e18);
        assertEq(low, uint256(2970e18) * 1e18 / 151e18); // low base over high fx
        assertEq(high, uint256(3030e18) * 1e18 / 149e18); // high base over low fx
        assertLt(low, spot);
        assertGt(high, spot);
    }

    /// @notice The legs may arrive in one update or in two, in either order, and the composite is
    ///         only as fresh as its older leg.
    function test_Composite_LegsInSeparateUpdates_PublishTimeIsTheOlderLeg() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes[] memory updates =
            LazerUpdate.two(_live(USD_JPY_FEED, 150e8, 1, nowTs - 40), _live(ASSET_JPY_FEED, 3000e8, 1, nowTs - 5));
        (uint256 spot,,, uint256 publishTime) = _fetch(compositeId, updates);
        assertEq(spot, 20e18);
        assertEq(publishTime, nowTs - 40);
    }

    function test_Composite_QuoteLegMissing_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes[] memory updates = LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, nowTs));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, USD_JPY_FEED));
        oracle.verifyAndFetchPrice{value: FEE}(compositeId, updates, MAX_AGE);
    }

    function test_Composite_QuoteLegStale_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes[] memory updates = LazerUpdate.two(
            _live(ASSET_JPY_FEED, 3000e8, 1, nowTs), _live(USD_JPY_FEED, 150e8, 1, nowTs - uint64(MAX_AGE) - 1)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__StalePrice.selector, USD_JPY_FEED, uint256(nowTs) - MAX_AGE - 1
            )
        );
        oracle.verifyAndFetchPrice{value: 2 * FEE}(compositeId, updates, MAX_AGE);
    }

    function test_Composite_QuoteConfidenceTooHigh_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes[] memory updates = _jpyPair(3000e8, 1, 150e8, 4e8); // 2.67% on the quote leg
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector, uint256(4e18), uint256(150e18)
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(compositeId, updates, MAX_AGE);
    }

    /// @notice A zero quote leg is a hard error — flooring it (the base-leg trick) would explode
    ///         the composite instead of zeroing it, so it must revert. A negative one likewise.
    function test_Composite_NonPositiveQuote_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();

        bytes[] memory zero = _jpyPair(3000e8, 1, 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, USD_JPY_FEED, int64(0), int32(EXPO)
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(compositeId, zero, MAX_AGE);

        bytes[] memory negative = _jpyPair(3000e8, 1, -1e8, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, USD_JPY_FEED, int64(-1e8), int32(EXPO)
            )
        );
        oracle.verifyAndFetchPrice{value: FEE}(compositeId, negative, MAX_AGE);
    }

    // ---- composed-bracket cap (2% TOTAL uncertainty) ----

    /// @notice Legs share the 2% budget: 1.8% + 0.15% composes to ~1.95% — passes, even though
    ///         a naive per-leg 1% split would have rejected the base leg.
    function test_ComposedCap_LopsidedWithinBudget_Passes() public {
        bytes32 compositeId = _registerJpyComposite();
        // base conf 54e8 = 1.8% of 3000e8; quote conf 0.225e8 = 0.15% of 150e8.
        (uint256 spot,,,) = _fetch(compositeId, _jpyPair(3000e8, 54e8, 150e8, 22500000));
        assertEq(spot, 20e18);
    }

    /// @notice Two legs at 1.2% each pass the per-leg checks but compose to ~2.43% total. Per-leg
    ///         enforcement alone would admit this, so the cap is applied to the composed bracket.
    function test_ComposedCap_EvenSplitOverBudget_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();
        // base conf 36e8 = 1.2% of 3000e8; quote conf 1.8e8 = 1.2% of 150e8.
        bytes[] memory updates = _jpyPair(3000e8, 36e8, 150e8, 1.8e8);
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector);
        oracle.verifyAndFetchPrice{value: FEE}(compositeId, updates, MAX_AGE);
    }

    // ==================== fetchPriceAtTick ====================

    uint64 constant CUTOFF = 1_699_990_000;

    function _atTick(bytes32 id, bytes[] memory updates) internal returns (uint256 spot) {
        return oracle.fetchPriceAtTick{value: FEE * updates.length}(id, updates, CUTOFF);
    }

    /// @notice The tick settles at the price it carries, whenever that price was generated: on the
    ///         tick, a moment before it, or days earlier and carried forward ever since.
    function test_Tick_SettlesAtThePriceItCarries_HoweverOld() public {
        assertEq(_atTick(ASSET_JPY_FEED, LazerUpdate.one(_tick(ASSET_JPY_FEED, 3000e8, 30e8, CUTOFF, CUTOFF))), 3000e18);
        assertEq(
            _atTick(ASSET_JPY_FEED, LazerUpdate.one(_tick(ASSET_JPY_FEED, 3001e8, 0, CUTOFF, CUTOFF - 1))), 3001e18
        );
        assertEq(
            _atTick(ASSET_JPY_FEED, LazerUpdate.one(_tick(ASSET_JPY_FEED, 2990e8, 0, CUTOFF, CUTOFF - 3 days))),
            2990e18,
            "the feed's last price before a long quiet stretch"
        );
    }

    /// @notice Only the price and the exponent are read: a tick requested without the confidence
    ///         or the feed update timestamp settles all the same, and a confidence of any width
    ///         does not refuse it.
    function test_Tick_NeedsOnlyPriceAndExponent() public {
        bytes[] memory bare = LazerUpdate.one(
            LazerUpdate.sign(
                LazerUpdate.rawPayload(
                    CUTOFF * MICROS,
                    LazerUpdate.CHANNEL_FIXED_RATE_1000,
                    1,
                    LazerUpdate.rawFeed(
                        ASSET_JPY_FEED,
                        2,
                        abi.encodePacked(LazerUpdate.propExponent(EXPO), LazerUpdate.propPrice(3000e8))
                    )
                )
            )
        );
        assertEq(_atTick(ASSET_JPY_FEED, bare), 3000e18);
        assertEq(
            _atTick(ASSET_JPY_FEED, LazerUpdate.one(_tick(ASSET_JPY_FEED, 3000e8, 300e8, CUTOFF, CUTOFF))),
            3000e18,
            "10% confidence still settles"
        );
    }

    /// @notice A tick requested without the price or without the exponent reverts.
    function test_Tick_UpdateMissingPriceOrExponent_Reverts() public {
        bytes memory refusal =
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED);
        bytes[2] memory bodies = [
            abi.encodePacked(LazerUpdate.propPrice(3000e8), LazerUpdate.propGenerated(CUTOFF * MICROS)),
            abi.encodePacked(LazerUpdate.propExponent(EXPO), LazerUpdate.propGenerated(CUTOFF * MICROS))
        ];
        for (uint256 i = 0; i < 2; i++) {
            bytes[] memory updates = LazerUpdate.one(
                LazerUpdate.sign(
                    LazerUpdate.rawPayload(
                        CUTOFF * MICROS,
                        LazerUpdate.CHANNEL_FIXED_RATE_1000,
                        1,
                        LazerUpdate.rawFeed(ASSET_JPY_FEED, 2, bodies[i])
                    )
                )
            );
            vm.expectRevert(refusal);
            oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, updates, CUTOFF);
        }
    }

    /// @notice A tick at which the feed has no price settles nothing: it reverts, like any
    ///         non-positive price.
    function test_Tick_NoPriceOrNegativePrice_Reverts() public {
        bytes[] memory noPrice = LazerUpdate.one(_tick(ASSET_JPY_FEED, 0, 0, CUTOFF, CUTOFF));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, ASSET_JPY_FEED, int64(0), int32(EXPO)
            )
        );
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, noPrice, CUTOFF);

        bytes[] memory negative = LazerUpdate.one(_tick(ASSET_JPY_FEED, -1e8, 0, CUTOFF, CUTOFF));
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__InvalidPrice.selector);
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, negative, CUTOFF);
    }

    /// @notice Only the one-second channel's update stamped exactly on the tick is read.
    function test_Tick_AnotherSecondOrAnotherChannel_Reverts() public {
        bytes[] memory early = LazerUpdate.one(_tick(ASSET_JPY_FEED, 3000e8, 0, CUTOFF - 1, CUTOFF - 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__WrongTick.selector,
                (CUTOFF - 1) * MICROS,
                LazerUpdate.CHANNEL_FIXED_RATE_1000
            )
        );
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, early, CUTOFF);

        bytes[] memory late = LazerUpdate.one(_tick(ASSET_JPY_FEED, 3000e8, 0, CUTOFF + 1, CUTOFF));
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__WrongTick.selector);
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, late, CUTOFF);

        bytes[] memory realTime = LazerUpdate.one(_live(ASSET_JPY_FEED, 3000e8, 1, CUTOFF));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__WrongTick.selector, CUTOFF * MICROS, LazerUpdate.CHANNEL_REAL_TIME
            )
        );
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, realTime, CUTOFF);

        // On the one-second channel but between two seconds.
        bytes memory offGrid = LazerUpdate.sign(
            LazerUpdate.payload(
                CUTOFF * MICROS + 1,
                LazerUpdate.CHANNEL_FIXED_RATE_1000,
                LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 0, EXPO, CUTOFF * MICROS)
            )
        );
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__WrongTick.selector);
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, LazerUpdate.one(offGrid), CUTOFF);
    }

    function test_Tick_NoUpdateOrAnotherFeed_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, ASSET_JPY_FEED));
        oracle.fetchPriceAtTick(ASSET_JPY_FEED, new bytes[](0), CUTOFF);

        bytes[] memory other = LazerUpdate.one(_tick(GBP_USD_FEED, 1.25e8, 0, CUTOFF, CUTOFF));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, ASSET_JPY_FEED));
        oracle.fetchPriceAtTick{value: FEE}(ASSET_JPY_FEED, other, CUTOFF);
    }

    function test_Tick_FeeMustMatchExactly() public {
        bytes[] memory updates = LazerUpdate.one(_tick(ASSET_JPY_FEED, 3000e8, 0, CUTOFF, CUTOFF));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeeMismatch.selector, FEE + 1, FEE));
        oracle.fetchPriceAtTick{value: FEE + 1}(ASSET_JPY_FEED, updates, CUTOFF);
    }

    /// @notice A composite's tick carries both legs in one update or in one each, and each leg
    ///         settles at the price it carries: here the equity leg closed an hour before the
    ///         cutoff and its close is what the tick still holds.
    function test_Tick_Composite() public {
        bytes32 compositeId = _registerJpyComposite();

        bytes memory both = LazerUpdate.sign(
            LazerUpdate.payload(
                CUTOFF * MICROS,
                LazerUpdate.CHANNEL_FIXED_RATE_1000,
                LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 0, EXPO, (CUTOFF - 3600) * MICROS),
                LazerUpdate.feed(USD_JPY_FEED, 150e8, 0, EXPO, CUTOFF * MICROS)
            )
        );
        assertEq(_atTick(compositeId, LazerUpdate.one(both)), 20e18);

        bytes[] memory apart = LazerUpdate.two(
            _tick(USD_JPY_FEED, 150e8, 0, CUTOFF, CUTOFF), _tick(ASSET_JPY_FEED, 3150e8, 0, CUTOFF, CUTOFF - 2)
        );
        assertEq(_atTick(compositeId, apart), 21e18);

        bytes[] memory quoteMissing = LazerUpdate.one(_tick(ASSET_JPY_FEED, 3000e8, 0, CUTOFF, CUTOFF));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, USD_JPY_FEED));
        oracle.fetchPriceAtTick{value: FEE}(compositeId, quoteMissing, CUTOFF);

        // One leg stamped a second off the tick refuses the whole call.
        bytes[] memory offTick = LazerUpdate.two(
            _tick(ASSET_JPY_FEED, 3000e8, 0, CUTOFF, CUTOFF), _tick(USD_JPY_FEED, 150e8, 0, CUTOFF + 1, CUTOFF + 1)
        );
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__WrongTick.selector);
        oracle.fetchPriceAtTick{value: 2 * FEE}(compositeId, offTick, CUTOFF);
    }

    // ==================== fetchChainedMedian ====================

    uint64 constant SPACING = 600;

    function _median(bytes32 id, bytes[] memory set, uint64 maxPublishTime, uint256 count) internal returns (uint256) {
        return oracle.fetchChainedMedian{value: FEE * set.length}(id, set, CUTOFF, maxPublishTime, SPACING, count);
    }

    /// @dev A one-second update for `tickTs` carrying `id` at `price`, generated on the tick.
    function _on(bytes32 id, int64 price, uint64 tickTs) internal pure returns (bytes memory) {
        return _tick(id, price, 0, tickTs, tickTs);
    }

    function test_Chain_SingleFeed_MedianOfSamplesOnTheirTargets() public {
        int64[5] memory prices = [int64(3000e8), 3300e8, 2700e8, 3200e8, 4100e8];
        bytes[] memory set = new bytes[](5);
        for (uint64 k = 0; k < 5; k++) {
            set[k] = _on(ASSET_JPY_FEED, prices[k], CUTOFF + k * SPACING);
        }
        assertEq(_median(ASSET_JPY_FEED, set, type(uint64).max, 5), 3200e18);
        assertEq(address(oracle).balance, 0, "one fee per update, nothing kept");
    }

    /// @notice The median of an even count is the upper of its two middle samples.
    function test_Chain_EvenCountTakesTheUpperMiddle() public {
        bytes[] memory set =
            LazerUpdate.two(_on(ASSET_JPY_FEED, 3000e8, CUTOFF), _on(ASSET_JPY_FEED, 3100e8, CUTOFF + SPACING));
        assertEq(_median(ASSET_JPY_FEED, set, type(uint64).max, 2), 3100e18);
    }

    function test_Chain_ZeroCount_Reverts() public {
        bytes[] memory set = LazerUpdate.one(_on(ASSET_JPY_FEED, 3000e8, CUTOFF));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, 1, 0));
        oracle.fetchChainedMedian{value: FEE}(ASSET_JPY_FEED, set, CUTOFF, type(uint64).max, SPACING, 0);
    }

    /// @notice A sample after a quiet stretch is proven by the tick before it, still carrying the
    ///         price from before the target, and the next target is measured from the sample's
    ///         tick, not from the cutoff.
    function test_Chain_QuietStretch_NextTargetFromTheSamplesTick() public {
        uint64 reopen = CUTOFF + 7200;
        bytes[] memory set = new bytes[](3);
        set[0] = _tick(ASSET_JPY_FEED, 3000e8, 0, reopen - 1, CUTOFF - 30); // quiet since before the cutoff
        set[1] = _on(ASSET_JPY_FEED, 2900e8, reopen);
        set[2] = _on(ASSET_JPY_FEED, 2950e8, reopen + SPACING);
        assertEq(_median(ASSET_JPY_FEED, set, type(uint64).max, 2), 2950e18);

        // Measured from the cutoff the second target would be CUTOFF + SPACING: the tick there is
        // before the real one and is refused.
        set[2] = _on(ASSET_JPY_FEED, 2950e8, CUTOFF + SPACING);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__SampleNotProven.selector, ASSET_JPY_FEED, reopen + SPACING, CUTOFF + SPACING
            )
        );
        oracle.fetchChainedMedian{value: 3 * FEE}(ASSET_JPY_FEED, set, CUTOFF, type(uint64).max, SPACING, 2);
    }

    /// @notice Every sample's tick is bounded: one a second past the limit is refused, one on it
    ///         accepted.
    function test_Chain_EverySampleBounded() public {
        bytes[] memory set =
            LazerUpdate.two(_on(ASSET_JPY_FEED, 3000e8, CUTOFF), _on(ASSET_JPY_FEED, 3100e8, CUTOFF + SPACING));
        assertEq(_median(ASSET_JPY_FEED, set, CUTOFF + SPACING, 2), 3100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__SampleTooLate.selector,
                ASSET_JPY_FEED,
                CUTOFF + SPACING,
                CUTOFF + SPACING - 1
            )
        );
        oracle.fetchChainedMedian{value: 2 * FEE}(ASSET_JPY_FEED, set, CUTOFF, CUTOFF + SPACING - 1, SPACING, 2);
    }

    /// @notice A sample's update must carry the price, exponent and feed update timestamp: leaving
    ///         the timestamp out cannot pass a later tick off as quiet.
    function test_Chain_UpdateMissingAProperty_Reverts() public {
        bytes memory noTimestamp = LazerUpdate.sign(
            LazerUpdate.rawPayload(
                CUTOFF * MICROS,
                LazerUpdate.CHANNEL_FIXED_RATE_1000,
                1,
                LazerUpdate.rawFeed(
                    ASSET_JPY_FEED, 2, abi.encodePacked(LazerUpdate.propPrice(3000e8), LazerUpdate.propExponent(EXPO))
                )
            )
        );
        bytes[] memory set = LazerUpdate.two(noTimestamp, _on(ASSET_JPY_FEED, 3000e8, CUTOFF + 1));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED));
        oracle.fetchChainedMedian{value: 2 * FEE}(ASSET_JPY_FEED, set, CUTOFF, type(uint64).max, SPACING, 1);
    }

    /// @notice A tick is quiet only when it carries a price generated before the target. One with
    ///         no price, or with a price and no generation time, says nothing about when the feed
    ///         last priced: it is neither a sample nor a quiet tick, and reverts rather than open
    ///         the way to a later tick.
    function test_Chain_TickThatIsNeitherSampleNorQuiet_Reverts() public {
        bytes memory refusal =
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED);
        bytes memory next = _on(ASSET_JPY_FEED, 3000e8, CUTOFF + 1);

        // A price, its timestamp property present but unset.
        bytes[] memory undated = LazerUpdate.two(_tick(ASSET_JPY_FEED, 3000e8, 0, CUTOFF, 0), next);
        vm.expectRevert(refusal);
        oracle.fetchChainedMedian{value: 2 * FEE}(ASSET_JPY_FEED, undated, CUTOFF, type(uint64).max, SPACING, 1);

        // No price, yet generated on the target.
        bytes[] memory dropped = LazerUpdate.two(_tick(ASSET_JPY_FEED, 0, 0, CUTOFF, CUTOFF), next);
        vm.expectRevert(refusal);
        oracle.fetchChainedMedian{value: 2 * FEE}(ASSET_JPY_FEED, dropped, CUTOFF, type(uint64).max, SPACING, 1);

        // No price beside a generation time from before the target.
        bytes[] memory emptied = LazerUpdate.two(_tick(ASSET_JPY_FEED, 0, 0, CUTOFF, CUTOFF - 60), next);
        vm.expectRevert(refusal);
        oracle.fetchChainedMedian{value: 2 * FEE}(ASSET_JPY_FEED, emptied, CUTOFF, type(uint64).max, SPACING, 1);
    }

    /// @notice A tick with no price and no generation time cannot stand in for a quiet one. If it
    ///         could, a set built on it would step over a price generated earlier in the stretch,
    ///         and whoever submits the set would choose between the two.
    function test_Chain_BlankTickIsNotAQuietProof() public {
        bytes[] memory overBlank =
            LazerUpdate.two(_tick(ASSET_JPY_FEED, 0, 0, CUTOFF + 9, 0), _on(ASSET_JPY_FEED, 3100e8, CUTOFF + 10));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__IncompleteFeed.selector, ASSET_JPY_FEED));
        oracle.fetchChainedMedian{value: 2 * FEE}(ASSET_JPY_FEED, overBlank, CUTOFF, type(uint64).max, SPACING, 1);

        // The sample the feed's history fixes: the first price generated at or after the target,
        // proven by the tick before it, which still carries a price from before the target.
        bytes[] memory proven = LazerUpdate.two(
            _tick(ASSET_JPY_FEED, 2900e8, 0, CUTOFF + 4, CUTOFF - 60), _on(ASSET_JPY_FEED, 3000e8, CUTOFF + 5)
        );
        assertEq(_median(ASSET_JPY_FEED, proven, type(uint64).max, 1), 3000e18);
    }

    /// @notice Generation times fall between seconds. A price generated a fraction of a second
    ///         before the target is before it, so the target's own tick is quiet and the sample
    ///         is the first tick after it carrying a price generated at or after the target.
    function test_Chain_SubSecondGenerationTimes() public {
        bytes memory beforeTarget = LazerUpdate.sign(
            LazerUpdate.payload(
                CUTOFF * MICROS,
                LazerUpdate.CHANNEL_FIXED_RATE_1000,
                LazerUpdate.feed(ASSET_JPY_FEED, 2999e8, 0, EXPO, CUTOFF * MICROS - 1)
            )
        );
        bytes memory afterTarget = LazerUpdate.sign(
            LazerUpdate.payload(
                (CUTOFF + 1) * MICROS,
                LazerUpdate.CHANNEL_FIXED_RATE_1000,
                LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 0, EXPO, CUTOFF * MICROS + 250_000)
            )
        );
        assertEq(_median(ASSET_JPY_FEED, LazerUpdate.two(beforeTarget, afterTarget), type(uint64).max, 1), 3000e18);

        // The target's tick alone does not qualify: its price is a microsecond too early.
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, 1, 2));
        oracle.fetchChainedMedian{value: FEE}(
            ASSET_JPY_FEED, LazerUpdate.one(beforeTarget), CUTOFF, type(uint64).max, SPACING, 1
        );
    }

    function test_Chain_FeeMustMatchExactly() public {
        bytes[] memory set = LazerUpdate.one(_on(ASSET_JPY_FEED, 3000e8, CUTOFF));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeeMismatch.selector, FEE + 1, FEE));
        oracle.fetchChainedMedian{value: FEE + 1}(ASSET_JPY_FEED, set, CUTOFF, type(uint64).max, SPACING, 1);
    }

    /// @notice For a composite each sample reads the base leg's proof, then the quote leg's, each
    ///         leg its own earliest tick, and the next target lies SPACING past the later of the
    ///         two. Here the FX leg prices on the cutoff and the equity leg an hour later.
    function test_Chain_Composite_NextTargetFromTheLaterLeg() public {
        bytes32 compositeId = _registerJpyComposite();
        uint64 baseOpen = CUTOFF + 3600;

        bytes[] memory set = new bytes[](5);
        // sample 1: the base leg behind its quiet tick, then the quote leg on the cutoff
        set[0] = _tick(ASSET_JPY_FEED, 2990e8, 0, baseOpen - 1, CUTOFF - 60);
        set[1] = _on(ASSET_JPY_FEED, 3000e8, baseOpen);
        set[2] = _on(USD_JPY_FEED, 150e8, CUTOFF);
        // sample 2: both legs on the target, SPACING past the later leg
        set[3] = _on(ASSET_JPY_FEED, 3150e8, baseOpen + SPACING);
        set[4] = _on(USD_JPY_FEED, 150e8, baseOpen + SPACING);
        assertEq(_median(compositeId, set, type(uint64).max, 2), 21e18, "the upper of $20 and $21");

        // A second sample SPACING past the quote leg's earlier tick sits before the real target.
        set[3] = _on(ASSET_JPY_FEED, 3150e8, CUTOFF + SPACING);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__SampleNotProven.selector,
                ASSET_JPY_FEED,
                baseOpen + SPACING,
                CUTOFF + SPACING
            )
        );
        oracle.fetchChainedMedian{value: 5 * FEE}(compositeId, set, CUTOFF, type(uint64).max, SPACING, 2);
    }

    /// @notice The legs of a sample are read base first: offered the other way round, the quote
    ///         leg's update does not carry the base feed.
    function test_Chain_Composite_QuoteLegFirst_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes[] memory set = LazerUpdate.two(_on(USD_JPY_FEED, 150e8, CUTOFF), _on(ASSET_JPY_FEED, 3000e8, CUTOFF));
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, ASSET_JPY_FEED));
        oracle.fetchChainedMedian{value: 2 * FEE}(compositeId, set, CUTOFF, type(uint64).max, SPACING, 1);
    }

    /// @notice One update carrying both legs serves each leg in turn when supplied once per leg.
    function test_Chain_Composite_BothLegsInOneUpdateSuppliedPerLeg() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes memory both = LazerUpdate.sign(
            LazerUpdate.payload(
                CUTOFF * MICROS,
                LazerUpdate.CHANNEL_FIXED_RATE_1000,
                LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 0, EXPO, CUTOFF * MICROS),
                LazerUpdate.feed(USD_JPY_FEED, 150e8, 0, EXPO, CUTOFF * MICROS)
            )
        );
        assertEq(_median(compositeId, LazerUpdate.two(both, both), type(uint64).max, 1), 20e18);

        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, 1, 2));
        oracle.fetchChainedMedian{value: FEE}(compositeId, LazerUpdate.one(both), CUTOFF, type(uint64).max, SPACING, 1);
    }
}
