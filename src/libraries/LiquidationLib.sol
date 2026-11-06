// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title LiquidationLib
/// @notice External library for liquidation processing logic.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage.
///         Liquidated positions are aggregated into the vault's two buckets, one per side,
///         rather than creating individual orders. The buckets' overlap is netted at the oracle
///         when the fund can afford it (RiskParamsLib.tryNetBuckets).
library LiquidationLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BazaarTypes.MIN_LIQUIDATOR_REWARD; // 0.05 USDC per account

    // -------------------- Events --------------------

    event PositionLiquidated(
        bytes32 indexed pairId,
        address indexed liquidatedUser,
        address indexed liquidator,
        uint256 size,
        bool isLong,
        uint256 bankruptcyPrice,
        uint256 triggerPrice,
        uint256 collateralSeized,
        uint256 timestamp
    );

    // -------------------- Structs --------------------

    /// @notice One seized position, as the vault's buckets consume it.
    /// @param size The position's size
    /// @param entryNotional The position's entry basis
    /// @param bankruptcyNotional The notional at which its equity was zero (bankruptcyNotionalOf)
    /// @param seized The collateral the fund received for it, capped at the deposits ledger
    /// @param entryFundingIndex The position's entry funding index
    /// @param isLong The position's side
    struct Estate {
        uint256 size;
        uint256 entryNotional;
        uint256 bankruptcyNotional;
        uint256 seized;
        int256 entryFundingIndex;
        bool isLong;
    }

    // -------------------- External --------------------

    /// @notice Processes liquidations for a list of users
    /// @dev Iterates through users, checks solvency, and seizes each insolvent position into the
    ///      vault's bucket on its own side (absorb). After each seizure the two buckets' overlap
    ///      is netted when the netting is a gain or a loss the fund can afford above its reserve
    ///      (RiskParamsLib.tryNetBuckets); otherwise both buckets stand, and the auction closes
    ///      each against its own counterparties.
    ///      Reward, per account: flatReward for every position the call seizes —
    ///      MIN_LIQUIDATOR_REWARD, or the account's own equity when its position is worth less
    ///      than MIN_ORDER_AMOUNT and holds less — earned at liquidation time with no
    ///      profit-contingent component. A seizure whose absorb nets the buckets retires the
    ///      overlap at once, exposure it takes off the fund, and earns the larger of its flat
    ///      reward and LIQUIDATION_FEE_EBP of the overlap's notional at the liquidation price
    ///      (seizureReward). Per account rather than per call so that one call naming many
    ///      accounts earns what separate calls would: a per-call amount pays more the more finely
    ///      a batch is split, which moves keepers to one transaction per account in a cascade.
    ///      Paid here, so it stays due when no walk runs, as while an ADL window is open: debited
    ///      from insurance, capped at the fund's free capital, and accrued to the liquidator's
    ///      claimable balance, to be pulled via BazaarPair.claimFees.
    ///
    ///      The rate on what liquidate()'s inline walk sells is paid by the walk
    ///      (MatchingEngineLib.unloadBook) past `LiquidateResult.unloadPrepaid`, the part of this
    ///      payment beyond the nettings' rate, so the walk pays only what its rate adds past the
    ///      flat rewards. The call earns the nettings' rate plus the larger of that credit and the
    ///      rate on what the walk sold.
    ///
    ///      A netting's rate is not part of the affordability test (RiskParamsLib.overlapAffordable):
    ///      counted there it would refuse nettings whose loss the fund can carry. It is paid like
    ///      the flat part, which the reserve may fund and the earmark may not, so like the flat
    ///      part it can bring a window forward by what it pays.
    /// @param usersToLiquidate The accounts to check and liquidate
    /// @param orders Storage mapping of orders
    /// @param book The order book
    /// @param positionBuckets Storage mapping of position buckets
    /// @param pairVault The pair's vault aggregates
    /// @param feeEscrow The claimable-fee escrow the reward accrues to
    /// @param params The liquidation parameters
    /// @return result The accounts seized and the walk's credit (unloadPrepaid)
    function processLiquidations(
        address[] calldata usersToLiquidate,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.LiquidateParams memory params
    ) external returns (BazaarTypes.LiquidateResult memory result) {
        uint256 reward;
        uint256 nettingRate;
        for (uint256 i = 0; i < usersToLiquidate.length; i++) {
            address user = usersToLiquidate[i];

            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
            if (bucket.size == 0) continue; // no position

            // Use the plain oracle price (not a bracket bound) for solvency. Confidence-band
            // polarity has no clean answer for liquidation: user-favorable lets noise carry,
            // protocol-eager risks false liquidations. The 2% confidence-ratio cap at the oracle
            // layer already pauses pricing when uncertainty is too high; that is where
            // conservatism belongs.
            BazaarTypes.BucketState memory state =
                BucketLib.calculateState(bucket, params.currentPrice, params.currentFundingIndex, params.marginReqs);

            if (state.isSolvent) continue;

            Estate memory e = seize(user, bucket, state, orders, book, pairVault, params);
            // What the absorb's netting retires is taken off the fund here and earns the rate.
            // What stays in a bucket is exposure moved onto the fund, paid for when it is retired.
            uint256 netted = absorb(pairVault, e, params.currentPrice, params.currentFundingIndex);
            nettingRate += rateOn(netted, params.currentPrice);
            reward += seizureReward(state, netted, params.currentPrice);

            unchecked {
                ++result.liquidatedCount;
            }
        }

        // The reward moves from insurance into the fee escrow here rather than in BazaarPair
        // (DELEGATECALL preserves msg.sender = caller), keeping the pair's EIP-170 budget free
        // of it. Insurance and the escrow liability move together, so the books-vs-cash check
        // stays exact, and the liquidation never runs a token transfer — nothing a liquidator's
        // address does can revert or strand it. Capped at the fund's free capital. A seizure
        // that joins a bucket does not raise it: its collateral is earmarked against the
        // inventory it arrived with, and a reward drawn from it would resurface as a shortfall
        // when that inventory settles — deficit on an unload fill, funding withheld from a
        // deleveraged winner. A netted slice's seizure is released with the slice and raises it
        // by what the netting's loss leaves of it. The reserve may pay the reward; the earmark
        // may not. The liquidations themselves commit whatever is paid.
        uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
        if (reward > free) reward = free;
        if (reward > 0) {
            pairVault.insuranceFundBalance -= reward;
            FeeEscrowLib.credit(feeEscrow, params.pairId, msg.sender, reward);
        }
        // The walk pays the rate on what it sells past this credit: the payment less the
        // nettings' rate, which is what the flat rewards add beyond it. A cap that bit only
        // lowers the call's total.
        result.unloadPrepaid = reward > nettingRate ? reward - nettingRate : 0;
    }

    // -------------------- Seizure --------------------

    /// @notice Seizes one insolvent position: removes it from the open-interest aggregates,
    ///         credits its collateral to the insurance fund and resets its bucket. Leaves the
    ///         vault's inventory untouched — the caller absorbs the estate into it in the same
    ///         transaction — and leaves the reward to the caller, which knows how much of the
    ///         position the seizure retires (seizureReward).
    /// @dev Insurance is credited with the seized book collateral. Winners realize gains into
    ///      their buckets without touching the deposits ledger and withdraw them from it later,
    ///      so a loser's book collateral can legitimately exceed the entire remaining ledger; an
    ///      uncapped debit would panic there, leaving exactly the deepest-underwater position
    ///      unliquidatable. The part the ledger cannot pay is carried as the ledger's arrears to
    ///      the fund rather than dropped or booked as deficit: the estate settles at its entry
    ///      basis through transfers paid net of those arrears, so the fund's outlay on it
    ///      is the loss beyond the bucket — the bankruptcy price — and a genuine shortfall
    ///      surfaces as deficit only if insurance cannot fund that. `seized` is the cash the
    ///      fund received and is what the inventory earmarks; the arrears back it alongside.
    /// @param user The account being liquidated
    /// @param bucket The account's bucket
    /// @param state The bucket's state at the liquidation price and the live index
    /// @param orders Storage mapping of orders
    /// @param book The order book
    /// @param pairVault The pair's vault aggregates
    /// @param params The liquidation parameters
    /// @return e The estate the seizure produced
    function seize(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.BucketState memory state,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.LiquidateParams memory params
    ) internal returns (Estate memory e) {
        e.size = state.adjustedSize;
        e.isLong = bucket.isLong;
        e.entryNotional = state.entryValue;
        e.entryFundingIndex = state.adjustedEntryFundingIndex;

        e.bankruptcyNotional = bankruptcyNotionalOf(state, e.isLong);

        // Update vault aggregates - remove this position from OI
        if (e.isLong) {
            pairVault.totalLongOI = pairVault.totalLongOI > e.size ? pairVault.totalLongOI - e.size : 0;
            pairVault.longWeightedEntrySum = pairVault.longWeightedEntrySum > state.entryValue
                ? pairVault.longWeightedEntrySum - state.entryValue
                : 0;
        } else {
            pairVault.totalShortOI = pairVault.totalShortOI > e.size ? pairVault.totalShortOI - e.size : 0;
            pairVault.shortWeightedEntrySum = pairVault.shortWeightedEntrySum > state.entryValue
                ? pairVault.shortWeightedEntrySum - state.entryValue
                : 0;
        }

        e.seized = RiskParamsLib.collectFromLedger(pairVault, state.effectiveCollateral);

        _resetBucket(
            user,
            bucket,
            orders,
            book,
            params.currentFundingIndex,
            params.marginReqs,
            params.pairId,
            params.currentBlock
        );

        emit PositionLiquidated(
            params.pairId,
            user,
            msg.sender,
            e.size,
            e.isLong,
            Math.mulDiv(e.bankruptcyNotional, BAZAAR_SCALE, e.size),
            params.currentPrice,
            e.seized,
            block.timestamp
        );
    }

    /// @notice The flat part of the reward for liquidating one account: MIN_LIQUIDATOR_REWARD,
    ///         or the account's own equity when its position is worth less than MIN_ORDER_AMOUNT
    ///         at the liquidation price and that equity is smaller.
    /// @dev Maintenance margin never drops below RiskParamsLib.MIN_IMR_BP / 2, so a position worth
    ///      MIN_ORDER_AMOUNT or more holds twice the floor or more in equity at the maintenance
    ///      line, and only the market carries it further: a withdrawal must leave initial margin,
    ///      and a partial close cannot take it across the line. Such a position earns the full
    ///      floor even past bankruptcy, because until it is seized its further losses are the
    ///      fund's and a keeper must be paid to stop them.
    ///
    ///      Below that notional the maintenance line can sit under the floor, and a position can
    ///      be brought to the line, or to zero equity, with no price move at all: margin that
    ///      rounds to zero lets a withdrawal take everything, and a partial close at an off-market
    ///      price to a second account can leave the remainder exactly at maintenance. An
    ///      unconditional floor would make each such account a flat payment from insurance.
    ///      Capped at equity, the fund never pays more for one than the equity it takes over.
    /// @param state The account's bucket state at the liquidation price and the live index
    /// @return The flat reward in BAZAAR_SCALE precision
    function flatReward(BazaarTypes.BucketState memory state) internal pure returns (uint256) {
        if (state.currentNotional < BazaarTypes.MIN_ORDER_AMOUNT && state.availableEquity < MIN_LIQUIDATOR_REWARD) {
            return state.availableEquity;
        }
        return MIN_LIQUIDATOR_REWARD;
    }

    /// @notice The keeper rate, LIQUIDATION_FEE_EBP, on `size` valued at `price`.
    /// @param size The size retired (BAZAAR_SCALE precision)
    /// @param price The price it is valued at (BAZAAR_SCALE precision)
    /// @return The rate in BAZAAR_SCALE precision
    function rateOn(uint256 size, uint256 price) internal pure returns (uint256) {
        return RiskParamsLib.keeperRateOn(size, price);
    }

    /// @notice What seizing one account earns: its flat reward, or the rate on the inventory the
    ///         seizure retires when that is larger.
    /// @dev Retired means taken off the books in the same transaction: the overlap the absorb's
    ///      netting closes, so it never sits on the fund. What stays in a bucket instead is
    ///      exposure moved onto the fund, and whoever later retires it is paid for that: an
    ///      unload's sale or a later netting at this rate, an ADL batch's close at this rate or at
    ///      its share of the bad debt the close averts where that is larger. Paying the rate at
    ///      seizure as well would pay twice for those units. The flat part covers gas on small
    ///      positions; the rate scales with size.
    /// @param state The account's bucket state at the liquidation price and the live index
    /// @param retiredSize The inventory the seizure retires (BAZAAR_SCALE precision)
    /// @param price The liquidation price (BAZAAR_SCALE precision)
    /// @return The reward in BAZAAR_SCALE precision
    function seizureReward(BazaarTypes.BucketState memory state, uint256 retiredSize, uint256 price)
        internal
        pure
        returns (uint256)
    {
        uint256 flat = flatReward(state);
        uint256 rate = rateOn(retiredSize, price);
        return rate > flat ? rate : flat;
    }

    /// @notice Folds a seized estate into the vault: merges it into its own side's bucket, seeding
    ///         one when that side is empty, then nets the two buckets' overlap where the fund may
    ///         (RiskParamsLib.tryNetBuckets).
    /// @dev The bucket's funding index is seeded/merged from the LIQUIDATEE'S ENTRY index, not the
    ///      liquidation-time index. The estate has no surviving owner, so its accrued funding
    ///      (entry → liquidation) must reach insurance or it vanishes while the counterparties'
    ///      offsetting side stays live — breaking funding zero-sum by exactly the estate's
    ///      funding PnL per liquidation. Carrying the entry index forward makes the settlement
    ///      paths (an unload fill, a netting, an ADL close) realize funding over entry → close in
    ///      one signed term: the estate's pre-liquidation balance and the funding accrued while
    ///      the vault held the inventory settle together into insurance.
    ///
    ///      The seizure stamp the unload floor opens from is kept the same way: seeded at the
    ///      present instant and blended by size when an estate joins, so a large estate arriving
    ///      late restarts most of the countdown while a dust one barely moves it. An aged bucket
    ///      therefore cannot lend a large new estate an already-open floor; what a dust estate
    ///      inherits from one is its own dust-sized residual equity.
    ///
    ///      Merged before any netting, so that one routine nets the buckets wherever the fund's
    ///      means move. A netting that takes the whole opposite bucket leaves the estate's
    ///      remainder in its own bucket, which is the inventory the fund then holds; a bucket
    ///      never changes side.
    /// @param pairVault The pair's vault aggregates
    /// @param e The estate to absorb
    /// @param price The liquidation price, which the netting's reserve is valued at
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return netted The size the netting retired off each bucket, 0 when nothing was netted
    function absorb(BazaarTypes.Vault storage pairVault, Estate memory e, uint256 price, int256 currentFundingIndex)
        internal
        returns (uint256 netted)
    {
        BazaarTypes.Inventory storage b = RiskParamsLib.bucketOf(pairVault, e.isLong);
        uint256 size = b.size;
        if (size == 0) {
            b.size = e.size;
            b.entryNotional = e.entryNotional;
            b.bankruptcyNotional = e.bankruptcyNotional;
            b.seized = e.seized;
            b.entryFundingIndex = e.entryFundingIndex;
            b.seizedTs = uint64(block.timestamp);
        } else {
            uint256 newTotalSize = size + e.size;
            b.entryFundingIndex =
                (b.entryFundingIndex * int256(size) + e.entryFundingIndex * int256(e.size)) / int256(newTotalSize);
            b.seizedTs = _blendSeizedTs(b.seizedTs, size, e.size, newTotalSize);
            b.size = newTotalSize;
            b.entryNotional += e.entryNotional;
            b.bankruptcyNotional += e.bankruptcyNotional;
            b.seized += e.seized;
        }
        netted = RiskParamsLib.tryNetBuckets(pairVault, price, currentFundingIndex);
    }

    // -------------------- Internal --------------------

    /// @dev A bucket's seizure stamp once `newSize` seized now joins `oldSize` stamped `oldTs`:
    ///      the size-weighted mean, rounded up so the blend never reads older than the estates in
    ///      it.
    function _blendSeizedTs(uint256 oldTs, uint256 oldSize, uint256 newSize, uint256 total)
        internal
        view
        returns (uint64)
    {
        return uint64((oldTs * oldSize + block.timestamp * newSize + total - 1) / total);
    }

    /// @notice The notional at which `state`'s position holds exactly zero equity: its entry
    ///         basis less its collateral and accrued funding for a long, plus them for a short.
    /// @dev Closing the position at this notional realizes a loss equal to its collateral once
    ///      the funding it accrued is settled, so the seizure covers it to the wei. That holds
    ///      only for the exact figure. Rebuilding it as size times a per-unit price rounds twice,
    ///      and for a long both roundings lower the proceeds: the loss would exceed the seizure
    ///      by the rounding, and a fund with no free capital has nothing to pay that from.
    /// @param state The position's bucket state at the liquidation price and the live index
    /// @param isLong The position's side
    /// @return The bankruptcy notional in BAZAAR_SCALE precision, floored at 0: a long whose
    ///         collateral and funding cover its whole entry basis is bankrupt at no positive price
    function bankruptcyNotionalOf(BazaarTypes.BucketState memory state, bool isLong) internal pure returns (uint256) {
        int256 backing = int256(state.effectiveCollateral) + state.fundingPnl;
        int256 notional = isLong ? int256(state.entryValue) - backing : int256(state.entryValue) + backing;
        return notional > 0 ? uint256(notional) : 0;
    }

    /// @notice Resets a user's position bucket to zero state
    /// @dev Cancels any active TP/SL orders and resets all position fields to zero. The
    ///      cancellation is load-bearing: TP/SL wait outside the book for a keeper to fire them,
    ///      so an order left live after the position is seized would execute market-style and
    ///      re-open exposure for a user who was just liquidated.
    function _resetBucket(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        int256 currentFundingIndex,
        BazaarTypes.MarginRequirements memory marginReqs,
        bytes32 pairId,
        uint64 currentBlock
    ) internal {
        _cancelBucketOrder(orders, book, bucket.takeProfitOrderId, pairId, currentBlock);
        _cancelBucketOrder(orders, book, bucket.stopLossOrderId, pairId, currentBlock);

        // Reset bucket fields (always reset collateral during liquidation)
        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.collateral = 0;
        bucket.entryFundingIndex = 0;
        bucket.takeProfitOrderId = 0;
        bucket.stopLossOrderId = 0;

        BucketLib.emitBucketUpdate(user, bucket, currentFundingIndex, marginReqs, pairId);
    }

    /// @dev Cancel one slot-anchored order (0 = none): stamp, unlink, emit. Already-terminal
    ///      orders are left untouched.
    function _cancelBucketOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId,
        bytes32 pairId,
        uint64 currentBlock
    ) private {
        if (orderId == 0) return;
        BazaarTypes.Order storage o = orders[orderId];
        if (o.canceledBlock != 0 || o.filledBlock != 0) return;
        o.canceledBlock = currentBlock;
        OrderBookLib.unlink(orders, book, orderId);
        OrderBookLib.emitOrderUpdated(
            pairId, orderId, o, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Liquidated
        );
    }
}
