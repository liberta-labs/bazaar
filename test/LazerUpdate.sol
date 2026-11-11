// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";

/// @notice Builds signed Pyth Pro updates for tests and local chains, in the format PythLazer
///         verifies and LazerPayloadLib reads.
/// @dev Updates are signed with SIGNER_KEY, a key derived from a fixed label, which the local
///      deployment's MockPythLazer trusts (HelperConfig). Everything here is an internal function
///      over cheatcodes, so building an update makes no external call and leaves a pending
///      vm.prank in place.
library LazerUpdate {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The private key every test update is signed with. Public by construction: it must
    ///      never be trusted by a verifier on a live chain.
    uint256 internal constant SIGNER_KEY = uint256(keccak256("bazaar.test.pyth-lazer-signer"));

    uint32 internal constant ENVELOPE_MAGIC = 706910618;
    uint32 internal constant PAYLOAD_MAGIC = 2479346549;

    uint8 internal constant CHANNEL_REAL_TIME = 1;
    uint8 internal constant CHANNEL_FIXED_RATE_50 = 2;
    uint8 internal constant CHANNEL_FIXED_RATE_200 = 3;
    uint8 internal constant CHANNEL_FIXED_RATE_1000 = 4;

    uint64 internal constant MICROS = 1e6;

    /// @notice One feed's contents in an update: the four properties BazaarOracle reads.
    /// @param id The Pyth Pro feed ID
    /// @param price The price mantissa; zero encodes a feed with no price
    /// @param conf The confidence mantissa
    /// @param expo The exponent both mantissas are scaled by
    /// @param generatedUs When the price was generated, in microseconds; zero encodes a feed that
    ///        has never produced one
    struct Feed {
        uint32 id;
        int64 price;
        uint64 conf;
        int16 expo;
        uint64 generatedUs;
    }

    /// @notice The address SIGNER_KEY signs as.
    function signer() internal pure returns (address) {
        return vm.addr(SIGNER_KEY);
    }

    /// @notice The Pyth Pro feed ID a bytes32 feed ID holds.
    function rawId(bytes32 feedId) internal pure returns (uint32) {
        require(uint256(feedId) != 0 && uint256(feedId) <= type(uint32).max, "not a raw Pyth Pro feed ID");
        return uint32(uint256(feedId));
    }

    // -------------------- Whole updates --------------------

    /// @notice A real-time update carrying `feedId` at a price generated in second `generatedTs`,
    ///         stamped at that same second: what a keeper attaches to a live call.
    function live(bytes32 feedId, int64 price, uint64 conf, int16 expo, uint64 generatedTs)
        internal
        pure
        returns (bytes memory)
    {
        uint64 us = generatedTs * MICROS;
        return sign(payload(us, CHANNEL_REAL_TIME, feed(feedId, price, conf, expo, us)));
    }

    /// @notice A real-time update carrying two feeds, both generated in second `generatedTs`.
    function livePair(Feed memory a, Feed memory b, uint64 generatedTs) internal pure returns (bytes memory) {
        return sign(payload(generatedTs * MICROS, CHANNEL_REAL_TIME, a, b));
    }

    /// @notice The one-second channel's update for second `tickTs`, carrying `feedId` at a price
    ///         generated in second `generatedTs`: equal to `tickTs` for a price produced on the
    ///         tick, earlier for one carried forward.
    function tick(bytes32 feedId, int64 price, uint64 conf, int16 expo, uint64 tickTs, uint64 generatedTs)
        internal
        pure
        returns (bytes memory)
    {
        return sign(
            payload(tickTs * MICROS, CHANNEL_FIXED_RATE_1000, feed(feedId, price, conf, expo, generatedTs * MICROS))
        );
    }

    // -------------------- Parts --------------------

    function feed(bytes32 feedId, int64 price, uint64 conf, int16 expo, uint64 generatedUs)
        internal
        pure
        returns (Feed memory)
    {
        return Feed({id: rawId(feedId), price: price, conf: conf, expo: expo, generatedUs: generatedUs});
    }

    /// @notice A payload stamped `timestampUs` on `channel`, carrying one feed.
    function payload(uint64 timestampUs, uint8 channel, Feed memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(header(timestampUs, channel, 1), encodeFeed(a));
    }

    /// @notice A payload stamped `timestampUs` on `channel`, carrying two feeds.
    function payload(uint64 timestampUs, uint8 channel, Feed memory a, Feed memory b)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(header(timestampUs, channel, 2), encodeFeed(a), encodeFeed(b));
    }

    function header(uint64 timestampUs, uint8 channel, uint8 feeds) internal pure returns (bytes memory) {
        return abi.encodePacked(PAYLOAD_MAGIC, timestampUs, channel, feeds);
    }

    /// @notice One feed with its price, exponent, confidence and feed update timestamp, in that
    ///         order. A zero `generatedUs` is written as an absent timestamp.
    function encodeFeed(Feed memory f) internal pure returns (bytes memory) {
        bytes memory generated = f.generatedUs == 0
            ? abi.encodePacked(uint8(12), uint8(0))
            : abi.encodePacked(uint8(12), uint8(1), f.generatedUs);
        return abi.encodePacked(f.id, uint8(4), uint8(0), f.price, uint8(4), f.expo, uint8(5), f.conf, generated);
    }

    /// @notice `body` wrapped in the EVM envelope and signed with SIGNER_KEY.
    function sign(bytes memory body) internal pure returns (bytes memory) {
        return sign(body, SIGNER_KEY);
    }

    /// @notice `body` wrapped in the EVM envelope and signed with `key`.
    function sign(bytes memory body, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(body));
        return abi.encodePacked(ENVELOPE_MAGIC, r, s, uint8(v - 27), uint16(body.length), body);
    }

    /// @notice A one-element update list.
    function one(bytes memory update) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = update;
    }

    /// @notice A two-element update list.
    function two(bytes memory a, bytes memory b) internal pure returns (bytes[] memory list) {
        list = new bytes[](2);
        list[0] = a;
        list[1] = b;
    }

    // -------------------- Arbitrary property lists --------------------
    // For updates a requester shaped differently from encodeFeed: properties left out, extra ones
    // BazaarOracle does not read, another order.

    /// @notice A payload stamped `timestampUs` on `channel` whose `feeds` feed entries are `body`.
    function rawPayload(uint64 timestampUs, uint8 channel, uint8 feeds, bytes memory body)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(header(timestampUs, channel, feeds), body);
    }

    /// @notice A feed entry carrying `count` properties, already encoded in `properties`.
    function rawFeed(bytes32 feedId, uint8 count, bytes memory properties) internal pure returns (bytes memory) {
        return abi.encodePacked(rawId(feedId), count, properties);
    }

    function propPrice(int64 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), v);
    }

    function propBestBid(int64 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), v);
    }

    function propBestAsk(int64 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), v);
    }

    function propPublisherCount(uint16 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(3), v);
    }

    function propExponent(int16 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(4), v);
    }

    function propConfidence(uint64 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(5), v);
    }

    /// @dev The three funding properties (IDs 6 to 8) share one layout: a presence byte, then the
    ///      value only when it is set.
    function propFunding(uint8 id, bool exists, uint64 v) internal pure returns (bytes memory) {
        return exists ? abi.encodePacked(id, uint8(1), v) : abi.encodePacked(id, uint8(0));
    }

    function propMarketSession(uint16 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(9), v);
    }

    function propEmaPrice(int64 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(10), v);
    }

    function propEmaConfidence(uint64 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(11), v);
    }

    /// @notice The feed update timestamp; zero writes the property with its presence byte unset.
    function propGenerated(uint64 us) internal pure returns (bytes memory) {
        return us == 0 ? abi.encodePacked(uint8(12), uint8(0)) : abi.encodePacked(uint8(12), uint8(1), us);
    }
}
