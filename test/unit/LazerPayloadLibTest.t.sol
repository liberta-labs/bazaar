// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {LazerPayloadLib} from "../../src/libraries/LazerPayloadLib.sol";
import {LazerUpdate} from "../LazerUpdate.sol";
import {PythLazerLib} from "../vendor/pyth-lazer/PythLazerLib.sol";
import {PythLazerStructs} from "../vendor/pyth-lazer/PythLazerStructs.sol";

/// @dev Exposes LazerPayloadLib.readFeeds as an external call, so a revert inside it can be caught.
contract LazerPayloadReader {
    function readFeeds(bytes memory payload, uint32 idA, uint32 idB)
        external
        pure
        returns (uint64 timestamp, uint8 channel, LazerPayloadLib.Feed memory a, LazerPayloadLib.Feed memory b)
    {
        return LazerPayloadLib.readFeeds(payload, idA, idB);
    }
}

/// @dev Exposes Pyth's own parser the same way.
contract PythReferenceParser {
    function parse(bytes memory payload) external pure returns (PythLazerStructs.Update memory) {
        return PythLazerLib.parseUpdateFromPayload(payload);
    }
}

/// @notice LazerPayloadLib against Pyth's reference parser: on every well-formed payload the two
///         read the same timestamp, channel and feed fields, and a payload either refuses, the
///         other refuses too.
contract LazerPayloadLibTest is Test {
    LazerPayloadReader reader;
    PythReferenceParser pythParser;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    function setUp() public {
        reader = new LazerPayloadReader();
        pythParser = new PythReferenceParser();
    }

    // -------------------- Random payloads --------------------

    /// @dev The next value of a hash chain seeded by the fuzzer.
    function _next(uint256 state) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(state)));
    }

    /// @dev One randomly chosen property with a random value. A quarter of the values are zero,
    ///      the encoding of an absent price or confidence, and the presence byte of the
    ///      conditional properties is set half the time.
    function _randomProperty(uint256 r) internal pure returns (bytes memory) {
        uint8 id = uint8(r % 13);
        uint64 v = (r >> 8) % 4 == 0 ? 0 : uint64(r >> 16);
        if (id == 0) return LazerUpdate.propPrice(int64(v));
        if (id == 1) return LazerUpdate.propBestBid(int64(v));
        if (id == 2) return LazerUpdate.propBestAsk(int64(v));
        if (id == 3) return LazerUpdate.propPublisherCount(uint16(v));
        if (id == 4) return LazerUpdate.propExponent(int16(uint16(v)));
        if (id == 5) return LazerUpdate.propConfidence(v);
        if (id == 9) return LazerUpdate.propMarketSession(uint16(v % 5));
        if (id == 10) return LazerUpdate.propEmaPrice(int64(v));
        if (id == 11) return LazerUpdate.propEmaConfidence(v);
        if (id == 12) return (r >> 80) % 2 == 0 ? LazerUpdate.propGenerated(0) : LazerUpdate.propGenerated(v | 1);
        return LazerUpdate.propFunding(id, (r >> 80) % 2 == 0, v);
    }

    /// @dev A well-formed payload of one to four feeds with IDs 1 to 3, so the two IDs the test
    ///      reads appear, repeat and go missing, each with up to seven properties in any order,
    ///      repeats included.
    function _randomPayload(uint256 seed) internal pure returns (bytes memory payload) {
        uint256 r = _next(seed);
        uint8 feeds = uint8(1 + r % 4);
        bytes memory body;
        for (uint256 i = 0; i < feeds; i++) {
            r = _next(r);
            uint8 count = uint8((r >> 8) % 8);
            bytes memory properties;
            uint256 p = r;
            for (uint256 j = 0; j < count; j++) {
                p = _next(p);
                properties = abi.encodePacked(properties, _randomProperty(p));
            }
            body = abi.encodePacked(body, LazerUpdate.rawFeed(bytes32(1 + r % 3), count, properties));
        }
        r = _next(r);
        payload = LazerUpdate.rawPayload(uint64(r), uint8(1 + (r >> 64) % 4), feeds, body);
    }

    /// @dev The state Pyth's parser recorded for property `id`: 0 not in the payload, 1 in it
    ///      without a value, 2 with one.
    function _state(PythLazerStructs.Feed memory f, uint8 id) internal pure returns (uint256) {
        return (f.triStateMap >> (2 * id)) & 3;
    }

    function _assertSameFeed(LazerPayloadLib.Feed memory mine, PythLazerStructs.Update memory theirs, uint32 id)
        internal
        pure
    {
        // Pyth returns every entry; LazerPayloadLib reads a feed from its first.
        for (uint256 i = 0; i < theirs.feeds.length; i++) {
            PythLazerStructs.Feed memory f = theirs.feeds[i];
            if (f.feedId != id) continue;

            assertTrue(mine.found, "found");
            assertEq(mine.included & LazerPayloadLib.HAS_PRICE != 0, _state(f, 0) != 0, "price included");
            assertEq(mine.included & LazerPayloadLib.HAS_EXPONENT != 0, _state(f, 4) != 0, "exponent included");
            assertEq(mine.included & LazerPayloadLib.HAS_CONFIDENCE != 0, _state(f, 5) != 0, "confidence included");
            assertEq(
                mine.included & LazerPayloadLib.HAS_FEED_UPDATE_TIMESTAMP != 0, _state(f, 12) != 0, "timestamp included"
            );
            assertEq(mine.price, f._price, "price");
            assertEq(mine.exponent, f._exponent, "exponent");
            assertEq(mine.confidence, f._confidence, "confidence");
            assertEq(mine.feedUpdateTimestamp, _state(f, 12) == 2 ? f._feedUpdateTimestamp : 0, "feed update timestamp");
            return;
        }
        assertFalse(mine.found, "not found");
        assertEq(mine.included, 0, "nothing included for a feed that is not there");
    }

    /// @notice Every well-formed payload reads the same through both parsers.
    function testFuzz_AgreesWithPythsParser(uint256 seed) public view {
        bytes memory payload = _randomPayload(seed);
        (uint64 timestamp, uint8 channel, LazerPayloadLib.Feed memory a, LazerPayloadLib.Feed memory b) =
            reader.readFeeds(payload, 1, 2);
        PythLazerStructs.Update memory theirs = pythParser.parse(payload);

        assertEq(timestamp, theirs.timestamp, "timestamp");
        assertEq(channel, uint8(theirs.channel), "channel");
        _assertSameFeed(a, theirs, 1);
        _assertSameFeed(b, theirs, 2);
    }

    /// @notice A payload cut short anywhere, or carrying a byte too many, is refused by both.
    function testFuzz_TruncatedOrPaddedPayloadRefusedByBoth(uint256 seed, uint256 cut) public {
        bytes memory payload = _randomPayload(seed);
        cut = bound(cut, 0, payload.length - 1);
        bytes memory truncated = new bytes(cut);
        for (uint256 i = 0; i < cut; i++) {
            truncated[i] = payload[i];
        }
        vm.expectRevert(LazerPayloadLib.LazerPayloadLib__Malformed.selector);
        reader.readFeeds(truncated, 1, 2);
        vm.expectRevert();
        pythParser.parse(truncated);

        bytes memory padded = abi.encodePacked(payload, uint8(0));
        vm.expectRevert(LazerPayloadLib.LazerPayloadLib__Malformed.selector);
        reader.readFeeds(padded, 1, 2);
        vm.expectRevert();
        pythParser.parse(padded);
    }

    // -------------------- Fixed cases --------------------

    function _oneFeed(bytes memory properties, uint8 count) internal pure returns (bytes memory) {
        return LazerUpdate.rawPayload(1_700_000_000_000_000, 1, 1, LazerUpdate.rawFeed(FEED_A, count, properties));
    }

    function _expectBothRefuse(bytes memory payload) internal {
        vm.expectRevert(LazerPayloadLib.LazerPayloadLib__Malformed.selector);
        reader.readFeeds(payload, 1, 0);
        vm.expectRevert();
        pythParser.parse(payload);
    }

    /// @notice The four properties the oracle reads, as a keeper's update carries them.
    function test_ReadsTheOraclesFourProperties() public view {
        bytes memory payload = LazerUpdate.payload(
            1_700_000_000_500_000,
            LazerUpdate.CHANNEL_FIXED_RATE_200,
            LazerUpdate.feed(FEED_A, 6_512_345_000_000, 2_100_000_000, -8, 1_700_000_000_400_000)
        );
        (uint64 timestamp, uint8 channel, LazerPayloadLib.Feed memory a, LazerPayloadLib.Feed memory b) =
            reader.readFeeds(payload, 1, 2);
        assertEq(timestamp, 1_700_000_000_500_000);
        assertEq(channel, LazerUpdate.CHANNEL_FIXED_RATE_200);
        assertTrue(a.found);
        assertEq(a.included, 15, "all four properties");
        assertEq(a.price, 6_512_345_000_000);
        assertEq(a.exponent, -8);
        assertEq(a.confidence, 2_100_000_000);
        assertEq(a.feedUpdateTimestamp, 1_700_000_000_400_000);
        assertFalse(b.found, "the second feed is not in the payload");
    }

    /// @notice A property left out of the request is reported as not included, and one included
    ///         without a value as included with a zero.
    function test_OmittedPropertyIsNotIncluded_AbsentValueIsIncludedAsZero() public view {
        bytes memory properties =
            abi.encodePacked(LazerUpdate.propPrice(0), LazerUpdate.propExponent(-8), LazerUpdate.propGenerated(0));
        (,, LazerPayloadLib.Feed memory a,) = reader.readFeeds(_oneFeed(properties, 3), 1, 0);
        assertEq(
            a.included,
            LazerPayloadLib.HAS_PRICE | LazerPayloadLib.HAS_EXPONENT | LazerPayloadLib.HAS_FEED_UPDATE_TIMESTAMP,
            "confidence was not requested"
        );
        assertEq(a.price, 0, "no price for the timestamp");
        assertEq(a.feedUpdateTimestamp, 0, "the feed never produced a price");
    }

    /// @notice A feed listed twice is read from its first entry; a property listed twice takes its
    ///         last value.
    function test_FirstEntryOfAFeed_LastValueOfAProperty() public view {
        bytes memory first =
            LazerUpdate.rawFeed(FEED_A, 2, abi.encodePacked(LazerUpdate.propPrice(100), LazerUpdate.propPrice(200)));
        bytes memory second = LazerUpdate.rawFeed(FEED_A, 1, LazerUpdate.propPrice(300));
        bytes memory payload = LazerUpdate.rawPayload(1, 1, 2, abi.encodePacked(first, second));
        (,, LazerPayloadLib.Feed memory a,) = reader.readFeeds(payload, 1, 0);
        assertEq(a.price, 200);
    }

    /// @notice Asking for no second feed never matches an entry, whatever its ID.
    function test_NoSecondFeedRequested() public view {
        (,, LazerPayloadLib.Feed memory a, LazerPayloadLib.Feed memory b) =
            reader.readFeeds(_oneFeed(LazerUpdate.propPrice(7), 1), 1, 0);
        assertTrue(a.found);
        assertFalse(b.found);
    }

    /// @notice script/dev-update.sh, the shell encoder the local tooling signs test prices with,
    ///         and LazerUpdate produce the same bytes for the same price: these are that script's
    ///         outputs for feed 1 at $50,000 and feed 2 at $2,000.
    function test_ShellEncoderProducesTheSameUpdate() public pure {
        assertEq(
            LazerUpdate.live(FEED_A, 5_000_000_000_000, 5_000_000_000, -8, 1_700_000_000),
            hex"2a22999a079a38ecd5ab46a05c14e23826175819be52e611bae98447893d8bb61016394e3a3e3109ed7718e268cd0e4fb3179ad3c22ef449076c5a3073372bc8dacf90bc01003293c7d37500060a24181e400001010000000104000000048c2739500004fff805000000012a05f2000c0100060a24181e4000"
        );
        assertEq(
            LazerUpdate.live(FEED_B, 200_000_000_000, 200_000_000, -8, 1_700_000_123),
            hex"2a22999adc3099ca18e92d4425114efd168a4acf7759696ba9431c48c313f758657a01b64e57016bf3d5b869473c0057fae98dc246aeeb996e4cf99d1548fef4eca0d9e000003293c7d37500060a241f7314c001010000000204000000002e90edd00004fff805000000000bebc2000c0100060a241f7314c0"
        );
    }

    function test_WrongMagicRefused() public {
        bytes memory payload = _oneFeed(LazerUpdate.propPrice(7), 1);
        payload[0] = 0x00;
        _expectBothRefuse(payload);
    }

    function test_UnknownPropertyRefused() public {
        _expectBothRefuse(_oneFeed(abi.encodePacked(uint8(13), uint64(1)), 1));
    }

    function test_MarketSessionOutOfRangeRefused() public {
        _expectBothRefuse(_oneFeed(LazerUpdate.propMarketSession(5), 1));
    }

    function test_PropertyCountBeyondThePayloadRefused() public {
        _expectBothRefuse(_oneFeed(LazerUpdate.propPrice(7), 2));
    }

    function test_FeedCountBeyondThePayloadRefused() public {
        bytes memory payload = LazerUpdate.rawPayload(1, 1, 2, LazerUpdate.rawFeed(FEED_A, 1, LazerUpdate.propPrice(7)));
        _expectBothRefuse(payload);
    }

    function test_EmptyPayloadRefused() public {
        vm.expectRevert(LazerPayloadLib.LazerPayloadLib__Malformed.selector);
        reader.readFeeds("", 1, 0);
    }
}
