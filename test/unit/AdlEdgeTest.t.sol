// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @dev Holds a vault with its two buckets, a book of positions and the fee escrow, and forwards
///      to AdlLib.executeAdlCore and LiquidationLib.processLiquidations the way BazaarPair does.
contract AdlEdgeHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.FeeEscrow internal feeEscrow;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;

    // -------- positions --------

    function setPosition(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
    }

    /// @dev The funding index a position entered at; one at the live index carries no funding of
    ///      its own.
    function setPositionFundingIndex(address user, int256 idx) external {
        positionBuckets[user].entryFundingIndex = idx;
    }

    function positionSize(address u) external view returns (uint256) {
        return positionBuckets[u].size;
    }

    function positionEntry(address u) external view returns (uint256) {
        return positionBuckets[u].entryValue;
    }

    function positionCollateral(address u) external view returns (uint256) {
        return positionBuckets[u].collateral;
    }

    // -------- the vault's two buckets --------

    /// @dev Stage one bucket whole. The seizure stamp stays 0, which the unload walk reads as
    ///      fully aged and the batch never reads.
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
        b.entryFundingIndex = int192(entryFundingIndex);
        b.seizedTs = 0;
    }

    function clearBucket(bool isLong) external {
        RiskParamsLib.clearBucket(isLong ? vault.longInv : vault.shortInv);
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    function bucketSize(bool isLong) external view returns (uint256) {
        return isLong ? vault.longInv.size : vault.shortInv.size;
    }

    function inventorySize() external view returns (uint256) {
        return RiskParamsLib.inventorySize(vault);
    }

    // -------- vault scalars --------

    /// @dev What the deposits ledger owes the fund: collections it could not pay.
    function setLedgerArrears(uint256 x) external {
        vault.ledgerArrears = x;
    }

    function arrears() external view returns (uint256) {
        return vault.ledgerArrears;
    }

    /// @dev The trailing minimum of per-side open interest the reserve is sized on; live open
    ///      interest above it closes without releasing any reserve.
    function setTrailingOi(uint128 x) external {
        vault.trailingOiSize = x;
    }

    /// @dev The insurance target ratio the pair would have cached: the reserve the ADL gate and
    ///      the batch sizing net out of the fund is derived from it.
    function setTargetRatio(uint256 bp) external {
        vault.targetInsuranceRatioBp = bp;
    }

    function setVaultInsurance(uint256 x) external {
        vault.insuranceFundBalance = x;
    }

    function setVaultCollateral(uint256 x) external {
        vault.totalCollateralDeposited = x;
    }

    function setOI(uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum) external {
        vault.totalLongOI = longOI;
        vault.totalShortOI = shortOI;
        vault.longWeightedEntrySum = longSum;
        vault.shortWeightedEntrySum = shortSum;
    }

    /// @dev A deficit already on the books. BazaarPair.executeAdl's entry health check sends a pair
    ///      that carries one to termination before any batch runs, so only a direct call reaches
    ///      the batch with it.
    function setDeficit(uint256 x) external {
        vault.deficit = x;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function vaultCollateral() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function shortOI() external view returns (uint256) {
        return vault.totalShortOI;
    }

    function longOI() external view returns (uint256) {
        return vault.totalLongOI;
    }

    function shortSum() external view returns (uint256) {
        return vault.shortWeightedEntrySum;
    }

    function longSum() external view returns (uint256) {
        return vault.longWeightedEntrySum;
    }

    // -------- ADL window-deposit state (epoch-tagged score freeze) --------

    uint64 public adlEpoch;
    mapping(address => uint64) internal adlDepositEpoch;
    mapping(address => uint256) internal adlWindowDeposits;

    function setAdlEpoch(uint64 e) external {
        adlEpoch = e;
    }

    function setWindowDeposit(address user, uint64 epoch, uint256 amount) external {
        adlDepositEpoch[user] = epoch;
        adlWindowDeposits[user] = amount;
    }

    // -------- the batch and the liquidation path --------

    /// @dev One ADL batch: `longBucketWinners` are the shorts submitted to close the long bucket,
    ///      `shortBucketWinners` the longs submitted to close the short bucket.
    function execAdl(
        address[] calldata longBucketWinners,
        address[] calldata shortBucketWinners,
        BazaarTypes.AdlParams calldata params
    ) external returns (BazaarTypes.AdlResult memory) {
        return AdlLib.executeAdlCore(
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            longBucketWinners,
            shortBucketWinners,
            params,
            adlEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );
    }

    /// @dev liquidate()'s seizure path on the staged book: the seizure into the estate's own
    ///      bucket and the netting of the two buckets' overlap where the fund can afford it.
    /// @param user The account to liquidate
    /// @param price The liquidation price
    /// @param fundingIndex The live funding index
    /// @return The accounts seized and the walk's credit
    function liquidate(address user, uint256 price, int256 fundingIndex)
        external
        returns (BazaarTypes.LiquidateResult memory)
    {
        address[] memory users = new address[](1);
        users[0] = user;
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
                marginReqs: BazaarTypes.MarginRequirements({
                    imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
                }),
                pairId: bytes32(uint256(0xADE)),
                currentBlock: uint64(block.number)
            })
        );
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    // -------- readings --------

    /// @dev The ADL gate's figures for the staged vault, so a test can check the release
    ///      condition a batch is sized to.
    function exposure(uint256 price, int256 fundingIndex, uint256 mmrBp)
        external
        view
        returns (uint256 expectedLoss, uint256 base, uint256 worstFinish, uint256 shortfall)
    {
        return RiskParamsLib.vaultAdlExposure(vault, price, fundingIndex, mmrBp);
    }

    /// @dev The two buckets' overlap and what netting it realizes for the fund.
    function overlap() external view returns (uint256 o, int256 pnl, uint256 seized) {
        return RiskParamsLib.overlap(vault);
    }

    /// @dev The netting gate on the two buckets as they stand.
    function overlapAffordable(uint256 price, int256 fundingIndex) external view returns (bool) {
        return RiskParamsLib.overlapAffordable(vault, price, fundingIndex);
    }

    /// @dev What the fund holds for closing the inventory at the estates' bankruptcy prices, as
    ///      the netting gate reads it — free capital above the reserve plus the arrears — and
    ///      what those closes need beyond the buckets' earmarks, both buckets together.
    function survivorBacking(uint256 price, int256 fundingIndex)
        external
        view
        returns (uint256 backing, uint256 needed)
    {
        uint256 free = RiskParamsLib.insuranceFreeCapital(vault);
        uint256 reserve = RiskParamsLib.adlReserve(vault, price);
        backing = (free > reserve ? free - reserve : 0) + vault.ledgerArrears;
        needed = RiskParamsLib.bucketBankruptcyCloseCost(vault.longInv, true, fundingIndex)
            + RiskParamsLib.bucketBankruptcyCloseCost(vault.shortInv, false, fundingIndex);
    }

    /// @dev The fund's balance less both buckets' earmarks.
    function freeCapital() external view returns (uint256) {
        return RiskParamsLib.insuranceFreeCapital(vault);
    }
}

