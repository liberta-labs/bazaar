// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";

/// @dev Owns a vault with both buckets, trader positions and a fee escrow, forwards into
///      LiquidationLib.processLiquidations and reads every aggregate back, so the library's
///      bookkeeping (the netting of the two buckets' overlap, the merge into a bucket, the
///      bankruptcy notional, the OI floors) can be asserted directly instead of only seeded.
contract BookkeepingHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;
    BazaarTypes.FeeEscrow internal feeEscrow;

    function setPosition(
        address user,
        bool isLong,
        uint256 size,
        uint256 entryValue,
        uint256 collateral,
        int256 entryFundingIndex
    ) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
        b.entryFundingIndex = entryFundingIndex;
    }

    function seedCollateral(uint256 amount) external {
        vault.totalCollateralDeposited = amount;
    }

    function seedInsurance(uint256 amount) external {
        vault.insuranceFundBalance = amount;
    }

    function seedOI(uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum) external {
        vault.totalLongOI = longOI;
        vault.totalShortOI = shortOI;
        vault.longWeightedEntrySum = longSum;
        vault.shortWeightedEntrySum = shortSum;
    }

    /// @dev Stage one of the vault's two buckets, with no seizure stamp.
    function setBucket(
        bool isLong,
        uint256 size,
        uint256 entryNotional,
        uint256 bankruptcyNotional,
        uint256 seized,
        int256 entryFundingIndex
    ) external {
        BazaarTypes.Inventory storage b = isLong ? vault.longInv : vault.shortInv;
        b.size = size;
        b.entryNotional = entryNotional;
        b.bankruptcyNotional = bankruptcyNotional;
        b.seized = seized;
        b.entryFundingIndex = entryFundingIndex;
        b.seizedTs = 0;
    }

    function liquidate(address[] calldata users, uint256 price, int256 fundingIndex)
        external
        returns (BazaarTypes.LiquidateResult memory)
    {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: fundingIndex,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    // read-backs
    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function depositsLedger() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function longOI() external view returns (uint256) {
        return vault.totalLongOI;
    }

    function longSum() external view returns (uint256) {
        return vault.longWeightedEntrySum;
    }

    function positionSize(address u) external view returns (uint256) {
        return positionBuckets[u].size;
    }
}

