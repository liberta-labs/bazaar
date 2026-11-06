// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {LiquidationLib} from "./LiquidationLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";

/// @title AdlLib
/// @notice External library for Auto-Deleveraging (ADL) logic. Runs via DELEGATECALL with
///         BazaarPair storage. Uses O(1) aggregate decrement instead of O(n) FIFO queue popping.
///
///         The vault holds two buckets, liquidated longs and liquidated shorts, and one batch runs
///         one leg per bucket: the long bucket is closed against profitable shorts, the short
///         bucket against profitable longs, each at its own settlement price — the bucket's
///         average bankruptcy price, or the mark when the mark sits on the fund's favorable side
///         of it — so a bucket's shortfall lands on that bucket's own counterparties and the fund
///         pays nothing on a close. Every cohort is scored at the price the call resolved and
///         sorted here, so a keeper submits its winners in any order and a newer tick cannot
///         reorder a batch out from under it.
///
///         The two legs meet only through the fund. Where the losing bucket's cohort cannot make
///         progress on its own because the bucket is hedged by the other one, its units are closed
///         in pairs with the winning bucket's; where the losing bucket has no cohort at all, the
///         winning bucket is closed at the mark until the fund can afford to net the two, and the
///         fund pays what it can afford, as a liquidation would have. Every batch ends by netting
///         the buckets' overlap if the fund can then afford it (RiskParamsLib.tryNetBuckets).
library AdlLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    uint256 internal constant MAX_ADL_WINNERS_PER_BATCH = 25;
    uint256 internal constant ADL_AUCTION_DURATION = BazaarTypes.ADL_AUCTION_DURATION;

    /// @dev The most of one close's shortfall that is treated as rounding rather than as a loss
    ///      the fund failed to back (_settleInventorySlice): one unit of USDC precision, the
    ///      smallest amount the pair can pay anyone.
    uint256 internal constant ROUNDING_ALLOWANCE = BAZAAR_SCALE / BazaarTypes.USDC_SCALE;

    // -------------------- Errors --------------------

    error AdlLib__EmptySubmission();
    error AdlLib__TooManyWinners(uint256 count, uint256 max);
    error AdlLib__NoPendingLiquidations();
    error AdlLib__NoEligibleWinners();

    // -------------------- Structs --------------------

    /// @notice What one close pays and releases.
    /// @param credit The amount added to the winner's collateral
    /// @param withheld The part of the credit the fund could not back, see _settleInventorySlice
    /// @param sliceEntry The entry basis released from the winner's bucket and the OI aggregates
    struct SliceSettlement {
        uint256 credit;
        uint256 withheld;
        uint256 sliceEntry;
    }

    /// @notice A bucket as a leg works it: the vault's aggregate loaded from storage.
    /// @dev The same fields as BazaarTypes.Inventory, with the side made explicit. Closes
    ///      decrement it pro rata in memory and write it back after each one.
    struct Inventory {
        uint256 size;
        uint256 entryNotional;
        uint256 bankruptcyNotional;
        uint256 seized;
        int256 entryFundingIndex;
        bool isLong;
    }

    /// @notice One leg of the batch: a bucket and the cohort submitted to close it.
    /// @param isLong The bucket's side; the cohort is the other side
    /// @param inv The bucket as loaded, decremented by the leg's closes
    /// @param settlementPrice The price the leg settles at (_settlementPrice)
    /// @param order Indices into the submitted cohort of the winners the scan admitted, sorted by
    ///        descending score and ascending address, duplicates dropped
    /// @param scores Each admitted winner's score, aligned with `order`
    /// @param eligibleSize The size the admitted winners cover, capped at the bucket
    /// @param eligibleCount The admitted winners counted toward that size
    /// @param highestAdlScore The first admitted winner's score
    /// @param lowestAdlScore The last admitted winner's score
    /// @param closed The size the leg closed
    /// @param ran True once the leg has been executed: a leg runs once per batch, so nothing can
    ///        be sized as pairs against it afterwards (_sizeToRestoreHealth)
    struct Leg {
        bool isLong;
        Inventory inv;
        uint256 settlementPrice;
        uint256[] order;
        uint256[] scores;
        uint256 eligibleSize;
        uint256 eligibleCount;
        uint256 highestAdlScore;
        uint256 lowestAdlScore;
        uint256 closed;
        bool ran;
    }

    /// @notice The vault-wide figures a close is sized against.
    /// @param edge The unload band's edge against the vault's net exposure
    /// @param edgeAgainstLong The band's lower edge, the one a long bucket is finished at
    /// @param edgeAgainstShort The band's upper edge, the one a short bucket is finished at
    /// @param finish What finishing the whole inventory at `edge` would cost beyond its earmark;
    ///        0 when the earmark covers the loss there
    /// @param budget The balance less the earmark and the reserve, plus the arrears: negative by
    ///        any shortfall below the reserve, or below the earmark itself
    /// @param heldBack Live open interest above the trailing reading the reserve is sized on:
    ///        units that close without releasing any reserve
    struct Figures {
        uint256 edge;
        uint256 edgeAgainstLong;
        uint256 edgeAgainstShort;
        uint256 finish;
        int256 budget;
        uint256 heldBack;
    }

    /// @notice What the batch earns its executor, paid once.
    /// @param closes What the legs' closes earn (_closeReward)
    /// @param netting The keeper rate on what the batch's netting retired
    struct Rewards {
        uint256 closes;
        uint256 netting;
    }

    // -------------------- Events --------------------

    /// @notice Emitted for every winner an ADL batch closes, fully or in part.
    /// @param pairId The pair
    /// @param user The deleveraged winner
    /// @param isLong The winner's side
    /// @param closedSize The size closed against the vault's inventory
    /// @param realizedPnl The amount credited to the winner's collateral: PnL at the settlement
    ///        price with the live funding index, less `withheldFunding`
    /// @param remainingCollateral The winner's collateral after the credit
    /// @param adlScore The winner's score at the price the batch resolved
    /// @param adlSettlementPrice The price the close settled at: the bucket's average bankruptcy
    ///        price, or the mark when the mark sat on the fund's favorable side of it
    /// @param withheldFunding What the insurance fund could not back and therefore did not pay;
    ///        bounded by the winner's funding income on the closed size, or by ROUNDING_ALLOWANCE
    ///        where that is larger, and by the credit
    event UserAdld(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        uint256 closedSize,
        int256 realizedPnl,
        uint256 remainingCollateral,
        uint256 adlScore,
        uint256 adlSettlementPrice,
        uint256 withheldFunding
    );

    /// @notice Emitted once per ADL batch.
    /// @dev Emitted here (via DELEGATECALL, so the log's emitter is the BazaarPair) rather than
    ///      from BazaarPair, which keeps the pair's EIP-170 budget free of it. Like every event a
    ///      linked library emits, it is absent from the pair's compiled ABI; script/export-abis.sh
    ///      writes an ABI that includes it.
    /// @param pairId The pair
    /// @param adlId The batch's sequence number on the pair
    /// @param submitter The executor, credited with the batch's rewards
    /// @param longBucketClosed The size closed off the long bucket, against shorts
    /// @param longBucketSettlementPrice The long leg's settlement price; 0 when the leg did not run
    /// @param shortBucketClosed The size closed off the short bucket, against longs
    /// @param shortBucketSettlementPrice The short leg's settlement price; 0 when the leg did not run
    /// @param netted The overlap netted bucket against bucket at the end of the batch
    /// @param timestamp The block timestamp
    event AdlExecuted(
        bytes32 indexed pairId,
        uint256 indexed adlId,
        address indexed submitter,
        uint256 longBucketClosed,
        uint256 longBucketSettlementPrice,
        uint256 shortBucketClosed,
        uint256 shortBucketSettlementPrice,
        uint256 netted,
        uint256 timestamp
    );

    // -------------------- External Functions --------------------

    /// @notice Core ADL execution: close each bucket against its own cohort, net the buckets'
    ///         overlap where the fund can afford it, and pay the executor.
    /// @dev Called via DELEGATECALL from BazaarPair.executeAdl, which re-evaluates vault health
    ///      after this returns. Rewards accrue to msg.sender's claimable balance here: for every
    ///      leg the keeper rate on what it closes, or ADL_EXECUTOR_REWARD_BP of the bad debt the
    ///      close averts where larger (_closeReward), and the keeper rate on what the netting
    ///      retires, capped together at the fund's free capital — the earmark left against
    ///      unclosed inventory settles that inventory, so a reward drawn from it would come out
    ///      of a later winner's funding income or an unload fill's backing.
    ///
    ///      Order: the losing leg first, the leg whose bucket is under water and settles at its
    ///      bankruptcy price; where both or neither are, the larger bucket first. The losing leg
    ///      is sized on the vault as the batch finds it, so its counterparties pay what restoring
    ///      health takes before any gain on the other bucket is realized; the other leg is sized
    ///      on what the first leaves, and closes only what is still needed. Each leg is sized to
    ///      the gate's release condition (_sizeToRestoreHealth): a deleverage takes what the
    ///      exposure requires and no more.
    ///
    ///      A losing bucket smaller than the other is hedged by it: closing its units alone turns
    ///      a hedged unit into exposure on the other bucket, and where the band edge lies closer to
    ///      the mark than its bankruptcy price does that worsens the finish cost rather than
    ///      lowering it. Such units are closed in pairs, one of each bucket against its own cohort,
    ///      and the other leg is held to at least that many. A losing bucket with no cohort at all
    ///      is resolved through the fund instead: the winning leg closes enough at the mark for the
    ///      fund to afford netting the overlap (_sizeToAffordNetting), and the netting that ends
    ///      every batch takes it.
    ///
    ///      Both legs rank their cohort at the price this call resolved and sort it here, so
    ///      neither depends on the order the keeper submitted, and a tick stored ahead of the call
    ///      moves the ranking without reverting the batch (_scan).
    /// @param longBucketWinners Candidate shorts to close the long bucket against, any order
    /// @param shortBucketWinners Candidate longs to close the short bucket against, any order
    function executeAdlCore(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        address[] calldata longBucketWinners,
        address[] calldata shortBucketWinners,
        BazaarTypes.AdlParams memory params,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) external returns (BazaarTypes.AdlResult memory r) {
        if (longBucketWinners.length == 0 && shortBucketWinners.length == 0) {
            revert AdlLib__EmptySubmission();
        }
        uint256 longest =
            longBucketWinners.length > shortBucketWinners.length ? longBucketWinners.length : shortBucketWinners.length;
        if (longest > MAX_ADL_WINNERS_PER_BATCH) revert AdlLib__TooManyWinners(longest, MAX_ADL_WINNERS_PER_BATCH);
        if (RiskParamsLib.inventorySize(pairVault) == 0) revert AdlLib__NoPendingLiquidations();

        Leg memory lng = _leg(pairVault, true, params.currentPrice);
        Leg memory sht = _leg(pairVault, false, params.currentPrice);
        _scan(positionBuckets, longBucketWinners, lng, params, adlEpoch, adlDepositEpoch, adlWindowDeposits);
        _scan(positionBuckets, shortBucketWinners, sht, params, adlEpoch, adlDepositEpoch, adlWindowDeposits);

        Rewards memory rw;
        uint256 pairUnits;
        if (_longFirst(lng, sht, params.currentPrice)) {
            pairUnits = _runLeg(orders, book, positionBuckets, pairVault, longBucketWinners, lng, sht, params, rw, 0);
            _runLeg(orders, book, positionBuckets, pairVault, shortBucketWinners, sht, lng, params, rw, pairUnits);
        } else {
            pairUnits = _runLeg(orders, book, positionBuckets, pairVault, shortBucketWinners, sht, lng, params, rw, 0);
            _runLeg(orders, book, positionBuckets, pairVault, longBucketWinners, lng, sht, params, rw, pairUnits);
        }

        // The legs moved the fund's means: every close handed it the slice's earmark and its
        // realization and freed reserve. A netting the fund could not afford before the batch can
        // fit now, and what it retires earns the executor the rate a liquidation's caller earns.
        r.netted = RiskParamsLib.tryNetBuckets(pairVault, params.currentPrice, params.currentFundingIndex);
        rw.netting = LiquidationLib.rateOn(r.netted, params.currentPrice);

        // Nothing to do at all: no winner passed either scan and no netting fit. A winner the scan
        // admitted but the close skipped at the settlement price is not that case, so the batch
        // returns quietly.
        if (lng.eligibleSize == 0 && sht.eligibleSize == 0 && r.netted == 0) revert AdlLib__NoEligibleWinners();

        _payRewards(pairVault, feeEscrow, params.pairId, rw);
        r.longBucket = _legResult(lng);
        r.shortBucket = _legResult(sht);
        emit AdlExecuted(
            params.pairId,
            params.adlId,
            msg.sender,
            lng.closed,
            lng.settlementPrice,
            sht.closed,
            sht.settlementPrice,
            r.netted,
            block.timestamp
        );
    }

    // -------------------- Legs --------------------

    /// @dev One leg as loaded for the batch: the bucket and the price it settles at. A leg over an
    ///      empty bucket admits no winner and closes nothing.
    function _leg(BazaarTypes.Vault storage pairVault, bool isLong, uint256 currentPrice)
        internal
        view
        returns (Leg memory leg)
    {
        leg.isLong = isLong;
        BazaarTypes.Inventory storage b = RiskParamsLib.bucketOf(pairVault, isLong);
        leg.inv = Inventory(b.size, b.entryNotional, b.bankruptcyNotional, b.seized, b.entryFundingIndex, isLong);
        if (b.size != 0) leg.settlementPrice = _settlementPrice(leg.inv, currentPrice);
    }

    /// @dev Whether the long leg runs first: the losing leg does, the one whose bucket settles at
    ///      its bankruptcy price rather than the mark; where both or neither do, the larger bucket.
    function _longFirst(Leg memory lng, Leg memory sht, uint256 currentPrice) internal pure returns (bool) {
        bool longLosing = lng.inv.size != 0 && lng.settlementPrice != currentPrice;
        bool shortLosing = sht.inv.size != 0 && sht.settlementPrice != currentPrice;
        if (longLosing != shortLosing) return longLosing;
        return lng.inv.size >= sht.inv.size;
    }

    /// @dev Sizes and closes one leg. The size is the gate's release figure on the vault as it
    ///      stands (_sizeToRestoreHealth), or, when the other bucket has no cohort and sits under
    ///      water, what the fund needs this bucket closed at the mark for to afford netting the
    ///      two (_sizeToAffordNetting); never less than `forced`, the pairs the other leg sized
    ///      against this one, and never more than the cohort covers or the bucket holds.
    /// @return pairUnits The units this leg closed as pairs with the other leg's, which that leg is
    ///         held to; 0 when it sized itself alone
    function _runLeg(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] calldata winners,
        Leg memory leg,
        Leg memory other,
        BazaarTypes.AdlParams memory params,
        Rewards memory rw,
        uint256 forced
    ) internal returns (uint256 pairUnits) {
        leg.ran = true;
        if (leg.inv.size == 0 || leg.eligibleSize == 0) return 0;
        uint256 mmrBp = BucketLib.effectiveMmrBp(params.marginRequirements);
        uint256 plan;
        bool otherStranded = other.inv.size != 0 && other.eligibleSize == 0
            && other.settlementPrice != params.currentPrice && leg.settlementPrice == params.currentPrice;
        if (otherStranded) {
            plan = _sizeToAffordNetting(pairVault, params, leg, mmrBp, _rewardOf(rw));
        } else {
            (plan, pairUnits) = _sizeToRestoreHealth(pairVault, params, leg, other, mmrBp, _rewardOf(rw));
        }
        // The pairs are the tail of the plan, behind the units the leg closes alone.
        uint256 alone = plan - pairUnits;
        if (plan < forced) plan = forced;
        if (plan > leg.eligibleSize) plan = leg.eligibleSize;
        if (plan > leg.inv.size) plan = leg.inv.size;
        if (plan == 0) return 0;
        leg.closed = _closeAdlWinners(orders, book, positionBuckets, pairVault, winners, leg, params, plan);
        rw.closes += _closeReward(leg.isLong, params.currentPrice, leg.settlementPrice, leg.closed);
        // A pair whose half this leg did not close — the cap above, or a winner skipped at the
        // settlement price — does not hold the other leg to its unit.
        uint256 paired = leg.closed > alone ? leg.closed - alone : 0;
        if (pairUnits > paired) pairUnits = paired;
    }

    /// @dev A leg's figures as the batch reports them.
    function _legResult(Leg memory leg) internal pure returns (BazaarTypes.AdlLegResult memory lr) {
        lr.eligibleSize = leg.eligibleSize;
        lr.eligibleCount = leg.eligibleCount;
        lr.highestAdlScore = leg.highestAdlScore;
        lr.lowestAdlScore = leg.lowestAdlScore;
        lr.closedSize = leg.closed;
        lr.settlementPrice = leg.settlementPrice;
    }

    // -------------------- Ranking --------------------

    /// @notice The ranking denominator: the bucket's collateral less any deposit tagged to the
    ///         current ADL window, floored at 1.
    /// @dev A deposit made while a window is open must not improve its owner's queue position on
    ///      either side, which is what dividing by the pre-deposit collateral guarantees. Deposits
    ///      from earlier windows (a different epoch) are not subtracted. Floored at 1 so a
    ///      zero-collateral winner ranks at the top rather than reverting the batch — profit on no
    ///      collateral is the strongest possible claim.
    function _scoreCollateral(
        uint256 effectiveCollateral,
        address user,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) private view returns (uint256) {
        uint256 wd = adlDepositEpoch[user] == adlEpoch ? adlWindowDeposits[user] : 0;
        return _scoreCollateral(effectiveCollateral, wd);
    }

    /// @notice The ranking denominator as the lens computes it: the bucket's collateral less the
    ///         already-epoch-checked deposit, floored at 1.
    /// @param effectiveCollateral The bucket's collateral at the ranking price
    /// @param windowDeposit The already-epoch-checked deposit tagged to the current ADL window
    /// @return The collateral denominator used in the ADL score
    function _scoreCollateral(uint256 effectiveCollateral, uint256 windowDeposit) internal pure returns (uint256) {
        uint256 base = effectiveCollateral > windowDeposit ? effectiveCollateral - windowDeposit : 0;
        return base == 0 ? 1 : base;
    }

    /// @notice Computes the ADL auction score threshold (quadratic decay)
    /// @dev Measured from the auction's current decay run rather than from the window's opening:
    ///      a market discontinuity restarts the run, because a threshold that descended while ADL
    ///      was unexecutable narrowed against attempts nobody could make.
    /// @param auctionStartTs Start of the current decay run; 0 when no auction is running, which
    ///        returns a threshold no score can reach
    /// @return The minimum ADL score a winner must carry to be eligible right now
    function _getAdlScoreThreshold(uint256 auctionStartTs) internal view returns (uint256) {
        if (auctionStartTs == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - auctionStartTs;
        uint256 maxScore = BazaarTypes.ADL_MAX_SCORE;
        if (elapsed >= ADL_AUCTION_DURATION) return 1;
        uint256 remaining = ADL_AUCTION_DURATION - elapsed;
        return 1 + maxScore * remaining * remaining / (ADL_AUCTION_DURATION * ADL_AUCTION_DURATION);
    }

    /// @notice Pass 1: read-only scan of one leg's cohort. Admits every submitted account on the
    ///         cohort's side with a positive PnL at the price the call resolved and a score at or
    ///         above the Dutch threshold, sorts the admitted by descending score and ascending
    ///         address, drops repeats, and reads off the size the cohort covers.
    /// @dev Ranked at the live price and funding index, the same figures the close settles the
    ///      winning leg at, so the two agree on who is a winner there; the losing leg's close
    ///      re-checks each winner at its bankruptcy price and skips one under water there. Sorted
    ///      here rather than by the keeper: the score moves with every tick, and a keeper's sort
    ///      checked against the on-chain order would be reverted by any tick stored ahead of its
    ///      call, which anyone can post. The sort is an insertion sort over at most
    ///      MAX_ADL_WINNERS_PER_BATCH entries. Ties break on ascending address, which makes the
    ///      order total, so a repeated account sorts next to itself and is dropped there; the
    ///      close loop therefore consumes each account once.
    ///
    ///      The eligible size counts admitted winners in order until it covers the bucket, which
    ///      the close loop's own `totalClosed >= requiredSize` break enforces; entries past that
    ///      point stay in the order in case a winner ahead of them is skipped at the settlement
    ///      price.
    function _scan(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] calldata winners,
        Leg memory leg,
        BazaarTypes.AdlParams memory params,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal view {
        uint256 n = winners.length;
        if (n == 0 || leg.inv.size == 0) return;
        uint256 threshold = _getAdlScoreThreshold(params.adlAuctionStartTs);
        uint256[] memory order = new uint256[](n);
        uint256[] memory scores = new uint256[](n);
        uint256 m;
        for (uint256 i = 0; i < n; i++) {
            address user = winners[i];
            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
            if (bucket.size == 0 || bucket.isLong == leg.isLong) continue;
            BazaarTypes.BucketState memory state = BucketLib.calculateState(
                bucket, params.currentPrice, params.currentFundingIndex, params.marginRequirements
            );
            if (state.totalPnl <= 0) continue;
            uint256 score = Math.mulDiv(
                uint256(state.totalPnl),
                BAZAAR_SCALE,
                _scoreCollateral(state.effectiveCollateral, user, adlEpoch, adlDepositEpoch, adlWindowDeposits)
            );
            if (score < threshold) continue;
            // Insert behind every entry that outranks it: a higher score, or the same score and a
            // lower address.
            uint256 j = m;
            while (j > 0 && _outranks(score, user, scores[j - 1], winners[order[j - 1]])) {
                order[j] = order[j - 1];
                scores[j] = scores[j - 1];
                j--;
            }
            order[j] = i;
            scores[j] = score;
            m++;
        }
        // Repeats sort adjacent; keep the first of each. Read off the size the kept cover.
        uint256 kept;
        for (uint256 a = 0; a < m; a++) {
            address user = winners[order[a]];
            if (kept != 0 && winners[order[kept - 1]] == user) continue;
            order[kept] = order[a];
            scores[kept] = scores[a];
            kept++;
            if (leg.eligibleSize < leg.inv.size) {
                uint256 winnerSize = positionBuckets[user].size;
                uint256 remaining = leg.inv.size - leg.eligibleSize;
                leg.eligibleSize += winnerSize < remaining ? winnerSize : remaining;
                leg.eligibleCount++;
                if (leg.eligibleCount == 1) leg.highestAdlScore = scores[a];
                leg.lowestAdlScore = scores[a];
            }
        }
        assembly ("memory-safe") {
            mstore(order, kept)
            mstore(scores, kept)
        }
        leg.order = order;
        leg.scores = scores;
    }

    /// @dev Whether (`score`, `user`) sorts ahead of (`prevScore`, `prevUser`): a higher score, or
    ///      the same score and a lower address. A repeat of the same account never does, so it
    ///      lands directly behind its first entry.
    function _outranks(uint256 score, address user, uint256 prevScore, address prevUser) private pure returns (bool) {
        return score > prevScore || (score == prevScore && user < prevUser);
    }

    // -------------------- Sizing --------------------

    /// @notice The vault-wide figures a close is sized against (Figures).
    /// @dev The gate's release condition reduced to one budget: free capital above the reserve
    ///      (negative by the shortfall below it) plus the ledger's arrears, which a close's loss is
    ///      paid net of. Free capital is taken signed, the balance less the earmark: a fund holding
    ///      less than it has earmarked is short by the difference, and what the closes hand it
    ///      fills that hole before any of it reaches the reserve or the finish cost — the gate
    ///      reads such a fund as holding nothing, and would go on reading it so after a close sized
    ///      as if the hole were not there. Against the budget, what finishing the whole inventory
    ///      at the band edge would cost beyond its earmark, taken without the arrears since the
    ///      budget counts them once. The edge is the one RiskParamsLib.vaultAdlExposure reads:
    ///      against the vault's net exposure, since the buckets' overlap does not move with it.
    function _figures(BazaarTypes.Vault storage pairVault, BazaarTypes.AdlParams memory params, uint256 mmrBp)
        internal
        view
        returns (Figures memory f)
    {
        uint256 bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        f.edgeAgainstLong = params.currentPrice * (BP_SCALE - bandBp) / BP_SCALE;
        f.edgeAgainstShort = params.currentPrice * (BP_SCALE + bandBp) / BP_SCALE;
        f.edge = RiskParamsLib.netLong(pairVault) ? f.edgeAgainstLong : f.edgeAgainstShort;
        uint256 seized = RiskParamsLib.seizedTotal(pairVault);
        int256 net = RiskParamsLib.vaultPnl(pairVault, f.edge, params.currentFundingIndex) + int256(seized);
        if (net < 0) f.finish = uint256(-net);
        uint256 reserve = RiskParamsLib.adlReserve(pairVault, params.currentPrice);
        f.budget =
            int256(pairVault.insuranceFundBalance) - int256(seized) - int256(reserve) + int256(pairVault.ledgerArrears);
        uint256 liveOi = RiskParamsLib.openInterestSize(pairVault);
        f.heldBack = liveOi - RiskParamsLib.reserveOiSizeOf(liveOi, pairVault.trailingOiSize);
    }

    /// @notice What closing `units` of a leg's bucket at `settlementPrice` moves the release
    ///         condition by, before any reserve release: the cash the close hands the fund less
    ///         what it takes off the finish cost, which is the bucket's PnL at the settlement
    ///         price less its PnL at the band edge on those units. Signed: negative when the
    ///         bucket's units are hedged by the other bucket and the edge sits on their favorable
    ///         side, so closing them alone widens the exposure the edge is measured on.
    /// @dev The earmark enters both terms and cancels; so does the funding leg, which both prices
    ///      share. On a long bucket it is (settlement − edge) per unit, on a short bucket
    ///      (edge − settlement).
    function _legGain(Leg memory leg, uint256 edge, uint256 settlementPrice, uint256 units)
        internal
        pure
        returns (int256)
    {
        int256 distance = leg.isLong ? int256(settlementPrice) - int256(edge) : int256(edge) - int256(settlementPrice);
        return BazaarMathLib.signedMulDiv(distance, int256(units), int256(BAZAAR_SCALE));
    }

    /// @notice The size of `leg`'s bucket whose close at the leg's settlement price brings the
    ///         vault back under the ADL release condition, in two segments: the bucket's excess
    ///         over the other bucket, closed alone, and then its units hedged by the other bucket,
    ///         closed in pairs with the other leg's where that leg is still to run, or alone where
    ///         closing them alone still gains.
    /// @dev Sizes the batch so a deleverage takes only what the exposure requires. Bounding by
    ///      winner count instead would let one account large enough to cover the bucket absorb
    ///      all of it: every unit past this figure settles a solvent trader at the batch's
    ///      settlement price for no protective gain, and the executor reward — linear in the size
    ///      closed — pays for the excess.
    ///
    ///      The target is the gate's release condition: the fund's budget (_figures) must be able
    ///      to finish the remaining inventory at the unload band's edge, so the walk that resumes
    ///      afterwards can sell it inside the band without reopening the window. Closing one unit
    ///      moves both sides of that comparison by the leg's gain on it (_legGain), less what the
    ///      unit pays the executor (_closeReward), debited on this batch's own closed size before
    ///      the health re-evaluation that ends the auction; and the budget rises by the reserve on
    ///      the unit itself. A close removes the unit from the vault's side and from the winner's,
    ///      so per-side open interest falls by it and the reserve, a share of the target on that
    ///      open interest, falls with it: capital that returns to the budget without a dollar
    ///      moving. The reserve is sized on live open interest only up to its trailing minimum
    ///      (RiskParamsLib.reserveOiSizeOf), so while live open interest sits above that minimum
    ///      the first units closed release nothing: the release starts once the close has brought
    ///      live open interest down to it.
    ///
    ///      The bucket's excess over the other bucket is the vault's net exposure, and those units
    ///      always gain: their settlement price lies on the favorable side of the mark, and the
    ///      edge on the adverse side. Past the excess every unit is hedged by one of the other
    ///      bucket, and closing it alone turns the pair into exposure of the other bucket, finished
    ///      at the edge adverse to that bucket: the unit gains only where its own settlement price
    ///      lies beyond that edge, that is where the bucket is under water by more than the band.
    ///      Such units are closed in pairs where they can be, one of each bucket, each against its
    ///      own cohort: a pair retires an overlap unit whole, its gain is the two legs' together,
    ///      the two settlement prices' gap less the rewards, with reserve released on both sides.
    ///      The pairs are capped at what the other cohort covers, and the other leg is held to at
    ///      least that many (executeAdlCore). Only the leg that runs first can size pairs: the
    ///      other leg has not run yet and is held to them, whereas a leg that has already run
    ///      closes nothing more, so a pair sized against it would close its own half alone and
    ///      forfeit the hedge the figure counted on. Hedged units with no leg to pair with close
    ///      alone where that gains, and otherwise not at all.
    ///
    ///      Every term is linear in the size closed within a segment under the proportional
    ///      decrement _releaseSlice applies, and none depends on which winner takes the other side,
    ///      so one figure holds per segment; _sizeToCover solves each, the second over what the
    ///      first leaves of the distance, with the units that release no reserve consumed first.
    ///      ROUNDING_ALLOWANCE on top, so the pro-rata shares each slice rounds on its own cannot
    ///      land the release a few wei short and leave a second call to close dust.
    ///
    ///      What the batch has already earned is paid from the same free capital after this close,
    ///      so it is part of the distance to cover.
    /// @param pairVault The pair's vault aggregates
    /// @param params The batch parameters
    /// @param leg The leg being sized
    /// @param other The other leg, whose bucket bounds the excess and whose cohort the pairs are
    ///        capped at
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @param accruedReward The executor's reward accrued in this batch before this close
    /// @return size The size to close, 0 when the vault already meets the release condition or
    ///         the leg cannot move it
    /// @return pairUnits The part of `size` sized as pairs with the other leg's units, 0 when none
    function _sizeToRestoreHealth(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.AdlParams memory params,
        Leg memory leg,
        Leg memory other,
        uint256 mmrBp,
        uint256 accruedReward
    ) internal view returns (uint256 size, uint256 pairUnits) {
        // The gate's own reading first, so the figure is 0 exactly when the gate would release.
        (, uint256 base, uint256 worstFinish,) =
            RiskParamsLib.vaultAdlExposure(pairVault, params.currentPrice, params.currentFundingIndex, mmrBp);
        if (worstFinish + accruedReward <= base) return (0, 0);

        Figures memory f = _figures(pairVault, params, mmrBp);
        uint256 distance;
        {
            uint256 need = f.finish + accruedReward + ROUNDING_ALLOWANCE;
            if (int256(need) <= f.budget) return (0, 0);
            distance = uint256(int256(need) - f.budget);
        }
        uint256 targetBp = pairVault.targetInsuranceRatioBp;
        uint256 heldBack = f.heldBack;

        // Segment 1: the excess over the other bucket, directional units closed alone.
        uint256 excess = leg.inv.size > other.inv.size ? leg.inv.size - other.inv.size : 0;
        if (excess != 0) {
            int256 gain = _legGain(leg, f.edge, leg.settlementPrice, excess)
                - int256(_closeReward(leg.isLong, params.currentPrice, leg.settlementPrice, excess));
            if (gain > 0) {
                size = _sizeToCover(
                    distance,
                    gain,
                    RiskParamsLib.adlReserveOf(excess, params.currentPrice, targetBp),
                    RiskParamsLib.adlReserveOf(heldBack, params.currentPrice, targetBp),
                    heldBack,
                    excess
                );
                if (size <= excess) return (size, 0);
                // The whole excess does not cover the distance: take it all, and size the hedged
                // units over what it leaves.
                size = excess;
                uint256 releasing = excess > heldBack ? excess - heldBack : 0;
                uint256 progress = uint256(gain) + RiskParamsLib.adlReserveOf(releasing, params.currentPrice, targetBp);
                distance = distance > progress ? distance - progress : 0;
                heldBack = heldBack > excess ? heldBack - excess : 0;
            }
        }

        // Segment 2: the units hedged by the other bucket.
        uint256 hedged = leg.inv.size - excess;
        if (hedged == 0 || distance == 0) return (size, 0);
        bool paired = !other.ran && other.eligibleSize != 0;
        uint256 units = hedged;
        int256 gain2;
        if (paired) {
            if (units > other.eligibleSize) units = other.eligibleSize;
            gain2 = _legGain(leg, f.edge, leg.settlementPrice, units)
                + _legGain(other, f.edge, other.settlementPrice, units)
                - int256(_closeReward(leg.isLong, params.currentPrice, leg.settlementPrice, units))
                - int256(_closeReward(other.isLong, params.currentPrice, other.settlementPrice, units));
        } else {
            // Alone, a hedged unit leaves the other bucket's unit directional: it is finished at
            // the edge adverse to that bucket.
            uint256 edge = other.isLong ? f.edgeAgainstLong : f.edgeAgainstShort;
            gain2 = _legGain(leg, edge, leg.settlementPrice, units)
                - int256(_closeReward(leg.isLong, params.currentPrice, leg.settlementPrice, units));
        }
        if (gain2 <= 0) return (size, 0);
        uint256 size2 = _sizeToCover(
            distance,
            gain2,
            RiskParamsLib.adlReserveOf(paired ? 2 * units : units, params.currentPrice, targetBp),
            RiskParamsLib.adlReserveOf(heldBack, params.currentPrice, targetBp),
            heldBack,
            units
        );
        if (size2 > units) size2 = units;
        size += size2;
        if (paired) pairUnits = size2;
    }

    /// @notice The size of the winning leg's bucket to close at the mark so that the fund can
    ///         afford to net the two buckets' overlap, when the losing bucket has no cohort to
    ///         close it against.
    /// @dev A losing bucket with no cohort holds the window open however the rest reads, and
    ///      only the fund absorbing it ends that: the netting, once the fund can afford it, which
    ///      the netting at the end of every batch takes. The winning leg is what moves the fund's
    ///      means. Each unit it closes at the mark hands the fund the slice's earmark plus its
    ///      realization there, and once live open interest is down to the trailing reading the
    ///      reserve is sized on, frees the unit's share of the reserve. The condition is the
    ///      netting's own gate (RiskParamsLib.overlapAffordable) on the budget _figures reads, with
    ///      the release folded in: the budget after the close has to cover the netting's cost
    ///      beyond the two netted slices' own backing, the rate the netting pays its executor, the
    ///      reward accrued before this close, and what the bucket the netting leaves has to keep —
    ///      the larger of its finish cost at the band edge, which the release test reads, and the
    ///      cost beyond its earmark of closing it at its bankruptcy price, which the gate holds out
    ///      of the netting's reach so a later bankruptcy-priced close of it books no deficit.
    ///
    ///      Capped so the close never eats into the overlap itself: at the winning bucket's excess
    ///      over the other bucket when it is the larger, and at the whole bucket when it is the
    ///      smaller or the two are equal, where closing it all retires the overlap and leaves
    ///      nothing to net. Where no
    ///      size within that cap affords the netting, the cap is closed and the netting waits for
    ///      the next batch or walk to move the fund's means further.
    /// @param pairVault The pair's vault aggregates
    /// @param params The batch parameters
    /// @param leg The winning leg, settling at the mark
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @param accruedReward The executor's reward accrued in this batch before this close
    /// @return The size to close, 0 when the fund can already afford the netting
    function _sizeToAffordNetting(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.AdlParams memory params,
        Leg memory leg,
        uint256 mmrBp,
        uint256 accruedReward
    ) internal view returns (uint256) {
        (uint256 o, int256 pnl, uint256 seized) = RiskParamsLib.overlap(pairVault);
        if (o == 0) return 0;
        uint256 overlapCost;
        if (pnl + int256(seized) < 0) overlapCost = uint256(-(pnl + int256(seized)));

        Figures memory f = _figures(pairVault, params, mmrBp);
        bool big = RiskParamsLib.netLong(pairVault);
        BazaarTypes.Inventory storage survivor = RiskParamsLib.bucketOf(pairVault, big);
        uint256 rest = survivor.size - o;
        uint256 need;
        {
            // What the survivor has to keep, pro rata to what the netting leaves of it.
            uint256 finishWhole;
            {
                int256 net = RiskParamsLib.bucketPnl(survivor, big, f.edge, params.currentFundingIndex)
                    + int256(survivor.seized);
                if (net < 0) finishWhole = uint256(-net);
            }
            uint256 bankruptcyClose = RiskParamsLib.bucketBankruptcyCloseCost(survivor, big, params.currentFundingIndex);
            uint256 keepWhole = bankruptcyClose > finishWhole ? bankruptcyClose : finishWhole;
            need = overlapCost + LiquidationLib.rateOn(o, params.currentPrice) + accruedReward
                + Math.mulDiv(keepWhole, rest, survivor.size) + ROUNDING_ALLOWANCE;
        }
        if (int256(need) <= f.budget) return 0;
        uint256 distance = uint256(int256(need) - f.budget);

        // The winning bucket's excess over the other when it is the larger; the whole bucket when it
        // is the smaller or the two are equal, where closing it all retires the overlap.
        uint256 closable = leg.isLong == big && rest != 0 ? rest : leg.inv.size;
        if (closable == 0) return 0;
        (int256 realization, uint256 earmark) =
            _releaseSlice(_copy(leg.inv), params.currentFundingIndex, closable, params.currentPrice);
        int256 progress = realization + int256(earmark)
            - int256(_closeReward(leg.isLong, params.currentPrice, params.currentPrice, closable));
        uint256 size = _sizeToCover(
            distance,
            progress,
            RiskParamsLib.adlReserveOf(closable, params.currentPrice, pairVault.targetInsuranceRatioBp),
            RiskParamsLib.adlReserveOf(f.heldBack, params.currentPrice, pairVault.targetInsuranceRatioBp),
            f.heldBack,
            closable
        );
        return size > closable ? closable : size;
    }

    /// @notice The smallest size whose close covers `distance`, when closing all of `size`
    ///         progresses `progress` before any reserve release and the units past the first
    ///         `heldBack` release `reserve` between them.
    /// @dev With units that release nothing ahead of the ones that do, progress is two straight
    ///      segments, and the size is the smaller of two solutions: the one that never reaches
    ///      the release, and the one that counts it from the first unit and adds the reserve on
    ///      the unreleased stretch to the distance. The first is the answer when it falls inside
    ///      that stretch and the second when it does not, and in each case it is the smaller.
    ///      Neither solution exists when its denominator is non-positive: closing drains the fund
    ///      at least as fast as it repairs it.
    ///
    ///      Rounded up: landing a fraction of a unit short leaves the auction pending for a
    ///      second call that closes dust.
    /// @param distance What the close has to cover
    /// @param progress What closing the whole `size` contributes before any reserve release;
    ///        negative when closing costs the fund
    /// @param reserve The reserve released by closing the whole `size`, were every unit to release
    /// @param reserveHeldBack The reserve on the first `heldBack` units, which release nothing
    /// @param heldBack The units that close without releasing any reserve
    /// @param size The size the whole-inventory figures are measured over
    /// @return result The size to close, type(uint256).max when no size covers the distance
    function _sizeToCover(
        uint256 distance,
        int256 progress,
        uint256 reserve,
        uint256 reserveHeldBack,
        uint256 heldBack,
        uint256 size
    ) internal pure returns (uint256 result) {
        result = type(uint256).max;
        int256 denominator = progress + SafeCast.toInt256(reserve);
        if (denominator > 0) {
            result = Math.mulDiv(distance + reserveHeldBack, size, uint256(denominator), Math.Rounding.Ceil);
        }
        if (heldBack != 0 && progress > 0) {
            uint256 withoutRelease = Math.mulDiv(distance, size, uint256(progress), Math.Rounding.Ceil);
            if (withoutRelease < result) result = withoutRelease;
        }
    }

    /// @dev A copy of `inv`, for a reading by a function that decrements the inventory it is
    ///      given. A memory-to-memory struct assignment shares the pointer.
    function _copy(Inventory memory inv) internal pure returns (Inventory memory) {
        return Inventory({
            size: inv.size,
            entryNotional: inv.entryNotional,
            bankruptcyNotional: inv.bankruptcyNotional,
            seized: inv.seized,
            entryFundingIndex: inv.entryFundingIndex,
            isLong: inv.isLong
        });
    }

    // -------------------- Closing --------------------

    /// @notice Pass 2: closes the leg's admitted winners, in the scan's order, against the leg's
    ///         bucket at its settlement price until `requiredSize` is closed.
    /// @dev Settlement realizes at the live funding index and the leg's settlement price. A winner
    ///      profitable at the mark can be under water at a bankruptcy-priced settlement; only a
    ///      strictly negative settlement PnL is skipped, so a market-profitable trader is never
    ///      forced into a realized loss and a negative is never cast below. The bucket is written
    ///      back after every close, so the next iteration sees the reduced exposure.
    function _closeAdlWinners(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] calldata winners,
        Leg memory leg,
        BazaarTypes.AdlParams memory params,
        uint256 requiredSize
    ) internal returns (uint256 totalClosed) {
        BazaarTypes.Inventory storage stored = RiskParamsLib.bucketOf(pairVault, leg.isLong);
        for (uint256 k = 0; k < leg.order.length; k++) {
            if (totalClosed >= requiredSize) break;

            // executeAdl's entry health check routes a pre-existing deficit into termination
            // and never reaches this loop, so a non-zero value here means an earlier close in
            // THIS batch found the fund unable to back the inventory's own settlement beyond
            // what the winner's funding income could absorb. The post-batch health check
            // terminates the pair; every further close would only turn more of the survivors'
            // unrealized claims into realized ones the fund cannot back, so stop and let the
            // settlement waterfall share the recorded shortfall pro-rata.
            if (pairVault.deficit > 0) break;

            address user = winners[leg.order[k]];
            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
            if (bucket.size == 0 || bucket.isLong == leg.isLong) continue;

            BazaarTypes.BucketState memory state = BucketLib.calculateState(
                bucket, leg.settlementPrice, params.currentFundingIndex, params.marginRequirements
            );
            if (state.totalPnl < 0) continue;

            uint256 remaining = requiredSize - totalClosed;
            uint256 closedSize = state.adjustedSize <= remaining ? state.adjustedSize : remaining;
            totalClosed += closedSize;

            // Settles the inventory slice through insurance (and releases it from the bucket, so
            // the next iteration sees the reduced exposure), then sizes the winner's credit.
            uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
            SliceSettlement memory s = _settleSlice(
                pairVault, leg.inv, free, params.currentFundingIndex, state, closedSize, leg.settlementPrice
            );
            _storeInventory(stored, leg.inv);

            _applyAdlVaultUpdate(pairVault, !leg.isLong, closedSize, s.sliceEntry);
            bucket.collateral = SafeCast.toUint128(state.effectiveCollateral + s.credit);

            if (closedSize == state.adjustedSize) {
                emit UserAdld(
                    params.pairId,
                    user,
                    !leg.isLong,
                    closedSize,
                    int256(s.credit),
                    bucket.collateral,
                    leg.scores[k],
                    leg.settlementPrice,
                    s.withheld
                );
                _resetBucket(orders, book, user, bucket, params);
            } else {
                // Both subtrahends are proportional slices of the current values.
                bucket.size -= uint128(closedSize);
                bucket.entryValue -= uint128(s.sliceEntry);
                // A TP/SL sized for the pre-deleverage position needs no fence: it caps
                // itself at the live position when it fires, so it closes what is left
                // rather than filling past flat. The position keeps its side here and stays
                // non-zero (a full close takes the branch above), so it is still reducible.
                BucketLib.emitBucketUpdate(
                    user, bucket, params.currentFundingIndex, params.marginRequirements, params.pairId
                );
                emit UserAdld(
                    params.pairId,
                    user,
                    !leg.isLong,
                    closedSize,
                    int256(s.credit),
                    bucket.collateral,
                    leg.scores[k],
                    leg.settlementPrice,
                    s.withheld
                );
            }
        }
    }

    /// @dev The executor's reward for the whole batch (_rewardOf), capped at the fund's free
    ///      capital.
    function _payRewards(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        bytes32 pairId,
        Rewards memory rw
    ) internal {
        uint256 reward = _rewardOf(rw);
        uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
        if (reward > free) reward = free;
        if (reward > 0) {
            pairVault.insuranceFundBalance -= reward;
            FeeEscrowLib.credit(feeEscrow, pairId, msg.sender, reward);
        }
    }

    /// @dev The batch's reward before the cap: what the legs' closes earn and the rate on what the
    ///      netting retired.
    function _rewardOf(Rewards memory rw) internal pure returns (uint256) {
        return rw.closes + rw.netting;
    }

    /// @dev What a leg pays its executor for closing `closedSize` at `settlementPrice`: the keeper
    ///      rate on that size at the mark, or ADL_EXECUTOR_REWARD_BP of the bad debt the close
    ///      averts where that is larger. Those units are the inventory's own exposure, which only
    ///      closing it takes off the fund while the window halts unloads, so they are paid the
    ///      rate an unload's sale is paid, at the mark as at the bankruptcy price. The averted
    ///      share is the larger only once the mark lies past the bankruptcy price by more than the
    ///      ratio of the two rates, a fifth of the mark. Both are linear in the size closed, so the
    ///      batch sizing reads them per unit.
    function _closeReward(bool inventoryIsLong, uint256 currentPrice, uint256 settlementPrice, uint256 closedSize)
        internal
        pure
        returns (uint256)
    {
        uint256 rate = LiquidationLib.rateOn(closedSize, currentPrice);
        uint256 share = Math.mulDiv(
            _avertedLoss(inventoryIsLong, currentPrice, settlementPrice, closedSize),
            BazaarTypes.ADL_EXECUTOR_REWARD_BP,
            BP_SCALE
        );
        return rate > share ? rate : share;
    }

    /// @dev The bad debt a close averted: the distance from the mark to the settlement price on
    ///      the closed size, in the direction that would have cost the fund; nothing once the
    ///      mark sits on the fund's favorable side.
    function _avertedLoss(bool inventoryIsLong, uint256 currentPrice, uint256 settlementPrice, uint256 closedSize)
        internal
        pure
        returns (uint256)
    {
        if (inventoryIsLong) {
            return
                currentPrice < settlementPrice
                    ? Math.mulDiv(closedSize, settlementPrice - currentPrice, BAZAAR_SCALE)
                    : 0;
        }
        return
            currentPrice > settlementPrice ? Math.mulDiv(closedSize, currentPrice - settlementPrice, BAZAAR_SCALE) : 0;
    }

    /// @dev The estates' average bankruptcy price is where the bucket realizes exactly the
    ///      collateral seized with it, so a close there is neutral to the fund whatever the
    ///      winner's own entry was. The window can outlive a recovery past that price: it
    ///      releases only once the fund could finish the remainder at the band edge, so a fund
    ///      at its reserve stays pending with the mark up to a band above it. Settling there at
    ///      the bankruptcy price would hand the winners a close better than the market at the
    ///      fund's expense, and executeAdl is permissionless with a caller-chosen winner list,
    ///      so the leg takes the mark whenever it sits on the fund's favorable side. The close
    ///      then averts no loss, and pays the executor the keeper rate alone (_closeReward).
    function _settlementPrice(Inventory memory inv, uint256 currentPrice) internal pure returns (uint256) {
        return _settlementPriceOf(inv.isLong, inv.bankruptcyNotional, inv.size, currentPrice);
    }

    /// @dev _settlementPrice on the figures alone. The average bankruptcy price rounds toward the
    ///      fund: up for long inventory, which the vault sells, and down for short inventory, which
    ///      it buys back. Closed in full at that price the inventory realizes no less than its
    ///      bankruptcy notional as a long and pays no more than it as a short, so the seizure
    ///      covers the close; rounded the other way the close would cost the fund up to a wei per
    ///      unit of size beyond it.
    function _settlementPriceOf(bool isLong, uint256 bankruptcyNotional, uint256 size, uint256 currentPrice)
        internal
        pure
        returns (uint256)
    {
        uint256 avgBankruptcyPrice = Math.mulDiv(
            bankruptcyNotional, BAZAAR_SCALE, size, isLong ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        return isLong ? Math.max(avgBankruptcyPrice, currentPrice) : Math.min(avgBankruptcyPrice, currentPrice);
    }

    /// @dev Writes a leg's bucket back after a close: the fields a proportional close moves. A
    ///      bucket closed to nothing is cleared whole, so its seizure stamp and entry index go
    ///      with it and the next estate on that side seeds a fresh one.
    function _storeInventory(BazaarTypes.Inventory storage b, Inventory memory inv) internal {
        if (inv.size == 0) {
            RiskParamsLib.clearBucket(b);
            return;
        }
        b.size = inv.size;
        b.entryNotional = inv.entryNotional;
        b.bankruptcyNotional = inv.bankruptcyNotional;
        b.seized = inv.seized;
    }

    /// @notice Sizes one close: the winner's credit at the settlement price and the vault's own
    ///         realization on the same size of inventory.
    /// @dev The winner realizes `totalPnl` at the settlement price with the live funding index
    ///      into their bucket, exactly as a maker filled by the unload walk does, and the inventory
    ///      slice settles against the liquidatees' entry through insurance. Those are different
    ///      numbers: the winner's PnL runs from the WINNER's entry, and the part between that entry
    ///      and the estate's entry was already settled by the winner's earlier counterparties, so
    ///      it is backed by the deposits ledger and never by the fund. Charging the fund the
    ///      winner's PnL instead would misstate insurance by (estate entry − winner entry) × size
    ///      on every close: a false deficit and termination when the winner entered above the
    ///      estate, a deposits ledger below the buckets when they entered below it.
    ///
    ///      A partial close takes every term pro-rata on closedSize / adjustedSize. Only funding
    ///      income may be withheld, or ROUNDING_ALLOWANCE where the funding income is smaller,
    ///      and never more than the net credit, so a winner whose price leg is negative at the
    ///      settlement price still closes at no worse than break-even.
    /// @param pairVault The pair's vault accounting
    /// @param inv The inventory the slice is released from
    /// @param free The fund's free capital available to this close
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param state The winner's bucket state at the settlement price and the live index
    /// @param closedSize The size closed, at most `state.adjustedSize`
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @return s The credit, the amount withheld from it, and the entry basis released
    function _settleSlice(
        BazaarTypes.Vault storage pairVault,
        Inventory memory inv,
        uint256 free,
        int256 currentFundingIndex,
        BazaarTypes.BucketState memory state,
        uint256 closedSize,
        uint256 settlementPrice
    ) internal returns (SliceSettlement memory s) {
        uint256 slicePnl = uint256(state.totalPnl);
        uint256 sliceFunding = state.fundingPnl > 0 ? uint256(state.fundingPnl) : 0;
        s.sliceEntry = state.entryValue;
        if (closedSize < state.adjustedSize) {
            slicePnl = Math.mulDiv(slicePnl, closedSize, state.adjustedSize);
            sliceFunding = Math.mulDiv(sliceFunding, closedSize, state.adjustedSize);
            s.sliceEntry = Math.mulDiv(s.sliceEntry, closedSize, state.adjustedSize);
        }
        uint256 withholdCap = sliceFunding > ROUNDING_ALLOWANCE ? sliceFunding : ROUNDING_ALLOWANCE;
        if (withholdCap > slicePnl) withholdCap = slicePnl;
        s.withheld =
            _settleInventorySlice(pairVault, inv, free, currentFundingIndex, closedSize, settlementPrice, withholdCap);
        s.credit = slicePnl - s.withheld;
    }

    /// @notice Values `closedSize` of inventory closed at `settlementPrice` from the liquidatees'
    ///         entry, price and funding legs, and releases the slice from the inventory.
    /// @dev The price leg runs to the closed size at the settlement price, the notional the
    ///      winner's credit is measured against; the funding leg runs from the liquidatees' entry
    ///      index to the live index, as on an unload fill. At the estates' average bankruptcy
    ///      price the two legs net to the slice's earmark plus the funding accrued while the vault
    ///      held it: the bankruptcy price is the entry basis displaced by the seized collateral and
    ///      the estate's pre-liquidation funding, so that funding enters the price leg with one
    ///      sign and the funding leg with the other, and nothing is booked twice. At a mark on the
    ///      fund's favorable side the loss shrinks by the distance, or turns into a gain. The
    ///      aggregates decrement pro rata, which leaves the remainder's average bankruptcy price
    ///      and size-weighted entry index unchanged.
    /// @param inv The inventory the slice is released from, decremented in place
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param closedSize The inventory closed against the winner
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @return vaultPnl The vault's realization on the slice, negative for a loss
    /// @return earmark The slice's share of the collateral seized alongside the inventory
    function _releaseSlice(
        Inventory memory inv,
        int256 currentFundingIndex,
        uint256 closedSize,
        uint256 settlementPrice
    ) internal pure returns (int256 vaultPnl, uint256 earmark) {
        uint256 pendingSize = inv.size;
        uint256 entryPortion = Math.mulDiv(inv.entryNotional, closedSize, pendingSize);
        uint256 bkPortion = Math.mulDiv(inv.bankruptcyNotional, closedSize, pendingSize);
        uint256 closedNotional = Math.mulDiv(closedSize, settlementPrice, BAZAAR_SCALE);
        int256 rawFunding = BazaarMathLib.signedMulDiv(
            currentFundingIndex - inv.entryFundingIndex, int256(closedSize), int256(BAZAAR_SCALE)
        );
        earmark = Math.mulDiv(inv.seized, closedSize, pendingSize);
        if (inv.isLong) {
            vaultPnl = int256(closedNotional) - int256(entryPortion) - rawFunding;
        } else {
            vaultPnl = int256(entryPortion) - int256(closedNotional) + rawFunding;
        }
        inv.size = pendingSize - closedSize;
        inv.entryNotional -= entryPortion;
        inv.bankruptcyNotional -= bkPortion;
        inv.seized -= earmark;
    }

    /// @notice Books the vault's realization on a closed inventory slice as an insurance <->
    ///         deposits-ledger transfer, and decides how much of an uncovered loss the winner
    ///         absorbs.
    /// @dev A gain is a D → I transfer, carried as the ledger's arrears where D cannot pay it; a
    ///      loss is an I → D transfer paid net of those arrears. Both leave I + D unchanged, so
    ///      the books-vs-cash health check is unmoved, and the deposits ledger keeps tracking the
    ///      buckets: the winner's credit lands in a bucket and is withdrawn from the ledger
    ///      later, so the ledger must gain exactly what the vault lost, less the cash it already
    ///      owed the fund for this inventory.
    ///
    ///      A loss is funded from the slice's own share of the seizure earmark plus the fund's
    ///      free capital, never from the earmark of inventory still open, so one close's carry
    ///      cannot consume the backing of the next and concentrate a whole batch's shortfall on
    ///      whoever the batch reaches last. It is paid from the slice's earmark first, and only
    ///      then net of the arrears and from free capital (RiskParamsLib.fundLedgerFrom). Netted
    ///      from the arrears first, the loss would leave the inventory left reading worse to the
    ///      netting gate and the ADL gate, which count the arrears in full, while the earmark
    ///      sat in free capital, which below the reserve they do not count. Because the earmark
    ///      sits in the fund by construction and the arrears net off what the earmark could not
    ///      hold, the fund can only fall short by the holding-window funding and by rounding.
    ///      What it cannot pay is withheld from the winner's credit up to `withholdCap`. The cap
    ///      is the winner's funding income: that income accrued against this inventory, so
    ///      refusing to pay what the fund cannot back keeps every remaining claim cash-backed
    ///      without touching the winner's price PnL. Anything beyond the cap is a claim with no
    ///      backing left, recorded as deficit so the post-batch health check terminates the pair
    ///      and the settlement waterfall shares it pro-rata.
    ///
    ///      Rounding is the exception to both. The slice's entry basis and earmark are pro-rata
    ///      shares rounded on their own, its notional and funding leg each round once more, and
    ///      the funding leg runs from an entry index averaged across estates, so a close at the
    ///      bankruptcy price can land a few wei past its earmark with no carry at all. That is
    ///      not a loss the fund failed to back: what a rounded share leaves one slice short, the
    ///      rest of the inventory holds over. The cap is therefore never below
    ///      ROUNDING_ALLOWANCE, so the credit absorbs it where the winner has no funding income,
    ///      and a remainder within the allowance that the credit is too small to absorb is not
    ///      recorded: a deficit of any size fixes the settlement price, and this one would
    ///      terminate a pair that is solvent to the wei over less than it can pay anyone.
    /// @param pairVault The pair's vault accounting
    /// @param inv The inventory the slice is released from
    /// @param free The fund's free capital available to this close, read before the release
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param closedSize The inventory closed against the winner
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @param withholdCap The most that may be withheld from the winner's credit: the larger of
    ///        its funding income and ROUNDING_ALLOWANCE, capped at the credit
    /// @return withheld The part of the vault's loss withheld from the winner's credit
    function _settleInventorySlice(
        BazaarTypes.Vault storage pairVault,
        Inventory memory inv,
        uint256 free,
        int256 currentFundingIndex,
        uint256 closedSize,
        uint256 settlementPrice,
        uint256 withholdCap
    ) internal returns (uint256 withheld) {
        (int256 vaultPnl, uint256 earmark) = _releaseSlice(inv, currentFundingIndex, closedSize, settlementPrice);

        if (vaultPnl >= 0) {
            RiskParamsLib.collectFromLedger(pairVault, uint256(vaultPnl));
            return 0;
        }

        uint256 shortfall = RiskParamsLib.fundLedgerFrom(pairVault, uint256(-vaultPnl), earmark, earmark + free);
        withheld = shortfall < withholdCap ? shortfall : withholdCap;
        if (shortfall - withheld > ROUNDING_ALLOWANCE) {
            pairVault.deficit += shortfall - withheld;
        }
    }

    /// @notice Takes a closed winner's position off the open-interest aggregates on its side.
    /// @param winnersLong The closed winner's side
    function _applyAdlVaultUpdate(
        BazaarTypes.Vault storage pairVault,
        bool winnersLong,
        uint256 size,
        uint256 entryValue
    ) internal {
        if (winnersLong) {
            pairVault.totalLongOI -= size;
            pairVault.longWeightedEntrySum -= entryValue;
        } else {
            pairVault.totalShortOI -= size;
            pairVault.shortWeightedEntrySum -= entryValue;
        }
    }

    /// @notice Resets a user's position bucket after full ADL close (cancels TP/SL, zeros
    ///         position fields). Cancelling is required, not hygiene: TP/SL wait outside the book
    ///         for a keeper to fire them, so a live order left behind would execute market-style
    ///         against a position that no longer exists and open a fresh one in its place.
    function _resetBucket(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        address user,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.AdlParams memory params
    ) internal {
        _cancelBucketOrder(orders, book, bucket.takeProfitOrderId, params.pairId, params.currentBlock);
        _cancelBucketOrder(orders, book, bucket.stopLossOrderId, params.pairId, params.currentBlock);

        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.entryFundingIndex = 0;
        bucket.takeProfitOrderId = 0;
        bucket.stopLossOrderId = 0;
        // Note: collateral is NOT reset (already updated by caller with PnL)

        BucketLib.emitBucketUpdate(user, bucket, params.currentFundingIndex, params.marginRequirements, params.pairId);
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
            pairId, orderId, o, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Deleveraged
        );
    }
}
