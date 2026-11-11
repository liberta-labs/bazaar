// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPythLazer} from "./interfaces/IPythLazer.sol";
import {BazaarMathLib} from "./libraries/BazaarMathLib.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {LazerPayloadLib} from "./libraries/LazerPayloadLib.sol";

/// @title BazaarOracle
/// @notice Shared Pyth Pro oracle contract that all BazaarPair instances call.
///         Pyth Pro keeps no prices on-chain: its PythLazer contract only checks that an update
///         is signed by a signer Pyth trusts. Every price this contract returns therefore comes
///         out of updates the caller supplies, and this contract is what reads them, decides
///         whether a price is recent enough, and bounds its confidence.
///         USDC quote is hardcoded to $1 — assets quoted directly in USD need only the
///         base asset price. Assets quoted in another currency use a registered
///         composite feed: a base leg (the asset in its native currency) combined with
///         an FX leg that converts that currency to USD. Composite IDs are deterministic
///         hashes of their legs and are passed around exactly like plain Pyth feed IDs;
///         callers never need to know whether an ID is raw or composite.
///         Returns directional bracket prices (low = spot − conf, high = spot + conf) so
///         callers can value long/short exposure conservatively without recomputing conf.
/// @dev A raw feed ID is a Pyth Pro feed ID, a non-zero 32-bit integer, held in a bytes32
///      (isRawFeedId). A composite ID is a keccak256 hash, so the two kinds cannot be mistaken for
///      one another: a hash below 2^32 is not something anyone can produce.
///
///      An update carries only the properties its requester asked Pyth for, so each path checks
///      that the ones it relies on are there (LazerPayloadLib.Feed.included). A price's age is
///      measured from its feedUpdateTimestamp, when the price was generated, never from the
///      update's own timestamp: while a market is shut Pyth keeps issuing updates that carry the
///      last price forward, each stamped with the current time.
contract BazaarOracle {
    // -------------------- Errors --------------------
    error BazaarOracle__ZeroAddress();
    error BazaarOracle__InvalidFeedId(bytes32 feedId);
    error BazaarOracle__InvalidPrice(bytes32 feedId, int64 price, int32 expo);
    error BazaarOracle__ConfidenceTooHigh(uint256 confidence, uint256 price);
    error BazaarOracle__InvalidCompositeLegs(bytes32 baseId, bytes32 quoteId);
    error BazaarOracle__FeeMismatch(uint256 supplied, uint256 required);
    error BazaarOracle__FeedNotInUpdate(bytes32 feedId);
    error BazaarOracle__IncompleteFeed(bytes32 feedId);
    error BazaarOracle__StalePrice(bytes32 feedId, uint256 generatedTs);
    error BazaarOracle__WrongTick(uint64 timestampUs, uint8 channel);
    error BazaarOracle__SampleCountMismatch(uint256 updates, uint256 expected);
    error BazaarOracle__SampleNotProven(bytes32 feedId, uint64 target, uint64 tick);
    error BazaarOracle__SampleTooLate(bytes32 feedId, uint64 tick, uint64 maxPublishTime);

    // -------------------- Events --------------------
    event CompositeFeedRegistered(
        bytes32 indexed compositeId, bytes32 indexed baseId, bytes32 indexed quoteId, bool invertQuote
    );

    // -------------------- Types --------------------
    /// @param baseId Pyth feed for the asset in its native quote currency (e.g. a JPY-quoted stock)
    /// @param quoteId Pyth FX feed linking that currency to USD (e.g. GBP/USD or USD/JPY)
    /// @param invertQuote False when the FX feed is CCY/USD (multiply), true when it is USD/CCY (divide)
    struct CompositeFeed {
        bytes32 baseId;
        bytes32 quoteId;
        bool invertQuote;
    }

    /// @dev A chained sample set's legs, its running target and how far into the supplied updates
    ///      it has read, held in memory so the parse loop stays shallow (see fetchChainedMedian).
    struct SampleChain {
        bytes32 baseId;
        bytes32 quoteId;
        bool invertQuote;
        uint64 target;
        uint64 maxPublishTime;
        uint256 fee;
        uint256 cursor;
    }

    // -------------------- Constants --------------------
    int32 public constant BAZAAR_EXPONENT = BazaarTypes.BAZAAR_EXPONENT;
    uint256 public constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 public constant BP_SCALE = BazaarTypes.BP_SCALE;
    uint256 public constant MAX_CONFIDENCE_BP = 200; // max Pyth confidence/price ratio: 2%

    /// @dev What an update must carry for a feed to price a live call: its price, the exponent
    ///      that scales it, its confidence, and when the price was generated.
    uint8 internal constant LIVE_PROPERTIES = LazerPayloadLib.HAS_PRICE | LazerPayloadLib.HAS_EXPONENT
        | LazerPayloadLib.HAS_CONFIDENCE | LazerPayloadLib.HAS_FEED_UPDATE_TIMESTAMP;
    /// @dev What a tick must carry for a feed to settle a pair at it: its price and the exponent
    ///      that scales it. Confidence is left out because the settlement paths do not apply the
    ///      confidence cap.
    uint8 internal constant TICK_PROPERTIES = LazerPayloadLib.HAS_PRICE | LazerPayloadLib.HAS_EXPONENT;
    /// @dev What a tick must carry to prove a chain sample: the tick properties, and when the
    ///      price was generated, which is what places it before or after a target.
    uint8 internal constant CHAIN_PROPERTIES = TICK_PROPERTIES | LazerPayloadLib.HAS_FEED_UPDATE_TIMESTAMP;

    // -------------------- Immutables --------------------
    /// @notice Pyth's PythLazer contract, which verifies the signature on every update.
    IPythLazer public immutable pythLazer;

    // -------------------- Storage --------------------
    /// @notice compositeId => underlying legs. Empty baseId means the key is a raw Pyth feed ID.
    mapping(bytes32 => CompositeFeed) public composites;

    constructor(address _pythLazer) {
        if (_pythLazer == address(0)) revert BazaarOracle__ZeroAddress();
        pythLazer = IPythLazer(_pythLazer);
    }

    // ================================================================
    //                       Composite feed registry
    // ================================================================

    /// @notice Register a composite feed that prices a non-USD-quoted asset in USD by
    ///         combining the asset's native-currency feed with an FX feed.
    /// @dev Permissionless and idempotent: the composite ID is the hash of the legs, so a
    ///      given ID can only ever resolve to one (baseId, quoteId, invertQuote) tuple. Both legs
    ///      must be raw feed IDs, which also rules out nesting one composite inside another.
    /// @param baseId Pyth feed ID for the asset in its native quote currency
    /// @param quoteId Pyth FX feed ID linking that currency to USD
    /// @param invertQuote False when the FX feed is CCY/USD (e.g. GBP/USD — multiply),
    ///                    true when it is USD/CCY (e.g. USD/JPY — divide)
    /// @return compositeId The deterministic ID to use anywhere a feed ID is expected
    function registerComposite(bytes32 baseId, bytes32 quoteId, bool invertQuote)
        external
        returns (bytes32 compositeId)
    {
        if (!isRawFeedId(baseId) || !isRawFeedId(quoteId) || baseId == quoteId) {
            revert BazaarOracle__InvalidCompositeLegs(baseId, quoteId);
        }

        compositeId = getCompositeId(baseId, quoteId, invertQuote);
        if (composites[compositeId].baseId == bytes32(0)) {
            composites[compositeId] = CompositeFeed({baseId: baseId, quoteId: quoteId, invertQuote: invertQuote});
            emit CompositeFeedRegistered(compositeId, baseId, quoteId, invertQuote);
        }
    }

    /// @notice Deterministic composite ID for a given leg configuration.
    function getCompositeId(bytes32 baseId, bytes32 quoteId, bool invertQuote) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseId, quoteId, invertQuote));
    }

    /// @notice Whether `feedId` has the form of a raw Pyth Pro feed ID: a non-zero 32-bit integer
    ///         held in a bytes32. Says nothing about whether Pyth publishes such a feed.
    function isRawFeedId(bytes32 feedId) public pure returns (bool) {
        return feedId != bytes32(0) && uint256(feedId) <= type(uint32).max;
    }

    // ================================================================
    //                               Fees
    // ================================================================

    /// @notice Returns the ETH fee for having Pyth verify `updates` updates: every price function
    ///         below must be sent exactly this for the updates it is given.
    /// @param updates How many updates the call will carry
    /// @return The total fee in wei
    function getUpdateFee(uint256 updates) external view returns (uint256) {
        return pythLazer.verification_fee() * updates;
    }

    // ================================================================
    //                  Live price (payable, pays Pyth's fee)
    // ================================================================

    /// @notice Verify the supplied updates and return the USD price they carry, provided it was
    ///         generated within `maxStaleness` of the block.
    /// @dev Each leg is read from whichever supplied update holds its most recently generated
    ///      price, so a composite's legs may arrive in one update or in two, and an update for an
    ///      unrelated feed is ignored. Each leg must carry its price, exponent, confidence and
    ///      feed update timestamp in the update it is read from: a leg requested without one of
    ///      them reverts rather than being priced without it. Pyth writes a property it has no value for as zero, so a zero
    ///      confidence is an absent one and reverts the same way: the cap is never passed by a
    ///      price Pyth could not bound. Reverts on a non-positive price and on confidence above
    ///      MAX_CONFIDENCE_BP, per leg and, for a composite, on the composed bracket.
    ///
    ///      `maxStaleness` bounds the distance between the block timestamp and the second the price
    ///      was generated in, in either direction, since Pyth's clock may run slightly ahead of
    ///      the block's.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param priceUpdate The signed Pyth Pro updates; `msg.value` must equal getUpdateFee of their count
    /// @param maxStaleness Maximum acceptable age in seconds (applies to every leg)
    /// @return spotPrice The USD price normalized to BAZAAR_SCALE
    /// @return lowPrice spotPrice − confidence (floored at 1 wei)
    /// @return highPrice spotPrice + confidence
    /// @return publishTime The second the price was generated in (the older leg's for composites)
    function verifyAndFetchPrice(bytes32 baseFeedId, bytes[] calldata priceUpdate, uint256 maxStaleness)
        external
        payable
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = _resolve(baseFeedId);
        uint256 fee = _perUpdateFee(priceUpdate.length);

        LazerPayloadLib.Feed memory base;
        LazerPayloadLib.Feed memory quote;
        for (uint256 i = 0; i < priceUpdate.length; i++) {
            (,, LazerPayloadLib.Feed memory b, LazerPayloadLib.Feed memory q) =
                _verifyAndRead(priceUpdate[i], fee, baseId, quoteId);
            if (_isNewer(b, base)) base = b;
            if (_isNewer(q, quote)) quote = q;
        }

        _requireLive(baseId, base, maxStaleness);
        if (quoteId == bytes32(0)) {
            return _normalizeBase(baseId, base);
        }
        _requireLive(quoteId, quote, maxStaleness);
        return _composeSafe(baseId, base, quote, quoteId, invertQuote);
    }

    // ================================================================
    //                Settlement prices (payable, pays Pyth's fee)
    // ================================================================

    /// @notice Read the USD price Pyth's one-second channel carried at `tick`: the feed's most
    ///         recent price as of that second.
    /// @dev Every supplied update must be from the fixed-rate one-second channel and stamped
    ///      exactly `tick`. That channel issues one update per second, on the second, and Pyth's
    ///      aggregation is deterministic, so there is one price per feed for a given tick:
    ///      whoever supplies the update chooses nothing. While a feed is quiet Pyth carries its
    ///      last price forward under each new tick, so the tick prices a feed that produced
    ///      nothing on that second too, at the last price it did produce. A feed with no price at
    ///      all at the tick reverts, as any non-positive price does.
    ///
    ///      Each leg must carry its price and exponent. Nothing else enters the result, so
    ///      nothing a requester adds or leaves out changes it. A composite's legs may arrive in one
    ///      update or in one each.
    ///
    ///      The confidence cap is deliberately NOT applied. There is exactly one price for the
    ///      tick, so a cap could never redirect to a better one — it could only refuse, which
    ///      leaves the caller only its stored-price fallback, after whatever wait that fallback
    ///      carries, even though a genuine price exists. The first price after a closed session is
    ///      routinely wide, so a cap would push every off-hours cutoff onto that fallback.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param priceUpdate The tick's update(s): one carrying every leg, or one per leg;
    ///        `msg.value` must equal getUpdateFee of their count
    /// @param tick The second the update must be stamped with
    /// @return spotPrice The USD price normalized to BAZAAR_SCALE
    function fetchPriceAtTick(bytes32 baseFeedId, bytes[] calldata priceUpdate, uint64 tick)
        external
        payable
        returns (uint256 spotPrice)
    {
        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = _resolve(baseFeedId);
        uint256 fee = _perUpdateFee(priceUpdate.length);

        LazerPayloadLib.Feed memory base;
        LazerPayloadLib.Feed memory quote;
        for (uint256 i = 0; i < priceUpdate.length; i++) {
            (uint64 timestamp, uint8 channel, LazerPayloadLib.Feed memory b, LazerPayloadLib.Feed memory q) =
                _verifyAndRead(priceUpdate[i], fee, baseId, quoteId);
            if (
                channel != LazerPayloadLib.CHANNEL_FIXED_RATE_1000
                    || timestamp != uint256(tick) * LazerPayloadLib.MICROS_PER_SECOND
            ) {
                revert BazaarOracle__WrongTick(timestamp, channel);
            }
            if (b.found && !base.found) base = b;
            if (q.found && !quote.found) quote = q;
        }

        _requireTickProperties(baseId, base);
        if (quoteId == bytes32(0)) {
            (spotPrice,,,) = _normalizeBaseUnsafe(baseId, base);
            return spotPrice;
        }
        _requireTickProperties(quoteId, quote);
        (spotPrice,,,) = _composeUnsafe(baseId, base, quoteId, quote, invertQuote);
    }

    /// @notice Parse a chained sample set and return the median of its USD prices. The first
    ///         sample is the earliest one-second tick carrying a price generated at or after
    ///         `firstTarget`; each later sample is the earliest tick carrying a price generated at
    ///         or after `spacing` past the tick of the sample before it (the later of its two
    ///         legs' for a composite). Every sample's tick must be no later than
    ///         `maxPublishTime`, and the set must hold exactly `count` samples.
    /// @dev A sample's leg is proven in one of two ways. When the tick stamped with the target
    ///      itself carries a price generated at or after the target, that one update is the
    ///      proof: no earlier tick could qualify. Otherwise two consecutive ticks are supplied, in
    ///      order: one at or after the target whose price was generated before the target, which
    ///      shows the feed produced nothing from the target up to that tick, and the next
    ///      second's, whose price was generated at or after the target. Pyth carries a quiet
    ///      feed's last price forward under every tick, so the first of the two exists however
    ///      long the feed stays quiet.
    ///
    ///      The whole set is therefore fixed by the feed's history alone: every target after the
    ///      first is computed here from the tick verified for the sample before, never taken from
    ///      the caller, and a set built from any other ticks, in any other order, or with a sample
    ///      short reverts, so whoever submits it chooses nothing. Measuring each target from the
    ///      previous sample rather than from the first keeps the samples apart whatever the feed
    ///      does: a target that falls in a quiet stretch resolves to the feed's next price, and
    ///      the target after it moves past that, so a cutoff at a session's close yields, after at
    ///      most the closing price itself, prices from the reopen onward instead of the reopen's
    ///      first price over and over. The median
    ///      of an odd count is its middle sample, so moving it means moving more than half of the
    ///      samples.
    ///
    ///      The updates are read in order: for each sample, the base leg's one or two, then for a
    ///      composite the quote leg's one or two. Every update is from the one-second channel and
    ///      is verified in a Pyth call of its own, and `msg.value` must equal getUpdateFee of
    ///      their count, so no ETH is left here. Every update must carry its leg's exponent, a
    ///      price and the time that price was generated: a tick without either of the last two
    ///      reverts, so neither leaving the timestamp out nor a tick with no price can pass for a
    ///      quiet one. As in fetchPriceAtTick the confidence cap is not applied, since each sample
    ///      has exactly one qualifying price and a cap could only refuse it; only a non-positive
    ///      price is rejected.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param priceUpdate The sample set, in the order described above
    /// @param firstTarget The first sample's target, in seconds
    /// @param maxPublishTime Latest acceptable tick for every sample, in seconds
    /// @param spacing How far after a sample's tick the next sample's target lies, in seconds
    /// @param count How many samples the set must hold
    /// @return medianPrice The median sample price, normalized to BAZAAR_SCALE
    function fetchChainedMedian(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 firstTarget,
        uint64 maxPublishTime,
        uint64 spacing,
        uint256 count
    ) external payable returns (uint256 medianPrice) {
        if (count == 0) revert BazaarOracle__SampleCountMismatch(priceUpdate.length, 0);

        SampleChain memory chain;
        (chain.baseId, chain.quoteId, chain.invertQuote) = _resolve(baseFeedId);
        chain.target = firstTarget;
        chain.maxPublishTime = maxPublishTime;
        chain.fee = _perUpdateFee(priceUpdate.length);

        uint256[] memory prices = new uint256[](count);
        for (uint256 k = 0; k < count; k++) {
            prices[k] = _parseSample(chain, priceUpdate, spacing);
        }
        if (chain.cursor != priceUpdate.length) {
            revert BazaarOracle__SampleCountMismatch(priceUpdate.length, chain.cursor);
        }
        medianPrice = _median(prices);
    }

    // ================================================================
    //                         Internal helpers
    // ================================================================

    /// @dev Pyth's fee for one update, after checking that the call carries exactly that for each
    ///      of its `updates` updates. Exact because each update is verified at that fee and
    ///      nothing else is spent: any excess would stay in this contract, which has no way to
    ///      pass it on.
    function _perUpdateFee(uint256 updates) internal view returns (uint256 fee) {
        fee = pythLazer.verification_fee();
        if (msg.value != fee * updates) revert BazaarOracle__FeeMismatch(msg.value, fee * updates);
    }

    /// @dev Has Pyth verify `update`, then reads feeds `idA` and `idB` out of its payload. Both
    ///      IDs are raw feed IDs, or `idB` is zero to read one feed.
    function _verifyAndRead(bytes calldata update, uint256 fee, bytes32 idA, bytes32 idB)
        internal
        returns (uint64 timestamp, uint8 channel, LazerPayloadLib.Feed memory a, LazerPayloadLib.Feed memory b)
    {
        (bytes memory payload,) = pythLazer.verifyUpdate{value: fee}(update);
        return LazerPayloadLib.readFeeds(payload, uint32(uint256(idA)), uint32(uint256(idB)));
    }

    /// @dev True when `candidate` holds the feed and `current` either does not or holds a price
    ///      generated earlier.
    function _isNewer(LazerPayloadLib.Feed memory candidate, LazerPayloadLib.Feed memory current)
        internal
        pure
        returns (bool)
    {
        return candidate.found && (!current.found || candidate.feedUpdateTimestamp > current.feedUpdateTimestamp);
    }

    /// @dev Reverts unless `feed` was supplied, carries every property a live price needs with a
    ///      value for its confidence and its generation time, and was generated within
    ///      `maxStaleness` seconds of the block in either direction.
    function _requireLive(bytes32 feedId, LazerPayloadLib.Feed memory feed, uint256 maxStaleness) internal view {
        if (!feed.found) revert BazaarOracle__FeedNotInUpdate(feedId);
        if (feed.included & LIVE_PROPERTIES != LIVE_PROPERTIES || feed.feedUpdateTimestamp == 0 || feed.confidence == 0)
        {
            revert BazaarOracle__IncompleteFeed(feedId);
        }
        uint256 generated = LazerPayloadLib.toSeconds(feed.feedUpdateTimestamp);
        uint256 distance = generated > block.timestamp ? generated - block.timestamp : block.timestamp - generated;
        if (distance > maxStaleness) revert BazaarOracle__StalePrice(feedId, generated);
    }

    /// @dev Reverts unless `feed` was supplied with the properties a tick's price needs.
    function _requireTickProperties(bytes32 feedId, LazerPayloadLib.Feed memory feed) internal pure {
        if (!feed.found) revert BazaarOracle__FeedNotInUpdate(feedId);
        if (feed.included & TICK_PROPERTIES != TICK_PROPERTIES) revert BazaarOracle__IncompleteFeed(feedId);
    }

    /// @dev What the tick `feed` was read from says about second `since`: true when it carries a
    ///      price generated at or after it, false when the price it carries was generated earlier,
    ///      which shows the feed generated nothing from then up to the tick. Reverts unless the
    ///      feed was supplied with its price, exponent and feed update timestamp, and when it has
    ///      no price or no generation time: a tick that does not say when the feed last priced
    ///      would otherwise pass for a quiet one and let whoever submits the set step over a price
    ///      that qualifies.
    function _pricedSince(bytes32 feedId, LazerPayloadLib.Feed memory feed, uint64 since) internal pure returns (bool) {
        if (!feed.found) revert BazaarOracle__FeedNotInUpdate(feedId);
        if (feed.included & CHAIN_PROPERTIES != CHAIN_PROPERTIES || feed.price == 0 || feed.feedUpdateTimestamp == 0) {
            revert BazaarOracle__IncompleteFeed(feedId);
        }
        return feed.feedUpdateTimestamp >= uint256(since) * LazerPayloadLib.MICROS_PER_SECOND;
    }

    /// @dev Parses one sample of `chain`: each leg's earliest tick carrying a price generated at
    ///      or after the chain's target, composed to a USD price. Then moves the target to
    ///      `spacing` past the later leg's tick, where the next sample starts.
    /// @param chain The chain's legs, its current target, its maximum tick and its read position;
    ///        the target and the position are advanced in place
    /// @param priceUpdate The whole sample set
    /// @param spacing How far after this sample's tick the next sample's target lies
    /// @return price The sample's USD price, normalized to BAZAAR_SCALE
    function _parseSample(SampleChain memory chain, bytes[] calldata priceUpdate, uint64 spacing)
        internal
        returns (uint256 price)
    {
        (LazerPayloadLib.Feed memory base, uint64 tick) = _sampleLeg(chain, priceUpdate, chain.baseId);
        if (chain.quoteId == bytes32(0)) {
            (price,,,) = _normalizeBaseUnsafe(chain.baseId, base);
        } else {
            (LazerPayloadLib.Feed memory quote, uint64 quoteTick) = _sampleLeg(chain, priceUpdate, chain.quoteId);
            (price,,,) = _composeUnsafe(chain.baseId, base, chain.quoteId, quote, chain.invertQuote);
            if (quoteTick > tick) tick = quoteTick;
        }
        // A target past the uint64 range reverts here rather than wrapping to an earlier one.
        chain.target = tick + spacing;
    }

    /// @dev Reads one leg of the chain's current sample and proves it is the earliest tick
    ///      carrying a price generated at or after the target (see fetchChainedMedian).
    /// @param chain The chain's current target, its maximum tick and its read position; the
    ///        position is advanced past the one or two updates read
    /// @param priceUpdate The whole sample set
    /// @param legId The feed to read out of the sample's updates
    /// @return feed The leg's fields at the sample's tick
    /// @return tick The sample's tick, in seconds
    function _sampleLeg(SampleChain memory chain, bytes[] calldata priceUpdate, bytes32 legId)
        internal
        returns (LazerPayloadLib.Feed memory feed, uint64 tick)
    {
        (feed, tick) = _nextTick(chain, priceUpdate, legId);
        // A tick before the target says nothing about what the feed did from the target on.
        if (tick < chain.target) revert BazaarOracle__SampleNotProven(legId, chain.target, tick);

        if (_pricedSince(legId, feed, chain.target)) {
            // Only the target's own tick proves itself; a later one needs the quiet tick before it.
            if (tick != chain.target) revert BazaarOracle__SampleNotProven(legId, chain.target, tick);
        } else {
            uint64 quietTick = tick;
            (feed, tick) = _nextTick(chain, priceUpdate, legId);
            if (tick != quietTick + 1 || !_pricedSince(legId, feed, chain.target)) {
                revert BazaarOracle__SampleNotProven(legId, chain.target, tick);
            }
        }

        if (tick > chain.maxPublishTime) revert BazaarOracle__SampleTooLate(legId, tick, chain.maxPublishTime);
    }

    /// @dev Verifies the chain's next unread update, which must be a one-second tick, and reads
    ///      `legId` out of it.
    function _nextTick(SampleChain memory chain, bytes[] calldata priceUpdate, bytes32 legId)
        internal
        returns (LazerPayloadLib.Feed memory feed, uint64 tick)
    {
        uint256 index = chain.cursor;
        if (index >= priceUpdate.length) revert BazaarOracle__SampleCountMismatch(priceUpdate.length, index + 1);
        chain.cursor = index + 1;

        uint64 timestamp;
        uint8 channel;
        (timestamp, channel, feed,) = _verifyAndRead(priceUpdate[index], chain.fee, legId, bytes32(0));
        if (channel != LazerPayloadLib.CHANNEL_FIXED_RATE_1000 || timestamp % LazerPayloadLib.MICROS_PER_SECOND != 0) {
            revert BazaarOracle__WrongTick(timestamp, channel);
        }
        tick = uint64(LazerPayloadLib.toSeconds(timestamp));
    }

    /// @dev The middle value of `values` once sorted, sorting them in place: the median of an odd
    ///      count, and the upper of the two middle values of an even one.
    function _median(uint256[] memory values) internal pure returns (uint256) {
        uint256 n = values.length;
        for (uint256 i = 1; i < n; i++) {
            uint256 v = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > v) {
                values[j] = values[j - 1];
                j--;
            }
            values[j] = v;
        }
        return values[n / 2];
    }

    /// @dev Resolve a feed ID into its legs. A raw Pyth ID resolves to itself with no quote leg;
    ///      an ID that is neither a registered composite nor a raw ID reverts.
    function _resolve(bytes32 feedId) internal view returns (bytes32 baseId, bytes32 quoteId, bool invertQuote) {
        CompositeFeed storage c = composites[feedId];
        baseId = c.baseId;
        if (baseId != bytes32(0)) {
            return (baseId, c.quoteId, c.invertQuote);
        }
        if (!isRawFeedId(feedId)) revert BazaarOracle__InvalidFeedId(feedId);
        return (feedId, bytes32(0), false);
    }

    /// @dev True iff the COMPOSED bracket is within MAX_CONFIDENCE_BP of the composed spot on
    ///      both sides. Per-leg checks are necessary but not sufficient for composites: relative
    ///      widths ADD under multiply/divide, so two legs at the cap compound to ~2× it. This
    ///      enforces the total-uncertainty policy on the result, letting the legs share the 2%
    ///      budget however it falls (1.8% + 0.15% passes; 1.2% + 1.2% fails).
    function _composedBracketOk(uint256 spotPrice, uint256 lowPrice, uint256 highPrice) internal pure returns (bool) {
        uint256 cap = spotPrice * MAX_CONFIDENCE_BP;
        return (highPrice - spotPrice) * BP_SCALE <= cap && (spotPrice - lowPrice) * BP_SCALE <= cap;
    }

    /// @dev Normalize base price to BAZAAR_SCALE, validate confidence ratio, and compute bracket.
    ///      For single-feed assets the USDC quote is assumed to be $1, so spotPrice = baseNorm.
    function _normalizeBase(bytes32 baseId, LazerPayloadLib.Feed memory base)
        internal
        pure
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        // A non-positive price is an oracle malfunction (real prices are positive), and a zero one
        // is how Pyth encodes a feed with no price. Reject it on every path rather than flooring —
        // operating on a zero/negative price mass-liquidates longs and mis-values positions.
        // Symmetric with the quote-leg rejection.
        if (base.price <= 0) {
            revert BazaarOracle__InvalidPrice(baseId, base.price, base.exponent);
        }

        int256 baseNorm = BazaarMathLib.convertExponent(int256(base.price), base.exponent, BAZAAR_EXPONENT);
        if (baseNorm <= 0) revert BazaarOracle__InvalidPrice(baseId, base.price, base.exponent);
        int256 baseConf =
            BazaarMathLib.convertExponent(int256(uint256(base.confidence)), base.exponent, BAZAAR_EXPONENT);

        // Validate confidence-to-price ratio: revert if conf/price > MAX_CONFIDENCE_BP/BP_SCALE
        if (uint256(baseConf) * BP_SCALE > uint256(baseNorm) * MAX_CONFIDENCE_BP) {
            revert BazaarOracle__ConfidenceTooHigh(uint256(baseConf), uint256(baseNorm));
        }

        spotPrice = uint256(baseNorm);
        uint256 conf = baseConf > 0 ? uint256(baseConf) : 0;
        lowPrice = conf >= spotPrice ? 1 : spotPrice - conf;
        highPrice = spotPrice + conf;
        publishTime = LazerPayloadLib.toSeconds(base.feedUpdateTimestamp);
    }

    /// @dev Same normalization as _normalizeBase but without the confidence ratio check
    ///      (the settlement paths accept the one print there is).
    function _normalizeBaseUnsafe(bytes32 baseId, LazerPayloadLib.Feed memory base)
        internal
        pure
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        // Reject non-positive prices on this path too — a zero/negative price is a malfunction,
        // not "degraded but usable" data (matches the safe path and the quote leg).
        if (base.price <= 0) {
            revert BazaarOracle__InvalidPrice(baseId, base.price, base.exponent);
        }

        int256 baseNorm = BazaarMathLib.convertExponent(int256(base.price), base.exponent, BAZAAR_EXPONENT);
        if (baseNorm <= 0) revert BazaarOracle__InvalidPrice(baseId, base.price, base.exponent);

        spotPrice = uint256(baseNorm);

        int256 baseConf =
            BazaarMathLib.convertExponent(int256(uint256(base.confidence)), base.exponent, BAZAAR_EXPONENT);
        uint256 conf = baseConf > 0 ? uint256(baseConf) : 0;
        lowPrice = conf >= spotPrice ? 1 : spotPrice - conf;
        highPrice = spotPrice + conf;
        publishTime = LazerPayloadLib.toSeconds(base.feedUpdateTimestamp);
    }

    /// @dev Normalize the FX quote leg. A zero or negative quote is a hard error in every path,
    ///      as it is for the base leg: the quote scales the whole composite price, so flooring it
    ///      instead would explode the result.
    function _normalizeQuote(bytes32 quoteId, LazerPayloadLib.Feed memory quote, bool enforceConfRatio)
        internal
        pure
        returns (uint256 spot, uint256 low, uint256 high, uint256 publishTime)
    {
        if (quote.price <= 0) {
            revert BazaarOracle__InvalidPrice(quoteId, quote.price, quote.exponent);
        }

        int256 quoteNorm = BazaarMathLib.convertExponent(int256(quote.price), quote.exponent, BAZAAR_EXPONENT);
        if (quoteNorm <= 0) {
            revert BazaarOracle__InvalidPrice(quoteId, quote.price, quote.exponent);
        }

        int256 quoteConf =
            BazaarMathLib.convertExponent(int256(uint256(quote.confidence)), quote.exponent, BAZAAR_EXPONENT);
        uint256 conf = quoteConf > 0 ? uint256(quoteConf) : 0;

        if (enforceConfRatio && conf * BP_SCALE > uint256(quoteNorm) * MAX_CONFIDENCE_BP) {
            revert BazaarOracle__ConfidenceTooHigh(conf, uint256(quoteNorm));
        }

        spot = uint256(quoteNorm);
        low = conf >= spot ? 1 : spot - conf;
        high = spot + conf;
        publishTime = LazerPayloadLib.toSeconds(quote.feedUpdateTimestamp);
    }

    /// @dev Normalize both legs with confidence ratio checks, then combine into a USD price.
    ///      The per-leg checks fast-fail obviously-bad inputs; the composed bracket is then held
    ///      to the same MAX_CONFIDENCE_BP so composites never act above 2% TOTAL uncertainty.
    function _composeSafe(
        bytes32 baseId,
        LazerPayloadLib.Feed memory base,
        LazerPayloadLib.Feed memory quote,
        bytes32 quoteId,
        bool invertQuote
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        (uint256 bSpot, uint256 bLow, uint256 bHigh, uint256 bPub) = _normalizeBase(baseId, base);
        (uint256 qSpot, uint256 qLow, uint256 qHigh, uint256 qPub) = _normalizeQuote(quoteId, quote, true);
        (uint256 spot, uint256 low, uint256 high, uint256 pub) =
            _compose(bSpot, bLow, bHigh, bPub, qSpot, qLow, qHigh, qPub, invertQuote);
        if (!_composedBracketOk(spot, low, high)) {
            uint256 dev = high - spot > spot - low ? high - spot : spot - low;
            revert BazaarOracle__ConfidenceTooHigh(dev, spot);
        }
        return (spot, low, high, pub);
    }

    /// @dev Normalize both legs without confidence ratio checks, then combine into a USD price.
    function _composeUnsafe(
        bytes32 baseId,
        LazerPayloadLib.Feed memory base,
        bytes32 quoteId,
        LazerPayloadLib.Feed memory quote,
        bool invertQuote
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        (uint256 bSpot, uint256 bLow, uint256 bHigh, uint256 bPub) = _normalizeBaseUnsafe(baseId, base);
        (uint256 qSpot, uint256 qLow, uint256 qHigh, uint256 qPub) = _normalizeQuote(quoteId, quote, false);
        return _compose(bSpot, bLow, bHigh, bPub, qSpot, qLow, qHigh, qPub, invertQuote);
    }

    /// @dev Combine two normalized legs into a USD composite. The bracket pairs each base
    ///      bound with the quote bound that moves the result in the same direction, so the
    ///      composite bracket stays conservative for both long and short exposure.
    function _compose(
        uint256 baseSpot,
        uint256 baseLow,
        uint256 baseHigh,
        uint256 basePub,
        uint256 quoteSpot,
        uint256 quoteLow,
        uint256 quoteHigh,
        uint256 quotePub,
        bool invertQuote
    ) internal pure returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime) {
        if (invertQuote) {
            // Quote feed is USD/CCY (CCY per USD) — divide
            spotPrice = Math.mulDiv(baseSpot, BAZAAR_SCALE, quoteSpot);
            lowPrice = Math.mulDiv(baseLow, BAZAAR_SCALE, quoteHigh);
            highPrice = Math.mulDiv(baseHigh, BAZAAR_SCALE, quoteLow);
        } else {
            // Quote feed is CCY/USD (USD per CCY) — multiply
            spotPrice = Math.mulDiv(baseSpot, quoteSpot, BAZAAR_SCALE);
            lowPrice = Math.mulDiv(baseLow, quoteLow, BAZAAR_SCALE);
            highPrice = Math.mulDiv(baseHigh, quoteHigh, BAZAAR_SCALE);
        }

        // Preserve the single-feed path's 1-wei floor semantics after rounding
        if (spotPrice == 0) spotPrice = 1;
        if (lowPrice == 0) lowPrice = 1;
        if (highPrice < spotPrice) highPrice = spotPrice;

        // The composite is only as fresh as its stalest leg
        publishTime = basePub < quotePub ? basePub : quotePub;
    }
}