/// @notice Read-back tests for LiquidationLib's aggregate bookkeeping — the values every downstream
///         consumer (ADL settlement price, the gate's exposure, a close's PnL) depends on. Seeding
///         these values directly proves nothing about the arithmetic that produces them, so each
///         one is asserted after a real processLiquidations call.
contract LiquidationBookkeepingTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant PRICE = 50_000e18;

    BookkeepingHarness h;
    address victim = makeAddr("victim");

    function setUp() public {
        h = new BookkeepingHarness();
        vm.warp(1_700_000_000);
        h.seedCollateral(1_000_000e18);
        h.seedInsurance(5_000e18);
    }

    function _arr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    // ---------------- netting the overlap: estate smaller than the opposite bucket ----------------

    /// @notice An opposing estate smaller than the bucket it meets nets its own size: the bucket is
    ///         reduced pro rata and keeps its side, and the estate's bucket, taken whole, is cleared.
    function test_netting_partialReduce_proratesTheBucket() public {
        // Vault long 2 units, entry $50k/u, bankruptcy $48k/u, the $4k gap seized with it; the
        // $5k fund holds $1k above that earmark.
        h.setBucket(true, 2 * SCALE, 100_000e18, 96_000e18, 4_000e18, 0);
        // Opposing short 1 unit entered $49k, $10 collateral -> insolvent at $50k.
        h.setPosition(victim, false, 1 * SCALE, 49_000e18, 10e18, 0);

        h.liquidate(_arr(victim), PRICE, 0);

        BazaarTypes.Inventory memory l = h.bucket(true);
        assertEq(l.size, 1 * SCALE, "half the long bucket remains");
        assertEq(l.entryNotional, 50_000e18, "entry notional halved");
        assertEq(l.bankruptcyNotional, 48_000e18, "bankruptcy notional halved");
        assertEq(l.seized, 2_000e18, "earmark halved");
        assertEq(h.bucket(false).size, 0, "the estate's bucket was netted away whole");
        // netPnl = shortEntry(49k) - longEntryPortion(50k) = -1k; seizure +10; reward out.
        assertEq(h.claimable(address(this)), 10e18, "the reward: 2 bp of the netted unit at $50k");
        assertEq(
            h.insurance(),
            5_000e18 + 10e18 - 1_000e18 - h.claimable(address(this)),
            "net loss absorbed, collateral seized"
        );
        // The loss is an I -> D TRANSFER (backing for the survivors' offsetting realized gains),
        // net of the -10 seizure transfer in the other direction.
        assertEq(h.depositsLedger(), 1_000_000e18 - 10e18 + 1_000e18, "deposits ledger credited by the netting loss");
    }

    // ---------------- netting the overlap: estate larger than the opposite bucket ----------------

    /// @notice An opposing estate larger than the bucket it meets: the overlap is netted, which
    ///         takes the long bucket whole and clears it, and the estate's remainder stays in its
    ///         OWN bucket with its notionals prorated, the estate's ENTRY funding index (== current
    ///         here, since the victim's own funding is zeroed) and the stamp its seed took. A bucket
    ///         never changes side.
    function test_netting_estateLargerThanTheBucket_remainderStaysInItsOwnBucket() public {
        h.setBucket(true, 1 * SCALE, 50_000e18, 48_000e18, 2_000e18, 0);
        // Opposing short 3 units entered $49k/u, $10 collateral, own funding zeroed (entryIdx == current).
        int256 currentIdx = 7e18;
        h.setPosition(victim, false, 3 * SCALE, 147_000e18, 10e18, currentIdx);

        h.liquidate(_arr(victim), PRICE, currentIdx);

        BazaarTypes.Inventory memory l = h.bucket(true);
        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(l.size, 0, "the long bucket was netted away whole");
        assertEq(l.entryNotional, 0, "and cleared");
        assertEq(s.size, 2 * SCALE, "remainder after netting 1 against 1");
        // The netting takes the floor of its one-third slice off each figure, so the remainder
        // keeps the rounding.
        assertEq(
            s.entryNotional, uint256(147_000e18) - uint256(147_000e18) / 3, "remainder entry prorated from the estate"
        );
        // Victim bankruptcy notional = entry + effColl + fundingPnl = 147,010.
        assertEq(s.bankruptcyNotional, uint256(147_010e18) - uint256(147_010e18) / 3, "remainder bankruptcy prorated");
        assertEq(s.seized, uint256(10e18) - uint256(10e18) / 3, "remainder keeps its share of the seizure");
        assertEq(s.entryFundingIndex, currentIdx, "the estate's entry index seeds its bucket");
        assertEq(uint256(s.seizedTs), vm.getBlockTimestamp(), "seeded now");
        // Insurance: +10 seizure, -1,000 net entry PnL, -7 of funding on the netted unit (the long
        // bucket entered at index 0, the estate at 7), minus the liquidator's reward: 2 bp of the
        // one unit netted, not of all three.
        assertEq(h.claimable(address(this)), 10e18, "the reward: 2 bp of the netted unit at $50k");
        assertEq(
            h.insurance(),
            5_000e18 + 10e18 - 1_000e18 - 7e18 - h.claimable(address(this)),
            "netting PnL + funding realized"
        );
        // Mirror transfer into the deposits ledger (loss = 1,007), net of the -10 seizure.
        assertEq(h.depositsLedger(), 1_000_000e18 - 10e18 + 1_007e18, "deposits ledger credited by the netting loss");
    }

    // ---------------- seizure stamp: what the unload floor opens from ----------------

    /// @notice Seeding a bucket stamps the present instant.
    function test_seizedTs_seededAtTheSeizure() public {
        h.setPosition(victim, true, 1 * SCALE, 50_000e18, 10e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);
        assertEq(uint256(h.bucket(true).seizedTs), vm.getBlockTimestamp(), "stamped at the seizure");
    }

    /// @notice A same-side estate blends the stamp by size: three units seized two minutes after
    ///         one move it three quarters of the way to now.
    function test_seizedTs_sameSideJoinBlendsBySize() public {
        uint256 t0 = vm.getBlockTimestamp();
        h.setPosition(victim, true, 1 * SCALE, 50_000e18, 10e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);

        vm.warp(t0 + 120);
        address second = makeAddr("second");
        h.setPosition(second, true, 3 * SCALE, 150_000e18, 10e18, 0);
        h.liquidate(_arr(second), PRICE, 0);

        assertEq(h.bucket(true).size, 4 * SCALE, "merged");
        assertEq(uint256(h.bucket(true).seizedTs), t0 + 90, "(1 x t0 + 3 x (t0 + 120)) / 4");
    }

    /// @notice A dust estate joining a large bucket barely moves the stamp, and the blend rounds
    ///         up, so the bucket never reads older than the estates in it.
    function test_seizedTs_dustJoinBarelyMovesAndRoundsUp() public {
        uint256 t0 = vm.getBlockTimestamp();
        h.setPosition(victim, true, 100 * SCALE, 5_000_000e18, 10e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);

        vm.warp(t0 + 180);
        address dust = makeAddr("dust");
        h.setPosition(dust, true, 1 * SCALE, 50_000e18, 10e18, 0);
        h.liquidate(_arr(dust), PRICE, 0);

        // (100 x t0 + 1 x (t0 + 180)) / 101 = t0 + 1.78, rounded up.
        assertEq(uint256(h.bucket(true).seizedTs), t0 + 2, "dust moves the stamp by a rounded-up fraction");
    }

    /// @notice An opposing estate smaller than the bucket nets against it and leaves the bucket's
    ///         stamp alone: the remainder is the same inventory, no younger. The estate's own
    ///         bucket, netted away whole, is cleared with its stamp.
    function test_seizedTs_nettedBucketKeepsItsStamp() public {
        uint256 t0 = vm.getBlockTimestamp();
        h.setPosition(victim, true, 2 * SCALE, 100_000e18, 10e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);

        vm.warp(t0 + 100);
        address opp = makeAddr("opp");
        h.setPosition(opp, false, 1 * SCALE, 49_000e18, 10e18, 0);
        h.liquidate(_arr(opp), PRICE, 0);

        assertEq(h.bucket(true).size, 1 * SCALE, "netted down");
        assertEq(uint256(h.bucket(true).seizedTs), t0, "stamp untouched");
        assertEq(h.bucket(false).size, 0, "the estate's bucket was taken whole");
        assertEq(uint256(h.bucket(false).seizedTs), 0, "and cleared with its stamp");
    }

    /// @notice An opposing estate larger than the bucket nets the bucket away: the emptied bucket
    ///         is cleared whole — stamp and entry index with it — and the estate's remainder keeps
    ///         the stamp its own bucket was seeded with, now.
    function test_seizedTs_emptiedBucketIsClearedWhole_remainderKeepsItsSeedStamp() public {
        uint256 t0 = vm.getBlockTimestamp();
        h.setPosition(victim, true, 1 * SCALE, 50_000e18, 10e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);

        vm.warp(t0 + 100);
        address opp = makeAddr("opp");
        h.setPosition(opp, false, 3 * SCALE, 147_000e18, 10e18, 0);
        h.liquidate(_arr(opp), PRICE, 0);

        BazaarTypes.Inventory memory l = h.bucket(true);
        assertEq(l.size, 0, "netted away");
        assertEq(l.entryNotional, 0, "cleared: entry");
        assertEq(l.bankruptcyNotional, 0, "cleared: bankruptcy");
        assertEq(l.seized, 0, "cleared: earmark");
        assertEq(l.entryFundingIndex, 0, "cleared: funding index");
        assertEq(uint256(l.seizedTs), 0, "cleared: stamp");
        assertEq(h.bucket(false).size, 2 * SCALE, "the remainder stays in the estate's own bucket");
        assertEq(uint256(h.bucket(false).seizedTs), t0 + 100, "stamped at its seed, now");
    }

    /// @notice A bucket the fund could not net against the opposite one stands, and estates on
    ///         its side keep joining it: the blend runs on the estate's OWN bucket, and the
    ///         opposite bucket is untouched. Here the overlap would lose the $12k gap between a
    ///         $60k long and $48k shorts, against the $3k the two slices bring and no free capital.
    function test_seizedTs_ownBucketJoinWhileTheOppositeStands_blendsBySize() public {
        h.setBucket(true, 1 * SCALE, 60_000e18, 58_000e18, 2_000e18, 0);
        h.seedInsurance(2_000e18); // the earmark alone: nothing above it to pay a netting's loss
        uint256 t0 = vm.getBlockTimestamp();
        h.setPosition(victim, false, 1 * SCALE, 48_000e18, 1_000e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);
        assertEq(uint256(h.bucket(false).seizedTs), t0, "the short bucket seeded now");

        vm.warp(t0 + 120);
        address second = makeAddr("second");
        h.setPosition(second, false, 3 * SCALE, 144_000e18, 1_000e18, 0);
        h.liquidate(_arr(second), PRICE, 0);

        assertEq(h.bucket(false).size, 4 * SCALE, "merged into the short bucket");
        assertEq(uint256(h.bucket(false).seizedTs), t0 + 90, "(1 x t0 + 3 x (t0 + 120)) / 4");
        BazaarTypes.Inventory memory l = h.bucket(true);
        assertEq(l.size, 1 * SCALE, "the long bucket stands");
        assertEq(l.entryNotional, 60_000e18, "untouched");
        assertEq(uint256(l.seizedTs), 0, "its stamp is its own");
    }

    // ---------------- same-side merge: weighted funding index ----------------

    /// @notice A same-side merge takes the size-weighted average of the funding indices.
    function test_merge_sameSide_weightedFundingIndex() public {
        h.setBucket(true, 1 * SCALE, 50_000e18, 48_000e18, 2_000e18, 0);
        int256 currentIdx = 100e18;
        // Second underwater long, own funding zeroed.
        h.setPosition(victim, true, 1 * SCALE, 55_000e18, 10e18, currentIdx);

        h.liquidate(_arr(victim), PRICE, currentIdx);

        BazaarTypes.Inventory memory l = h.bucket(true);
        assertEq(l.size, 2 * SCALE, "sizes added");
        assertEq(l.entryFundingIndex, 50e18, "size-weighted merge (0x1 + 100x1)/2");
        assertEq(l.entryNotional, 105_000e18, "entry notionals added");
        // Victim bankruptcy = 55,000 - 10 (collateral) - 0 (funding) = 54,990.
        assertEq(l.bankruptcyNotional, 48_000e18 + 54_990e18, "bankruptcy notionals added");
        assertEq(l.seized, 2_010e18, "earmarks added");
    }

    /// @notice The weighted merge preserves sign with negative funding indices.
    function test_merge_sameSide_negativeFundingIndex() public {
        h.setBucket(true, 1 * SCALE, 50_000e18, 48_000e18, 2_000e18, 0);
        int256 currentIdx = -100e18;
        h.setPosition(victim, true, 1 * SCALE, 55_000e18, 10e18, currentIdx);

        h.liquidate(_arr(victim), PRICE, currentIdx);
        assertEq(h.bucket(true).entryFundingIndex, -50e18, "signed weighted merge");
    }

    /// @notice The weighted merge runs on the estate's OWN bucket while the opposite one stands:
    ///         a second short joins the short bucket's index, and the long bucket's index is
    ///         untouched. The overlap stays unnetted, its $12k gap past the $3k of backing.
    function test_merge_ownBucketWhileTheOppositeStands_weightedFundingIndex() public {
        h.setBucket(true, 1 * SCALE, 60_000e18, 58_000e18, 2_000e18, 0);
        h.seedInsurance(2_000e18);
        h.setPosition(victim, false, 1 * SCALE, 48_000e18, 1_000e18, 0);
        h.liquidate(_arr(victim), PRICE, 0);

        int256 currentIdx = 100e18;
        address second = makeAddr("second");
        // Entered at the live index: no funding of its own, so the merge alone moves the index.
        h.setPosition(second, false, 1 * SCALE, 48_000e18, 1_000e18, currentIdx);
        h.liquidate(_arr(second), PRICE, currentIdx);

        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.size, 2 * SCALE, "merged into the short bucket");
        assertEq(s.entryFundingIndex, 50e18, "size-weighted merge (0x1 + 100x1)/2 on the short bucket");
        assertEq(s.entryNotional, 96_000e18, "entry notionals added");
        assertEq(s.bankruptcyNotional, 98_000e18, "bankruptcy notionals added: 49,000 each");
        assertEq(h.bucket(true).size, 1 * SCALE, "the long bucket stands");
        assertEq(h.bucket(true).entryFundingIndex, 0, "its index untouched");
    }

    // ---------------- bankruptcy price read-back ----------------

    /// @notice Long bankruptcy notional = entryValue - collateral - fundingPnl, read back after a
    ///         real liquidation, so the subtraction is under test rather than a seeded value.
    function test_bankruptcy_long_entryMinusCollateral() public {
        // entry $50,500, collateral $600: equity 100 < minRequired (1.5% of 50k = 750) -> insolvent.
        h.setPosition(victim, true, 1 * SCALE, 50_500e18, 600e18, 0);

        h.liquidate(_arr(victim), PRICE, 0);

        BazaarTypes.Inventory memory l = h.bucket(true);
        assertEq(l.bankruptcyNotional, 49_900e18, "bk = entry - seized collateral");
        assertEq(l.size, 1 * SCALE);
        assertEq(l.seized, 600e18, "the collateral is the earmark");
        assertEq(h.bucket(false).size, 0, "a long estate seeds the long bucket only");
        assertEq(h.insurance(), 5_000e18 + 600e18 - h.claimable(address(this)), "full collateral seized to insurance");
    }

    /// @notice The funding term enters the long bankruptcy formula with a negative sign.
    function test_bankruptcy_long_includesFundingTerm() public {
        // Funding rose 50 (long pays): fundingPnl = -50 -> bk = 50,500 - 600 - (-50) = 49,950.
        h.setPosition(victim, true, 1 * SCALE, 50_500e18, 600e18, 0);
        h.liquidate(_arr(victim), PRICE, 50e18);
        assertEq(h.bucket(true).bankruptcyNotional, 49_950e18, "funding folds into the bankruptcy notional");
    }

    /// @notice A non-positive short numerator clamps the bankruptcy price to zero instead of
    ///         underflowing.
    function test_bankruptcy_short_numeratorClampsAtZero() public {
        // Short entered at $100 with funding pnl -200: numerator = 100 + 0 + (-200) <= 0 -> bk 0.
        h.setPosition(victim, false, 1 * SCALE, 100e18, 0, 200e18);
        h.liquidate(_arr(victim), PRICE, 0);
        assertEq(h.bucket(false).bankruptcyNotional, 0, "clamped to zero");
        assertEq(h.bucket(false).size, 1 * SCALE, "position still inherited, on its own side");
    }

    // ---------------- victim filtering ----------------

    /// @notice Solvent and flat users in a liquidation batch are skipped untouched.
    function test_batch_skipsSolventAndFlatVictims() public {
        address solvent = makeAddr("solvent");
        address flat = makeAddr("flat");
        h.setPosition(solvent, true, 1 * SCALE, 50_000e18, 5_000e18, 0); // equity 5k >= 750
        h.setPosition(victim, true, 1 * SCALE, 50_500e18, 600e18, 0); // insolvent

        address[] memory users = new address[](3);
        users[0] = solvent;
        users[1] = victim;
        users[2] = flat;
        BazaarTypes.LiquidateResult memory r = h.liquidate(users, PRICE, 0);

        assertEq(r.liquidatedCount, 1, "only the insolvent victim liquidated");
        assertEq(h.positionSize(solvent), 1 * SCALE, "solvent position untouched");
        assertEq(h.positionSize(victim), 0, "insolvent position reset");
    }

    /// @notice A zero-collateral insolvent victim still liquidates: nothing seized, and the
    ///         unconditional flat liquidator reward accrues, funded by insurance alone.
    function test_zeroCollateralVictim_liquidatesWithFlatReward() public {
        h.setPosition(victim, true, 1 * SCALE, 55_000e18, 0, 0);

        uint256 insBefore = h.insurance();
        BazaarTypes.LiquidateResult memory r = h.liquidate(_arr(victim), PRICE, 0);

        assertEq(r.liquidatedCount, 1);
        uint256 expected = BazaarTypes.MIN_LIQUIDATOR_REWARD;
        assertEq(r.unloadPrepaid, expected, "nothing netted: the walk is credited with the whole flat reward");
        assertEq(h.insurance(), insBefore - expected, "nothing to seize; only the reward leaves the fund");
        assertEq(h.claimable(address(this)), expected, "reward accrued to the liquidator");
    }

    // ---------------- OI decrement floors ----------------

    /// @notice OI decrements floor at zero when the aggregate under-counts the victim's size —
    ///         drift is masked rather than reverting the liquidation.
    function test_oiDecrement_floorsAtZeroInsteadOfUnderflowing() public {
        h.seedOI(SCALE / 2, 0, 1_000e18, 0); // long OI smaller than the victim's 1e18
        h.setPosition(victim, true, 1 * SCALE, 55_000e18, 10e18, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(_arr(victim), PRICE, 0);

        assertEq(r.liquidatedCount, 1, "liquidation not blocked by OI drift");
        assertEq(h.longOI(), 0, "floored, not underflowed");
        assertEq(h.longSum(), 0, "weighted sum floored");
    }
}
