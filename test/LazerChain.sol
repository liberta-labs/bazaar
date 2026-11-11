// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {LazerUpdate} from "./LazerUpdate.sol";

/// @notice Builds the sample sets the chain rule settles a vote-scheduled pair at: COUNT samples of
///         a direct feed, the first the earliest one-second tick carrying a price generated at or
///         after the cutoff and each later one the earliest carrying a price generated at least
///         SPACING after the tick before (BazaarOracle.fetchChainedMedian).
library LazerChain {
    uint256 internal constant COUNT = 5; // mirror of BazaarPairTerminator.SETTLEMENT_SAMPLE_COUNT
    uint64 internal constant SPACING = 10 minutes; // mirror of BazaarPairTerminator.SETTLEMENT_SAMPLE_SPACING

    /// @dev The one-second update for second `tickTs`, carrying `feedId` at `priceUsd`, eight
    ///      decimals, 0.1% confidence, generated in second `generatedTs`.
    function tick(bytes32 feedId, uint256 priceUsd, uint64 tickTs, uint64 generatedTs)
        internal
        pure
        returns (bytes memory)
    {
        int64 price = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        return LazerUpdate.tick(feedId, price, conf, -8, tickTs, generatedTs);
    }

    /// @dev The proof that the sample for `target` is the tick at `tickTs`, priced `priceUsd` and
    ///      generated on that tick. On the target itself the tick is its own proof. Later, the
    ///      proof opens with the tick a second earlier, still carrying `quietPriceUsd` from
    ///      `quietSince`: for the proof to hold, `quietSince` must lie before `target`.
    function sample(
        bytes32 feedId,
        uint256 priceUsd,
        uint64 target,
        uint64 tickTs,
        uint256 quietPriceUsd,
        uint64 quietSince
    ) internal pure returns (bytes[] memory pu) {
        if (tickTs == target) {
            return LazerUpdate.one(tick(feedId, priceUsd, tickTs, tickTs));
        }
        pu = new bytes[](2);
        pu[0] = tick(feedId, quietPriceUsd, tickTs - 1, quietSince);
        pu[1] = tick(feedId, priceUsd, tickTs, tickTs);
    }

    /// @dev A valid chain priced `pricesUsd`, sample by sample, for a cutoff at `target`: the
    ///      first sample at `firstTick`, after a feed quiet since `quietSince` when that is later
    ///      than the cutoff, each later one generated exactly on its target, SPACING after the
    ///      sample before.
    function chain(bytes32 feedId, uint256[5] memory pricesUsd, uint64 target, uint64 firstTick, uint64 quietSince)
        internal
        pure
        returns (bytes[] memory pu)
    {
        pu = sample(feedId, pricesUsd[0], target, firstTick, pricesUsd[0], quietSince);
        uint64 at = firstTick;
        for (uint256 k = 1; k < COUNT; k++) {
            at += SPACING;
            pu = append(pu, tick(feedId, pricesUsd[k], at, at));
        }
    }

    /// @dev As chain, every sample at `priceUsd`.
    function flat(bytes32 feedId, uint256 priceUsd, uint64 target, uint64 firstTick, uint64 quietSince)
        internal
        pure
        returns (bytes[] memory)
    {
        return chain(feedId, [priceUsd, priceUsd, priceUsd, priceUsd, priceUsd], target, firstTick, quietSince);
    }

    /// @dev As flat, for a feed that produces a price on the cutoff itself: one update per sample.
    function flat(bytes32 feedId, uint256 priceUsd, uint64 target) internal pure returns (bytes[] memory) {
        return flat(feedId, priceUsd, target, target, 0);
    }

    /// @dev The tick of the last sample of such a chain, the first sample at `firstTick`: the
    ///      earliest moment the set exists.
    function lastTick(uint64 firstTick) internal pure returns (uint64) {
        return firstTick + uint64(COUNT - 1) * SPACING;
    }

    /// @dev `list` with `update` added at the end.
    function append(bytes[] memory list, bytes memory update) internal pure returns (bytes[] memory out) {
        out = new bytes[](list.length + 1);
        for (uint256 i = 0; i < list.length; i++) {
            out[i] = list[i];
        }
        out[list.length] = update;
    }

    /// @dev `a` followed by `b`.
    function concat(bytes[] memory a, bytes[] memory b) internal pure returns (bytes[] memory out) {
        out = new bytes[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }
}
