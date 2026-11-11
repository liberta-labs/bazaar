// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

/// @title LazerPayloadLib
/// @notice Reads the fields BazaarOracle prices from out of a Pyth Pro payload, the bytes
///         PythLazer.verifyUpdate returns once it has checked their signature.
/// @dev A payload is big-endian: a 4-byte magic, the update's timestamp in microseconds (8 bytes),
///      its channel (1 byte), a feed count (1 byte), then each feed as its ID (4 bytes), a property
///      count (1 byte) and that many properties, each a 1-byte property ID followed by its value.
///      Which properties a feed carries is chosen by whoever requested the update from Pyth, so a
///      caller of this library must check `included` for every property it relies on: a property
///      left out of the request is simply not there, and reading its zero as a value would let
///      the requester drop a check by dropping the property.
///
///      The walk is strict. Every property of every feed is decoded, because the widths differ and
///      some are conditional, an unknown property ID reverts since its width cannot be known, and
///      the payload must end exactly where the last property does.
library LazerPayloadLib {
    // -------------------- Errors --------------------
    error LazerPayloadLib__Malformed();

    // -------------------- Constants --------------------
    uint32 internal constant PAYLOAD_MAGIC = 2479346549;

    /// @dev The channel whose updates are stamped once per second, on whole seconds.
    uint8 internal constant CHANNEL_FIXED_RATE_1000 = 4;

    uint256 internal constant MICROS_PER_SECOND = 1e6;

    // Property IDs, as Pyth numbers them.
    uint8 internal constant PROP_PRICE = 0;
    uint8 internal constant PROP_BEST_BID_PRICE = 1;
    uint8 internal constant PROP_BEST_ASK_PRICE = 2;
    uint8 internal constant PROP_PUBLISHER_COUNT = 3;
    uint8 internal constant PROP_EXPONENT = 4;
    uint8 internal constant PROP_CONFIDENCE = 5;
    uint8 internal constant PROP_FUNDING_RATE = 6;
    uint8 internal constant PROP_FUNDING_TIMESTAMP = 7;
    uint8 internal constant PROP_FUNDING_RATE_INTERVAL = 8;
    uint8 internal constant PROP_MARKET_SESSION = 9;
    uint8 internal constant PROP_EMA_PRICE = 10;
    uint8 internal constant PROP_EMA_CONFIDENCE = 11;
    uint8 internal constant PROP_FEED_UPDATE_TIMESTAMP = 12;

    /// @dev The highest market session value Pyth defines.
    uint16 internal constant MAX_MARKET_SESSION = 4;

    // Bits of Feed.included, one per property this library reads.
    uint8 internal constant HAS_PRICE = 1;
    uint8 internal constant HAS_EXPONENT = 2;
    uint8 internal constant HAS_CONFIDENCE = 4;
    uint8 internal constant HAS_FEED_UPDATE_TIMESTAMP = 8;

    // -------------------- Types --------------------
    /// @notice One feed's fields in one payload.
    /// @param found True when the payload carries the feed
    /// @param included Which of the properties below the payload carries for the feed (HAS_* bits)
    /// @param price The aggregate price mantissa; zero when the feed has no price at the payload's
    ///        timestamp, which is how Pyth encodes an absent price
    /// @param exponent The power of ten the mantissas are scaled by
    /// @param confidence The confidence mantissa; zero when Pyth published none
    /// @param feedUpdateTimestamp When the price was generated, in microseconds. Earlier than the
    ///        payload's timestamp when the price is carried forward from an earlier update; zero
    ///        when the feed has never produced a price
    struct Feed {
        bool found;
        uint8 included;
        int64 price;
        int16 exponent;
        uint64 confidence;
        uint64 feedUpdateTimestamp;
    }

    // -------------------- Reads --------------------

    /// @notice Reads up to two feeds out of `payload` in one walk.
    /// @dev A feed listed more than once is read from its first entry. Within one entry a property
    ///      listed more than once takes its last value.
    /// @param payload The payload PythLazer verified
    /// @param idA The first feed to read
    /// @param idB The second feed to read, or zero to read only the first; no feed has ID zero
    /// @return timestamp The update's timestamp in microseconds
    /// @return channel The channel the update was produced on
    /// @return a The first feed's fields
    /// @return b The second feed's fields, all zero when `idB` is zero
    function readFeeds(bytes memory payload, uint32 idA, uint32 idB)
        internal
        pure
        returns (uint64 timestamp, uint8 channel, Feed memory a, Feed memory b)
    {
        if (_u32(payload, 0) != PAYLOAD_MAGIC) revert LazerPayloadLib__Malformed();
        timestamp = _u64(payload, 4);
        channel = _u8(payload, 12);
        uint256 feeds = _u8(payload, 13);
        uint256 pos = 14;

        for (uint256 i = 0; i < feeds; i++) {
            uint32 id = _u32(payload, pos);
            uint256 properties = _u8(payload, pos + 4);
            pos += 5;

            Feed memory scratch;
            for (uint256 j = 0; j < properties; j++) {
                pos = _readProperty(payload, pos, scratch);
            }
            scratch.found = true;

            if (id == idA && !a.found) {
                a = scratch;
            } else if (idB != 0 && id == idB && !b.found) {
                b = scratch;
            }
        }

        if (pos != payload.length) revert LazerPayloadLib__Malformed();
    }

    /// @notice A microsecond timestamp in whole seconds, rounded down.
    function toSeconds(uint64 micros) internal pure returns (uint256) {
        return micros / MICROS_PER_SECOND;
    }

    // -------------------- Internal helpers --------------------

    /// @dev Decodes the property at `pos` into `feed` when it is one this library reads, and
    ///      steps over it otherwise. Returns the position after it.
    function _readProperty(bytes memory payload, uint256 pos, Feed memory feed) private pure returns (uint256) {
        uint8 property = _u8(payload, pos);
        pos += 1;

        if (property == PROP_PRICE) {
            feed.price = int64(_u64(payload, pos));
            feed.included |= HAS_PRICE;
            return pos + 8;
        }
        if (property == PROP_EXPONENT) {
            feed.exponent = int16(_u16(payload, pos));
            feed.included |= HAS_EXPONENT;
            return pos + 2;
        }
        if (property == PROP_CONFIDENCE) {
            feed.confidence = _u64(payload, pos);
            feed.included |= HAS_CONFIDENCE;
            return pos + 8;
        }
        if (property == PROP_FEED_UPDATE_TIMESTAMP) {
            // A presence byte, then the timestamp only when it is set.
            bool exists = _u8(payload, pos) != 0;
            feed.included |= HAS_FEED_UPDATE_TIMESTAMP;
            feed.feedUpdateTimestamp = exists ? _u64(payload, pos + 1) : 0;
            return exists ? pos + 9 : pos + 1;
        }
        if (
            property == PROP_BEST_BID_PRICE || property == PROP_BEST_ASK_PRICE || property == PROP_EMA_PRICE
                || property == PROP_EMA_CONFIDENCE
        ) {
            return pos + 8;
        }
        if (property == PROP_PUBLISHER_COUNT) {
            return pos + 2;
        }
        if (property == PROP_MARKET_SESSION) {
            if (_u16(payload, pos) > MAX_MARKET_SESSION) revert LazerPayloadLib__Malformed();
            return pos + 2;
        }
        if (
            property == PROP_FUNDING_RATE || property == PROP_FUNDING_TIMESTAMP
                || property == PROP_FUNDING_RATE_INTERVAL
        ) {
            // A presence byte, then eight bytes only when it is set.
            return _u8(payload, pos) != 0 ? pos + 9 : pos + 1;
        }
        revert LazerPayloadLib__Malformed();
    }

    /// @dev The `width` bytes at `pos`, as a big-endian integer. Reverts when they run past the
    ///      end of `data`, so a truncated payload can never be completed from whatever memory
    ///      follows it.
    function _read(bytes memory data, uint256 pos, uint256 width) private pure returns (uint256 value) {
        if (pos + width > data.length) revert LazerPayloadLib__Malformed();
        assembly ("memory-safe") {
            value := shr(sub(256, mul(8, width)), mload(add(add(data, 0x20), pos)))
        }
    }

    function _u8(bytes memory data, uint256 pos) private pure returns (uint8) {
        return uint8(_read(data, pos, 1));
    }

    function _u16(bytes memory data, uint256 pos) private pure returns (uint16) {
        return uint16(_read(data, pos, 2));
    }

    function _u32(bytes memory data, uint256 pos) private pure returns (uint32) {
        return uint32(_read(data, pos, 4));
    }

    function _u64(bytes memory data, uint256 pos) private pure returns (uint64) {
        return uint64(_read(data, pos, 8));
    }
}