/// @notice AdlLib and the bucket netting at the edges: the partial close of an oversized winner,
///         the batch cap, on-chain ranking and sorting, the window-deposit tag, settlement at the
///         mark, the executor's reward, the losing leg closed by its own cohort at its bankruptcy
///         price, the pairs rule, the fallback that nets through the fund, the end-of-batch
///         netting, the netting gate and the bookkeeping of earmarks and arrears, and the guards.
contract AdlEdgeTest is Test {
    uint256 constant SCALE = 1e18;
    /// @dev AdlLib.ROUNDING_ALLOWANCE: one unit of USDC precision, added to every sizing so the
    ///      pro-rata shares each slice rounds on its own cannot leave the release a few wei short.
    uint256 constant ALLOWANCE = 1e12;
    /// @dev How far, in wei, the netting gate's pro-rata figures, read before a netting, can sit
    ///      from the payment's, read once the netting has reduced the aggregate.
    uint256 constant NETTING_ROUNDING = 100;
    AdlEdgeHarness h;
    address winner = makeAddr("winner");
    address loser = makeAddr("loser");
    address loser2 = makeAddr("loser2");
    address ally = makeAddr("ally");
    address ally2 = makeAddr("ally2");

    function setUp() public {
        h = new AdlEdgeHarness();
        vm.warp(1_700_000_000);
        h.setVaultInsurance(1_000e18);
        h.setVaultCollateral(1_000e18);
    }

    /// @dev Batch parameters at `mark`, the auction `elapsedMinutes` into its decay. Both legs
    ///      rank and settle against this mark and a live index of 0.
    function _params(uint256 mark, uint256 elapsedMinutes) internal view returns (BazaarTypes.AdlParams memory) {
        return BazaarTypes.AdlParams({
            adlAuctionStartTs: block.timestamp - elapsedMinutes * 1 minutes,
            currentPrice: mark,
            currentFundingIndex: 0,
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });
    }

    /// @dev Batch parameters at `mark` with the Dutch threshold collapsed to 1 (the auction past
    ///      ADL_AUCTION_DURATION), so every winner in profit is eligible.
    function _at(uint256 mark) internal view returns (BazaarTypes.AdlParams memory) {
        return _params(mark, 15);
    }

    /// @dev The same with the live funding index at `idx`.
    function _atIndex(uint256 mark, int256 idx) internal view returns (BazaarTypes.AdlParams memory p) {
        p = _at(mark);
        p.currentFundingIndex = idx;
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _none() internal pure returns (address[] memory out) {
        out = new address[](0);
    }

    /// @dev The keeper rate, 2 bp, on `size` valued at `price`: what a leg pays its executor for a
    ///      close that averts no more than a fifth of its notional, and what a netting pays.
    function _rate(uint256 size, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(size, price, SCALE), 2, 10_000);
    }

    /// @dev ADL_EXECUTOR_REWARD_BP of the bad debt a close of `size` averts between `mark` and
    ///      `settlement`.
    function _share(uint256 size, uint256 mark, uint256 settlement) internal pure returns (uint256) {
        uint256 gap = settlement > mark ? settlement - mark : mark - settlement;
        return Math.mulDiv(Math.mulDiv(size, gap, SCALE), 10, 10_000);
    }

    // ---------------- logs ----------------

    bytes32 internal constant USER_ADLD_SIG =
        keccak256("UserAdld(bytes32,address,bool,uint256,int256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ADL_EXECUTED_SIG =
        keccak256("AdlExecuted(bytes32,uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)");

    /// @dev One UserAdld the harness emitted: whose close it was, the winner's side, its size and
    ///      its price.
    struct LoggedClose {
        address user;
        bool isLong;
        uint256 size;
        uint256 price;
    }

    /// @dev The one AdlExecuted a batch emits.
    struct LoggedBatch {
        uint256 longClosed;
        uint256 longPrice;
        uint256 shortClosed;
        uint256 shortPrice;
        uint256 netted;
    }

    /// @dev Every UserAdld in `logs`, in emission order.
    function _loggedCloses(Vm.Log[] memory logs) internal view returns (LoggedClose[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(h) && logs[i].topics[0] == USER_ADLD_SIG) n++;
        }
        out = new LoggedClose[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != USER_ADLD_SIG) continue;
            (bool isLong, uint256 size,,,, uint256 price,) =
                abi.decode(logs[i].data, (bool, uint256, int256, uint256, uint256, uint256, uint256));
            out[n++] = LoggedClose(address(uint160(uint256(logs[i].topics[2]))), isLong, size, price);
        }
    }

    /// @dev The figures AdlExecuted reported.
    function _loggedBatch(Vm.Log[] memory logs) internal view returns (LoggedBatch memory b) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != ADL_EXECUTED_SIG) continue;
            (b.longClosed, b.longPrice, b.shortClosed, b.shortPrice, b.netted,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            return b;
        }
        revert("no AdlExecuted");
    }

    // ---------------- partial close of an oversized winner ----------------

    /// @notice A winner larger than the bucket is PARTIALLY closed: pro-rata entry reduction,
    ///         realized PnL credited to collateral, position left open, and insurance and the
    ///         deposits ledger untouched when the inventory closes at its own basis.
    function test_partialClose_oversizedWinner_proRataAndConserved() public {
        // Long bucket 1 unit at bankruptcy $100/u -> settlement price $100 at the $90 mark.
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        // Short winner, 2 units entered at $150/u, $10 collateral; +$120 PnL at the mark.
        h.setPosition(winner, false, 2 * SCALE, 300 * SCALE, 10 * SCALE);
        h.setOI(0, 2 * SCALE, 0, 300 * SCALE);
        // An empty fund can finish nothing inside the band, so the batch is required to close
        // the whole bucket and the winner's size is what makes the close partial.
        h.setVaultInsurance(0);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.settlementPrice, 100 * SCALE, "settlement = bankruptcy notional / size");
        assertEq(r.longBucket.closedSize, 1 * SCALE, "only the bucket's size closed");
        assertEq(h.positionSize(winner), 1 * SCALE, "half the position remains open");
        assertEq(h.positionEntry(winner), 150 * SCALE, "entry reduced pro-rata");
        // Realized PnL on the closed half at the $100 settlement: 50, credited on top of raw
        // collateral 10.
        assertEq(h.positionCollateral(winner), 60 * SCALE, "collateral += realized partial PnL");
        // Entry and bankruptcy notional coincide (nothing was seized) and no funding accrued, so
        // the inventory slice realizes zero: the credit is backed by the ledger, not the fund.
        // The untouched deposits ledger is what proves it — a credit charged to the fund would
        // move it by the $50 the winner was paid. An empty fund pays no reward.
        assertEq(h.insurance(), 0, "inventory closed at its own basis: insurance untouched");
        assertEq(h.vaultCollateral(), 1_000e18, "no vault realization: deposits ledger untouched");
        assertEq(h.bucketSize(true), 0, "vault exposure cleared");
        assertEq(h.shortOI(), 1 * SCALE, "closed half removed from OI");
        assertEq(h.shortSum(), 150 * SCALE, "closed entry removed from weighted sum");
    }

    // ---------------- batch cap: only the size that restores the fund is closed ----------------

    /// @dev 1000 units of inherited long inventory: the estates entered at $100 and went bankrupt
    ///      at $90, so the fund holds $10/unit of seized collateral, and the mark is $80. One
    ///      short winner entered at $150 covers the entire bucket on their own.
    function _oversizedWinnerOnDeepInventory() internal {
        h.setBucket(true, 1000 * SCALE, 100_000 * SCALE, 90_000 * SCALE, 10_000 * SCALE, 0); // settlement $90
        h.setVaultCollateral(1_000_000e18);
        h.setPosition(winner, false, 1000 * SCALE, 150_000 * SCALE, 1_000 * SCALE);
        h.setOI(0, 1000 * SCALE, 0, 150_000 * SCALE);
    }

    /// @notice A winner large enough to cover the whole bucket is closed only for the size the
    ///         exposure requires. Finishing the 1000 units at the band edge ($76, the $80 mark
    ///         less the 5% band) would cost $14,000 against $12,000 of free capital, so the batch
    ///         must close $2,000 of that; each unit closed removes $14 of it and pays the executor
    ///         $0.016 of it back — 2 bp of the $80 mark, more than 0.1% of the $10 the close
    ///         averts — leaving 143 units to close and 857 with the winner. Bounding by winner
    ///         count instead would settle all 1000 at the estates' bankruptcy price and pay the
    ///         executor for every one.
    function test_batchCap_flatFunding_closesOnlyWhatTheExposureRequires() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18); // free capital = 22,000 − 10,000 seized

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(80 * SCALE));

        assertApproxEqRel(r.longBucket.closedSize, 143.0206e18, 0.0001e18, "2,000 excess / 13.984 per unit");
        assertEq(h.positionSize(winner), 1000 * SCALE - r.longBucket.closedSize, "the rest stays with the winner");
        assertEq(h.bucketSize(true), 1000 * SCALE - r.longBucket.closedSize, "and the matching inventory stays open");
    }

    /// @notice Every unit closed leaves both sides of the book, so the reserve on it returns to the
    ///         base as the batch runs and the batch needs fewer units than the finish cost alone
    ///         implies. With a 5% target the reserve is $0.40 per unit of open interest here:
    ///         $400 on the 1000-unit book, so the base is $11,600 rather than $12,000, and each
    ///         unit closed repairs $14.384 rather than $13.984 — 167 units instead of 172.
    function test_batchCap_reserveReleasedByTheCloseShortensTheBatch() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18); // free capital = 12,000
        h.setTargetRatio(500); // 5% of the $80,000 book → reserve $400

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(80 * SCALE));

        assertApproxEqRel(r.longBucket.closedSize, 166.8521e18, 0.0001e18, "2,400 excess / 14.384 per unit");
        assertLt(r.longBucket.closedSize, 172 * SCALE, "sizing without the released reserve would close 172");
    }

    /// @notice Right at the release boundary almost nothing needs closing. Free capital of $13,999
    ///         sits $1 under the $14,000 it would take to finish at the band edge, so seven
    ///         hundredths of a unit restores the fund — while the same winner, unbounded, would
    ///         have been settled for all 1000.
    function test_batchCap_atTheBoundary_closesAlmostNothing() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(23_999e18); // free capital = 13,999 -> $1 short of the band edge

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(80 * SCALE));

        assertApproxEqRel(r.longBucket.closedSize, 0.07151e18, 0.01e18, "$1 excess / 13.984 per unit");
        assertLt(r.longBucket.closedSize, 10 * SCALE, "a boundary breach does not deleverage the book");
    }

    /// @notice The funding the vault owes on the inventory it holds is part of the cap. It leaves
    ///         the fund as each unit settles, so the base descends with it and the batch has to
    ///         close further than the finish cost alone implies: 214 units here, where sizing
    ///         against the finish cost alone would stop at 200 and leave the auction pending.
    function test_batchCap_carryPushesTheCloseFurther() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18);

        // Index +1: the vault's long inventory owes $1/unit, $1,000 across the bucket.
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _atIndex(80 * SCALE, int256(1 * SCALE)));

        assertApproxEqRel(r.longBucket.closedSize, 214.5309e18, 0.0001e18, "3,000 excess / 13.984 per unit");
        assertGt(r.longBucket.closedSize, 200 * SCALE, "sizing against the finish cost alone would stop at 200");
    }

    /// @notice When the figure exceeds the inventory the cap does not bind: the batch runs to its
    ///         eligible size. Long bucket 100 units marked $10 ABOVE the bankruptcy price but owing
    ///         $20/unit of funding, with $100 in the fund against a $1,550 band-edge finish cost:
    ///         each unit closed at the $110 mark frees $5.478 ($15.50 of finish cost less the $10
    ///         it costs past the earmark and the executor's 2 bp of $110), so 265 would be needed.
    ///         The $2,000 of funding the slices owe is $900 more than the fund and the $1,000 price
    ///         gain can pay, and that part is withheld from the winner's own $2,000 of funding
    ///         income rather than booked as deficit.
    function test_batchCap_figureBeyondTheInventory_closesTheEligibleSize() public {
        h.setBucket(true, 100 * SCALE, 10_000 * SCALE, 10_000 * SCALE, 0, 0); // settlement price = $100, nothing seized
        h.setVaultInsurance(100e18);
        h.setPosition(winner, false, 100 * SCALE, 15_000 * SCALE, 100 * SCALE);
        h.setOI(0, 100 * SCALE, 0, 15_000 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _atIndex(110 * SCALE, int256(20 * SCALE)));

        assertEq(r.longBucket.closedSize, 100 * SCALE, "the whole eligible size closes");
        assertEq(h.bucketSize(true), 0, "vault exposure cleared");
        assertEq(h.insurance(), 0, "the fund paid all it had toward the funding the slices owed");
        // $4,000 of price PnL and $2,000 of funding income, less the $900 the fund could not back.
        assertEq(h.positionCollateral(winner), 5_200e18, "the unbacked part is withheld from the funding income");
        assertEq(h.deficit(), 0, "and never recorded as deficit");
    }

    /// @dev Long 10 @ $100 against $200 seized, the estates having paid $5 a unit of funding
    ///      before liquidation: bankrupt at $85. Mark $80, band edge $76, $40 in the fund above
    ///      the earmark, no reserve; one short winner, 10 @ $110.
    function _paidFundingSetup() internal {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 850 * SCALE, 200 * SCALE, 0);
        h.setVaultInsurance(240e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
    }

    /// @notice The funding the estates paid before liquidation is inside the bankruptcy price, so
    ///         a close there costs the fund nothing past the earmark: the batch closes the 5.57
    ///         units that put the fund on the release line — the $90 band-edge finish cost less
    ///         its $40, plus the rounding allowance, over the $8.984 a unit a close at $85 frees
    ///         ($9 of finish cost less the executor's 2 bp of the $80 mark, more than 0.1% of the
    ///         $5 averted) — and no more.
    function test_batchCap_paidPreLiquidationFunding_landsOnTheLine() public {
        _paidFundingSetup();
        int256 idx = int256(5 * SCALE);
        uint256 expected = Math.mulDiv(50.000001e18, 10 * SCALE, 89.84e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _atIndex(80 * SCALE, idx));

        assertEq(r.longBucket.settlementPrice, 85 * SCALE, "the bankruptcy price");
        assertEq(r.longBucket.closedSize, expected, "5.57 units");
        (, uint256 base, uint256 worstFinish,) = h.exposure(80 * SCALE, idx, 1_000);
        assertLe(worstFinish, base, "on the release line");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        // $20 a unit paid at $85, all of it earmark: free capital moves only by the executor's
        // reward.
        assertEq(h.claimable(address(this)), _rate(expected, 80 * SCALE), "2 bp of the close at the mark");
        assertApproxEqAbs(
            h.insurance(),
            240e18 - Math.mulDiv(expected, 20e18, SCALE) - h.claimable(address(this)),
            1e3,
            "the fund paid nothing past the earmark"
        );
    }

    /// @notice The mirror with the funding received: $5 a unit the estates took before liquidation
    ///         lowers the bankruptcy price to $75 and is no gain on the close. At the $70 mark the
    ///         batch closes the 5.30 units that put the fund on the release line — the $85 finish
    ///         cost less its $40, plus the allowance, over $8.486 a unit, the executor taking 2 bp
    ///         of the $70 mark — in one batch.
    function test_batchCap_receivedPreLiquidationFunding_landsOnTheLine() public {
        _paidFundingSetup();
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 750 * SCALE, 200 * SCALE, 0);
        int256 idx = -int256(5 * SCALE);
        uint256 expected = Math.mulDiv(45.000001e18, 10 * SCALE, 84.86e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _atIndex(70 * SCALE, idx));

        assertEq(r.longBucket.settlementPrice, 75 * SCALE, "the bankruptcy price");
        assertEq(r.longBucket.closedSize, expected, "5.30 units");
        (, uint256 base, uint256 worstFinish,) = h.exposure(70 * SCALE, idx, 1_000);
        assertLe(worstFinish, base, "on the release line");
        assertEq(h.deficit(), 0, "nothing went unpaid");
    }

    /// @notice Arrears left behind by earlier inventory are a receivable a close reaches only
    ///         once its own earmark is spent, not backing that shrinks with the inventory. Long 10
    ///         @ $100 against $150 seized, bankrupt at $85, with $20 of such arrears: at the $80
    ///         mark the batch closes the 3.34 units that put the fund on the release line — the
    ///         $90 finish cost less the fund's $40 and the $20, plus the allowance, over $8.984 a
    ///         unit — and the arrears stay, since each unit's $15 loss at $85 is exactly its
    ///         earmark.
    function test_batchCap_leftoverArrears_landsOnTheLine() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 850 * SCALE, 150 * SCALE, 0);
        h.setLedgerArrears(20e18);
        h.setVaultInsurance(190e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
        uint256 expected = Math.mulDiv(30.000001e18, 10 * SCALE, 89.84e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(80 * SCALE));

        assertEq(r.longBucket.closedSize, expected, "3.34 units");
        assertEq(h.arrears(), 20e18, "the close's own earmark covered it: the arrears stay owed");
        (, uint256 base, uint256 worstFinish,) = h.exposure(80 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "on the release line");
        // $15 a unit paid at $85, all of it in cash from the closed units' earmark.
        assertApproxEqAbs(
            h.insurance(),
            190e18 - Math.mulDiv(expected, 15e18, SCALE) - h.claimable(address(this)),
            1e3,
            "the earmark paid the whole close"
        );
    }

    // ---------------- funding: vault leg settles once, winner tab rides in the credit ----------------

    /// @notice The inventory's funding is the vault's own leg, settled into insurance from the
    ///         liquidatees' entry index to the live index. The winner's tab is part of the
    ///         winner's credit and is backed by the deposits ledger like the rest of it, so the
    ///         fund moves by the vault's leg alone, not by the winner's PnL.
    function test_adlClose_vaultFundingLegSettlesOnce_winnerTabInCredit() public {
        // Long bucket 2 units at bankruptcy $100/u; liquidatee's entry funding index 0. The winner
        // covers one of them, so the close is sized by the winner rather than by the batch cap.
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        // Short winner, 1 unit entered at $150/u, $10 collateral, entry funding index 0.
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        // The $4 fund is the whole exposure here: nothing was seized, so the only loss the vault
        // carries is the $4 of funding its 2 units owe at the live index.
        h.setVaultInsurance(4e18);

        // Index delta +2: shorts are owed $2/unit; the vault's long inventory is the payer.
        h.execAdl(_one(winner), _none(), _atIndex(100 * SCALE, int256(2 * SCALE)));

        // Winner credit: price PnL (150−100) + own funding receivable (+2) = $52, in full. The
        // vault's leg on the slice is the $2 the long inventory owed (entry and bankruptcy
        // notional coincide, so the price leg is zero): that is the only settlement entry, and
        // the executor's 2 bp of the unit at the $100 mark the only other.
        assertEq(h.positionCollateral(winner), 62 * SCALE, "winner paid totalPnl incl. funding");
        assertEq(h.insurance(), 4e18 - 2e18 - 0.02e18, "insurance settles the vault's funding leg once");
        assertEq(h.vaultCollateral(), 1_000e18 + 2e18, "deposits ledger mirrors the single I->D transfer");
        assertEq(h.bucketSize(true), 1 * SCALE, "the unit the winner could not cover stays open");
    }

    /// @notice Pre-liquidation funding is not booked twice. The estate had received $2 of
    ///         funding by liquidation, which the bankruptcy price embeds (bk = 100 − 10 − 2 =
    ///         88), and the index moved a further $1 in the vault's favor while it held the
    ///         inventory. The vault's leg runs from the estate's ENTRY: price 88 − 100 = −12,
    ///         funding +3, net −$9. The $2 enters the price leg with one sign and the funding
    ///         leg with the other, leaving the $10 seizure less the $1 window receivable. The
    ///         winner (entered at the same price and index) is credited price(100 − 88) + own
    ///         tab(−3) = $9, so both sides agree and insurance nets +$1 against its seizure.
    function test_adlClose_preAndWindowFunding_noDoubleCount() public {
        // Estate: two such longs, each entry $100, collateral $10, $2 received by liquidation →
        // bk $88/u, $24 seized. The winner covers one, so the close is sized by the winner, not
        // the batch cap.
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 176 * SCALE, 24 * SCALE, 0);
        // Winner: short 1 unit, entry $100, $5 collateral, entry funding index 0.
        h.setPosition(winner, false, 1 * SCALE, 100 * SCALE, 5 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 100 * SCALE);
        // The fund holds exactly the $24 it seized off the two estates and nothing beyond it, so
        // there is no free capital and the batch cap does not bind before the winner's size does.
        h.setVaultInsurance(24e18);

        // Index fell 3 since entry (−2 before liquidation, −1 during the vault's window):
        // longs (estate, then vault) received; shorts (winner) paid. The $80 mark is below the
        // bankruptcy price: the vault is in real loss.
        h.execAdl(_one(winner), _none(), _atIndex(80 * SCALE, -int256(3 * SCALE)));

        // Credit = (100 − 88) − 3 = $9 on top of $5 collateral.
        assertEq(h.positionCollateral(winner), 14 * SCALE, "winner credited price leg less own tab");
        // Less the executor's 2 bp of the unit at the $80 mark, $0.016, which is more than 0.1%
        // of the $8 the close averted.
        assertEq(h.insurance(), 24e18 - 9e18 - 0.016e18, "vault leg from entry: -12 price + 3 funding, booked once");
        assertEq(h.vaultCollateral(), 1_000e18 + 9e18, "deposits ledger mirrors the single transfer");
        assertEq(h.bucketSize(true), 1 * SCALE, "the estate the winner could not cover stays open");
    }

    // ---------------- window-deposit score freeze (ADL queue dodging) ----------------

    /// @notice A deposit made DURING the live ADL window is subtracted from the scoring
    ///         collateral: the winner ranks on their pre-window book (here $1 → score 60e18 at
    ///         the $90 mark, eligible even at the near-max early-auction threshold), while
    ///         settlement and the payout still use their REAL post-deposit collateral.
    ///         Mid-auction top-ups protect the account; they cannot re-rank the queue.
    function test_windowDeposit_cannotDodgeAdlQueue() public {
        // Long bucket 2 units at bankruptcy $100/u, marked at $90: a $20 loss against a $10 fund,
        // so the batch cap leaves room for more than the one unit the winner can cover.
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setVaultInsurance(10e18);
        // Short winner: entry $150, pnl $60 at the $90 mark. Real collateral $60 — of which $59
        // was deposited during THIS window (epoch 7) to dodge: raw score would be 60/60 = 1e18,
        // far below the early-auction threshold.
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 60 * SCALE);
        h.setAdlEpoch(7);
        h.setWindowDeposit(winner, 7, 59 * SCALE);

        // 1 minute into the 10-minute auction: threshold is 1 + 25e18 x 0.81 = 20.25e18 — only
        // the frozen pre-window score (60e18 on $1) clears it.
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _params(90 * SCALE, 1));

        assertEq(r.longBucket.highestAdlScore, 60e18, "ranked on the $1 of pre-window collateral");
        assertEq(h.positionSize(winner), 0, "dodger closed despite the top-up");
        assertEq(h.positionCollateral(winner), (60 + 50) * SCALE, "payout uses REAL collateral + pnl at $100");
        // Closed at its own basis, the inventory moves the fund only by the executor's 2 bp of
        // the unit at the $90 mark, $0.018, more than 0.1% of the $10 the close averted.
        assertEq(h.insurance(), 10e18 - 0.018e18, "inventory closed at its own basis: only the reward leaves");
        assertEq(h.vaultCollateral(), 1_000e18, "no vault realization: deposits ledger untouched");
        assertEq(h.bucketSize(true), 1 * SCALE, "the unit the winner could not cover stays open");
    }

    /// @notice The withdraw-to-zero dodge is dead: a winner who pulled ALL collateral out
    ///         (equity gate passes on unrealized PnL alone) floors to 1-wei score collateral —
    ///         effectively infinite score — and is closable from the FIRST minute of the
    ///         auction, at the near-max threshold. Skipping zero-collateral buckets instead of
    ///         flooring them would make exactly these pure-profit accounts ADL-immune.
    function test_withdrawToZero_cannotDodgeAdlQueue() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 0); // all collateral withdrawn
        h.setVaultInsurance(10e18);

        // 1 minute into the auction — only near-infinite scores are eligible, and this is one.
        h.execAdl(_one(winner), _none(), _params(90 * SCALE, 1));

        assertEq(h.positionSize(winner), 0, "pure-profit winner closed first");
        assertEq(h.positionCollateral(winner), 50 * SCALE, "credit = pnl at $100 on zero real collateral");
        // Closed at its own basis, the inventory moves the fund only by the executor's 2 bp of
        // the unit at the $90 mark, $0.018, more than 0.1% of the $10 the close averted.
        assertEq(h.insurance(), 10e18 - 0.018e18, "inventory closed at its own basis: only the reward leaves");
        assertEq(h.bucketSize(true), 1 * SCALE, "the unit the winner could not cover stays open");
    }

    /// @notice A tag from an OLDER window subtracts nothing: the same $59 tagged to epoch 6
    ///         while the current window is epoch 7 leaves the raw score (0.83e18) in force,
    ///         which the early-auction threshold rejects. Lazy epoch invalidation — deposits
    ///         from past windows are ordinary standing collateral.
    function test_windowDeposit_staleEpochTagIgnored() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 60 * SCALE);
        h.setAdlEpoch(7);
        h.setWindowDeposit(winner, 6, 59 * SCALE); // previous window's tag

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdl(_one(winner), _none(), _params(100 * SCALE, 1));
    }

    // ---------------- ordering + threshold ----------------

    /// @notice Winners may be submitted in any order: the batch sorts the cohort by descending
    ///         score itself and closes in that order. Here the lower score is submitted first.
    function test_ordering_anySubmissionOrderAccepted_sortedOnChain() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setOI(0, 2 * SCALE, 0, 300 * SCALE);
        // An empty fund cannot finish the two units inside the band, so both close.
        h.setVaultInsurance(0);
        address lowScore = makeAddr("lowScore");
        address highScore = makeAddr("highScore");
        // Same +$50 PnL at the $100 mark; scores 1e18 (coll 50) vs 5e18 (coll 10).
        h.setPosition(lowScore, false, 1 * SCALE, 150 * SCALE, 50 * SCALE);
        h.setPosition(highScore, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_two(lowScore, highScore), _none(), _at(100 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.longBucket.eligibleCount, 2, "both admitted");
        assertEq(r.longBucket.highestAdlScore, 5e18, "the higher score first");
        assertEq(r.longBucket.lowestAdlScore, 1e18, "the lower score last");
        assertEq(r.longBucket.closedSize, 2 * SCALE, "both closed");
        assertEq(closes.length, 2, "two closes");
        assertEq(closes[0].user, highScore, "the higher score closes first whatever the submission order");
        assertEq(closes[1].user, lowScore, "then the lower");
    }

    /// @notice Mid-auction the quadratic threshold is still high: a modest-score winner is not yet
    ///         eligible (Dutch-auction gating), so the batch reverts with no eligible winners.
    function test_threshold_midAuctionExcludesModestScores() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        // Score = 50/10 = 5e18. At 5 of the 10 minutes elapsed, threshold = 1 + 25e18 x (5/10)^2
        // = 6.25e18.
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdl(_one(winner), _none(), _params(100 * SCALE, 5));
    }

    // ---------------- ranking at the live price and funding index ----------------

    /// @dev Two short winners whose ADL-score ORDER depends on the funding index:
    ///        A: size 1, +$50 at the $100 mark, collateral $10 → score 5e18 at index 0
    ///        B: size 6, +$30 at the $100 mark, collateral $10 → score 3e18 at index 0
    ///      B has the far higher size/collateral ratio, so a rise in the index lifts B's score
    ///      faster: at index +10 the scores are A = 6e18, B = 9e18 — order flipped to [B, A].
    function _twoWinnersDivergentFunding() internal returns (address a, address b) {
        // The long bucket's 7 units = A(1) + B(6), bankrupt at $100.
        h.setBucket(true, 7 * SCALE, 700 * SCALE, 700 * SCALE, 0, 0);
        h.setOI(0, 7 * SCALE, 0, (150 + 630) * SCALE);
        a = makeAddr("winnerA");
        b = makeAddr("winnerB");
        h.setPosition(a, false, 1 * SCALE, 150 * SCALE, 10 * SCALE); // +50 @100, coll 10
        h.setPosition(b, false, 6 * SCALE, 630 * SCALE, 10 * SCALE); // +30 @100, coll 10
    }

    /// @notice Both legs rank at the live funding index: with the index at +10 the cohort sorts
    ///         [B, A] and closes in that order, whatever order the keeper submitted. Settlement
    ///         uses the same live index, so the credits include the live funding.
    function test_ranking_liveFundingIndex_sortsTheCohort() public {
        (address a, address b) = _twoWinnersDivergentFunding();
        // The fund holds exactly the $70 of funding the 7 units owe at the live index and nothing
        // beyond it. With no free capital nothing can be finished inside the band, so the batch
        // cap is the whole bucket and both winners close in full.
        h.setVaultInsurance(70e18);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_two(a, b), _none(), _atIndex(100 * SCALE, int256(10 * SCALE)));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.longBucket.highestAdlScore, 9e18, "B's score at the live index");
        assertEq(r.longBucket.lowestAdlScore, 6e18, "A's score at the live index");
        assertEq(closes[0].user, b, "B first");
        assertEq(closes[1].user, a, "A second");
        assertEq(r.longBucket.closedSize, 7 * SCALE, "both winners fully closed");
        // Settlement at the live index (+10): A credit = 50 price + 10 funding = 60; B = 30 + 60 = 90.
        assertEq(h.positionCollateral(a), (10 + 60) * SCALE, "A settled at live funding");
        assertEq(h.positionCollateral(b), (10 + 90) * SCALE, "B settled at live funding");
        assertEq(h.insurance(), 0, "insurance settled the vault's funding leg on 7 units");
        assertEq(h.vaultCollateral(), 1_000e18 + 70e18, "deposits ledger mirrors the same 7 units of funding");
        assertEq(h.bucketSize(true), 0, "vault exposure cleared");
    }

    /// @notice The submission order never decides the close order: at index 0 the same cohort
    ///         sorts [A, B], and submitting it as [B, A] closes A first all the same. A funding
    ///         move between a keeper's own sort and execution therefore reorders the queue
    ///         without reverting the batch.
    function test_ranking_submissionOrderDoesNotDecideTheCloseOrder() public {
        (address a, address b) = _twoWinnersDivergentFunding();
        h.setVaultInsurance(0);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_two(b, a), _none(), _at(100 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.longBucket.highestAdlScore, 5e18, "A's score at index 0");
        assertEq(r.longBucket.lowestAdlScore, 3e18, "B's score at index 0");
        assertEq(closes[0].user, a, "A closes first although submitted second");
        assertEq(closes[1].user, b, "B second");
        assertEq(r.longBucket.closedSize, 7 * SCALE, "both closed");
    }

    /// @notice Equal scores sort by ascending address, so the order is total and the same two
    ///         accounts close in the same order however they are submitted.
    function test_ranking_equalScoresSortByAscendingAddress() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setOI(0, 2 * SCALE, 0, 300 * SCALE);
        h.setVaultInsurance(0);
        address lowAddr = address(0x1111);
        address highAddr = address(0x2222);
        h.setPosition(lowAddr, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setPosition(highAddr, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_two(highAddr, lowAddr), _none(), _at(100 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.longBucket.highestAdlScore, r.longBucket.lowestAdlScore, "premise: equal scores");
        assertEq(closes[0].user, lowAddr, "the lower address first");
        assertEq(closes[1].user, highAddr, "the higher second");
    }

    // ---------------- settlement at the mark ----------------

    /// @notice With the mark on the fund's favorable side of the estates' bankruptcy price the
    ///         batch settles at the mark: the winner is credited no better than market and the
    ///         vault's gain on the slice moves from the deposits ledger into the fund. Long bucket
    ///         1 unit at bankruptcy $100, marked $104; an empty fund cannot finish the unit
    ///         inside the 5% band, which is what keeps the window open above the neutral price.
    ///         Every part of the unit closed at $104 hands the fund $4, takes $1.20 of finish cost
    ///         off and pays the executor 2 bp of its notional at the mark, so about 0.23 of it puts
    ///         the fund on the release line, and that is all the batch closes.
    function test_settlement_markAboveBankruptcy_longInventorySettlesAtMark() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        // Short winner, 1 unit entered at $150/u, $10 collateral.
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setVaultInsurance(0);
        // The $1.20 finish cost plus the rounding allowance, over the $5.1792 a unit a close at
        // $104 frees: the $4 gain and the $1.20 of finish cost it takes off, less the $0.0208 the
        // executor is paid.
        uint256 closed = Math.mulDiv(1.200001e18, SCALE, 5.1792e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(104 * SCALE));

        assertEq(r.longBucket.settlementPrice, 104 * SCALE, "settlement = the mark, not the bankruptcy price");
        assertEq(r.longBucket.closedSize, closed, "about 0.23 of the unit");
        // Winner: (150 - 104) on the part closed, the market close and no better.
        assertEq(h.positionCollateral(winner), 10 * SCALE + closed * 46, "winner credited PnL at the mark");
        assertEq(h.positionSize(winner), 1 * SCALE - closed, "the rest of the winner stays open");
        // Vault: the slice sold $4 above its entry basis, a D -> I transfer, less the reward.
        assertEq(h.claimable(address(this)), _rate(closed, 104 * SCALE), "2 bp of the close at the mark");
        assertEq(
            h.insurance(),
            closed * 4 - _rate(closed, 104 * SCALE),
            "the fund keeps the recovery above the bankruptcy price"
        );
        assertEq(h.vaultCollateral(), 1_000e18 - closed * 4, "deposits ledger paid the vault's gain");
        assertEq(h.bucketSize(true), 1 * SCALE - closed, "the rest of the inventory is carried");
        (, uint256 base, uint256 worstFinish,) = h.exposure(104 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the rest inside the band");
    }

    /// @notice Mirror for the short bucket: a mark BELOW the bankruptcy price is the fund's
    ///         favorable side, so the batch settles there. Short bucket 1 unit at bankruptcy
    ///         $100, marked $96, against a long winner: the $4 a unit gained and the $0.80 of
    ///         finish cost at the $100.80 band edge, less the executor's $0.0192, put about 0.17 of
    ///         the unit on the release line.
    function test_settlement_markBelowBankruptcy_shortInventorySettlesAtMark() public {
        h.setBucket(false, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        // Long winner, 1 unit entered at $50/u, $10 collateral.
        h.setPosition(winner, true, 1 * SCALE, 50 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 0, 50 * SCALE, 0);
        h.setVaultInsurance(0);
        uint256 closed = Math.mulDiv(0.800001e18, SCALE, 4.7808e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(winner), _at(96 * SCALE));

        assertEq(r.shortBucket.settlementPrice, 96 * SCALE, "settlement = the mark, not the bankruptcy price");
        assertEq(r.shortBucket.closedSize, closed, "about 0.17 of the unit");
        // Winner: (96 - 50) on the part closed.
        assertEq(h.positionCollateral(winner), 10 * SCALE + closed * 46, "winner credited PnL at the mark");
        assertEq(
            h.insurance(),
            closed * 4 - _rate(closed, 96 * SCALE),
            "the fund keeps the recovery below the bankruptcy price"
        );
        assertEq(h.vaultCollateral(), 1_000e18 - closed * 4, "deposits ledger paid the vault's gain");
        assertEq(h.bucketSize(false), 1 * SCALE - closed, "the rest of the inventory is carried");
        (, uint256 base, uint256 worstFinish,) = h.exposure(96 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the rest inside the band");
    }

    // ---------------- the executor's reward ----------------

    /// @notice Far enough past the bankruptcy price, the executor is paid its share of the bad
    ///         debt the close averts rather than the rate. Long bucket 1 unit at bankruptcy $100,
    ///         marked $70, against a $10 fund: finishing it at the $66.50 band edge would cost
    ///         $33.50. Each unit closed at $100 averts $30, whose 0.1% is $0.03, against 2 bp of
    ///         the $70 mark, $0.014; so it repairs $33.47, and the batch closes $23.500001 of it.
    function test_adlReward_markFarPastTheBankruptcyPrice_paysTheAvertedShare() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setVaultInsurance(10e18);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        uint256 closed = Math.mulDiv(23.500001e18, SCALE, 33.47e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(70 * SCALE));

        assertEq(r.longBucket.settlementPrice, 100 * SCALE, "the bankruptcy price");
        assertEq(r.longBucket.closedSize, closed, "sized with the averted share as the executor's reward");
        uint256 share = _share(closed, 70 * SCALE, 100 * SCALE);
        assertGt(share, _rate(closed, 70 * SCALE), "premise: the share is the larger");
        assertEq(h.claimable(address(this)), share, "0.1% of the $30 a unit averted");
        assertEq(h.insurance(), 10e18 - share, "the close itself costs the fund nothing");
        (, uint256 base, uint256 worstFinish,) = h.exposure(70 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the rest inside the band");
    }

    /// @notice The two routes to a losing bucket pay differently. With its cohort, the short
    ///         bucket's units, hedged by the long bucket, close in pairs: the short leg at its
    ///         $73.50 bankruptcy price for 0.1% of the $23.50 a unit that averts (more than 2 bp of
    ///         the $97 mark), the long leg at the mark for the rate, and the remainder the fund
    ///         then nets pays the rate. Without a cohort the long leg closes at the mark through
    ///         the fallback, and those closes pay the rate on their notional, plus the rate on the
    ///         netting.
    function test_adlReward_cohortRoutePaysTheAvertedShare_fallbackRoutePaysTheRateAtTheMark() public {
        _heldBook(94e18);
        h.setPosition(ally, true, 2 * SCALE, 120 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 10 * SCALE, 120 * SCALE, 1100 * SCALE);
        uint256 snap = vm.snapshotState();

        BazaarTypes.AdlResult memory withCohort = h.execAdl(_one(winner), _one(ally), _at(97 * SCALE));
        uint256 paidWithCohort = h.claimable(address(this));
        vm.revertToState(snap);

        BazaarTypes.AdlResult memory fb = h.execAdl(_one(winner), _none(), _at(97 * SCALE));
        uint256 paidFallback = h.claimable(address(this));

        assertEq(
            paidWithCohort,
            _share(withCohort.shortBucket.closedSize, 97 * SCALE, 73.5e18)
                + _rate(withCohort.longBucket.closedSize, 97 * SCALE) + _rate(withCohort.netted, 97 * SCALE),
            "the averted share on the cohort's closes, the rate on the paired closes at the mark and on the netting"
        );
        assertEq(fb.shortBucket.closedSize, 0, "premise: the fallback closes no short");
        assertEq(
            paidFallback,
            _rate(fb.longBucket.closedSize, 97 * SCALE) + _rate(fb.netted, 97 * SCALE),
            "the rate on the closes at the mark and the rate on the netting"
        );
    }

    /// @dev One inventory-only book for the reward fuzz: the side, the mark's place against the
    ///      $100 bankruptcy price, the fund and its reserve.
    struct RewardCase {
        bool vaultShort;
        uint256 mark;
        uint256 free;
        uint256 target;
    }

    /// @notice Across both sides, marks from $40 past the bankruptcy price to $10 on the fund's
    ///         side of it, funds and reserves: every close the leg makes pays the executor the
    ///         larger of 2 bp of its notional at the mark and 0.1% of the bad debt it averts,
    ///         nothing else is paid, and a batch that leaves inventory open leaves it on the
    ///         release line. The bucket holds 10 units at a $100 entry with nothing seized,
    ///         against a winner twice that size in profit at every mark.
    function testFuzz_adlReward_eachCloseEarnsTheLargerOfTheRateAndTheAvertedShare(RewardCase memory c) public {
        // On the long side a mark below $100 is past the bankruptcy price; on the short side, above.
        uint256 m = bound(c.mark, 60, 110);
        uint256 mark = (c.vaultShort ? 200 - m : m) * SCALE;
        h.setBucket(!c.vaultShort, 10 * SCALE, 1_000 * SCALE, 1_000 * SCALE, 0, 0);
        h.setVaultInsurance(bound(c.free, 1, 60) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 2_000));
        if (c.vaultShort) {
            h.setPosition(winner, true, 20 * SCALE, 400 * SCALE, 100 * SCALE);
            h.setOI(20 * SCALE, 0, 400 * SCALE, 0);
        } else {
            h.setPosition(winner, false, 20 * SCALE, 4_000 * SCALE, 100 * SCALE);
            h.setOI(0, 20 * SCALE, 0, 4_000 * SCALE);
        }

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            c.vaultShort ? h.execAdl(_none(), _one(winner), _at(mark)) : h.execAdl(_one(winner), _none(), _at(mark));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        uint256 expected;
        for (uint256 i = 0; i < closes.length; i++) {
            uint256 rate = _rate(closes[i].size, mark);
            uint256 share = _share(closes[i].size, mark, closes[i].price);
            expected += rate > share ? rate : share;
        }
        assertEq(h.claimable(address(this)), expected, "each close pays the larger of the two");
        assertEq(h.deficit(), 0, "no deficit");
        uint256 closed = c.vaultShort ? r.shortBucket.closedSize : r.longBucket.closedSize;
        if (closed != 0 && closed < 10 * SCALE) {
            (, uint256 base, uint256 worstFinish,) = h.exposure(mark, 0, 1_000);
            assertLe(worstFinish, base, "the batch leaves the fund on the release line");
        }
    }

    // ---------------- negative settlement skip ----------------

    /// @notice A winner profitable at the mark but negative at the settlement (bankruptcy)
    ///         price is admitted by the scan and skipped at the close, not force-closed into a
    ///         realized loss; a winner skipped there does not revert the batch.
    function test_settlement_negativePnlWinnerSkipped() public {
        // Settlement = 200 (bankruptcy) while the mark is 150; an empty fund asks for the whole
        // unit.
        h.setBucket(true, 1 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setOI(0, 1 * SCALE, 0, 180 * SCALE);
        h.setVaultInsurance(0);
        // Short entered $180: +30 at the $150 mark (eligible), -20 at the $200 settlement (skip).
        h.setPosition(winner, false, 1 * SCALE, 180 * SCALE, 10 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(150 * SCALE));

        assertEq(r.longBucket.eligibleSize, 1 * SCALE, "admitted at the mark");
        assertEq(r.longBucket.closedSize, 0, "nothing closed at a loss");
        assertEq(h.positionSize(winner), 1 * SCALE, "winner untouched");
        assertEq(h.positionCollateral(winner), 10 * SCALE, "collateral untouched");
        assertEq(h.bucketSize(true), 1 * SCALE, "vault exposure unresolved");
    }

    // ---------------- input guards ----------------

    function test_guard_emptySubmissionReverts() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        h.execAdl(_none(), _none(), _at(100 * SCALE));
    }

    /// @notice The cap is per array: 26 entries in either one revert.
    function test_guard_tooManyWinnersReverts() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        address[] memory many = new address[](26);
        vm.expectRevert(abi.encodeWithSelector(AdlLib.AdlLib__TooManyWinners.selector, 26, 25));
        h.execAdl(many, _none(), _at(100 * SCALE));
        vm.expectRevert(abi.encodeWithSelector(AdlLib.AdlLib__TooManyWinners.selector, 26, 25));
        h.execAdl(_none(), many, _at(100 * SCALE));
    }

    function test_guard_noPendingLiquidationsReverts() public {
        vm.expectRevert(AdlLib.AdlLib__NoPendingLiquidations.selector);
        h.execAdl(_one(winner), _none(), _at(100 * SCALE));
    }

    /// @notice A cohort submitted for the wrong bucket is no cohort: a short in the short bucket's
    ///         array is skipped by the scan, and with nothing else to do the batch reverts.
    function test_guard_cohortOnTheBucketsOwnSide_isNotEligible() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(10e18); // the earmark alone: the overlap's $20 cannot be netted
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdl(_none(), _one(winner), _at(100 * SCALE));
    }

    /// @notice A deficit on the books stops every close before its first slice: the leg sizes a
    ///         close, admits the winner and closes nothing, and the batch returns quietly.
    function test_existingDeficit_closesNothing_batchReturnsQuietly() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setVaultInsurance(0);
        h.setDeficit(1e18);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(100 * SCALE));

        assertEq(r.longBucket.eligibleSize, 1 * SCALE, "the winner is admitted");
        assertEq(r.longBucket.closedSize, 0, "and nothing is closed");
        assertEq(h.positionSize(winner), 1 * SCALE, "winner untouched");
        assertEq(h.bucketSize(true), 1 * SCALE, "inventory untouched");
        assertEq(h.deficit(), 1e18, "the deficit stands");
    }

    /// @notice The end-of-batch netting does not read the deficit: with both legs stopped by it,
    ///         an overlap the fund can afford is still netted and pays the executor the rate on
    ///         what it retired. Long 20 @ $100 against $100 seized (bankrupt at $95) and short 10
    ///         @ $80 against $100 (bankrupt at $90), marked $93: both buckets are under water, the
    ///         $200 entry gap on the 10-unit overlap is within the $60 free plus the $150 of
    ///         seizure on the netted slices, and the long bucket's excess is under water at the
    ///         band edge by more than that, so the window is open and the netting fits.
    function test_existingDeficit_endOfBatchNettingStillRuns() public {
        h.setBucket(true, 20 * SCALE, 2000 * SCALE, 1900 * SCALE, 100 * SCALE, 0);
        h.setBucket(false, 10 * SCALE, 800 * SCALE, 900 * SCALE, 100 * SCALE, 0);
        h.setVaultInsurance(260e18);
        h.setDeficit(1e18);
        h.setPosition(winner, false, 20 * SCALE, 2200 * SCALE, 200 * SCALE);
        h.setPosition(ally, true, 10 * SCALE, 800 * SCALE, 100 * SCALE);
        h.setOI(10 * SCALE, 20 * SCALE, 800 * SCALE, 2200 * SCALE);
        (, uint256 base, uint256 worstFinish,) = h.exposure(93 * SCALE, 0, 1_000);
        assertGt(worstFinish, base, "premise: the window is open");
        assertTrue(h.overlapAffordable(93 * SCALE, 0), "premise: the netting fits");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(93 * SCALE));

        assertEq(r.longBucket.closedSize, 0, "the long leg closes nothing");
        assertEq(r.shortBucket.closedSize, 0, "nor the short leg");
        assertEq(r.netted, 10 * SCALE, "the netting takes the overlap");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.bucketSize(true), 10 * SCALE, "the long bucket's excess remains");
        assertEq(h.positionSize(winner), 20 * SCALE, "winner untouched");
        assertEq(h.positionSize(ally), 10 * SCALE, "ally untouched");
        assertEq(h.claimable(address(this)), _rate(10 * SCALE, 93 * SCALE), "the rate on the 10 units netted");
        assertEq(h.deficit(), 1e18, "no further deficit");
        // The $200 loss: $150 from the netted slices' seizure, $50 from free capital.
        assertEq(h.insurance(), 260e18 - 200e18 - _rate(10 * SCALE, 93 * SCALE), "the fund paid the gap and the rate");
    }

    // ---------------- the losing leg: a bucket closed by its own cohort at its bankruptcy price ----------------

    /// @dev Long bucket 1 unit at bankruptcy $100 with nothing seized. The short bucket holds one
    ///      estate, a short from $80 on $10 — bankrupt at $90 and $10 past it at the $100 mark —
    ///      whose netting the fund could not afford. `ally` is the long from $80 on $10 that is
    ///      its natural counterparty, $20 in profit at the mark. The fund holds the $10 seized
    ///      plus $5 free: the $20 entry gap stays unaffordable and the window stays open.
    function _shortBucketAgainstLongBucket() internal {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(15e18);
        h.setPosition(ally, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 0, 80 * SCALE, 0);
    }

    /// @notice The short bucket is closed against its own cohort at its bankruptcy price: the
    ///         seizure covers the loss exactly, so the fund moves only by the executor's reward,
    ///         and the long bucket is untouched — this cohort never needed the other one.
    function test_losingLeg_closedByItsOwnCohort_atItsBankruptcyPrice_fundNeutral() public {
        _shortBucketAgainstLongBucket();
        (, uint256 base, uint256 worstFinish,) = h.exposure(100 * SCALE, 0, 1_000);
        assertGt(worstFinish, base, "premise: the window is open");

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(100 * SCALE));

        assertEq(r.shortBucket.settlementPrice, 90 * SCALE, "the short bucket's bankruptcy price");
        assertEq(r.shortBucket.closedSize, 1 * SCALE, "the whole short bucket closed");
        assertEq(r.longBucket.closedSize, 0, "nothing closed against the long bucket");
        assertEq(r.netted, 0, "nothing netted");
        assertEq(h.positionSize(ally), 0, "counterparty closed in full");
        // Settled at the $90 bankruptcy price: (90 - 80) x 1 = $10 on top of $10 collateral.
        assertEq(h.positionCollateral(ally), 20 * SCALE, "credited at the bankruptcy price, not the mark");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.bucketSize(true), 1 * SCALE, "the long bucket is not what this cohort closes");
        assertEq(h.deficit(), 0, "no bad debt");
        // 2 bp of the unit at the $100 mark, $0.02, more than 0.1% of the $10 the close averted:
        // the only movement the fund sees beyond the earmark it pays out.
        assertEq(h.claimable(address(this)), 0.02e18, "the rate on the close");
        assertEq(h.insurance(), 15e18 - 10e18 - 0.02e18, "the $10 earmark out, the reward out");
        assertEq(h.vaultCollateral(), 1_010e18, "ledger: the vault leg paid back in");
    }

    /// @notice The same close at ten units, where 2 bp of the $1,000 closed at the mark is $0.20,
    ///         more than 0.1% of the $100 the close at the $90 bankruptcy price averts.
    function test_losingLeg_paysTheRateOnWhatItCloses() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 1000 * SCALE, 0, 0);
        h.setBucket(false, 10 * SCALE, 800 * SCALE, 900 * SCALE, 100 * SCALE, 0); // shorts from $80, bankrupt at $90
        h.setVaultInsurance(150e18);
        h.setPosition(ally, true, 10 * SCALE, 800 * SCALE, 100 * SCALE);
        h.setOI(10 * SCALE, 0, 800 * SCALE, 0);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(100 * SCALE));

        assertEq(r.shortBucket.closedSize, 10 * SCALE, "the whole bucket closed against its cohort");
        assertEq(h.positionCollateral(ally), 200 * SCALE, "credited (90 - 80) x 10 at the bankruptcy price");
        assertEq(h.claimable(address(this)), 0.2e18, "2 bp of the $1,000 closed");
        assertEq(h.insurance(), 150e18 - 100e18 - 0.2e18, "the earmark out, the rate out");
    }

    /// @notice A close against a bucket whose estate's collateral the deposits ledger could not
    ///         hand over in full still takes the whole bucket. The ledger held $4 of the $10: the
    ///         seizure collected the $4 and carries the other $6 as arrears, and the close at the
    ///         $90 bankruptcy price pays its $10 loss from the $4 and then nets the $6. Nothing is
    ///         left unpaid, so no deficit stops the close.
    function test_losingLeg_collateralTheLedgerCouldNotPay_completesWithNoDeficit() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 4 * SCALE, 0);
        h.setLedgerArrears(6e18);
        h.setVaultCollateral(0);
        h.setVaultInsurance(9e18); // the $4 seized and $5 free
        h.setPosition(ally, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 0, 80 * SCALE, 0);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(100 * SCALE));

        assertEq(r.shortBucket.closedSize, 1 * SCALE, "the whole bucket closed against its cohort");
        assertEq(h.deficit(), 0, "no deficit");
        assertEq(h.arrears(), 0, "the close nets the $6 the ledger owed");
        assertEq(h.positionCollateral(ally), 20 * SCALE, "credited at the bankruptcy price");
        assertEq(h.claimable(address(this)), 0.02e18, "the rate on the close");
        assertEq(h.insurance(), 9e18 - 4e18 - 0.02e18, "the $4 seized paid back out, the reward out");
        assertEq(h.vaultCollateral(), 4e18, "the ledger gets back the $4 it handed over");
        assertEq(h.bucketSize(true), 1 * SCALE, "the long bucket is untouched");
    }

    /// @notice The losing leg ranks its cohort at the price the call resolved. Two longs: `ally`
    ///         from $88 on $5 and `winner` from $65 on $20. At the $100 mark their scores are 2.4
    ///         and 1.75, which puts `ally` first (at $95 they would be 1.4 and 1.5, `winner`
    ///         first). Submitted in the other order, the batch sorts them and closes `ally`
    ///         first, both at the short bucket's $90 bankruptcy price.
    function test_losingLeg_ranksTheCohortAtTheLivePrice() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setBucket(false, 2 * SCALE, 160 * SCALE, 180 * SCALE, 20 * SCALE, 0); // shorts from $80, bankrupt at $90
        h.setVaultInsurance(21e18);
        h.setPosition(ally, true, 1 * SCALE, 88 * SCALE, 5 * SCALE);
        h.setPosition(winner, true, 1 * SCALE, 65 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 0, 153 * SCALE, 0);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _two(winner, ally), _at(100 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.shortBucket.highestAdlScore, 2.4e18, "ally's score at the mark");
        assertEq(r.shortBucket.lowestAdlScore, 1.75e18, "winner's score at the mark");
        assertEq(r.shortBucket.closedSize, 2 * SCALE, "the short bucket closed against the cohort");
        assertEq(closes[0].user, ally, "the first-ranked long closed first");
        assertEq(closes[1].user, winner, "and the second, which the two-unit bucket needed");
        assertEq(closes[0].price, 90 * SCALE, "at the bankruptcy price");
        assertEq(h.positionCollateral(ally), 7 * SCALE, "$5 plus (90 - 88) x 1");
        assertEq(h.positionCollateral(winner), 45 * SCALE, "$20 plus (90 - 65) x 1");
    }

    /// @notice A deposit tagged to the current window is subtracted on this leg too: `ally` from
    ///         $88 on $25, of which $20 was deposited during this window (epoch 7), scores 12 / 5
    ///         = 2.4 rather than 0.48 and stands first, ahead of the more levered `winner` at
    ///         1.75. The deposit still counts in full at settlement.
    function test_losingLeg_windowDepositSubtractedFromTheScore() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 200 * SCALE, 0, 0);
        h.setBucket(false, 2 * SCALE, 160 * SCALE, 180 * SCALE, 20 * SCALE, 0);
        h.setVaultInsurance(21e18);
        h.setPosition(ally, true, 1 * SCALE, 88 * SCALE, 25 * SCALE);
        h.setPosition(winner, true, 1 * SCALE, 65 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 0, 153 * SCALE, 0);
        h.setAdlEpoch(7);
        h.setWindowDeposit(ally, 7, 20 * SCALE); // tagged to the live window

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _two(winner, ally), _at(100 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.shortBucket.highestAdlScore, 2.4e18, "ally ranked on the $5 of pre-window collateral");
        assertEq(r.shortBucket.lowestAdlScore, 1.75e18, "winner's score on full collateral");
        assertEq(closes[0].user, ally, "the topped-up long closed first");
        assertEq(closes[1].user, winner, "the more levered long second");
        // Settled at the $90 bankruptcy price on the REAL collateral: the top-up counts in full.
        assertEq(h.positionCollateral(ally), (25 + 2) * SCALE, "$25 plus (90 - 88) x 1");
        assertEq(h.positionCollateral(winner), (20 + 25) * SCALE, "$20 plus (90 - 65) x 1");
    }

    /// @notice A dust bucket pays the same way: the executor earns 2 bp of the $4 closed at the
    ///         mark, $0.0008, which is more than 0.1% of the $0.40 the close at $90 averts; there
    ///         is no flat floor on a close.
    function test_losingLeg_dustBucket_paysTheRateOnTheClose() public {
        // A $4 short from $80 on $0.40, bankrupt at $90; `ally` is its counterparty from $80.
        uint256 size = 0.04e18;
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, size, 3.2e18, 3.6e18, 0.4e18, 0);
        h.setVaultInsurance(1.4e18);
        h.setPosition(ally, true, size, 3.2e18, 0.4e18);
        h.setOI(size, 0, 3.2e18, 0);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(100 * SCALE));

        assertEq(r.shortBucket.closedSize, size, "the whole bucket closed");
        assertEq(r.longBucket.closedSize, 0, "nothing closed against the long bucket");
        // Settled at the $90 bankruptcy price: (90 - 80) x 0.04 = $0.40 on top of $0.40 collateral.
        assertEq(h.positionCollateral(ally), 0.8e18, "credited at the bankruptcy price");
        assertEq(h.deficit(), 0, "no bad debt");
        assertEq(h.claimable(address(this)), 0.0008e18, "2 bp of the $4 notional");
        assertEq(h.insurance(), 1.4e18 - 0.4e18 - 0.0008e18, "the earmark out, the rate out");
    }

    /// @notice A bucket is an aggregate: a cohort covering half of it closes half, and the other
    ///         half stands for a later batch — here one with the second counterparty. With the
    ///         fund holding nothing above the earmark the netting stays unaffordable, so the
    ///         remainder is not netted either.
    function test_losingLeg_partialCohortClosesWhatItCovers_theRestStands() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(10e18);
        h.setPosition(ally, true, 0.5e18, 40 * SCALE, 5 * SCALE);
        h.setOI(0.5e18, 0, 40 * SCALE, 0);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(100 * SCALE));

        assertEq(r.shortBucket.eligibleSize, 0.5e18, "the cohort covers half");
        assertEq(r.shortBucket.closedSize, 0.5e18, "and half closes");
        assertEq(r.netted, 0, "the rest is not netted");
        assertEq(h.positionSize(ally), 0, "the counterparty closed whole");
        assertEq(h.positionCollateral(ally), 10 * SCALE, "credited (90 - 80) x 0.5");
        BazaarTypes.Inventory memory rest = h.bucket(false);
        assertEq(rest.size, 0.5e18, "half the bucket stands");
        assertEq(rest.entryNotional, 40 * SCALE, "at the same entry basis");
        assertEq(rest.bankruptcyNotional, 45 * SCALE, "and bankruptcy price");
        assertEq(rest.seized, 5 * SCALE, "with its share of the earmark");
        // The $5 earmark paid the close; what is left in the fund is the other half's earmark,
        // so nothing is free for the reward.
        assertEq(h.insurance(), 5e18, "the earmark of the half that stands");
        assertEq(h.claimable(address(this)), 0, "no free capital, no reward");

        h.setPosition(ally2, true, 0.5e18, 40 * SCALE, 5 * SCALE);
        h.setOI(0.5e18, 0, 40 * SCALE, 0);
        r = h.execAdl(_none(), _two(ally, ally2), _at(100 * SCALE));

        assertEq(r.shortBucket.closedSize, 0.5e18, "the other half closes once covered");
        assertEq(h.positionCollateral(ally2), 10 * SCALE, "credited (90 - 80) x 0.5");
        assertEq(h.bucketSize(false), 0, "the bucket is gone");
        assertEq(h.insurance(), 0, "the earmark paid the close; an empty fund pays no reward");
    }

    /// @notice A cohort profitable at the mark but under water at the bucket's bankruptcy price
    ///         is admitted by the scan and skipped at the close. Nothing closes, nothing is
    ///         netted — the fund holds only the earmark — and the batch returns quietly rather
    ///         than reverting, since a winner was eligible.
    function test_losingLeg_cohortUnderWaterAtTheBankruptcyPrice_skipped_batchReturnsQuietly() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(10e18);
        // Long from $95 on $10: +$5 at the $100 mark, -$5 at the $90 settlement.
        h.setPosition(ally, true, 1 * SCALE, 95 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 0, 95 * SCALE, 0);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(100 * SCALE));

        assertEq(r.shortBucket.eligibleSize, 1 * SCALE, "admitted at the mark");
        assertEq(r.shortBucket.closedSize, 0, "skipped at the bankruptcy price");
        assertEq(r.netted, 0, "nothing netted");
        assertEq(h.positionSize(ally), 1 * SCALE, "nothing closed against it");
        assertEq(h.bucketSize(false), 1 * SCALE, "the short bucket stands");
        assertEq(h.bucketSize(true), 1 * SCALE, "the long bucket is untouched");
        assertEq(h.insurance(), 10e18, "the fund spent nothing");
        assertEq(h.deficit(), 0, "no bad debt");
    }

    /// @notice A batch that closes nothing still nets an overlap the fund can afford: with $1,000
    ///         free the long leg is sized to zero, and the netting that ends the batch takes the
    ///         one-unit overlap at its $20 entry gap, $10 from the netted slice's seizure and $10
    ///         from free capital, paying the executor the rate on the unit.
    function test_endOfBatchNetting_takesAnAffordableOverlapWithoutACohort() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(1_010e18);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.eligibleSize, 1 * SCALE, "the winner is eligible");
        assertEq(r.longBucket.closedSize, 0, "but the fund carries the inventory, so nothing closes");
        assertEq(r.netted, 1 * SCALE, "the overlap is netted");
        assertEq(h.inventorySize(), 0, "both buckets are gone");
        assertEq(h.positionSize(winner), 1 * SCALE, "winner untouched");
        assertEq(h.deficit(), 0, "the fund could afford the netting");
        assertEq(h.claimable(address(this)), _rate(1 * SCALE, 90 * SCALE), "the rate on the unit netted");
        assertEq(h.insurance(), 1_010e18 - 20e18 - _rate(1 * SCALE, 90 * SCALE), "seizure in, entry gap out, rate out");
        assertEq(h.vaultCollateral(), 1_020e18, "the ledger receives the gap");
    }

    /// @notice A bucket closed whole leaves the other bucket as the inventory: there is no side
    ///         for the vault to be on and no flip. The long bucket closes whole at $100 against
    ///         its winner; the short bucket, with no cohort, stands with its earmark in the fund,
    ///         so nothing is free to pay the executor.
    function test_longBucketClosedWhole_shortBucketStandsAsTheInventory() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 2 * SCALE, 140 * SCALE, 150 * SCALE, 10 * SCALE, 0); // shorts from $70, bankrupt at $75
        h.setVaultInsurance(10e18);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.closedSize, 1 * SCALE, "the long bucket closed in full");
        assertEq(r.longBucket.settlementPrice, 100 * SCALE, "at its bankruptcy price");
        assertEq(r.shortBucket.closedSize, 0, "no cohort was supplied for the short bucket");
        assertEq(r.shortBucket.settlementPrice, 75 * SCALE, "whose settlement price the batch still reports");
        assertEq(r.netted, 0, "nothing netted");
        assertEq(h.bucketSize(true), 0, "the long bucket is gone");
        assertEq(h.bucketSize(false), 2 * SCALE, "the short bucket is the inventory");
        assertEq(h.positionCollateral(winner), 60 * SCALE, "$10 plus (150 - 100) x 1");
        // The $10 seizure is earmarked against the short bucket, so nothing is free to pay the
        // executor: the reward is skipped, never drawn from the earmark.
        assertEq(h.insurance(), 10e18, "the earmark, untouched by the reward");
        assertEq(h.claimable(address(this)), 0, "no free capital, no reward");
    }

    // ---------------- liquidate(): seizure into the estate's own bucket and the netting ----------------

    /// @notice An estate larger than the opposite bucket nets the overlap and its remainder seeds
    ///         its own bucket. Long bucket 1 unit at $10,000; the short of 3 from $10,000 on $10 is
    ///         under maintenance at the $10,000 mark and level with the long's entry, so the
    ///         netting costs nothing. The liquidator earns 2 bp of the one unit the netting
    ///         retired, $2, not of all three: the two left over are exposure moved onto the fund,
    ///         paid for when they are retired.
    function test_liquidate_estateLargerThanTheOppositeBucket_netsTheOverlap_remainderSeedsItsOwnBucket() public {
        h.setBucket(true, 1 * SCALE, 10_000 * SCALE, 10_000 * SCALE, 0, 0);
        h.setPosition(loser, false, 3 * SCALE, 30_000 * SCALE, 10 * SCALE);
        h.setOI(0, 3 * SCALE, 0, 30_000 * SCALE);

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser, 10_000 * SCALE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.positionSize(loser), 0, "the estate is off the book");
        assertEq(h.bucketSize(true), 0, "the long bucket is netted away");
        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.size, 2 * SCALE, "the two units past the overlap are the short bucket");
        assertEq(s.entryNotional, 20_000 * SCALE, "at the estate's entry basis");
        assertEq(
            s.seized,
            10 * SCALE - Math.mulDiv(10 * SCALE, 1, 3),
            "with its share of the $10 seized, the netted third floored"
        );
        assertEq(h.claimable(address(this)), 2e18, "2 bp of the $10,000 unit netted, not of all three");
        assertEq(h.insurance(), 1_000e18 + 10e18 - 2e18, "the seizure in, nothing realized, the reward out");
        assertEq(h.vaultCollateral(), 990e18, "the ledger handed over the $10");
    }

    /// @notice A second estate on the bucket's side merges into it, moves its exposure onto the
    ///         fund, and earns the $0.05 floor alone: no overlap exists to be retired.
    function test_liquidate_estateOnTheBucketsSide_mergesIntoIt_earnsTheFlatRewardOnly() public {
        h.setBucket(true, 1 * SCALE, 10_000 * SCALE, 10_000 * SCALE, 0, 0);
        h.setPosition(loser, false, 3 * SCALE, 30_000 * SCALE, 10 * SCALE);
        h.setOI(0, 3 * SCALE, 0, 30_000 * SCALE);
        h.liquidate(loser, 10_000 * SCALE, 0);
        h.setPosition(loser2, false, 1 * SCALE, 10_000 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 10_000 * SCALE);

        h.liquidate(loser2, 10_000 * SCALE, 0);

        assertEq(h.positionSize(loser2), 0, "the second estate is seized too");
        assertEq(h.bucketSize(false), 3 * SCALE, "and merged into the short bucket");
        assertEq(h.bucketSize(true), 0, "nothing on the other side");
        assertEq(h.claimable(address(this)), 2e18 + 0.05e18, "the overlap's 2 bp and the merged estate's floor");
        assertEq(h.insurance(), 1_000e18 + 20e18 - 2.05e18, "both seizures in, nothing realized, the rewards out");
    }

    /// @notice A merge is not put to any gate. A short from $10,500 on $10 is $500 in profit at
    ///         the $10,000 mark but under maintenance there; with a short bucket present and no
    ///         long one, it is seized and merged, realizing nothing, for the flat reward.
    function test_liquidate_profitableUndermarginedEstate_mergesIntoItsBucket() public {
        uint256 seized = Math.mulDiv(10 * SCALE, 2, 3);
        h.setBucket(false, 2 * SCALE, 20_000 * SCALE, 20_000 * SCALE + seized, seized, 0);
        h.setVaultInsurance(seized + 5e18);
        h.setPosition(loser2, false, 1 * SCALE, 10_500 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 10_500 * SCALE);

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser2, 10_000 * SCALE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.bucketSize(false), 3 * SCALE, "merged into the short bucket");
        assertEq(h.bucket(false).entryNotional, 30_500 * SCALE, "at its own entry");
        assertEq(h.deficit(), 0, "nothing realized");
        assertEq(h.claimable(address(this)), 0.05e18, "the flat reward");
        assertEq(h.insurance(), seized + 5e18 + 10e18 - 0.05e18, "the seizure in, the reward out");
    }

    /// @notice Whatever the entry and collateral of an estate on the bucket's side, as long as it
    ///         is insolvent at the mark it merges into the bucket: seized, its size added, nothing
    ///         realized, and the floor paid for it. Its entry runs from $2,000 below the $10,000
    ///         mark to $999 above it, against less collateral than keeps it above maintenance.
    function testFuzz_liquidate_estateOnTheBucketsSide_alwaysMerges(uint256 size, uint256 gap, uint256 collateral)
        public
    {
        h.setBucket(false, 2 * SCALE, 20_000 * SCALE, 20_010 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(11e18); // the earmark and $1 free for the reward
        h.setVaultCollateral(1_000_000e18);
        uint256 b = bound(size, 0.01e18, 5e18);
        uint256 entry = 8_000 + bound(gap, 0, 2_999);
        // Maintenance at the mark is 10% of $10,000 a unit; equity is the collateral plus the
        // short's PnL, (entry - 10,000) a unit.
        uint256 c = bound(collateral, 0, (11_000 - entry) * b - 1);
        h.setPosition(loser2, false, b, entry * b, c);
        h.setOI(0, 2 * SCALE + b, 0, 20_000 * SCALE + entry * b);

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser2, 10_000 * SCALE, 0);

        assertEq(r.liquidatedCount, 1, "the estate is seized");
        assertEq(h.bucketSize(false), 2 * SCALE + b, "its size joined the short bucket");
        assertEq(h.bucketSize(true), 0, "nothing on the other side");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.claimable(address(this)), 0.05e18, "the merged estate's floor");
        assertEq(h.insurance(), 11e18 + c - 0.05e18, "the seizure in, nothing realized, the reward out");
    }

    /// @notice One estate nets the whole opposite bucket and the next on the same side seeds a
    ///         fresh bucket: the first pays the $0.05 floor (2 bp of $100 is less) for the netting
    ///         that empties the long bucket, the second the floor for the seed.
    function test_liquidate_nettingThatEmptiesTheBucket_thenTheNextEstateSeedsItsOwn() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setPosition(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setPosition(loser2, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setOI(0, 2 * SCALE, 0, 160 * SCALE);

        h.liquidate(loser, 100 * SCALE, 0);

        assertEq(h.inventorySize(), 0, "the first estate netted the long bucket whole");
        // The $20 entry gap: $10 from the estate's seizure, $10 from free capital; the floor out.
        assertEq(h.insurance(), 1_000e18 - 10e18 - 0.05e18, "seizure in, entry gap out, floor out");
        assertEq(h.vaultCollateral(), 1_010e18, "the ledger received the gap less the seizure");

        h.liquidate(loser2, 100 * SCALE, 0);

        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.size, 1 * SCALE, "the second estate seeds the short bucket");
        assertEq(s.entryNotional, 80 * SCALE, "at its entry");
        assertEq(s.bankruptcyNotional, 90 * SCALE, "bankrupt at $90");
        assertEq(s.seized, 10 * SCALE, "with its seizure earmarked");
        assertEq(h.claimable(address(this)), 0.1e18, "two floors");
        assertEq(h.insurance(), 1_000e18 - 0.1e18, "both seizures in, one gap out, two floors out");
    }

    // ---------------- duplicates and the cover cutoff ----------------

    /// @notice The same account twice in a cohort is counted and closed once: repeats sort next
    ///         to each other and the second is dropped.
    function test_duplicate_droppedAfterTheSort_closedOnce() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(10e18);
        h.setPosition(ally, true, 0.5e18, 40 * SCALE, 5 * SCALE);
        h.setOI(0.5e18, 0, 40 * SCALE, 0);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _two(ally, ally), _at(100 * SCALE));

        assertEq(r.shortBucket.eligibleCount, 1, "counted once");
        assertEq(r.shortBucket.eligibleSize, 0.5e18, "for its own size");
        assertEq(r.shortBucket.closedSize, 0.5e18, "closed once");
        assertEq(h.positionSize(ally), 0, "whole");
        assertEq(h.positionCollateral(ally), 10 * SCALE, "credited (90 - 80) x 0.5 once");
        assertEq(h.bucketSize(false), 0.5e18, "the other half stands");
    }

    /// @notice Entries past the point where the cohort covers the bucket stay in the order, so a
    ///         winner skipped at the settlement price is replaced by the next one; a repeat among
    ///         them is still dropped. `ally2` ranks first (2e18) and covers half; `ally` (1e18)
    ///         fills the scan but is under water at the $90 settlement, so only `ally2` closes,
    ///         once.
    function test_duplicate_pastTheCoverCutoff_dropped_skippedWinnerReplaced() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0); // settles at $90
        h.setVaultInsurance(10e18);
        h.setPosition(ally, true, 1 * SCALE, 95 * SCALE, 5 * SCALE); // +5 at $100, -5 at $90
        h.setPosition(ally2, true, 0.5e18, 40 * SCALE, 5 * SCALE); // +5 at $90
        h.setOI(1.5e18, 0, 135 * SCALE, 0);

        address[] memory cohort = new address[](3);
        cohort[0] = ally;
        cohort[1] = ally2;
        cohort[2] = ally2;
        BazaarTypes.AdlResult memory r = h.execAdl(_none(), cohort, _at(100 * SCALE));

        assertEq(r.shortBucket.eligibleCount, 2, "ally2 and ally cover the bucket; the repeat is dropped");
        assertEq(r.shortBucket.eligibleSize, 1 * SCALE, "the bucket is covered");
        assertEq(r.shortBucket.highestAdlScore, 2e18, "ally2 first");
        assertEq(r.shortBucket.lowestAdlScore, 1e18, "ally second");
        assertEq(r.shortBucket.closedSize, 0.5e18, "ally2's half; ally is skipped at $90");
        assertEq(h.positionSize(ally2), 0, "ally2 closed once");
        assertEq(h.positionCollateral(ally2), 10 * SCALE, "credited (90 - 80) x 0.5 once");
        assertEq(h.positionSize(ally), 1 * SCALE, "ally untouched");
    }

    // ---------------- the fallback: a losing bucket with no cohort, resolved through the fund ----------------

    /// @dev The long bucket is 10 @ $100 against $50 seized (bankrupt at $95) and the short bucket
    ///      2 @ $70 against $7 (bankrupt at $73.50): one estate the fund could not afford to net.
    ///      The mark is $97: the long bucket is above water and settles at the mark; the short
    ///      bucket is $47 under water and settles at its bankruptcy price. Netting the overlap
    ///      costs the entry gap, 2 x ($100 - $70) = $60, against the $17 of seizure on the netted
    ///      slices and whatever the fund holds free. With `fund` at $94 that is $37: unaffordable,
    ///      and finishing both buckets at the $92.15 band edge would cost $65.80, so the window
    ///      stays open. The short winner, 10 @ $110, is in profit at the mark.
    function _heldBook(uint256 fund) internal {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 2 * SCALE, 140 * SCALE, 147 * SCALE, 7 * SCALE, 0);
        h.setVaultInsurance(fund);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
    }

    /// @notice With no cohort for the losing short bucket, the long leg closes at the mark until
    ///         the fund can afford to net the two, and the netting that ends the batch takes the
    ///         overlap. The sizing needs the budget to cover the netting's $43 beyond the netted
    ///         slices' seizure, its $0.0388 rate, the 8 surviving units' $22.80 of band-edge
    ///         finish cost and the allowance, $28.84 more than the $37 the fund holds, and counts
    ///         each unit closed at the mark for the $2 it hands the fund ($5 of earmark less the
    ///         $3 lost from $100) less its 2 bp — not for the finish cost it takes off the
    ///         survivors — so its figure exceeds the 8 closable units and the cap is closed: all
    ///         8 units of excess go at the mark, the netting takes the 2 that remain, and the
    ///         fund pays the $43.
    function test_fallback_losingBucketWithNoCohort_longLegClosesAtTheMark_untilTheNettingFits() public {
        _heldBook(94e18);
        uint256 planned = Math.mulDiv(28.838801e18, 8 * SCALE, 15.8448e18, Math.Rounding.Ceil);
        assertGt(planned, 8 * SCALE, "premise: the figure is past the 8 closable units");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(97 * SCALE));

        assertEq(r.longBucket.settlementPrice, 97 * SCALE, "the long leg settles at the mark");
        assertEq(r.longBucket.closedSize, 8 * SCALE, "the whole excess over the overlap");
        assertEq(r.shortBucket.closedSize, 0, "no cohort closes the short bucket");
        assertEq(r.netted, 2 * SCALE, "the netting takes the overlap");
        assertEq(h.inventorySize(), 0, "nothing is left in either bucket");
        assertEq(h.positionSize(winner), 2 * SCALE, "the winner keeps the rest");
        assertEq(h.positionCollateral(winner), 100e18 + 8 * 13e18, "credited (110 - 97) x 8 at the mark");
        assertEq(h.deficit(), 0, "the fund could afford the netting");
        // $3 lost a unit on the 8 closed at the mark, paid from their $40 of earmark; the $60 gap
        // on the netting, $17 of it from the netted slices' seizure; the rate on both.
        assertEq(h.claimable(address(this)), _rate(8 * SCALE, 97 * SCALE) + _rate(2 * SCALE, 97 * SCALE), "the rates");
        assertEq(h.insurance(), 94e18 - 24e18 - 60e18 - 0.194e18, "the fund paid the gap to the mark and the netting");
        assertEq(h.vaultCollateral(), 1_084e18, "the ledger received both realizations");
    }

    /// @notice With more free capital the figure sits inside the cap and that is what closes:
    ///         $57 free leaves $8.84 to cover at $1.98 a unit, 4.46 units, after which the netting
    ///         fits and the window releases with inventory left on the long side.
    function test_fallback_sizedToAffordTheNetting_notTheWholeExcess() public {
        _heldBook(114e18);
        uint256 closed = Math.mulDiv(8.838801e18, 8 * SCALE, 15.8448e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(97 * SCALE));

        assertEq(r.longBucket.closedSize, closed, "about 4.46 units at the mark");
        assertLt(closed, 8 * SCALE, "inside the cap");
        assertEq(r.netted, 2 * SCALE, "the netting fits afterwards");
        assertEq(h.bucketSize(true), 10 * SCALE - closed - 2 * SCALE, "the netting took its 2 units off the remainder");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(
            h.claimable(address(this)),
            _rate(closed, 97 * SCALE) + _rate(2 * SCALE, 97 * SCALE),
            "the rate on the closes at the mark and on the netting"
        );
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the remainder at the band edge: the window releases");
    }

    /// @notice The netting's rate is part of what the fallback sizes for and of what the batch
    ///         pays. The book above at ten times the prices: 2 bp of the 2 units netted at the
    ///         $970 mark is $0.388, the leg is sized with it, and the executor is paid it on top
    ///         of the rate on the closes at the mark.
    function test_fallback_paysTheRateOnTheOverlapNetted() public {
        h.setBucket(true, 10 * SCALE, 10_000 * SCALE, 9_500 * SCALE, 500 * SCALE, 0);
        h.setBucket(false, 2 * SCALE, 1_400 * SCALE, 1_470 * SCALE, 70 * SCALE, 0);
        h.setVaultInsurance(1_140e18);
        h.setPosition(winner, false, 10 * SCALE, 11_000 * SCALE, 1_000 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 11_000 * SCALE);
        uint256 closed = Math.mulDiv(88.388001e18, 8 * SCALE, 158.448e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(970 * SCALE));

        assertEq(r.longBucket.closedSize, closed, "sized with the netting's rate in the need");
        assertEq(r.netted, 2 * SCALE, "the overlap netted");
        assertEq(_rate(2 * SCALE, 970 * SCALE), 0.388e18, "premise: the rate on the netting");
        assertEq(h.claimable(address(this)), _rate(closed, 970 * SCALE) + 0.388e18, "paid on top of the closes' rate");
        (, uint256 base, uint256 worstFinish,) = h.exposure(970 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice A winner too small for the sized close is closed whole. The netting fits — the
    ///         close freed more than it needed — but the inventory it leaves is more than the fund
    ///         can finish at the band edge, so the window stays open for the next batch, which
    ///         the ordinary sizing then bounds.
    function test_fallback_shortWinner_netsAndLeavesTheRestToTheNextBatch() public {
        _heldBook(94e18);
        h.setPosition(winner, false, 5 * SCALE, 550 * SCALE, 100 * SCALE);
        h.setOI(0, 5 * SCALE, 0, 550 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(97 * SCALE));

        assertEq(r.longBucket.closedSize, 5 * SCALE, "the winner's whole position, short of the sized close");
        // After 5 units the fund holds $47 above a $32 earmark: the netting's $60 against $47 +
        // $17 fits.
        assertEq(r.netted, 2 * SCALE, "the overlap is netted");
        assertEq(h.bucketSize(true), 3 * SCALE, "3 units remain");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.insurance(), 94e18 - 15e18 - 60e18 - 0.1358e18, "the fund paid the netting and the rates");
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertEq(worstFinish, 8.55e18, "finishing 3 units at the band edge costs $8.55");
        assertEq(base, 3.8642e18, "against $3.8642 above the earmark");
        assertGt(worstFinish, base, "so the window stays open");
    }

    /// @notice Where the winning bucket is the smaller one, the fallback can close no more than
    ///         all of it, and closing it all retires the overlap and leaves nothing to net: the
    ///         long bucket of 2 goes whole at the mark and the losing short bucket of 10 stands
    ///         with no cohort, the window held open by it.
    function test_fallback_winningBucketSmaller_closesItWhole_netsNothing() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 190 * SCALE, 10 * SCALE, 0); // bankrupt at $95
        h.setBucket(false, 10 * SCALE, 700 * SCALE, 770 * SCALE, 70 * SCALE, 0); // shorts from $70, bankrupt at $77
        h.setVaultInsurance(117e18); // $37 above the earmarks
        h.setPosition(winner, false, 2 * SCALE, 220 * SCALE, 20 * SCALE);
        h.setOI(0, 2 * SCALE, 0, 220 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(97 * SCALE));

        assertEq(r.longBucket.closedSize, 2 * SCALE, "the whole long bucket at the mark");
        assertEq(r.longBucket.settlementPrice, 97 * SCALE, "at the mark");
        assertEq(r.netted, 0, "nothing left to net");
        assertEq(h.bucketSize(true), 0, "the long bucket is gone");
        assertEq(h.bucketSize(false), 10 * SCALE, "the short bucket stands");
        assertEq(h.positionCollateral(winner), 46 * SCALE, "credited (110 - 97) x 2");
        assertEq(h.claimable(address(this)), _rate(2 * SCALE, 97 * SCALE), "the rate on the closes");
        // $3 lost a unit at the mark, paid from the $10 earmark; the rest of it is freed.
        assertEq(h.insurance(), 117e18 - 6e18 - _rate(2 * SCALE, 97 * SCALE), "the gap to the mark and the rate");
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertGt(worstFinish, base, "the short bucket holds the window open");
    }

    /// @notice With a cohort for the losing bucket there is no fallback. The short leg runs first;
    ///         its 2 units are hedged by the long bucket, so they are sized as pairs with the long
    ///         cohort's: a pair closes a short unit at $73.50 and a long unit at the $97 mark, and
    ///         moves the release condition by the $23.50 between the two prices, less the 0.1% of
    ///         the $23.50 averted the short close pays and the 2 bp of $97 the long close pays, so
    ///         1.228 pairs cover the $28.80 gap to the release line. The short cohort pays the
    ///         short bucket's loss, the long cohort closes at market, and the fund moves only by the
    ///         earmarks. The long leg is held to the pairs and finds the release met. The netting
    ///         that ends the batch takes the short remainder at the fund's expense, which the legs
    ///         were not sized for, so the release can sit short of the line by the rate that
    ///         netting paid.
    function test_losingCohortPresent_noFallback_pairsWithTheLongCohort_remainderNetted() public {
        _heldBook(94e18);
        h.setPosition(ally, true, 2 * SCALE, 120 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 10 * SCALE, 120 * SCALE, 1100 * SCALE);
        uint256 closed = Math.mulDiv(28.800001e18, 2 * SCALE, 46.9142e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(97 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.shortBucket.closedSize, closed, "about 1.23 of the 2 units, in pairs, at the bankruptcy price");
        assertEq(r.shortBucket.settlementPrice, 73.5e18, "the short bucket's bankruptcy price");
        assertGe(r.longBucket.closedSize, closed, "the long leg is held to the pairs");
        assertApproxEqAbs(
            r.longBucket.closedSize, closed, ALLOWANCE, "and its own figure is the pairs' within the allowance"
        );
        assertEq(r.longBucket.settlementPrice, 97 * SCALE, "at the mark");
        assertEq(r.netted, 2 * SCALE - closed, "the end-of-batch netting takes the short remainder");
        assertEq(closes.length, 2, "one close per leg");
        assertEq(closes[0].user, ally, "the losing leg first");
        assertEq(closes[0].price, 73.5e18, "at the bankruptcy price");
        assertEq(closes[1].user, winner, "then the long leg");
        assertEq(closes[1].price, 97 * SCALE, "at the mark");
        assertEq(h.positionSize(ally), 2 * SCALE - closed, "ally keeps the rest");
        assertEq(h.positionSize(winner), 10 * SCALE - r.longBucket.closedSize, "the winner keeps the rest");
        assertEq(h.positionCollateral(ally), 20e18 + Math.mulDiv(closed, 13.5e18, SCALE), "credited (73.5 - 60) a unit");
        assertEq(
            h.positionCollateral(winner),
            100e18 + Math.mulDiv(r.longBucket.closedSize, 13e18, SCALE),
            "credited (110 - 97) a unit"
        );
        assertEq(
            h.bucketSize(true),
            10 * SCALE - r.longBucket.closedSize - r.netted,
            "the long bucket less the closes and the netting"
        );
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(
            h.claimable(address(this)),
            _share(closed, 97 * SCALE, 73.5e18) + _rate(r.longBucket.closedSize, 97 * SCALE)
                + _rate(r.netted, 97 * SCALE),
            "the averted share on the short closes, the rate on the long closes and on the netting"
        );
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertLe(worstFinish, base + _rate(r.netted, 97 * SCALE), "within the netting's rate of the release line");
    }

    /// @notice A short bucket above water at the mark is not a losing leg: it settles at the mark,
    ///         so no fallback runs and the long leg is sized by the ordinary restoring figure; the
    ///         netting that ends the batch then takes what the close left overlapping.
    ///         Long 10 @ $100 against $20 seized (bankrupt at $98) and short 2 @ $70 against $41
    ///         (bankrupt at $90.50), marked $90 with $10 free: finishing both at the $85.50 band
    ///         edge costs $115 — the long's $125 less the short's $10 of gain there — so the long
    ///         leg has $105 plus the allowance to cover. Its 8 units of excess repair $12.482 each
    ///         at $98, $99.856 in all; the 2 units the short bucket hedges have no cohort to pair
    ///         with and close alone, each repairing $3.482 — $98 against the $94.50 edge the short
    ///         bucket is finished at once a hedge is gone — so 1.477 of them cover the rest.
    function test_shortBucketAboveWater_isNotALosingLeg_longLegTakesTheRestoringFigure() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 980 * SCALE, 20 * SCALE, 0);
        h.setBucket(false, 2 * SCALE, 140 * SCALE, 181 * SCALE, 41 * SCALE, 0);
        h.setVaultInsurance(71e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
        uint256 ordinary = 8 * SCALE + Math.mulDiv(105.000001e18 - 99.856e18, SCALE, 3.482e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.shortBucket.settlementPrice, 90 * SCALE, "the short bucket settles at the mark");
        assertEq(r.longBucket.settlementPrice, 98 * SCALE, "the long at its bankruptcy price");
        assertEq(r.longBucket.closedSize, ordinary, "the ordinary sizing, not a fallback");
        assertEq(r.shortBucket.closedSize, 0, "no cohort for the short bucket");
        // The closes handed the fund the long earmark on 9.48 units; the $15.68 gap on the 0.52
        // units left overlapping fits against their $11.76 of seizure and the fund's free capital,
        // so the netting that ends the batch takes them.
        assertEq(r.netted, 10 * SCALE - ordinary, "the netting takes the long remainder");
        assertEq(h.bucketSize(true), 0, "the long bucket is gone");
        assertEq(h.bucketSize(false), 2 * SCALE - r.netted, "the short bucket keeps what the netting left");
        assertEq(h.deficit(), 0, "nothing went wrong");
    }

    /// @notice Negative control: one bucket the fund carries. Long 10 @ $100 against $50 seized,
    ///         $37 free, marked $97: finishing at the band edge costs $28.50, so the batch is sized
    ///         to zero and closes nothing, and the eligible winner keeps it from reverting.
    function test_oneBucket_fundCarriesIt_closesNothing() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setVaultInsurance(87e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "premise: the fund can finish the inventory at the band edge");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(97 * SCALE));

        assertEq(r.longBucket.eligibleSize, 10 * SCALE, "the winner is eligible");
        assertEq(r.longBucket.closedSize, 0, "but nothing is closed");
        assertEq(h.bucketSize(true), 10 * SCALE, "the inventory is untouched");
    }

    /// @notice The same with the bucket under water at the mark: long 10 @ $100 against $50
    ///         seized, marked $90 with $120 free against a $95 band-edge finish cost. Carried.
    function test_oneBucket_underWaterButCarried_closesNothing() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setVaultInsurance(170e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
        (, uint256 base, uint256 worstFinish,) = h.exposure(90 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "premise: the fund can finish the inventory at the band edge");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.closedSize, 0, "nothing is closed");
        assertEq(h.positionSize(winner), 10 * SCALE, "the winner keeps its position");
    }

    /// @notice The fallback's close settles at one price, the mark, and the batch's event reports
    ///         both legs: the long leg's size and price, the short bucket's settlement price with
    ///         nothing closed, and what the netting retired.
    function test_fallback_onePriceForTheClose_batchEventReportsBothLegs() public {
        _heldBook(94e18);

        vm.recordLogs();
        h.execAdl(_one(winner), _none(), _at(97 * SCALE));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        LoggedClose[] memory closes = _loggedCloses(logs);
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].size, 8 * SCALE, "for the whole sized leg");
        assertEq(closes[0].price, 97 * SCALE, "at the mark");
        LoggedBatch memory b = _loggedBatch(logs);
        assertEq(b.longClosed, 8 * SCALE, "the long leg's size");
        assertEq(b.longPrice, 97 * SCALE, "at the mark");
        assertEq(b.shortClosed, 0, "nothing closed off the short bucket");
        assertEq(b.shortPrice, 73.5e18, "whose bankruptcy price the batch still reports");
        assertEq(b.netted, 2 * SCALE, "the overlap netted");
    }

    // ---------------- the fallback against a bucket above water, with arrears ----------------

    /// @dev The long bucket is 10 @ $100, bankrupt at $91: $50 of the estates' $90 of collateral
    ///      was seized in cash and the ledger still owes the other $40. The short bucket is two
    ///      estates of 2 @ $80 against $5, 4 units bankrupt at $85, $100 under water at the $110
    ///      mark. The fund holds $11 above the earmarks. The long bucket is above water at the
    ///      mark and at the $104.50 band edge, so on its own it would close nothing; netting the
    ///      overlap loses the $20 a unit entry gap, $80, against $11 + $40 of arrears − $24 (the 6
    ///      survivors' share of the $40 the bankruptcy-priced close needs) + $30 of seizure on the
    ///      netted slices = $57: refused. The short winner, 10 @ $150, is in profit.
    function _aboveWaterBook() internal {
        h.setBucket(true, 10 * SCALE, 1_000 * SCALE, 910 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 4 * SCALE, 320 * SCALE, 340 * SCALE, 10 * SCALE, 0);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(71e18);
        h.setPosition(winner, false, 10 * SCALE, 1_500 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1_500 * SCALE);
    }

    /// @notice Above water, the inventory the netting leaves is counted at its bankruptcy-priced
    ///         close, $24 for the 6 survivors, rather than at its zero band-edge finish cost: the
    ///         netting's $50 beyond its own backing, its $0.088 rate, the $24 and the allowance,
    ///         less the $51 of free capital and arrears, is $23.09, and each unit closed at the
    ///         $110 mark covers $14.98 of it — $5 of earmark and $10 realized, less its 2 bp. The
    ///         leg closes that at the mark, the netting takes both estates, and the window
    ///         releases in one batch with the survivors still backed.
    function test_fallback_aboveWater_sizedOnTheSurvivorsBankruptcyPricedClose() public {
        _aboveWaterBook();
        assertFalse(h.overlapAffordable(110 * SCALE, 0), "premise: the netting is refused as the book stands");
        uint256 closed = Math.mulDiv(23.088001e18, 6 * SCALE, 89.868e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(110 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.longBucket.closedSize, closed, "about 1.54 units, sized on the bankruptcy-priced close");
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].price, 110 * SCALE, "at the mark: no haircut");
        assertEq(r.netted, 4 * SCALE, "the netting takes the overlap");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.bucketSize(true), 10 * SCALE - closed - 4 * SCALE, "the netting took its 4 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(110 * SCALE, 0);
        (, uint256 base, uint256 worstFinish,) = h.exposure(110 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @dev The fund can still close the inventory left at its bankruptcy prices without a deficit.
    function _assertSurvivorsBacked(uint256 mark, int256 idx) internal view {
        (uint256 backing, uint256 needed) = h.survivorBacking(mark, idx);
        assertGe(backing, needed, "the inventory left stays backed at its bankruptcy price");
    }

    /// @notice A leg that closes less than it planned leaves the netting gated on what it leaves.
    ///         On the same book the only winner holds 0.1 units, so the leg closes those at the
    ///         mark and stops short of the 1.54 units it planned; the netting, gated on the 9.9
    ///         units' $39.60 of need, is refused, and the fund still backs them at their
    ///         bankruptcy price. A batch whose winner covers the plan then nets.
    function test_fallback_shortLeg_leavesTheNettingForTheNextBatch_remainderStaysBacked() public {
        _aboveWaterBook();
        h.setPosition(winner, false, 0.1e18, 15 * SCALE, 1 * SCALE);
        h.setOI(0, 0.1e18, 0, 15 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(110 * SCALE));

        assertEq(r.longBucket.closedSize, 0.1e18, "the leg closes the small winner");
        assertEq(r.netted, 0, "the netting is refused");
        assertEq(h.bucketSize(false), 4 * SCALE, "the short bucket stands");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertFalse(h.overlapAffordable(110 * SCALE, 0), "still unaffordable");
        _assertSurvivorsBacked(110 * SCALE, 0);

        h.setPosition(winner, false, 10 * SCALE, 1_500 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1_500 * SCALE);
        r = h.execAdl(_one(winner), _none(), _at(110 * SCALE));

        assertEq(r.netted, 4 * SCALE, "the next batch nets");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(110 * SCALE, 0);
    }

    /// @notice The mirror: the short bucket 10 @ $100, bankrupt at $109, $50 seized and $40 in
    ///         arrears, marked $90; the long bucket 4 @ $120 against $10, bankrupt at $115; a long
    ///         winner from $50. Every figure mirrors except the rates at the $90 mark, so the leg
    ///         closes almost the same size at the mark and the netting takes both estates.
    function test_fallback_aboveWater_shortBucketMirror() public {
        h.setBucket(false, 10 * SCALE, 1_000 * SCALE, 1_090 * SCALE, 50 * SCALE, 0);
        h.setBucket(true, 4 * SCALE, 480 * SCALE, 460 * SCALE, 10 * SCALE, 0);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(71e18);
        h.setPosition(winner, true, 10 * SCALE, 500 * SCALE, 100 * SCALE);
        h.setOI(10 * SCALE, 0, 500 * SCALE, 0);
        uint256 closed = Math.mulDiv(23.072001e18, 6 * SCALE, 89.892e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(winner), _at(90 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.shortBucket.closedSize, closed, "the long book's close, at the $90 rates");
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].price, 90 * SCALE, "at the mark");
        assertEq(r.netted, 4 * SCALE, "the netting takes the overlap");
        assertEq(h.bucketSize(true), 0, "the long bucket is gone");
        assertEq(h.bucketSize(false), 10 * SCALE - closed - 4 * SCALE, "the netting took its 4 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(90 * SCALE, 0);
    }

    // ---------------- a netting the fund can afford as the batch begins ----------------

    /// @dev The long bucket is 10 @ $100 against $50 seized, bankrupt at $95, and has paid $3 a
    ///      unit of funding while held (the index is at 3, the estates entered at 0): closing it
    ///      at its bankruptcy price needs that $30 beyond the earmark. The short bucket is four
    ///      estates of 2 @ $90 against $15.50, entered at the live index: 8 units bankrupt at
    ///      $97.75, $196 under water at the $110 mark. Netting the overlap loses the $80 entry
    ///      gap plus the $24 of funding the long paid on it, $104, against the $102 of seizure on
    ///      the netted slices, the fund's $10 free and the 2 survivors' $6 share of the $30:
    ///      affordable as the book stands.
    function _netsAsItStandsBook() internal {
        h.setBucket(true, 10 * SCALE, 1_000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 8 * SCALE, 720 * SCALE, 782 * SCALE, 62 * SCALE, int256(3 * SCALE));
        h.setVaultInsurance(122e18);
        h.setPosition(winner, false, 10 * SCALE, 1_500 * SCALE, 100 * SCALE);
        h.setPositionFundingIndex(winner, int256(3 * SCALE));
        h.setOI(0, 10 * SCALE, 0, 1_500 * SCALE);
    }

    /// @notice When the fund can net the overlap as the book stands, the fallback sizes the leg
    ///         to zero and the netting that ends the batch takes it: 8 units off each bucket, the
    ///         $2 beyond the slices' own backing from free capital, and the executor paid the rate
    ///         on the 8 units. The eligible winner is not closed.
    function test_endOfBatchNetting_fundNetsAsItStands_closesNothing() public {
        _netsAsItStandsBook();
        (uint256 o, int256 pnl, uint256 seized) = h.overlap();
        assertEq(o, 8 * SCALE, "premise: the overlap");
        assertEq(pnl, -104e18, "premise: the entry gap and the funding offset");
        assertEq(seized, 102e18, "premise: the netted slices' seizure");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _atIndex(110 * SCALE, int256(3 * SCALE)));

        assertEq(r.longBucket.eligibleSize, 10 * SCALE, "the winner is eligible");
        assertEq(r.longBucket.closedSize, 0, "no winner is closed");
        assertEq(r.netted, 8 * SCALE, "the overlap is netted");
        assertEq(h.positionSize(winner), 10 * SCALE, "the winner keeps its position");
        _assertNettedAsItStands();
        assertEq(h.claimable(address(this)), _rate(8 * SCALE, 110 * SCALE), "the rate on the 8 units netted");
    }

    /// @dev The book above once the overlap is netted: the 2 units left keep $10 earmarked, and
    ///      the fund, $122 less the netting's $104 less the rate, holds $7.82 above that against
    ///      their $6 share of the bankruptcy-priced close.
    function _assertNettedAsItStands() internal view {
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.bucketSize(true), 2 * SCALE, "the 8 units came off the long bucket");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.insurance(), 122e18 - 104e18 - 0.176e18, "the fund after the netting and the rate");
        _assertSurvivorsBacked(110 * SCALE, int256(3 * SCALE));
        (, uint256 base, uint256 worstFinish,) = h.exposure(110 * SCALE, int256(3 * SCALE), 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice The netting needs no winner. With the only winner entered at $100, under water at
    ///         the $110 mark and so not eligible, the batch still nets the overlap and does not
    ///         revert.
    function test_endOfBatchNetting_fundNetsAsItStands_noEligibleWinner() public {
        _netsAsItStandsBook();
        h.setPosition(winner, false, 10 * SCALE, 1_000 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1_000 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _atIndex(110 * SCALE, int256(3 * SCALE)));

        assertEq(r.longBucket.eligibleSize, 0, "premise: no winner is eligible");
        assertEq(r.longBucket.closedSize, 0, "nothing closes");
        assertEq(r.netted, 8 * SCALE, "the overlap is netted");
        assertEq(h.positionSize(winner), 10 * SCALE, "the winner keeps its position");
        _assertNettedAsItStands();
    }

    /// @notice Nor does it need the long bucket's cohort: a caller submitting only a cohort for the
    ///         short bucket, here one with no position, reaches it too.
    function test_endOfBatchNetting_fundNetsAsItStands_shortCohortOnly() public {
        _netsAsItStandsBook();

        BazaarTypes.AdlResult memory r =
            h.execAdl(_none(), _one(makeAddr("flat")), _atIndex(110 * SCALE, int256(3 * SCALE)));

        assertEq(r.longBucket.closedSize, 0, "nothing closes");
        assertEq(r.shortBucket.closedSize, 0, "and nothing against the cohort");
        assertEq(r.netted, 8 * SCALE, "the overlap is netted");
        assertEq(h.positionSize(winner), 10 * SCALE, "the winner keeps its position");
        _assertNettedAsItStands();
    }

    // ---------------- both buckets under water ----------------

    /// @notice Both buckets under water and only the long bucket's cohort supplied: the larger
    ///         short bucket's leg runs first and does nothing, the long leg closes its bucket at
    ///         its $95 bankruptcy price — its units gain against the $94.50 edge the net-short
    ///         vault is measured at — and the short bucket stands as the inventory with its
    ///         window. No flip: the vault holds the short bucket, not a re-targeted inventory.
    function test_bothUnderWater_longBucketClosedAtItsBankruptcyPrice_shortBucketStands() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 12 * SCALE, 960 * SCALE, 970 * SCALE, 10 * SCALE, 0); // shorts from $80, bankrupt at $80.83
        h.setVaultInsurance(180e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.settlementPrice, 95 * SCALE, "the long bucket's bankruptcy price");
        assertEq(r.longBucket.closedSize, 10 * SCALE, "the whole long bucket");
        assertEq(r.shortBucket.settlementPrice, 80_833_333_333_333_333_333, "the short bucket's, rounded down");
        assertEq(r.shortBucket.closedSize, 0, "no cohort for the short bucket");
        assertEq(r.netted, 0, "nothing to net");
        assertEq(h.bucketSize(true), 0, "the long bucket is gone");
        assertEq(h.bucketSize(false), 12 * SCALE, "the short bucket is the inventory");
        assertEq(h.positionCollateral(winner), 250e18, "$100 plus 10 x (110 - 95)");
        // $5 a unit paid at $95, all of it earmark; 2 bp of the $900 closed at the mark, more than
        // 0.1% of the $50 averted.
        assertEq(h.claimable(address(this)), 0.18e18, "the rate on the close");
        assertEq(h.insurance(), 180e18 - 50e18 - 0.18e18, "the earmark out, the rate out");
        (, uint256 base, uint256 worstFinish,) = h.exposure(90 * SCALE, 0, 1_000);
        assertGt(worstFinish, base, "the short bucket holds the window open");
    }

    /// @notice Both buckets under water with both cohorts: both legs settle at their own
    ///         bankruptcy prices, the long leg first (equal sizes, both losing). Long 10 @ $100
    ///         against $50 (bankrupt at $95) and short 10 @ $80 against $100 (bankrupt at $90),
    ///         marked $93 with $10 free: finishing both at the $88.35 band edge costs $50. Every
    ///         unit is hedged by the other bucket, so the long leg sizes pairs with the short
    ///         cohort: a pair closes a long unit at $95 and a short unit at $90 and repairs the
    ///         $5 between them less the two rates, 2 bp of $93 each, $4.9628; 8.06 pairs cover
    ///         the $40 plus the allowance. The short leg is held to the pairs and its own figure
    ///         on what the long leg left agrees within the allowance. Each close pays its bucket's
    ///         earmark and no more; the overlap the pairs leave is netted at the end of the batch
    ///         only if the fund can then afford its $20 a unit against the slices' $15 of seizure
    ///         and its free capital, which this book leaves on the line.
    function test_bothUnderWater_bothLegsAtTheirBankruptcyPrices_longFirst() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 10 * SCALE, 800 * SCALE, 900 * SCALE, 100 * SCALE, 0);
        h.setVaultInsurance(160e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setPosition(ally, true, 10 * SCALE, 800 * SCALE, 100 * SCALE);
        h.setOI(10 * SCALE, 10 * SCALE, 800 * SCALE, 1100 * SCALE);
        uint256 longClosed = Math.mulDiv(40.000001e18, 10 * SCALE, 49.628e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(93 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.longBucket.settlementPrice, 95 * SCALE, "the long bucket's bankruptcy price");
        assertEq(r.shortBucket.settlementPrice, 90 * SCALE, "the short bucket's bankruptcy price");
        assertEq(r.longBucket.closedSize, longClosed, "about 8.06 units off the long bucket, as pairs");
        assertGe(r.shortBucket.closedSize, longClosed, "the short leg is held to the pairs");
        assertApproxEqAbs(
            r.shortBucket.closedSize, longClosed, ALLOWANCE, "and its own figure agrees within the allowance"
        );
        assertLt(r.shortBucket.closedSize, 10 * SCALE, "and not all of it");
        uint256 left = 10 * SCALE - r.shortBucket.closedSize;
        assertTrue(r.netted == 0 || r.netted == left, "the overlap left is netted whole or not at all");
        assertEq(closes.length, 2, "one close per leg");
        assertEq(closes[0].user, winner, "the long leg first");
        assertEq(closes[0].price, 95 * SCALE, "at $95");
        assertEq(closes[1].user, ally, "then the short leg");
        assertEq(closes[1].price, 90 * SCALE, "at $90");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        // $5 a unit at $95 and $10 a unit at $90, each the bucket's own earmark; $20 a unit on
        // whatever the netting took, its $15 of seizure first; the rates out.
        assertApproxEqAbs(
            h.insurance(),
            160e18 - Math.mulDiv(longClosed, 5e18, SCALE) - Math.mulDiv(r.shortBucket.closedSize, 10e18, SCALE)
                - Math.mulDiv(r.netted, 20e18, SCALE) - h.claimable(address(this)),
            1e3,
            "each close paid its earmark and no more"
        );
    }

    // ---------------- the restoring figure with a second bucket ----------------

    /// @notice The losing long leg takes the restoring figure on the vault as it stands and the
    ///         netting that ends the batch takes the overlap. Long 10 @ $100 against $90 seized
    ///         (bankrupt at $91) under a 20% target, and short 2 @ $80 against $4 (bankrupt at
    ///         $82), marked $90 with $6 above the $21.60 reserve: finishing both at the $85.50
    ///         band edge costs $62, so the leg closes $56 plus the allowance over the $7.282 each
    ///         unit at $91 repairs — $5.50 of finish cost and $1.80 of reserve, less 2 bp of $90.
    ///         The overlap's $40 gap then fits against the $28 of seizure on the netted slices
    ///         and the fund's free capital, and the window releases.
    function test_losingLongLeg_restoringFigure_thenTheEndOfBatchNettingTakesTheOverlap() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 910 * SCALE, 90 * SCALE, 0);
        h.setBucket(false, 2 * SCALE, 160 * SCALE, 164 * SCALE, 4 * SCALE, 0);
        h.setTargetRatio(2_000);
        h.setVaultInsurance(121.6e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 10 * SCALE, 200 * SCALE, 1100 * SCALE);
        uint256 closed = Math.mulDiv(56.000001e18, 10 * SCALE, 72.82e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.settlementPrice, 91 * SCALE, "the bankruptcy price");
        assertEq(r.longBucket.closedSize, closed, "about 7.69 units");
        assertEq(r.netted, 2 * SCALE, "the overlap is netted afterwards");
        assertEq(h.bucketSize(true), 10 * SCALE - closed - 2 * SCALE, "the netting took its 2 units off the remainder");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(
            h.claimable(address(this)),
            _rate(closed, 90 * SCALE) + _rate(2 * SCALE, 90 * SCALE),
            "2 bp of the close at the mark, more than 0.1% of the $1 averted, and the rate on the netting"
        );
        (, uint256 base, uint256 worstFinish,) = h.exposure(90 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice A close at the bankruptcy price spends the bucket's earmark and nothing else: with
    ///         $100 of arrears on the books and a winning short bucket outnumbering the long one,
    ///         the long leg closes its whole bucket at $95, pays $5 a unit from the $50 earmark,
    ///         and the arrears stay owed.
    function test_losingLeg_closeAtTheBankruptcyPrice_spendsTheEarmarkOnly_arrearsUntouched() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 950 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 12 * SCALE, 960 * SCALE, 970 * SCALE, 10 * SCALE, 0);
        h.setLedgerArrears(100 * SCALE);
        h.setTargetRatio(2_000);
        h.setVaultInsurance(61e18);
        h.setPosition(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(12 * SCALE, 10 * SCALE, 1200 * SCALE, 1100 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.closedSize, 10 * SCALE, "the whole long bucket");
        assertEq(r.longBucket.settlementPrice, 95 * SCALE, "at its bankruptcy price");
        assertEq(h.positionCollateral(winner), 250e18, "$15 a unit");
        assertEq(h.arrears(), 100e18, "the earmark paid the whole close: the arrears stay owed");
        assertEq(h.bucketSize(false), 12 * SCALE, "the short bucket stands");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.insurance(), 61e18 - 50e18 - 0.18e18, "the earmark out, the rate out");
    }

    /// @notice A winner at a loss at the bankruptcy price is skipped there, so the long leg closes
    ///         nothing, and the short bucket, settling at the mark, is no fallback: the fund spends
    ///         nothing. Long 10 @ $100 against $90 (bankrupt at $91) and short 2 @ $80 against $10
    ///         (bankrupt at $90), marked $90; the only winner is short 10 @ $90.50 — in profit at
    ///         the mark, at a loss at $91.
    function test_losingLeg_winnerUnderWaterAtTheBankruptcyPrice_closesNothing_fundSpendsNothing() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 910 * SCALE, 90 * SCALE, 0);
        h.setBucket(false, 2 * SCALE, 160 * SCALE, 180 * SCALE, 10 * SCALE, 0);
        h.setTargetRatio(2_000);
        h.setVaultInsurance(127.6e18);
        h.setPosition(winner, false, 10 * SCALE, 905 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 10 * SCALE, 200 * SCALE, 905 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.eligibleSize, 10 * SCALE, "the winner is eligible");
        assertEq(r.longBucket.closedSize, 0, "but nothing is closed");
        assertEq(r.shortBucket.settlementPrice, 90 * SCALE, "the short bucket settles at the mark: not a losing leg");
        assertEq(r.netted, 0, "the overlap stays unaffordable");
        assertEq(h.positionSize(winner), 10 * SCALE, "the winner keeps its position");
        assertEq(h.inventorySize(), 12 * SCALE, "both buckets are untouched");
        assertEq(h.insurance(), 127.6e18, "the fund spent nothing");
        assertEq(h.deficit(), 0, "nothing went unpaid");
    }

    // ---------------- both legs in one batch ----------------

    /// @dev The size the long leg closes on the shared setup below, and the score it ranks its
    ///      winner at. One long unit at $100 against a $10 fund, marked $90: finishing the unit at
    ///      the $85.50 band edge would cost $14.50 against $10 of capital, plus the rounding
    ///      allowance, and each unit closed repairs $14.482 of that: the $14.50 less the
    ///      executor's 2 bp of the $90 mark, more than 0.1% of the $10 averted. The score is the
    ///      winner's $60 of profit at the mark over its $10 of collateral.
    function _longLegClose() internal pure returns (uint256) {
        return Math.mulDiv(4.500001e18, SCALE, 14.482e18, Math.Rounding.Ceil);
    }

    uint256 internal constant LONG_LEG_SCORE = 6e18;

    /// @notice The long leg alone: the baseline the two-bucket batch below must reproduce.
    function test_bothLegs_longLegAlone_baseline() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setVaultInsurance(10e18);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(90 * SCALE));

        assertEq(r.longBucket.eligibleCount, 1, "the short winner is eligible");
        assertEq(r.longBucket.highestAdlScore, LONG_LEG_SCORE, "ranked at the mark");
        assertEq(r.longBucket.closedSize, _longLegClose(), "the batch cap bounds the close");
    }

    /// @notice An idle cohort on the short leg moves nothing on either leg. The short bucket's one
    ///         cohort member has no profit at the mark, so that leg admits nobody and closes
    ///         nothing; the long leg ranks and sizes on its own side and its own cohort — here a
    ///         whole unit, the short bucket's loss at the edge having widened the gap — and the
    ///         short bucket and its cohort are left exactly as staged.
    function test_bothLegs_idleShortCohort_movesNothingOnTheShortBucket() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 60 * SCALE, 70 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(20e18);
        h.setPosition(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setPosition(ally, true, 1 * SCALE, 100 * SCALE, 50 * SCALE); // -$10 at the $90 mark
        h.setOI(1 * SCALE, 1 * SCALE, 100 * SCALE, 150 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(90 * SCALE));

        assertEq(r.shortBucket.eligibleSize, 0, "the short cohort admits nobody");
        assertEq(r.shortBucket.closedSize, 0, "and closes nothing");
        assertEq(r.longBucket.highestAdlScore, LONG_LEG_SCORE, "the long leg ranks its own cohort at the mark");
        assertEq(r.longBucket.closedSize, 1 * SCALE, "and closes its bucket");
        assertEq(h.positionSize(ally), 1 * SCALE, "the idle cohort member is untouched");
        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.size, 1 * SCALE, "the short bucket is untouched");
        assertEq(s.entryNotional, 60 * SCALE, "entry");
        assertEq(s.bankruptcyNotional, 70 * SCALE, "bankruptcy notional");
        assertEq(s.seized, 10 * SCALE, "seizure");
        assertEq(r.netted, 0, "nothing netted");
    }

    /// @notice The mirror: an idle cohort on the long leg while the short leg closes. The long
    ///         bucket's cohort member has no profit at the mark; the short leg closes its bucket
    ///         against its own cohort at its bankruptcy price and the long bucket is untouched.
    function test_bothLegs_idleLongCohort_movesNothingOnTheLongBucket() public {
        h.setBucket(true, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, 0);
        h.setBucket(false, 1 * SCALE, 80 * SCALE, 90 * SCALE, 10 * SCALE, 0);
        h.setVaultInsurance(15e18);
        h.setPosition(winner, false, 1 * SCALE, 100 * SCALE, 50 * SCALE); // $0 at the $100 mark
        h.setPosition(ally, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 1 * SCALE, 80 * SCALE, 100 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(100 * SCALE));

        assertEq(r.longBucket.eligibleSize, 0, "the long cohort admits nobody");
        assertEq(r.longBucket.closedSize, 0, "and closes nothing");
        assertEq(r.shortBucket.closedSize, 1 * SCALE, "the short leg closes its bucket");
        assertEq(r.shortBucket.settlementPrice, 90 * SCALE, "at its bankruptcy price");
        assertEq(h.positionSize(winner), 1 * SCALE, "the idle cohort member is untouched");
        assertEq(h.bucketSize(true), 1 * SCALE, "the long bucket is untouched");
        assertEq(h.positionCollateral(ally), 20 * SCALE, "credited at $90");
    }

    // ---------------- the pairs rule: a small losing bucket hedged by the other ----------------

    /// @dev The long bucket is 10 @ $100 against $50 seized (bankrupt at $95), above water at the
    ///      $97 mark. The short bucket is 2 @ $90 against $6, bankrupt at $93: under water at the
    ///      mark, but its bankruptcy price lies INSIDE the 5% band, above the $92.15 edge the net-
    ///      long vault is measured at. Closing one of its units alone at $93 turns a hedged unit
    ///      into a long unit exposed at the edge and raises the finish cost by $0.85, so such
    ///      units are closed only in pairs with the long bucket's. `ally`, long 2 @ $80 on $20,
    ///      is the short bucket's cohort; the short winner, 10 @ $110, the long bucket's.
    function _hedgedBook(uint256 fund) internal {
        _heldBook(fund);
        h.setBucket(false, 2 * SCALE, 180 * SCALE, 186 * SCALE, 6 * SCALE, 0);
        h.setPosition(ally, true, 2 * SCALE, 160 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 10 * SCALE, 160 * SCALE, 1100 * SCALE);
    }

    /// @notice Pairs retire the overlap through winners, fund-neutral on the losing side. With
    ///         $20 free against a $26.80 band-edge finish cost, each pair — a short unit at $93
    ///         against `ally`, a long unit at $97 against the winner — repairs $3.9612: the $4 the
    ///         two legs take off the finish cost together less the two 2 bp rewards; 1.7167 pairs
    ///         cover the $6.80 gap. The losing leg runs first and the long leg is held to the same
    ///         size. The netting then takes the 0.2833 units of overlap left, and the long bucket
    ///         ends at exactly 8 units.
    function test_pairs_hedgedLosingBucket_closedInPairsWithTheOtherLeg_fundNeutral() public {
        _hedgedBook(76e18);
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertEq(base, 20e18, "premise: $20 free");
        assertEq(worstFinish, 26.8e18, "premise: $26.80 to finish at the edge");
        uint256 pairs = Math.mulDiv(6.800001e18, 2 * SCALE, 7.9224e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(97 * SCALE));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.shortBucket.closedSize, pairs, "about 1.72 short units at the bankruptcy price");
        assertEq(r.shortBucket.settlementPrice, 93 * SCALE, "the short bucket's bankruptcy price");
        assertEq(r.longBucket.closedSize, pairs, "the long leg is held to the same size");
        assertEq(r.longBucket.settlementPrice, 97 * SCALE, "at the mark");
        assertEq(closes.length, 2, "one close per leg");
        assertEq(closes[0].user, ally, "the losing leg first");
        assertEq(closes[1].user, winner, "then the winning leg");
        assertEq(r.netted, 2 * SCALE - pairs, "the netting takes the overlap left");
        assertEq(h.bucketSize(true), 8 * SCALE, "the long bucket is left with its excess");
        assertEq(h.bucketSize(false), 0, "the short bucket is gone");
        assertEq(h.positionCollateral(ally), 20e18 + Math.mulDiv(pairs, 13e18, SCALE), "credited (93 - 80) a unit");
        assertEq(h.positionCollateral(winner), 100e18 + Math.mulDiv(pairs, 13e18, SCALE), "credited (110 - 97) a unit");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        (, base, worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertLe(worstFinish, base + _rate(r.netted, 97 * SCALE), "within the netting's rate of the release line");
    }

    /// @notice Hedged units with no other cohort to pair with close nothing: alone they would
    ///         worsen the finish cost. With $2 free the netting is unaffordable too, so the batch
    ///         does nothing and returns quietly, its cohort having been eligible.
    function test_pairs_hedgedLosingBucketWithoutTheOtherCohort_closesNothing() public {
        _hedgedBook(58e18);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(97 * SCALE));

        assertEq(r.shortBucket.eligibleSize, 2 * SCALE, "the cohort is eligible");
        assertEq(r.shortBucket.closedSize, 0, "but closes nothing alone");
        assertEq(r.netted, 0, "and the netting is unaffordable");
        assertEq(h.inventorySize(), 12 * SCALE, "both buckets stand");
        assertEq(h.positionSize(ally), 2 * SCALE, "the cohort is untouched");
        assertEq(h.insurance(), 58e18, "the fund spent nothing");
    }

    /// @notice The same bucket is not hedged under a narrower band: at 2% the edge is $95.06, above
    ///         the short's $93 bankruptcy price, so each of its units closed alone takes $2.06 off
    ///         the finish cost less its 2 bp, and the leg closes 0.745 of them on its own to cover
    ///         the $1.52 gap.
    function test_pairs_bankruptcyPriceOutsideTheBand_losingBucketClosesAlone() public {
        _hedgedBook(58e18);
        BazaarTypes.AdlParams memory p = _at(97 * SCALE);
        p.marginRequirements.laggedMmrBp = 200;
        uint256 closed = Math.mulDiv(1.520001e18, 2 * SCALE, 4.0812e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), p);

        assertEq(r.shortBucket.closedSize, closed, "about 0.74 units alone");
        assertEq(r.shortBucket.settlementPrice, 93 * SCALE, "at the bankruptcy price");
        assertEq(r.netted, 0, "nothing netted");
        assertEq(h.bucketSize(false), 2 * SCALE - closed, "the rest of the short bucket stands");
        assertEq(h.bucketSize(true), 10 * SCALE, "the long bucket is untouched");
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 200);
        assertLe(worstFinish, base, "on the release line under the 2% band");
    }

    // ---------------- the netting gate and the survivors' arrears ----------------

    /// @notice The overlap's realization is fixed whatever the price: the gap between the two
    ///         buckets' entry bases on the overlap plus the offset between their entry clocks.
    ///         Long 10 @ $100 entered at index 0 and short 4 @ $87 entered at index 2: $13 a unit
    ///         of entry gap and $2 a unit the long has paid since, $60 on the 4 units, backed by
    ///         the $12 and $3 of seizure the netted slices carry.
    function test_overlap_realizationIsPriceIndependent_andCarriesTheEntryClockOffset() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 905 * SCALE, 30 * SCALE, 0);
        h.setBucket(false, 4 * SCALE, 348 * SCALE, 351 * SCALE, 3 * SCALE, int256(2 * SCALE));

        (uint256 o, int256 pnl, uint256 seized) = h.overlap();

        assertEq(o, 4 * SCALE, "the smaller bucket's size");
        assertEq(pnl, -60e18, "the entry gap and the funding offset, no price in it");
        assertEq(seized, 15e18, "the two netted slices' seizure");
    }

    /// @notice The netting gate keeps what the surviving inventory needs to close at its
    ///         bankruptcy price out of a netting's reach. Long 10 @ $100 against $30 of cash and
    ///         $65 of arrears, the vault having paid $2 a unit of funding while holding it, is
    ///         bankrupt at $90.50; closing it there needs $85 beyond its earmark — the $65 the
    ///         ledger never paid and the $20 of funding — $8.50 a unit. The fund holds nothing
    ///         above the earmarks. Netting the short bucket, 4 @ $87 against $3, loses $60 against
    ///         the netted slices' $15: $45 beyond its own backing.
    function test_nettingGate_keepsTheSurvivorsBankruptcyCloseBacked() public {
        h.setBucket(true, 10 * SCALE, 1000 * SCALE, 905 * SCALE, 30 * SCALE, 0);
        h.setBucket(false, 4 * SCALE, 348 * SCALE, 351 * SCALE, 3 * SCALE, int256(2 * SCALE));
        h.setLedgerArrears(65 * SCALE);
        h.setVaultInsurance(33e18);
        int256 idx = int256(2 * SCALE);

        // The 6 surviving units need $51, so $14 of the $65 is spendable: $29 with the netted
        // slices' own backing, short of the $60.
        assertFalse(h.overlapAffordable(90 * SCALE, idx), "refused with 6 units to keep backed");

        // A long bucket of 6 leaves 2 survivors: $17 to keep, $48 spendable, $63 with the slices'
        // own backing.
        h.setBucket(true, 6 * SCALE, 600 * SCALE, 543 * SCALE, 18 * SCALE, 0);
        h.setVaultInsurance(21e18);
        assertTrue(h.overlapAffordable(90 * SCALE, idx), "affordable with 2 units to keep backed");
    }

    /// @notice A losing leg's close spends its bucket's own arrears and books no deficit. Short
    ///         10 @ $100 against $142 of cash and $46 of arrears, the estates having received
    ///         $4.75 a unit before liquidation: bankrupt at $123.55, and closing a unit there needs
    ///         $4.60 beyond its earmark, its share of the arrears. Mark $123.56, no free capital.
    ///         The long bucket, 1 @ $142.56 against $3.04, is the estate whose netting the fund
    ///         could not afford. The long winner, 10 @ $90, takes the nine units the long bucket
    ///         does not hedge at $123.55, each paid from its own arrears and earmark. The tenth
    ///         stands: closed alone it would leave the long unit finished at the $117.38 edge for
    ///         less than the hedged pair's fixed loss, and the pair's $37.81 gap is beyond the
    ///         $21.84 the gate finds backing it, so the two buckets stand as a pair.
    function test_losingLeg_closeConsumesItsOwnArrears_noDeficit() public {
        h.setBucket(false, 10 * SCALE, 1000 * SCALE, 1235.5e18, 142e18, 0);
        h.setBucket(true, 1 * SCALE, 142.56e18, 139.52e18, 3.04e18, 4.75e18);
        h.setLedgerArrears(46e18);
        h.setVaultInsurance(145.04e18);
        h.setPosition(winner, true, 10 * SCALE, 900 * SCALE, 100 * SCALE);
        h.setPositionFundingIndex(winner, 4.75e18);
        h.setOI(10 * SCALE, 0, 900 * SCALE, 0);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(winner), _atIndex(123.56e18, 4.75e18));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.shortBucket.settlementPrice, 123.55e18, "the bankruptcy price");
        assertEq(r.shortBucket.closedSize, 9 * SCALE, "the nine units the long bucket does not hedge");
        uint256 closed;
        for (uint256 i = 0; i < closes.length; i++) {
            assertEq(closes[i].price, 123.55e18, "every close at the bankruptcy price");
            closed += closes[i].size;
        }
        assertEq(closed, 9 * SCALE, "all of it against the winner");
        assertEq(r.netted, 0, "the pair's gap is beyond what backs it");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 4.6e18, "the closes consumed their own arrears, the hedged unit keeps its $4.60");
        assertEq(h.bucketSize(false), 1 * SCALE, "the hedged short unit stands");
        assertEq(h.bucketSize(true), 1 * SCALE, "the long bucket stands");
        // $169.20 paid at $123.55: $41.40 by netting the arrears, $127.80 the earmark. What is
        // left in the fund is the two buckets' earmarks, so nothing is free to pay the executor.
        assertEq(h.claimable(address(this)), 0, "no free capital for a reward");
        assertEq(h.insurance(), 17.24e18, "the fund paid nothing past its backing");
    }

    // ---------------- a netting's loss and the arrears the inventory it leaves needs ----------------

    /// @dev The long bucket is 10 @ $100, bankrupt at $91: $50 of the estates' $90 of collateral
    ///      was seized in cash and the ledger still owes the other $40, exactly what closing the
    ///      bucket at its bankruptcy price needs beyond its earmark. The fund holds $10 above the
    ///      earmark under a 30% target, whose reserve on the book's 10 units exceeds it at every
    ///      mark staged here, so the netting gate reads the arrears alone. The 10 units of shorts
    ///      are the loser's 2 from `entry` against no collateral and the winner's 8.
    /// @param entry The loser's entry price
    function _nettingBelowTheReserveSetup(uint256 entry) internal {
        h.setBucket(true, 10 * SCALE, 1_000 * SCALE, 910 * SCALE, 50 * SCALE, 0);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(60e18);
        h.setTargetRatio(3_000);
        h.setPosition(loser, false, 2 * SCALE, 2 * entry, 0);
        h.setPosition(winner, false, 8 * SCALE, 1_200 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 2 * entry + 1_200 * SCALE);
    }

    /// @notice A netting the gate passes leaves the inventory it does not net backed as the gate
    ///         reads it. The short, marked $95, loses its $15 entry gap netting 2 units: the gate
    ///         passes it on the $8 of arrears beyond the 8 survivors' $32 and the $10 earmark on
    ///         the overlap. The earmark pays the first $10 into the ledger and the arrears the
    ///         other $5, so they end at $35: the survivors' $32 and $3 the netted units were owed.
    ///         Paid net of the arrears first, they would end at $25 with the whole earmark in free
    ///         capital under the reserve, where the gate does not read it, and the survivors
    ///         would read $7 short with the fund holding the same value.
    function test_nettingBelowTheReserve_backedSurvivorsStayBacked() public {
        _nettingBelowTheReserveSetup(92.5e18);
        (uint256 backingBefore, uint256 neededBefore) = h.survivorBacking(95 * SCALE, 0);
        assertEq(backingBefore, 40e18, "premise: the gate reads the arrears alone");
        assertEq(neededBefore, 40e18, "premise: the inventory is backed as the gate reads it");

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser, 95 * SCALE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.bucketSize(false), 0, "and netted whole against the long bucket");
        assertEq(h.bucketSize(true), 8 * SCALE, "which keeps 8 of its 10 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 35e18, "the earmark paid first; the arrears the $5 beyond it");
        assertEq(h.vaultCollateral(), 1_010e18, "the earmark paid $10 into the ledger");
        assertEq(h.freeCapital(), 9.95e18, "nothing of the earmark freed; the $0.05 reward paid");
        (uint256 backing, uint256 needed) = h.survivorBacking(95 * SCALE, 0);
        assertEq(needed, 32e18, "the 8 units' bankruptcy-priced close");
        assertEq(backing, 35e18, "still backed as the gate reads them");
    }

    /// @notice A netting the gate passes opens no window the inventory did not already call for.
    ///         At a $91.50 mark the inventory is $5 above water counting its earmark and the
    ///         arrears, and the fund holds nothing above its reserve: no window. The short from
    ///         $91.20 loses $17.60, within the $8 of spare arrears and the $10 earmark the gate
    ///         counts. Paid from the earmark first and then $7.60 of the arrears, it leaves the 8
    ///         units $32.40 of them, $4.40 above water. Paid net of the arrears first, they would
    ///         read $5.60 under water, with the earmark sitting below the reserve, and the ADL
    ///         gate would open a window.
    function test_nettingBelowTheReserve_opensNoWindow() public {
        _nettingBelowTheReserveSetup(91.2e18);
        (uint256 lossBefore, uint256 baseBefore,,) = h.exposure(91.5e18, 0, 1_000);
        assertEq(lossBefore, 0, "premise: no loss at the mark");
        assertEq(baseBefore, 0, "premise: nothing above the reserve");

        h.liquidate(loser, 91.5e18, 0);

        assertEq(h.bucketSize(true), 8 * SCALE, "netted");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 32.4e18, "the arrears paid only what the earmark did not");
        (uint256 loss, uint256 base,,) = h.exposure(91.5e18, 0, 1_000);
        assertEq(base, 0, "still nothing above the reserve");
        assertEq(loss, 0, "and no loss at the mark: no window");
    }

    /// @notice A netting that leaves no inventory pays in the same order, and the arrears it does
    ///         not reach stay owed: nothing open relies on them, and a later loss nets them or
    ///         finalize collects them. The long bucket is 2 @ $100, bankrupt at $91, $10 of the
    ///         estates' $18 seized in cash and $8 owed; the short, 2 @ $92.50 against nothing,
    ///         loses $15 netting the whole bucket. The earmark pays the first $10, the arrears the
    ///         other $5, and $3 of them stay owed.
    function test_nettingThatEmptiesBothBuckets_spendsItsSeizureFirst() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 182 * SCALE, 10 * SCALE, 0);
        h.setLedgerArrears(8 * SCALE);
        h.setVaultInsurance(20e18);
        h.setTargetRatio(3_000);
        h.setPosition(loser, false, 2 * SCALE, 185 * SCALE, 0);
        h.setOI(0, 2 * SCALE, 0, 185 * SCALE);

        h.liquidate(loser, 95 * SCALE, 0);

        assertEq(h.inventorySize(), 0, "both buckets netted away");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 3e18, "$5 of the arrears netted, $3 still owed");
        assertEq(h.vaultCollateral(), 1_010e18, "the earmark paid $10 into the ledger");
        assertEq(h.insurance(), 9.95e18, "the fund's $10, less the $0.05 reward");
    }

    /// @notice A netting larger than the opposite bucket keeps the arrears the estate's remainder
    ///         needs once it is a bucket. The long bucket is 2 @ $100, bankrupt at $91, $10 seized
    ///         in cash and $8 owed, and the fund holds $2 above the earmark under a reserve of
    ///         over $37. The short, 5 @ $90 against $20 and marked $95, is seized from a ledger
    ///         holding $5, so $15 joins the arrears. Netting 2 of its units against the long
    ///         bucket loses the $20 entry gap, which the gate passes on the $8 of arrears, the $10
    ///         earmark and the netted $2 of the estate's cash. Its other 3 units are the short
    ///         bucket, bankrupt at $94, and closing them there needs the $9 of the estate's unpaid
    ///         collateral that rides on them. The loss is paid from the $12 of netted seizure
    ///         first, then $8 of the $23 of arrears, which end at $15: that $9 and the $6 of
    ///         unpaid collateral the netted units carried. Paid net of the arrears first, $3
    ///         would be left.
    function test_netting_estateLargerThanTheBucket_remainderKeepsItsArrears() public {
        h.setBucket(true, 2 * SCALE, 200 * SCALE, 182 * SCALE, 10 * SCALE, 0);
        h.setLedgerArrears(8 * SCALE);
        h.setVaultInsurance(12e18);
        h.setVaultCollateral(5e18);
        h.setTargetRatio(3_000);
        h.setPosition(loser, false, 5 * SCALE, 450 * SCALE, 20 * SCALE);
        h.setOI(13 * SCALE, 15 * SCALE, 1_300 * SCALE, 1_450 * SCALE);

        h.liquidate(loser, 95 * SCALE, 0);

        assertEq(h.bucketSize(true), 0, "the long bucket is netted away");
        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.size, 3 * SCALE, "the estate's remainder is the short bucket");
        assertEq(s.entryNotional, 270 * SCALE, "at its entry");
        assertEq(s.bankruptcyNotional, 282 * SCALE, "bankrupt at $94");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 15e18, "the short bucket's $9 and the netted units' $6 kept");
        (uint256 backing, uint256 needed) = h.survivorBacking(95 * SCALE, 0);
        assertEq(needed, 9e18, "what the short bucket needs to close at its bankruptcy price");
        assertEq(backing, 15e18, "backed as the gate reads it");
    }

    /// @dev One netting book for the fuzz below, every figure in whole dollars or units.
    struct NettingCase {
        bool shortInventory;
        bool vaultReceives;
        uint256 size;
        uint256 bankruptcyGap;
        uint256 cash;
        uint256 orphan;
        uint256 holdingFunding;
        uint256 accountSize;
        uint256 entryGap;
        uint256 accountFunding;
        uint256 lossAtMark;
        uint256 collateral;
        uint256 ledger;
        uint256 free;
        uint256 target;
        uint256 trailingOi;
    }

    /// @dev Bounds and stages `c`. The vault holds one bucket of 2 to 20 units entered at $100 and
    ///      bankrupt $1 to $20 past that, their collateral split between cash seized and arrears
    ///      owed, up to $20 more of arrears an earlier inventory left behind, and up to $3 a unit
    ///      of funding paid or received holding them. The loser holds 1 to 25 units on the other
    ///      side, entered $1 to $25 past the bucket's entry at an index up to $3 a unit either
    ///      side of the live one, and marked $1 to $20 against its entry on less collateral than
    ///      that loss; the ledger it is seized from holds up to $10 more than its collateral, or
    ///      less. The fund holds up to $60 above the earmark under a target of up to 30%, open
    ///      interest balances, and the reserve is sized on live open interest or a trailing
    ///      reading below it.
    /// @param c The case to bound and stage
    /// @return mark The mark the book is staged at
    /// @return idx The live funding index
    /// @return moved What the netting moves the fund's balance and arrears by: the account's
    ///         collateral plus the netting's realization, a loss or a gain
    function _stageNetting(NettingCase memory c) internal returns (uint256 mark, int256 idx, int256 moved) {
        c.size = bound(c.size, 2, 20);
        c.bankruptcyGap = bound(c.bankruptcyGap, 1, 20);
        c.cash = bound(c.cash, 0, c.size * c.bankruptcyGap);
        c.holdingFunding = bound(c.holdingFunding, 0, 3);
        c.accountSize = bound(c.accountSize, 1, 25);
        c.entryGap = bound(c.entryGap, 1, 25);
        c.lossAtMark = bound(c.lossAtMark, 1, 20);
        c.collateral = bound(c.collateral, 0, c.accountSize * c.lossAtMark - 1);
        // A long bucket pays funding while the index rises, a short one while it falls.
        idx = int256(c.holdingFunding * SCALE);
        if (c.shortInventory != c.vaultReceives) idx = -idx;
        int256 accountIdx = idx + (int256(bound(c.accountFunding, 0, 6)) - 3) * int256(SCALE);
        uint256 entry;
        if (c.shortInventory) {
            entry = 100 + c.entryGap;
            mark = (entry - c.lossAtMark) * SCALE;
            h.setBucket(
                false, c.size * SCALE, c.size * 100 * SCALE, c.size * (100 + c.bankruptcyGap) * SCALE, c.cash * SCALE, 0
            );
            h.setOI(
                (c.accountSize + c.size) * SCALE,
                c.accountSize * SCALE,
                (c.accountSize * entry + c.size * 100) * SCALE,
                c.accountSize * 100 * SCALE
            );
        } else {
            entry = 100 - c.entryGap;
            mark = (entry + c.lossAtMark) * SCALE;
            h.setBucket(
                true, c.size * SCALE, c.size * 100 * SCALE, c.size * (100 - c.bankruptcyGap) * SCALE, c.cash * SCALE, 0
            );
            h.setOI(
                c.accountSize * SCALE,
                (c.accountSize + c.size) * SCALE,
                c.accountSize * 100 * SCALE,
                (c.accountSize * entry + c.size * 100) * SCALE
            );
        }
        h.setLedgerArrears((c.size * c.bankruptcyGap - c.cash + bound(c.orphan, 0, 20)) * SCALE);
        h.setPosition(
            loser, c.shortInventory, c.accountSize * SCALE, c.accountSize * entry * SCALE, c.collateral * SCALE
        );
        h.setPositionFundingIndex(loser, accountIdx);
        h.setVaultCollateral(bound(c.ledger, 0, c.collateral + 10) * SCALE);
        h.setVaultInsurance((c.cash + bound(c.free, 0, 60)) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setTrailingOi(uint128(bound(c.trailingOi, 0, c.accountSize + c.size) * SCALE));
        // The realization RiskParamsLib.overlap books on the netted size: the entry gap, plus the
        // two sides' entry-clock offset, the bucket having entered at index 0.
        uint256 netted = c.size < c.accountSize ? c.size : c.accountSize;
        int256 funding = -accountIdx * int256(netted);
        moved = int256(c.collateral * SCALE) - int256(netted * c.entryGap * SCALE)
            + (c.shortInventory ? -funding : funding);
    }

    /// @dev The seizure the netting of the loser's estate against the bucket would release — the
    ///      bucket's earmark and the loser's seized cash, each pro rata on the overlap and rounded
    ///      as RiskParamsLib.overlap rounds them — and what the ledger cannot pay of the loser's
    ///      collateral, which the seizure adds to the arrears.
    /// @return seizure The seizure the netting releases
    /// @return unpaid The part of the loser's collateral the seizure adds to the arrears
    function _nettedSeizure() internal view returns (uint256 seizure, uint256 unpaid) {
        uint256 inventory = h.inventorySize();
        uint256 account = h.positionSize(loser);
        uint256 netted = inventory < account ? inventory : account;
        uint256 collateral = h.positionCollateral(loser);
        uint256 ledger = h.vaultCollateral();
        uint256 paid = collateral < ledger ? collateral : ledger;
        seizure = Math.mulDiv(h.insurance() - h.freeCapital(), netted, inventory) + Math.mulDiv(paid, netted, account);
        unpaid = collateral - paid;
    }

    /// @notice Across both sides, the earmark's split between cash and arrears, arrears an earlier
    ///         inventory left, funding the vault paid or received holding the bucket, estates with
    ///         funding of their own, estates smaller than the bucket, as large and larger, ledgers
    ///         too thin to pay a seizure, and reserves above and below free capital, sized on live
    ///         or trailing open interest: every insolvent estate is seized; one whose netting the
    ///         gate refuses stands in its own bucket at no cost beyond the flat reward; a netting
    ///         the gate passes books no deficit, moves the fund's balance plus arrears by exactly
    ///         the estate's collateral plus the netting's realization, conserves cash, nets the
    ///         arrears by no more than its loss exceeds the seizure it releases, and leaves
    ///         whatever inventory remains reading, with the reward paid back, no less than the
    ///         smaller of the gate's reading before and what that inventory needs to close at its
    ///         bankruptcy price. An estate its own funding keeps solvent is left alone.
    /// @param c The book, bounded and staged by _stageNetting
    function testFuzz_netting_spendsOnlyWhatTheGateLetsIt(NettingCase memory c) public {
        (uint256 mark, int256 idx, int256 moved) = _stageNetting(c);
        (uint256 backingBefore,) = h.survivorBacking(mark, idx);
        uint256 value = h.insurance() + h.arrears();
        uint256 cash = h.insurance() + h.vaultCollateral();
        uint256 collateral = h.positionCollateral(loser);
        // The seizure adds the unpaid part of the loser's collateral to the arrears before the
        // netting pays, so the arrears the payment starts from are those plus that.
        (uint256 ownCash, uint256 unpaid) = _nettedSeizure();
        uint256 arrearsBefore = h.arrears() + unpaid;
        int256 realized = moved - int256(collateral);

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser, mark, idx);

        if (r.liquidatedCount == 0) return; // solvent by its own funding
        assertEq(h.positionSize(loser), 0, "an insolvent estate is always seized");
        bool netted = h.bucketSize(true) == 0 || h.bucketSize(false) == 0;
        if (!netted) {
            assertFalse(h.overlapAffordable(mark, idx), "both buckets stand only when the gate refuses");
            assertEq(h.deficit(), 0, "a seizure into a bucket realizes nothing");
            assertEq(h.insurance() + h.claimable(address(this)) + h.arrears(), value + collateral, "cash in");
            return;
        }
        if (realized < 0) {
            uint256 excess = uint256(-realized) > ownCash ? uint256(-realized) - ownCash : 0;
            assertGe(
                h.arrears() + NETTING_ROUNDING,
                arrearsBefore > excess ? arrearsBefore - excess : 0,
                "the arrears pay only what the netted seizure does not"
            );
        }
        uint256 paid = h.claimable(address(this));
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(int256(h.insurance() + h.arrears() + paid), int256(value) + moved, "the netting alone moves the fund");
        assertEq(h.insurance() + h.vaultCollateral() + paid, cash, "cash is conserved");
        (uint256 backing, uint256 needed) = h.survivorBacking(mark, idx);
        assertGe(
            backing + paid + NETTING_ROUNDING,
            Math.min(backingBefore, needed),
            "the inventory left keeps its backing as the gate reads it"
        );
    }

    // ---------------- a close's loss and the arrears the inventory it leaves keeps ----------------

    /// @notice An inventory close at the bankruptcy price leaves the units it does not close their
    ///         arrears. The long bucket is 10 @ $100, bankrupt at $91: $50 of the estates' $90
    ///         seized in cash and $40 owed, what closing it at its bankruptcy price needs beyond
    ///         its earmark. The fund holds $10 above the earmark under a reserve of about $27, and
    ///         the $89 mark puts the bucket under water. The batch closes the 2-unit winner at $91,
    ///         an $18 loss: its $10 of earmark and its $8 share of the arrears. The 8 units left
    ///         keep $32, their need and their share alike, and the gate reads them backed. Netted
    ///         from the arrears first, they would keep $22 while the earmark sat in free capital
    ///         under the reserve.
    function test_adlClose_belowTheReserve_inventoryLeftKeepsItsArrears() public {
        h.setBucket(true, 10 * SCALE, 1_000 * SCALE, 910 * SCALE, 50 * SCALE, 0);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(60e18);
        h.setTargetRatio(3_000);
        h.setPosition(winner, false, 2 * SCALE, 300 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1_100 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(89 * SCALE));

        assertEq(r.longBucket.settlementPrice, 91 * SCALE, "settled at the bankruptcy price");
        assertEq(r.longBucket.closedSize, 2 * SCALE, "the winner's 2 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 32e18, "the 8 units keep their $32");
        (uint256 backing, uint256 needed) = h.survivorBacking(89 * SCALE, 0);
        assertEq(needed, 32e18, "their bankruptcy-priced close");
        assertEq(backing, 32e18, "backed as the gate reads them");
    }

    /// @notice A losing leg's close spends its own bucket's arrears and none of the other
    ///         bucket's. The long bucket is 10 @ $100, bankrupt at $91, $50 seized and $40 owed.
    ///         The short bucket, 2 @ $80 on $5, was seized from a ledger holding $3, so $2 more is
    ///         owed; bankrupt at $82.50, it is $15 past its collateral at the $90 mark. Its cohort,
    ///         a long from $70, closes it at $82.50, a $5 loss: its $3 of seizure and its own $2 of
    ///         arrears. The arrears end at the long bucket's $40. Netted from the arrears first,
    ///         the loss would have taken $3 of the long bucket's while the short's seizure joined
    ///         free capital.
    function test_losingLeg_closeSpendsItsOwnArrears_theOtherBucketsStay() public {
        h.setBucket(true, 10 * SCALE, 1_000 * SCALE, 910 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 2 * SCALE, 160 * SCALE, 165 * SCALE, 3 * SCALE, 0);
        h.setLedgerArrears(42 * SCALE);
        h.setVaultInsurance(63e18);
        h.setVaultCollateral(0);
        h.setTargetRatio(3_000);
        h.setPosition(ally, true, 2 * SCALE, 140 * SCALE, 10 * SCALE);
        h.setOI(2 * SCALE, 10 * SCALE, 140 * SCALE, 1_000 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(ally), _at(90 * SCALE));

        assertEq(r.shortBucket.closedSize, 2 * SCALE, "the short bucket closed against its cohort");
        assertEq(r.shortBucket.settlementPrice, 82.5e18, "at its bankruptcy price");
        assertEq(h.positionCollateral(ally), 35e18, "credited at $82.50");
        assertEq(h.bucketSize(true), 10 * SCALE, "the long bucket untouched");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 40e18, "the long bucket's arrears untouched");
    }

    /// @dev One inventory-leg book for the fuzz below, every figure in whole dollars or units.
    struct CloseCase {
        bool shortInventory;
        bool vaultReceives;
        uint256 size;
        uint256 bankruptcyGap;
        uint256 cash;
        uint256 leftover;
        uint256 holdingFunding;
        uint256 markOffset;
        uint256 winnerSize;
        uint256 free;
        uint256 target;
        uint256 trailingOi;
    }

    /// @dev Bounds and stages `c`. The vault holds one bucket of 2 to 20 units entered at $100 and
    ///      bankrupt $1 to $20 past that, their collateral split between cash seized and arrears
    ///      owed, up to $20 more of arrears an earlier inventory left, and up to $3 a unit of
    ///      funding paid or received holding them. The mark sits from $15 past the bankruptcy
    ///      price, where the bucket is under water and closes there, to $10 short of it, where it
    ///      closes at the mark. The winner, 1 unit up to the bucket's size, is in profit at every
    ///      price staged. The fund holds up to $60 above the earmark under a target of up to 30%,
    ///      and the reserve is sized on live open interest or a trailing reading below it.
    /// @param c The case to bound and stage
    /// @return mark The mark the book is staged at
    /// @return idx The live funding index
    function _stageClose(CloseCase memory c) internal returns (uint256 mark, int256 idx) {
        c.size = bound(c.size, 2, 20);
        c.bankruptcyGap = bound(c.bankruptcyGap, 1, 20);
        c.cash = bound(c.cash, 0, c.size * c.bankruptcyGap);
        c.holdingFunding = bound(c.holdingFunding, 0, 3);
        c.winnerSize = bound(c.winnerSize, 1, c.size);
        c.markOffset = bound(c.markOffset, 0, 25);
        // A long bucket pays funding while the index rises, a short one while it falls.
        idx = int256(c.holdingFunding * SCALE);
        if (c.shortInventory != c.vaultReceives) idx = -idx;
        uint256 others = c.size - c.winnerSize;
        if (c.shortInventory) {
            uint256 bk = 100 + c.bankruptcyGap;
            mark = (bk + 15 - c.markOffset) * SCALE;
            h.setBucket(false, c.size * SCALE, c.size * 100 * SCALE, c.size * bk * SCALE, c.cash * SCALE, 0);
            h.setPosition(winner, true, c.winnerSize * SCALE, c.winnerSize * 50 * SCALE, 100 * SCALE);
            h.setOI(c.size * SCALE, 0, (c.winnerSize * 50 + others * 100) * SCALE, 0);
        } else {
            uint256 bk = 100 - c.bankruptcyGap;
            mark = (bk - 15 + c.markOffset) * SCALE;
            h.setBucket(true, c.size * SCALE, c.size * 100 * SCALE, c.size * bk * SCALE, c.cash * SCALE, 0);
            h.setPosition(winner, false, c.winnerSize * SCALE, c.winnerSize * 150 * SCALE, 100 * SCALE);
            h.setOI(0, c.size * SCALE, 0, (c.winnerSize * 150 + others * 100) * SCALE);
        }
        h.setLedgerArrears((c.size * c.bankruptcyGap - c.cash + bound(c.leftover, 0, 20)) * SCALE);
        h.setPositionFundingIndex(winner, idx);
        h.setVaultInsurance((c.cash + bound(c.free, 0, 60)) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setTrailingOi(uint128(bound(c.trailingOi, 0, c.size) * SCALE));
    }

    /// @notice Across both sides, the earmark's split between cash and arrears, arrears an earlier
    ///         inventory left, funding the vault paid or received, marks either side of the
    ///         bankruptcy price, winners of any size up to the bucket's, and reserves either side
    ///         of free capital: a batch conserves cash and never leaves the arrears further short
    ///         of what the inventory left needs at its bankruptcy price than they were of the
    ///         whole bucket's need. Where they covered that need, the batch books no deficit and
    ///         the inventory left keeps at least its pro-rata share of the arrears, so the netting
    ///         gate still reads it backed and the ADL gate reads it no worse per unit.
    /// @param c The book, bounded and staged by _stageClose
    function testFuzz_adlClose_inventoryLeftKeepsItsArrears(CloseCase memory c) public {
        (uint256 mark, int256 idx) = _stageClose(c);
        (, uint256 needBefore) = h.survivorBacking(mark, idx);
        uint256 arrearsBefore = h.arrears();
        uint256 sizeBefore = h.inventorySize();
        uint256 cash = h.insurance() + h.vaultCollateral();

        if (c.shortInventory) h.execAdl(_none(), _one(winner), _atIndex(mark, idx));
        else h.execAdl(_one(winner), _none(), _atIndex(mark, idx));

        assertEq(h.insurance() + h.vaultCollateral() + h.claimable(address(this)), cash, "cash is conserved");
        (, uint256 needAfter) = h.survivorBacking(mark, idx);
        uint256 arrearsAfter = h.arrears();
        uint256 shortBefore = needBefore > arrearsBefore ? needBefore - arrearsBefore : 0;
        uint256 shortAfter = needAfter > arrearsAfter ? needAfter - arrearsAfter : 0;
        assertLe(shortAfter, shortBefore + NETTING_ROUNDING, "the arrears fall no further short of the need");
        if (arrearsBefore >= needBefore) {
            assertEq(h.deficit(), 0, "nothing went unpaid");
            assertGe(
                arrearsAfter + NETTING_ROUNDING,
                Math.mulDiv(arrearsBefore, h.inventorySize(), sizeBefore),
                "the inventory left keeps its share of the arrears"
            );
        }
    }

    // ---------------- two buckets, one batch ----------------

    /// @dev One two-bucket book for the fuzz below, every figure in whole dollars or units.
    struct TwoBucketCase {
        uint256 longSize;
        uint256 longGap;
        uint256 longCash;
        uint256 shortSize;
        uint256 shortEntry;
        uint256 shortGap;
        uint256 shortCash;
        uint256 orphan;
        uint256 mark;
        uint256 shortWinner;
        uint256 longWinner;
        uint256 free;
        uint256 target;
        uint256 trailing;
    }

    /// @dev Bounds and stages `c`. The long bucket holds 1 to 20 units entered at $100 and bankrupt
    ///      $1 to $20 below; the short bucket 1 to 20 units entered at $60 to $140 and bankrupt $1
    ///      to $20 above; each bucket's collateral is split between cash seized and arrears owed,
    ///      with up to $20 more of arrears an earlier inventory left. The mark runs from $70 to
    ///      $130, either bucket above or under water at it. The short winner, 1 to 25 units from
    ///      $150, and the long winner, 1 to 25 units from $50, are in profit at every mark. The
    ///      fund holds up to $200 above the earmarks under a target of up to 30%, and the reserve
    ///      is sized on live open interest or a trailing reading below it.
    /// @param c The case to bound and stage
    /// @return mark The mark the book is staged at
    function _stageTwoBuckets(TwoBucketCase memory c) internal returns (uint256 mark) {
        c.longSize = bound(c.longSize, 1, 20);
        c.longGap = bound(c.longGap, 1, 20);
        c.longCash = bound(c.longCash, 0, c.longSize * c.longGap);
        c.shortSize = bound(c.shortSize, 1, 20);
        c.shortEntry = bound(c.shortEntry, 60, 140);
        c.shortGap = bound(c.shortGap, 1, 20);
        c.shortCash = bound(c.shortCash, 0, c.shortSize * c.shortGap);
        c.shortWinner = bound(c.shortWinner, 1, 25);
        c.longWinner = bound(c.longWinner, 1, 25);
        mark = bound(c.mark, 70, 130) * SCALE;
        h.setBucket(
            true,
            c.longSize * SCALE,
            c.longSize * 100 * SCALE,
            (100 - c.longGap) * c.longSize * SCALE,
            c.longCash * SCALE,
            0
        );
        h.setBucket(
            false,
            c.shortSize * SCALE,
            c.shortSize * c.shortEntry * SCALE,
            (c.shortEntry + c.shortGap) * c.shortSize * SCALE,
            c.shortCash * SCALE,
            0
        );
        h.setLedgerArrears(
            (c.longGap * c.longSize - c.longCash + c.shortGap * c.shortSize - c.shortCash + bound(c.orphan, 0, 20))
                * SCALE
        );
        h.setVaultInsurance((c.longCash + c.shortCash + bound(c.free, 0, 200)) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        uint256 larger = c.shortWinner > c.longWinner ? c.shortWinner : c.longWinner;
        h.setTrailingOi(uint128(bound(c.trailing, 0, larger) * SCALE));
        h.setPosition(winner, false, c.shortWinner * SCALE, c.shortWinner * 150 * SCALE, 100 * SCALE);
        h.setPosition(ally, true, c.longWinner * SCALE, c.longWinner * 50 * SCALE, 100 * SCALE);
        h.setOI(c.longWinner * SCALE, c.shortWinner * SCALE, c.longWinner * 50 * SCALE, c.shortWinner * 150 * SCALE);
    }

    /// @notice Across two buckets of any size, entry and backing, marks either side of both
    ///         bankruptcy prices, winners of any size on both legs, funds and reserves: one batch
    ///         with both cohorts books no deficit, conserves cash, closes each leg only at that
    ///         leg's settlement price and no more than its cohort covers, and leaves the arrears
    ///         and free capital no further short of what the inventory left needs at its
    ///         bankruptcy prices than before — unless the batch nets, in which case the netting
    ///         spent free capital above the reserve on the overlap's fixed loss as the gate
    ///         allows, and what survives it is backed as the gate reads it.
    function testFuzz_twoBuckets_oneBatch_noDeficit_cashConserved_legsAtTheirPrices(TwoBucketCase memory c) public {
        uint256 mark = _stageTwoBuckets(c);
        uint256 cash = h.insurance() + h.vaultCollateral();
        (uint256 backingBefore, uint256 needBefore) = h.survivorBacking(mark, 0);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _one(ally), _at(mark));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(h.deficit(), 0, "no deficit");
        uint256 paid = h.claimable(address(this));
        assertEq(h.insurance() + h.vaultCollateral() + paid, cash, "cash is conserved");
        for (uint256 i = 0; i < closes.length; i++) {
            // A long winner closes the short bucket, a short winner the long bucket.
            uint256 want = closes[i].isLong ? r.shortBucket.settlementPrice : r.longBucket.settlementPrice;
            assertEq(closes[i].price, want, "every close at its leg's settlement price");
        }
        assertLe(
            r.longBucket.closedSize, r.longBucket.eligibleSize, "the long leg closes no more than its cohort covers"
        );
        assertLe(r.shortBucket.closedSize, r.shortBucket.eligibleSize, "nor the short leg");
        (uint256 backing, uint256 needed) = h.survivorBacking(mark, 0);
        if (r.netted != 0) {
            assertGe(
                backing + paid + NETTING_ROUNDING, needed, "what survives the netting is backed as the gate reads it"
            );
        } else {
            int256 shortBefore = int256(needBefore) - int256(backingBefore);
            int256 shortAfter = int256(needed) - int256(backing + paid);
            assertLe(
                shortAfter, shortBefore + int256(NETTING_ROUNDING), "the closes leave the backing no further short"
            );
        }
    }

    /// @dev One fallback book for the fuzz below: a long bucket above water at the mark with a
    ///      cohort, and a short bucket under water at the mark with none.
    struct FallbackCase {
        uint256 longSize;
        uint256 longGap;
        uint256 longCash;
        uint256 shortSize;
        uint256 shortGap;
        uint256 shortCash;
        uint256 orphan;
        uint256 markAbove;
        uint256 shortDepth;
        uint256 winnerSize;
        uint256 free;
        uint256 target;
    }

    /// @dev Bounds and stages `c`. The long bucket, 1 to 20 units entered at $100 and bankrupt $1
    ///      to $20 below, is marked at or up to $30 above its bankruptcy price; the short bucket, 1
    ///      to 20 units bankrupt $1 to $20 above an entry $1 to $30 below the mark less that gap, is
    ///      under water at the mark. Collateral splits between cash and arrears as in the other
    ///      fuzz books. The short winner, 1 to 30 units from $150, is in profit at every mark.
    /// @param c The case to bound and stage
    /// @return mark The mark the book is staged at
    function _stageFallback(FallbackCase memory c) internal returns (uint256 mark) {
        c.longSize = bound(c.longSize, 1, 20);
        c.longGap = bound(c.longGap, 1, 20);
        c.longCash = bound(c.longCash, 0, c.longSize * c.longGap);
        c.shortSize = bound(c.shortSize, 1, 20);
        c.shortGap = bound(c.shortGap, 1, 20);
        c.shortCash = bound(c.shortCash, 0, c.shortSize * c.shortGap);
        c.winnerSize = bound(c.winnerSize, 1, 30);
        uint256 m = (100 - c.longGap) + bound(c.markAbove, 0, 30);
        uint256 depth = bound(c.shortDepth, 1, 30);
        uint256 shortEntry = m > c.shortGap + depth ? m - c.shortGap - depth : 1;
        mark = m * SCALE;
        h.setBucket(
            true,
            c.longSize * SCALE,
            c.longSize * 100 * SCALE,
            (100 - c.longGap) * c.longSize * SCALE,
            c.longCash * SCALE,
            0
        );
        h.setBucket(
            false,
            c.shortSize * SCALE,
            c.shortSize * shortEntry * SCALE,
            (shortEntry + c.shortGap) * c.shortSize * SCALE,
            c.shortCash * SCALE,
            0
        );
        h.setLedgerArrears(
            (c.longGap * c.longSize - c.longCash + c.shortGap * c.shortSize - c.shortCash + bound(c.orphan, 0, 20))
                * SCALE
        );
        h.setVaultInsurance((c.longCash + c.shortCash + bound(c.free, 0, 200)) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setPosition(winner, false, c.winnerSize * SCALE, c.winnerSize * 150 * SCALE, 100 * SCALE);
        h.setOI(0, c.winnerSize * SCALE, 0, c.winnerSize * 150 * SCALE);
    }

    /// @notice Across long buckets above water, short buckets under water with no cohort, winners
    ///         of any size, funds and reserves: the fallback books no deficit, conserves cash,
    ///         closes only at the mark with the winner realizing the mark in full, closes nothing
    ///         off the short bucket, and whenever the netting that ends the batch fires, what
    ///         survives it is backed as the gate reads it.
    function testFuzz_fallback_losingBucketWithoutACohort_closesAtTheMark_noDeficit(FallbackCase memory c) public {
        uint256 mark = _stageFallback(c);
        uint256 cash = h.insurance() + h.vaultCollateral();
        uint256 collateralBefore = h.positionCollateral(winner);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), _at(mark));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(h.deficit(), 0, "no deficit");
        uint256 paid = h.claimable(address(this));
        assertEq(h.insurance() + h.vaultCollateral() + paid, cash, "cash is conserved");
        for (uint256 i = 0; i < closes.length; i++) {
            assertEq(closes[i].price, mark, "every close at the mark");
        }
        assertEq(r.shortBucket.closedSize, 0, "nothing closes off the short bucket");
        assertEq(
            h.positionCollateral(winner),
            collateralBefore + Math.mulDiv(r.longBucket.closedSize, 150 * SCALE - mark, SCALE),
            "the winner realizes the mark in full"
        );
        if (r.netted != 0) {
            (uint256 backing, uint256 needed) = h.survivorBacking(mark, 0);
            assertGe(
                backing + paid + NETTING_ROUNDING, needed, "what survives the netting is backed as the gate reads it"
            );
        }
    }
}
