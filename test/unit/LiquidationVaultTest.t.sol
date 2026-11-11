// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// Consolidated: liquidator reward, vault bucket netting, the netting gate, ADL guard, vault
// health, transfer safety.
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

// ==================== liquidator reward ====================

/// @notice Harness owning its own vault/position state and forwarding into LiquidationLib,
///         so the per-position reward math can be unit-tested without a full BazaarPair.
contract LiqRewardHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;
    BazaarTypes.FeeEscrow internal feeEscrow;

    /// @dev The liquidator's accrued reward (the lib credits msg.sender, i.e. the test contract).
    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function setPosition(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
    }

    /// @dev Seed totalCollateralDeposited. The seizure is capped at the deposits ledger, so
    ///      tests asserting a FULL seizure must seed at least the summed position collateral;
    ///      seeding less exercises the cap itself.
    function seedCollateral(uint256 amount) external {
        vault.totalCollateralDeposited = amount;
    }

    function deposits() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    /// @dev Seed free capital. The seizure a liquidation credits is earmarked against the
    ///      inventory it arrives with, so only what is seeded here can pay the reward.
    function seedInsurance(uint256 amount) external {
        vault.insuranceFundBalance = amount;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function arrears() external view returns (uint256) {
        return vault.ledgerArrears;
    }

    function liquidate(address[] calldata users, uint256 price) external returns (BazaarTypes.LiquidateResult memory) {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: 0,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    /// @dev Both buckets' size.
    function inventorySize() external view returns (uint256) {
        return vault.longInv.size + vault.shortInv.size;
    }
}

/// @notice Unit tests for the liquidator reward's flat part: the floor for every position a
///         call seizes, limited to the account's own equity when its position is worth less than
///         MIN_ORDER_AMOUNT, summed across the call, capped at the fund's free capital, debited
///         from insurance and accrued to the liquidator's claimable balance at liquidation time,
///         with no profit-contingent (secondary) component. The rate on what the call sells is
///         paid by the inline unload, which this harness does not run.
contract LiquidatorRewardTest is Test {
    uint256 internal constant FLOOR = 0.05e18; // 0.05 USDC
    uint256 internal constant PRICE = 50_000e18; // $50,000

    LiqRewardHarness internal harness;

    function setUp() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        harness.seedInsurance(1_000e18); // free capital the reward is paid from
    }

    /// @dev A long position of `size` BTC, entered `cushionBp` above PRICE with `collateral`,
    ///      so it is underwater at PRICE. Entry slightly above spot guarantees a loss.
    function _long(address user, uint256 size, uint256 entryPrice, uint256 collateral) internal {
        harness.setPosition(user, true, size, Math_mulDiv(size, entryPrice, 1e18), collateral);
    }

    function _liq(address user, uint256 price) internal returns (BazaarTypes.LiquidateResult memory) {
        address[] memory users = new address[](1);
        users[0] = user;
        return harness.liquidate(users, price);
    }

    // -------------------- The flat reward --------------------

    /// @notice A seizure pays the flat $0.05 whatever the position's size. The rate is paid on
    ///         what the call's inline unload sells into the book, which this harness does not run.
    function test_largePosition_paysTheFlatReward() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18); // 0.1 BTC, ~$5,005 entry, $10 collateral
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.claimable(address(this)), FLOOR, "the flat reward, not a rate on the position");
        assertEq(r.unloadPrepaid, FLOOR, "nothing netted: the walk is credited with the whole flat reward");
    }

    function test_smallPosition_paysTheFlatReward() public {
        _long(alice(), 0.001e18, 50_050e18, 0.1e18); // 0.001 BTC, ~$50 notional
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.claimable(address(this)), FLOOR, "the same flat reward");
    }

    // -------------------- One reward per seizure --------------------

    /// @notice The flat reward is due for every position the call seizes, so one call naming
    ///         several accounts earns what separate calls would and batching costs a keeper
    ///         nothing.
    function test_batchPaysTheFlatRewardPerSeizure() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18);
        _long(dave(), 0.001e18, 50_050e18, 0.1e18);

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2);
        assertEq(harness.claimable(address(this)), 2 * FLOOR, "one flat reward per seizure, both accrued");
    }

    /// @notice An account named twice in one call is seized once and paid for once: the second
    ///         entry finds an empty position.
    function test_duplicateEntry_paysOnce() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18);

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = alice();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 1, "seized once");
        assertEq(harness.claimable(address(this)), FLOOR, "paid once");
    }

    /// @notice A call that seizes nothing earns nothing: the reward is for work done, so naming
    ///         a solvent account cannot farm it.
    function test_nothingSeized_paysNothing() public {
        _long(alice(), 0.1e18, 50_000e18, 5_000e18); // fully collateralized, solvent at the price
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 0);
        assertEq(harness.claimable(address(this)), 0, "no seizure, no reward");
        assertEq(r.unloadPrepaid, 0, "and nothing credited against the walk");
    }

    // -------------------- A netting retires exposure --------------------

    /// @notice Opposite-direction liquidations in one call: the first seeds the long bucket and
    ///         earns its flat reward, the second seeds the short bucket and the two net to zero.
    ///         The netting takes the 0.1 BTC off the fund, so its account earns 2 bp of the $5,000
    ///         at the liquidation price, $1, in place of its own flat reward.
    function test_oppositeNetting_paysTheRateOnWhatItRetired() public {
        _long(alice(), 0.1e18, 55_000e18, 100e18); // long underwater at $50k
        harness.setPosition(dave(), false, 0.1e18, Math_mulDiv(0.1e18, 45_500e18, 1e18), 100e18); // short underwater

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2);
        assertEq(harness.inventorySize(), 0, "equal opposite sizes fully net");
        assertEq(harness.claimable(address(this)), FLOOR + 1e18, "alice's flat reward and 2 bp of the $5,000 netted");
        assertEq(r.unloadPrepaid, FLOOR, "only alice's flat reward is credited against the walk");
    }

    // -------------------- Capped at free capital --------------------

    /// @notice The seizure just credited is earmarked against the inventory it arrived with, so
    ///         it is not free capital: a fund holding nothing else pays no reward, and the earmark
    ///         reaches the books whole.
    function test_noFreeCapital_paysNothing_earmarkStaysWhole() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        _long(alice(), 0.1e18, 50_050e18, 10e18); // earns $0.05; seizes $10 into an empty fund
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.claimable(address(this)), 0, "nothing accrued: the fund holds only the earmark");
        assertEq(r.unloadPrepaid, 0, "nothing paid, nothing credited against the walk");
        assertEq(harness.insurance(), 10e18, "the seizure sits in the fund untouched");
        assertEq(harness.bucket(true).seized, 10e18, "and is the long bucket's earmark");
    }

    /// @notice Free capital short of the reward pays what it has, never more.
    function test_partialFreeCapital_paysTheCappedReward() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        harness.seedInsurance(0.04e18);
        _long(alice(), 0.1e18, 50_050e18, 10e18); // earns $0.05 against $0.04 of free capital
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(harness.claimable(address(this)), 0.04e18, "capped at free capital");
        assertEq(r.unloadPrepaid, 0.04e18, "the walk is credited with what was paid, not what was due");
        assertEq(harness.insurance(), 10e18, "the earmark is whole: only the free $0.04 left the fund");
    }

    // -------------------- Positions below the order minimum --------------------

    uint256 internal constant SUB_MIN_SIZE = 0.00008e18; // $4 at PRICE, under MIN_ORDER_AMOUNT
    uint256 internal constant MIN_SIZE = 0.0001e18; // exactly MIN_ORDER_AMOUNT at PRICE

    /// @notice A position worth less than MIN_ORDER_AMOUNT with no equity left earns no flat
    ///         reward: the fund takes over nothing of value with it, so it pays nothing for it.
    function test_subMinimumPosition_noEquity_paysNoFlatReward() public {
        // $4 of notional entered at $50,100: a $0.008 loss against $0.005 of collateral.
        _long(alice(), SUB_MIN_SIZE, 50_100e18, 0.005e18);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), 0, "no flat reward for an account with nothing left");
        assertEq(harness.insurance(), 1_000e18 + 0.005e18, "the fund received the seizure and paid nothing");
    }

    /// @notice Below MIN_ORDER_AMOUNT the flat reward is the account's own equity when that is
    ///         smaller than MIN_LIQUIDATOR_REWARD.
    function test_subMinimumPosition_paysItsEquity() public {
        // $4 of notional at its entry price with $0.03 of collateral, under the $0.06 maintenance line.
        _long(alice(), SUB_MIN_SIZE, 50_000e18, 0.03e18);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), 0.03e18, "the flat reward is the account's equity");
        assertEq(harness.insurance(), 1_000e18, "the fund paid out exactly the equity it took over");
    }

    /// @notice The cap binds only when the equity is smaller: a position below the minimum that
    ///         still holds more than the floor earns the full floor.
    function test_subMinimumPosition_equityAboveTheFloor_paysTheFullFloor() public {
        // $4 of notional with $0.055 of collateral: under the $0.06 maintenance line, over the floor.
        _long(alice(), SUB_MIN_SIZE, 50_000e18, 0.055e18);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), FLOOR, "the full floor");
    }

    /// @notice A position worth MIN_ORDER_AMOUNT or more earns the full floor even with no equity
    ///         left: until it is seized its further losses are the fund's.
    function test_positionAtTheMinimum_bankrupt_paysTheFullFloor() public {
        // Exactly $5 of notional entered at $50,100 with no collateral: $0.01 past bankruptcy.
        _long(alice(), MIN_SIZE, 50_100e18, 0);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), FLOOR, "the full floor, whatever the equity");
    }

    /// @notice Each account in a batch is capped on its own: a sub-minimum account with nothing
    ///         left adds nothing, and a full-size one beside it still adds the floor.
    function test_batch_capsEachAccountOnItsOwn() public {
        _long(alice(), SUB_MIN_SIZE, 50_100e18, 0.005e18); // no equity left
        _long(dave(), 0.1e18, 50_050e18, 10e18); // ~$5,000, under maintenance

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(harness.claimable(address(this)), FLOOR, "only the full-size account adds the floor");
    }

    // -------------------- Helpers --------------------

    function Math_mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d;
    }

    function alice() internal returns (address) {
        return makeAddr("alice");
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }
}

// ==================== seizure ledger cap ====================

/// @notice The liquidation seizure credits insurance with the liquidatee's book collateral
///         capped at totalCollateralDeposited. Winners realize gains into positions without
///         touching the deposits ledger and withdraw them from it later, so a loser's book
///         collateral can legitimately exceed the entire remaining ledger — an uncapped
///         seizure would panic there and make the position unliquidatable.
contract SeizureLedgerClampTest is Test {
    uint256 internal constant PRICE = 50_000e18;

    LiqRewardHarness internal harness;
    address internal loser;
    address internal loser2;

    function setUp() public {
        harness = new LiqRewardHarness();
        loser = makeAddr("loser");
        loser2 = makeAddr("loser2");
    }

    /// @dev A long that is insolvent at PRICE: entry $65k on 1 unit → $15k loss against
    ///      `collateral` of book value.
    function _underwaterLong(address user, uint256 collateral) internal {
        harness.setPosition(user, true, 1e18, 65_000e18, collateral);
    }

    function _liq(address user) internal returns (BazaarTypes.LiquidateResult memory) {
        address[] memory users = new address[](1);
        users[0] = user;
        return harness.liquidate(users, PRICE);
    }

    /// @notice Book collateral above the whole ledger: liquidation succeeds, insurance is
    ///         credited exactly the ledger balance, the ledger floors at zero, the unpaid
    ///         remainder is carried as the ledger's arrears to the fund, and no deficit is
    ///         booked — settlement of the inherited estate decides solvency.
    function test_bucketAboveLedger_seizureCapsAndSucceeds() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(9_200e18);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(r.liquidatedCount, 1, "liquidation must not revert on a thin ledger");
        assertEq(
            harness.insurance(),
            9_200e18 - harness.claimable(address(this)),
            "insurance receives the capped amount, less the reward"
        );
        assertEq(harness.deposits(), 0, "ledger floors at zero");
        assertEq(harness.arrears(), 800e18, "the unpaid remainder is the ledger's arrears to the fund");
        assertEq(harness.deficit(), 0, "no deficit at seizure time");
        assertEq(harness.bucket(true).size, 1e18, "estate carries the full position");
        assertEq(harness.bucket(true).seized, 9_200e18, "the earmark is the cash the fund received");
    }

    /// @notice Ledger fully covers the book: the cap is inactive, the full collateral moves to
    ///         insurance and no arrears arise.
    function test_ledgerCoversBook_fullSeizure() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(30_000e18);

        _liq(loser);

        assertEq(
            harness.insurance(), 10_000e18 - harness.claimable(address(this)), "full book value seized, less the reward"
        );
        assertEq(harness.deposits(), 20_000e18);
        assertEq(harness.arrears(), 0, "a ledger that covers the book owes nothing");
        assertEq(harness.deficit(), 0);
    }

    /// @notice A batch whose summed books exceed the ledger, though each position fits
    ///         alone: the first seizure takes its full book, the second is capped at the
    ///         remainder with the rest carried as arrears, and both liquidations commit.
    function test_batchCascade_capsAtRemainder() public {
        _underwaterLong(loser, 6_000e18);
        _underwaterLong(loser2, 6_000e18);
        harness.seedCollateral(9_000e18);

        address[] memory users = new address[](2);
        users[0] = loser;
        users[1] = loser2;
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2, "the aggregate cap must not revert the batch");
        assertEq(
            harness.insurance(),
            9_000e18 - harness.claimable(address(this)),
            "6,000 full + 3,000 capped, less the rewards"
        );
        assertEq(harness.deposits(), 0);
        assertEq(harness.arrears(), 3_000e18, "the second seizure's unpaid 3,000 is owed to the fund");
        assertEq(harness.bucket(true).size, 2e18, "both estates on the books");
    }

    /// @notice An empty ledger seizes nothing but the liquidation still commits, the estate is
    ///         still recorded, and the whole book is owed to the fund.
    function test_emptyLedger_liquidationStillCommits() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(0);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.insurance(), 0, "nothing attributable, nothing credited");
        assertEq(harness.arrears(), 10_000e18, "the whole book is owed to the fund");
        assertEq(harness.claimable(address(this)), 0, "a reward the fund cannot cover is skipped, never partial");
        assertEq(harness.bucket(true).size, 1e18);
    }
}

// ==================== vault bucket netting ====================

/// @notice Harness that stages the vault's two buckets so the netting of their overlap — on an
///         estate's arrival (LiquidationLib.absorb) or directly (RiskParamsLib.tryNetBuckets) —
///         can be exercised in isolation. The funding index is settable per liquidate() call,
///         which the LiquidatorRewardTest harness (hardcoded to 0) cannot do.
contract NettingHarness {
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

    /// @dev Seed what the deposits ledger already owes the fund, as an earlier seizure the
    ///      ledger could only partly pay would have left it.
    function seedArrears(uint256 amount) external {
        vault.ledgerArrears = amount;
    }

    function seedOI(uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum) external {
        vault.totalLongOI = longOI;
        vault.totalShortOI = shortOI;
        vault.longWeightedEntrySum = longSum;
        vault.shortWeightedEntrySum = shortSum;
    }

    /// @dev The cached insurance target the reserve is sized from; 0 leaves no reserve.
    function seedTargetRatio(uint256 bp) external {
        vault.targetInsuranceRatioBp = bp;
    }

    function seedTrailingOi(uint256 x) external {
        vault.trailingOiSize = uint128(x);
    }

    /// @dev Stage one of the vault's two buckets: inventory of liquidated positions on `isLong`'s
    ///      side, entered at funding index `entryFundingIndex`, backed by `seized`.
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
    }

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
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    function liquidateMany(address[] calldata users, uint256 price, int256 fundingIndex)
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

    // -------- the netting gate, on the staged buckets --------

    /// @dev Whether the fund may net the two buckets' overlap at `price`.
    function overlapAffordable(uint256 price, int256 fundingIndex) external view returns (bool) {
        return RiskParamsLib.overlapAffordable(vault, price, fundingIndex);
    }

    /// @dev Nets the overlap where the gate allows; returns the size netted off each bucket.
    function tryNet(uint256 price, int256 fundingIndex) external returns (uint256) {
        return RiskParamsLib.tryNetBuckets(vault, price, fundingIndex);
    }

    /// @dev The overlap, what netting it realizes and the two netted slices' seizure.
    function overlapOf() external view returns (uint256 o, int256 pnl, uint256 seized) {
        return RiskParamsLib.overlap(vault);
    }

    /// @dev What the fund holds for a close of the larger bucket at its bankruptcy price, as the
    ///      netting gate reads it — free capital above the reserve plus the arrears — and what
    ///      that close needs beyond the bucket's earmark.
    function survivorBacking(uint256 price, int256 fundingIndex)
        external
        view
        returns (uint256 backing, uint256 needed)
    {
        uint256 free = RiskParamsLib.insuranceFreeCapital(vault);
        uint256 reserve = RiskParamsLib.adlReserve(vault, price);
        backing = (free > reserve ? free - reserve : 0) + vault.ledgerArrears;
        bool big = RiskParamsLib.netLong(vault);
        needed = RiskParamsLib.bucketBankruptcyCloseCost(RiskParamsLib.bucketOf(vault, big), big, fundingIndex);
    }

    // -------- read-backs --------

    function arrears() external view returns (uint256) {
        return vault.ledgerArrears;
    }

    function deposits() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function insuranceFundBalance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function freeCapital() external view returns (uint256) {
        return RiskParamsLib.insuranceFreeCapital(vault);
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    /// @dev Both buckets' size.
    function inventorySize() external view returns (uint256) {
        return vault.longInv.size + vault.shortInv.size;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function positionSize(address user) external view returns (uint256) {
        return positionBuckets[user].size;
    }
}

/// @notice When an opposing liquidation NETS against the vault's inherited inventory, the funding
///         the vault accrued on the netted portion over its holding window is realized into the
///         insurance fund — keeping funding zero-sum on the netting path, symmetric with an ADL
///         close of the bucket. And when the fund cannot afford the netting, the estate is seized
///         into its own side's bucket, final, for the auction to close against its own
///         counterparties; the overlap is netted later, by whichever call finds the fund able.
///
///         Construction isolates the funding term: the opposing position carries the SAME
///         entry notional as the netted inventory, so the price component of the net PnL is
///         exactly zero. The only insurance movements are then (a) the opposing position's
///         seized collateral and (b) the realized vault funding on the netted size. The funding
///         index carries the price factor, so the funding term is USD-scaled.
contract VaultFundingNettingTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 50_000e18;
    uint256 internal constant SIZE = 1e18; // 1 unit
    uint256 internal constant BASE_INSURANCE = 1_000e18;
    uint256 internal constant SEIZED_COLLATERAL = 10e18;

    NettingHarness internal h;

    function setUp() public {
        h = new NettingHarness();
        h.seedCollateral(1_000_000e18);
        h.seedInsurance(BASE_INSURANCE);
    }

    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d;
    }

    /// @dev The canonical standing pair every unaffordable case below starts from: the vault long
    ///      1 unit inherited at $60k entry, bankrupt at $58k, the $2k gap seized with it, and the
    ///      fund holding $4k, $2k above that earmark. An opposing short entered at $48k with $1k
    ///      collateral is insolvent at $50k (loss $2k > $1k), and netting it would lose the $12k
    ///      entry gap against the $2k free, the $2k earmark and the $1k seizure.
    function _longBucketAt60k() internal {
        h.setBucket(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 2_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
    }

    function _shortFrom48k(address user) internal {
        h.setPosition(user, false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);
    }

    // ----- Vault holds a LONG bucket; funding rose → vault (as long) PAYS → insurance falls -----

    /// @dev The $1k gap between the bucket's entry and bankruptcy notionals is the collateral
    ///      seized with it, and the $1k fund is exactly that earmark: the netting's loss is paid
    ///      from the two netted slices' seizure.
    function test_nettingLongInventory_realizesFundingOutflow() public {
        // Opposing SHORT entered at $49k (underwater at $50k), same entry notional as the inventory.
        uint256 entryNotional = _mulDiv(SIZE, 49_000e18, SCALE);
        int256 entryIdx = 0;
        int256 currentIdx = 100e18; // price-scaled funding accumulation over the holding window

        h.setBucket(true, SIZE, entryNotional, _mulDiv(SIZE, 48_000e18, SCALE), 1_000e18, entryIdx);
        // Short's own entry funding index == current → its own funding PnL is zero, isolating
        // the vault-inventory funding under test.
        h.setPosition(dave(), false, SIZE, entryNotional, SEIZED_COLLATERAL, currentIdx);

        h.liquidate(dave(), PRICE, currentIdx);

        assertEq(h.inventorySize(), 0, "equal opposite sizes fully net");

        uint256 nettedFunding = uint256(currentIdx - entryIdx) * SIZE / SCALE; // 100e18
        // base + seized - funding (long pays when funding rises) - liquidator reward; price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL - nettedFunding - h.claimable(address(this));
        assertEq(h.insuranceFundBalance(), expected, "long-inventory funding realized as outflow");
    }

    // ----- Vault holds a SHORT bucket; funding rose → vault (as short) RECEIVES → insurance rises -----

    function test_nettingShortInventory_realizesFundingInflow() public {
        // Opposing LONG entered at $51k (underwater at $50k), same entry notional as the inventory.
        uint256 entryNotional = _mulDiv(SIZE, 51_000e18, SCALE);
        int256 entryIdx = 0;
        int256 currentIdx = 100e18;

        h.setBucket(false, SIZE, entryNotional, _mulDiv(SIZE, 52_000e18, SCALE), 1_000e18, entryIdx);
        h.setPosition(dave(), true, SIZE, entryNotional, SEIZED_COLLATERAL, currentIdx);

        h.liquidate(dave(), PRICE, currentIdx);

        assertEq(h.inventorySize(), 0, "equal opposite sizes fully net");

        uint256 nettedFunding = uint256(currentIdx - entryIdx) * SIZE / SCALE; // 100e18
        // base + seized + funding (short receives when funding rises) - liquidator reward; price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL + nettedFunding - h.claimable(address(this));
        assertEq(h.insuranceFundBalance(), expected, "short-inventory funding realized as inflow");
    }

    // ----- Control: no funding delta → no funding adjustment (only seizure + zero price PnL) -----

    function test_nettingNoFundingDelta_noAdjustment() public {
        uint256 entryNotional = _mulDiv(SIZE, 49_000e18, SCALE);
        int256 idx = 0; // entry index == current index → zero funding delta

        h.setBucket(true, SIZE, entryNotional, _mulDiv(SIZE, 48_000e18, SCALE), 1_000e18, idx);
        h.setPosition(dave(), false, SIZE, entryNotional, SEIZED_COLLATERAL, idx);

        h.liquidate(dave(), PRICE, idx);

        assertEq(h.inventorySize(), 0, "equal opposite sizes fully net");
        // base + seized - liquidator reward only; price netPnl == 0 and funding delta == 0
        assertEq(
            h.insuranceFundBalance(),
            BASE_INSURANCE + SEIZED_COLLATERAL - h.claimable(address(this)),
            "no funding term when delta is zero"
        );
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }

    // ----- An unaffordable netting: the estate is seized into its own bucket -----

    /// @notice When the netting's loss exceeds what backs the two netted slices — free capital
    ///         above the reserve, their seizure and the ledger's arrears — the estate is seized all
    ///         the same, into its OWN side's bucket, and both buckets stand for the auction to close
    ///         each against its own counterparties. The long bucket is untouched, no deficit is
    ///         booked, and the liquidator earns the flat reward alone: nothing was retired.
    function test_nettingBeyondBacking_seizesIntoTheOppositeBucket() public {
        _longBucketAt60k();
        _shortFrom48k(dave());

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        // The $12k entry gap (60k long against 48k short) against $2k free + $2k earmark + $1k
        // seizure: unaffordable, so nothing is netted.
        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.positionSize(dave()), 0, "the position is gone from its owner");
        BazaarTypes.Inventory memory l = h.bucket(true);
        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(l.size, SIZE, "long bucket untouched");
        assertEq(l.entryNotional, 60_000 * SCALE, "long bucket untouched: entry");
        assertEq(s.size, SIZE, "the estate is the short bucket");
        assertEq(s.entryNotional, 48_000 * SCALE, "at its own entry");
        assertEq(s.bankruptcyNotional, 49_000 * SCALE, "bankrupt at entry + collateral");
        assertEq(s.seized, 1_000 * SCALE, "its collateral is its earmark");
        assertEq(uint256(s.seizedTs), block.timestamp, "seeded now");
        assertEq(h.deficit(), 0, "no bad debt booked");
        // The flat reward, paid from the fund's free capital. Nothing was netted, so no rate is
        // due and the whole reward is credited against the walk.
        assertEq(h.claimable(address(this)), BazaarTypes.MIN_LIQUIDATOR_REWARD, "the flat reward, for the seizure");
        assertEq(r.unloadPrepaid, BazaarTypes.MIN_LIQUIDATOR_REWARD, "the whole reward credited against the walk");
        assertEq(
            h.insuranceFundBalance(),
            4_000 * SCALE + 1_000 * SCALE - BazaarTypes.MIN_LIQUIDATOR_REWARD,
            "the fund received the seizure and paid the flat reward"
        );
        assertEq(
            h.freeCapital(), 2_000 * SCALE - BazaarTypes.MIN_LIQUIDATOR_REWARD, "free capital moved by the reward alone"
        );

        // Naming the account again finds an empty position and pays nothing.
        r = h.liquidate(dave(), PRICE, 0);
        assertEq(r.liquidatedCount, 0, "nothing left to seize");
        assertEq(h.claimable(address(this)), BazaarTypes.MIN_LIQUIDATOR_REWARD, "no reward for a re-submission");
        assertEq(r.unloadPrepaid, 0, "nothing paid, nothing credited");
        assertEq(h.bucket(false).size, SIZE, "the bucket stands as it was");
    }

    /// @notice Seizing several opposite-side estates in one call pays the flat reward for each,
    ///         like seizing same-side ones does, and they merge into one bucket.
    function test_twoOppositeSeizuresInOneCall_payTheFlatRewardEach() public {
        // Two units inherited at $60k entry, bankrupt at $58k: $4k earmarked, $200 free.
        h.setBucket(true, 2 * SIZE, 120_000 * SCALE, 116_000 * SCALE, 4_000 * SCALE, 0);
        h.seedInsurance(4_200 * SCALE);
        address erin = makeAddr("erin");
        // Two opposing shorts, each from $48k on $1k: each netting's $12k entry gap is unaffordable.
        _shortFrom48k(dave());
        _shortFrom48k(erin);
        address[] memory users = new address[](2);
        users[0] = dave();
        users[1] = erin;

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(users, PRICE, 0);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(h.bucket(false).size, 2 * SIZE, "both in the short bucket");
        assertEq(h.bucket(false).entryNotional, 96_000 * SCALE, "entries added");
        assertEq(h.bucket(true).size, 2 * SIZE, "the long bucket stands");
        assertEq(h.claimable(address(this)), 2 * BazaarTypes.MIN_LIQUIDATOR_REWARD, "one flat reward per seizure");
        assertEq(h.deficit(), 0, "nothing booked");
    }

    /// @notice An opposite-side seizure is paid like any other and capped the same way: an account
    ///         whose position is worth less than MIN_ORDER_AMOUNT earns at most its own equity.
    function test_subMinimumOppositeSeizure_paysItsEquity() public {
        // Vault holds a long inherited at $60k entry, bankrupt at $58k: $2k seized with it.
        h.setBucket(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 2_000 * SCALE, 0);
        // $0.50 of free capital on top of the $2k earmark.
        h.seedInsurance(2_000 * SCALE + SCALE / 2);
        // A $4 short entered at $48k with $0.19 of collateral: its $0.16 loss at $50k leaves $0.03
        // of equity, under the $0.06 maintenance line.
        uint256 dust = 0.00008e18;
        h.setPosition(dave(), false, dust, _mulDiv(dust, 48_000 * SCALE, SCALE), 0.19e18, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        // Netting it would lose $0.96 on the entry gap against $0.85 of backing: the $0.50 free,
        // $0.16 of the inventory's seizure and its own $0.19. So it is seized into the short bucket.
        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.bucket(false).size, dust, "the dust estate is the short bucket");
        assertEq(h.bucket(true).size, SIZE, "the long bucket stands");
        assertEq(h.claimable(address(this)), 0.03e18, "the flat reward is the account's equity");
        assertEq(
            h.insuranceFundBalance(),
            2_000 * SCALE + SCALE / 2 + 0.19e18 - 0.03e18,
            "the fund received the seizure and paid the capped reward"
        );
    }

    /// @notice A standing overlap is netted by the next call that finds the fund able: a deposit
    ///         lifts free capital, and the next seizure on the short side — merged into the short
    ///         bucket first — ends with the overlap netted, the long bucket cleared and the
    ///         remainder in the short bucket. That call earns the rate on what the netting retired.
    function test_standingOverlap_nettedOnceALaterSeizureFindsTheFundAble() public {
        _longBucketAt60k();
        _shortFrom48k(dave());
        h.liquidate(dave(), PRICE, 0);
        assertEq(h.inventorySize(), 2 * SIZE, "both buckets stand");

        // $10k more in the fund: $11k free above the $4k of earmarks once erin's $1k joins.
        h.seedInsurance(14_000 * SCALE);
        address erin = makeAddr("erin");
        _shortFrom48k(erin);
        BazaarTypes.LiquidateResult memory r = h.liquidate(erin, PRICE, 0);

        // The overlap: one unit, $12k of entry gap against $11k free + $3k of the slices' seizure.
        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.bucket(true).size, 0, "the long bucket was netted away");
        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.size, SIZE, "one of the two short units survives");
        assertEq(s.entryNotional, 48_000 * SCALE, "prorated");
        assertEq(s.seized, 1_000 * SCALE, "with its share of the seizure");
        assertEq(h.deficit(), 0, "the loss was paid in full");
        // The $12k loss: $3k from the netted slices' seizure, $9k from free capital.
        assertEq(
            h.insuranceFundBalance(), 15_000 * SCALE - 12_000 * SCALE - 10 * SCALE, "fund less the loss and the rate"
        );
        assertEq(
            h.claimable(address(this)),
            BazaarTypes.MIN_LIQUIDATOR_REWARD + 10 * SCALE,
            "dave's flat reward, then erin's rate on the unit netted"
        );
        assertEq(r.unloadPrepaid, 0, "the rate spent the whole payment");
    }

    /// @notice A seizure into a bucket is final: the account named again at a price where its
    ///         position would have been solvent finds nothing to reverse. The estate lives in the
    ///         bucket until the auction closes it or the fund nets it.
    function test_oppositeSeizure_isFinal_noReversalReopensIt() public {
        _longBucketAt60k();
        _shortFrom48k(dave());
        h.liquidate(dave(), PRICE, 0);
        assertEq(h.bucket(false).size, SIZE, "seized into the short bucket");

        // Back at the short's entry the position would be whole; there is no position left.
        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), 48_000 * SCALE, 0);

        assertEq(r.liquidatedCount, 0, "nothing to liquidate");
        assertEq(h.positionSize(dave()), 0, "still gone");
        assertEq(h.bucket(false).size, SIZE, "the bucket keeps the estate");
        assertEq(h.claimable(address(this)), BazaarTypes.MIN_LIQUIDATOR_REWARD, "paid once, for the seizure");
    }

    /// @notice There is no cap on how many estates a bucket takes: twenty shorts the fund cannot
    ///         net against the standing long bucket all join the short bucket, each paying its
    ///         flat reward, and the long bucket stands throughout.
    function test_oppositeSeizures_noCap_everyEstateJoinsTheBucket() public {
        _longBucketAt60k();
        uint256 n = 20;
        for (uint256 i = 0; i < n; i++) {
            address short_ = makeAddr(string.concat("short", vm.toString(i)));
            _shortFrom48k(short_);
            BazaarTypes.LiquidateResult memory r = h.liquidate(short_, PRICE, 0);
            assertEq(r.liquidatedCount, 1, "seized");
            assertEq(h.claimable(address(this)), (i + 1) * BazaarTypes.MIN_LIQUIDATOR_REWARD, "flat reward each");
            assertEq(h.bucket(false).size, (i + 1) * SIZE, "joined the short bucket");
        }

        BazaarTypes.Inventory memory s = h.bucket(false);
        assertEq(s.entryNotional, n * 48_000 * SCALE, "entries added");
        assertEq(s.bankruptcyNotional, n * 49_000 * SCALE, "bankruptcy notionals added");
        assertEq(s.seized, n * 1_000 * SCALE, "seizures added");
        assertEq(h.bucket(true).size, SIZE, "the long bucket stands");
        assertEq(h.deficit(), 0, "nothing booked");
        // Each seizure brought its own earmark, so free capital moved only by the rewards.
        assertEq(
            h.freeCapital(), 2_000 * SCALE - n * BazaarTypes.MIN_LIQUIDATOR_REWARD, "free capital: the rewards alone"
        );
    }

    // ----- Arrears netting: what the ledger owes the fund comes off the fund's payment first -----

    /// @notice The same loss with the ledger owing the fund $7k from an earlier seizure it could
    ///         only partly pay: $2k free, the $2k earmark, the $1k seizure and the $7k arrears
    ///         back the $12k exactly, so the netting runs. The loss is paid from the slices'
    ///         seizure first, then net of the arrears, and the $2k free covers the rest, with no
    ///         deficit.
    function test_nettingLoss_netsLedgerArrearsBeforeInsurancePays() public {
        _longBucketAt60k();
        h.seedArrears(7_000 * SCALE);
        _shortFrom48k(dave());
        uint256 ledgerBefore = h.deposits();

        h.liquidate(dave(), PRICE, 0);

        assertEq(h.inventorySize(), 0, "equal opposite sizes fully net");
        assertEq(h.arrears(), 0, "the loss consumed the whole arrears");
        assertEq(h.insuranceFundBalance(), 0, "the fund paid the $5k left after netting");
        assertEq(h.deficit(), 0, "no deficit: the fund covered the loss beyond the estates' collateral");
        // The ledger gave up the $1k seizure and received the $5k net payment.
        assertEq(h.deposits(), ledgerBefore - 1_000 * SCALE + 5_000 * SCALE, "ledger credited the net loss");
    }

    /// @notice Arrears count toward what the netting may spend, and short of covering the loss
    ///         together with the rest of the backing they leave the estate seized into its own
    ///         bucket: nothing is consumed and nothing booked.
    function test_nettingLoss_arrearsShortOfTheLoss_seizesIntoTheOppositeBucket() public {
        _longBucketAt60k();
        h.seedArrears(3_000 * SCALE);
        _shortFrom48k(dave());

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        // $2k free + $2k earmark + $1k seizure + $3k arrears = $8k against a $12k loss.
        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.arrears(), 3_000 * SCALE, "arrears untouched");
        assertEq(h.bucket(true).size, SIZE, "long bucket untouched");
        assertEq(h.bucket(false).size, SIZE, "the estate stands in the short bucket");
        assertEq(h.deficit(), 0, "nothing booked");
    }

    /// @notice A netting GAIN on a ledger too thin to pay it: the seizure takes what the ledger
    ///         holds and the gain the ledger cannot pay is added to its arrears rather than
    ///         dropped, so the fund's claim on the estates' value survives.
    function test_nettingGain_thinLedgerCarriesTheGainAsArrears() public {
        // Vault holds a long inherited at $40k entry (in profit at $50k).
        h.setBucket(true, SIZE, 40_000 * SCALE, 38_000 * SCALE, 2_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        // The ledger holds $500 against a $1k position: the seizure is capped at $500.
        h.seedCollateral(500 * SCALE);
        _shortFrom48k(dave());

        h.liquidate(dave(), PRICE, 0);

        assertEq(h.inventorySize(), 0, "equal opposite sizes fully net");
        assertEq(h.deposits(), 0, "the ledger gave up everything it held");
        // $500 of unpaid seizure plus the $8k netting gain (48k − 40k) the empty ledger could not pay.
        assertEq(h.arrears(), 8_500 * SCALE, "unpaid seizure and uncollected gain are both owed to the fund");
        // The liquidator is paid 2 bp of the netted unit at $50k: $10.
        assertEq(h.claimable(address(this)), 10 * SCALE, "the rate on what the netting retired");
        assertEq(
            h.insuranceFundBalance(), 4_500 * SCALE - 10 * SCALE, "fund holds base + the cash seized, less the reward"
        );
        assertEq(h.deficit(), 0);
    }
}

// ==================== netting reward ====================

/// @notice The rate a liquidation earns on what its nettings retire. A position seized against
///         an opposite bucket cancels the overlap at once, which takes that much exposure off
///         the fund just as an unload sale does, so its account earns LIQUIDATION_FEE_EBP of the
///         overlap's notional at the liquidation price when that beats its flat reward. Each
///         account earns its own larger figure, so batching changes nothing. What the payment
///         holds beyond the nettings' rate is the credit handed to the inline unload
///         (LiquidateResult.unloadPrepaid), which pays its own rate on what it sells only past
///         that credit.
///
///         Every bucket here is staged at the oracle with no earmark and every opposing
///         position enters at the oracle, so a netting's entry gap is zero: it is always
///         affordable and moves the fund only by the seizure and the reward.
contract NettingRewardTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 50_000e18;
    uint256 internal constant FLOOR = BazaarTypes.MIN_LIQUIDATOR_REWARD;

    NettingHarness internal h;
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank");

    function setUp() public {
        h = new NettingHarness();
        h.seedCollateral(1_000_000e18);
        h.seedInsurance(1_000e18);
    }

    /// @dev LIQUIDATION_FEE_EBP of `size` at PRICE, computed as processLiquidations does.
    function _rate(uint256 size) internal pure returns (uint256) {
        return (size * PRICE / SCALE) * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
    }

    /// @dev A bucket of `size` on `isLong`, entered at PRICE, with nothing earmarked.
    function _inventory(bool isLong, uint256 size) internal {
        uint256 notional = size * PRICE / SCALE;
        h.setBucket(isLong, size, notional, notional, 0, 0);
    }

    /// @dev A position of `size` entered at PRICE with `collateral`, under maintenance at PRICE
    ///      whenever the collateral is below 1.5% of its notional.
    function _position(address user, bool isLong, uint256 size, uint256 collateral) internal {
        h.setPosition(user, isLong, size, size * PRICE / SCALE, collateral, 0);
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /// @notice A netting that retires the whole bucket earns 2 bp of its notional, $10 for a
    ///         unit at $50k, where the flat reward alone would pay $0.05.
    function test_fullNetting_paysTheRateOnTheNettedNotional() public {
        _inventory(true, SCALE);
        _position(dave, false, SCALE, 10e18);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.inventorySize(), 0, "netted to zero");
        assertEq(_rate(SCALE), 10e18, "premise: 2 bp of $50,000");
        assertEq(h.claimable(address(this)), 10e18, "the rate on what the netting retired");
        assertEq(r.unloadPrepaid, 0, "the netting rate spent the whole payment");
        assertEq(h.insuranceFundBalance(), 1_000e18 + 10e18 - 10e18, "the fund received the seizure and paid the rate");
    }

    /// @notice An estate larger than the bucket it meets nets only the overlap; the rest stays in
    ///         the estate's own bucket, exposure moved onto the fund, and earns nothing until it
    ///         is sold.
    function test_estateLargerThanTheBucket_paysTheRateOnTheOverlapOnly() public {
        _inventory(true, SCALE);
        _position(dave, false, 3 * SCALE, 30e18);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(h.bucket(true).size, 0, "the long bucket was netted away");
        assertEq(h.bucket(false).size, 2 * SCALE, "two units left over, in the estate's own bucket");
        assertEq(h.claimable(address(this)), _rate(SCALE), "2 bp of the one unit netted, not of all three");
        assertEq(r.unloadPrepaid, 0, "nothing left to credit against the walk");
    }

    /// @notice A netting smaller than the bucket nets its own size.
    function test_partialNetting_paysTheRateOnTheEstate() public {
        _inventory(true, 3 * SCALE);
        _position(dave, false, SCALE, 10e18);

        h.liquidate(dave, PRICE, 0);

        assertEq(h.bucket(true).size, 2 * SCALE, "two units of the long bucket survive");
        assertEq(h.bucket(false).size, 0, "the estate's bucket was taken whole");
        assertEq(h.claimable(address(this)), _rate(SCALE), "2 bp of the unit the estate retired");
    }

    /// @notice Below $250 netted, 2 bp is under the flat reward, which stands. The walk is then
    ///         credited with what the flat reward pays beyond the netting rate, so that a sale
    ///         earns only what its own rate adds past the flat total.
    function test_smallNetting_flatRewardGoverns_walkCreditedWithTheRest() public {
        uint256 size = 0.0002e18; // $10 at $50k
        _inventory(true, size);
        _position(dave, false, size, 0.1e18); // under the $0.15 maintenance line

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        uint256 rate = _rate(size);
        assertEq(rate, 0.002e18, "premise: 2 bp of $10");
        assertEq(h.claimable(address(this)), FLOOR, "the flat reward stands");
        assertEq(r.unloadPrepaid, FLOOR - rate, "the walk is credited with the flat reward less the netting rate");
    }

    /// @notice Each account is paid its own larger figure: a $50 netting, whose 2 bp is a cent,
    ///         earns its flat reward, and the two same-side seizures after it earn theirs. The
    ///         walk is credited with the three flat rewards less the cent the netting's rate holds.
    function test_smallNettingAndTwoSeizures_eachAccountEarnsItsOwnLarger() public {
        uint256 size = 0.001e18; // $50 at $50k
        _inventory(true, size);
        _position(dave, false, size, 0.5e18); // nets the long bucket away
        _position(erin, false, size, 0.5e18); // seeds the short bucket
        _position(frank, false, size, 0.5e18); // adds to it

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(_three(dave, erin, frank), PRICE, 0);

        assertEq(r.liquidatedCount, 3, "all three seized");
        assertEq(h.bucket(false).size, 2 * size, "erin and frank are the short bucket");
        assertEq(h.bucket(true).size, 0, "the long bucket is gone");
        assertEq(h.claimable(address(this)), 3 * FLOOR, "three flat rewards, not three plus the rate");
        assertEq(r.unloadPrepaid, 3 * FLOOR - _rate(size), "the flat total less the netting rate");
    }

    /// @notice A large netting and a small seizure in one call earn what two calls would: the
    ///         netting's $10 and the seizure's $0.05, where one maximum over the call would drop
    ///         the $0.05 and pay a keeper to split the batch.
    function test_largeNettingAndASeizure_payWhatTwoCallsWould() public {
        _inventory(true, SCALE);
        _position(dave, false, SCALE, 10e18); // nets the long bucket away: $10
        _position(erin, false, 0.001e18, 0.5e18); // seeds the short bucket: $0.05
        address[] memory users = new address[](2);
        users[0] = dave;
        users[1] = erin;

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(users, PRICE, 0);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(h.claimable(address(this)), _rate(SCALE) + FLOOR, "the netting's rate and the seizure's flat reward");
        assertEq(r.unloadPrepaid, FLOOR, "erin's flat reward is credited against the walk that sells her");
    }

    /// @notice A cap between the netting's rate and its flat reward: the fund pays the free
    ///         capital it has, and the walk is credited only with what that payment holds beyond
    ///         the rate.
    function test_capBetweenTheRateAndTheFlatReward_creditIsWhatWasPaidPastTheRate() public {
        h.seedInsurance(0);
        uint256 size = 0.0002e18; // $10 at $50k: a $0.002 rate against the $0.05 floor
        _inventory(true, size);
        _position(dave, false, size, 0.03e18); // its $0.03 seizure is the fund's only free capital

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(h.claimable(address(this)), 0.03e18, "capped at the $0.03 the fund holds free");
        assertEq(r.unloadPrepaid, 0.03e18 - _rate(size), "the payment less the netting's rate");
    }

    /// @notice Each netting is measured against the inventory left by the one before it: two
    ///         one-unit estates against 1.5 units net 1 and 0.5, and the second's other half
    ///         stays in the short bucket.
    function test_twoNettings_eachMeasuredAgainstTheInventoryLeft() public {
        _inventory(true, 1.5e18);
        _position(dave, false, SCALE, 10e18);
        _position(erin, false, SCALE, 10e18);
        address[] memory users = new address[](2);
        users[0] = dave;
        users[1] = erin;

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(users, PRICE, 0);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(h.bucket(true).size, 0, "the long bucket is gone");
        assertEq(h.bucket(false).size, 0.5e18, "half of erin's unit is left over, in the short bucket");
        assertEq(h.claimable(address(this)), _rate(1.5e18), "2 bp of the 1.5 units netted");
    }

    /// @notice The netting rate is paid like the flat part: capped at free capital. A fund that
    ///         holds only the netted estate's seizure pays that and no more, and credits the
    ///         walk with nothing.
    function test_nettingRate_cappedAtFreeCapital() public {
        h.seedInsurance(0);
        _inventory(true, SCALE);
        _position(dave, false, SCALE, 4e18); // its $4 seizure is the fund's only free capital

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(h.inventorySize(), 0, "netted to zero");
        assertEq(h.claimable(address(this)), 4e18, "the $10 rate, capped at the $4 the fund holds free");
        assertEq(r.unloadPrepaid, 0, "a capped payment leaves nothing to credit");
        assertEq(h.insuranceFundBalance(), 0, "the fund paid out its free capital and no more");
    }

    /// @notice A netting the fund cannot afford does not run: the estate is seized into its own
    ///         bucket, and the account earns the flat reward for the seizure and the rate on
    ///         nothing.
    function test_unaffordableNetting_seizureEarnsTheFlatRewardOnly() public {
        // A unit inherited at $60k entry, bankrupt at $58k ($2k earmarked), against a short from
        // $48k with $1k: the $12k entry gap is past the $2k free, the $2k earmark and the $1k seizure.
        h.setBucket(true, SCALE, 60_000 * SCALE, 58_000 * SCALE, 2_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        h.setPosition(dave, false, SCALE, 48_000 * SCALE, 1_000 * SCALE, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.bucket(true).size, SCALE, "nothing netted off the long bucket");
        assertEq(h.bucket(false).size, SCALE, "the estate stands in the short bucket");
        assertEq(h.claimable(address(this)), FLOOR, "the flat reward alone");
        assertEq(r.unloadPrepaid, FLOOR, "all of it credited against the walk");
    }

    /// @notice Whatever the two sizes, the call pays max(flat, 2 bp of the overlap), credits
    ///         the walk with what that leaves past the netting rate, and leaves the excess in the
    ///         larger side's bucket.
    function testFuzz_netting_paysTheLargerOfFlatAndTheRateOnTheOverlap(uint256 inventorySize, uint256 estateSize)
        public
    {
        // From the $5 order minimum to 100 BTC on each side, so the flat part is the full floor.
        inventorySize = bound(inventorySize, 0.0001e18, 100e18);
        estateSize = bound(estateSize, 0.0001e18, 100e18);
        h.seedInsurance(1_000_000e18);
        _inventory(true, inventorySize);
        _position(dave, false, estateSize, 0); // no collateral: insolvent at any size

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        uint256 overlap = inventorySize < estateSize ? inventorySize : estateSize;
        uint256 rate = _rate(overlap);
        uint256 paid = rate > FLOOR ? rate : FLOOR;
        assertEq(h.claimable(address(this)), paid, "max(flat, rate on the overlap)");
        assertEq(r.unloadPrepaid, paid - rate, "the walk is credited with the flat part past the rate");
        if (inventorySize > estateSize) {
            assertEq(h.bucket(true).size, inventorySize - estateSize, "the long bucket keeps the excess");
            assertEq(h.bucket(false).size, 0, "the estate's bucket was taken whole");
        } else {
            assertEq(h.bucket(true).size, 0, "the long bucket was taken whole");
            assertEq(h.bucket(false).size, estateSize - inventorySize, "the estate's excess stays in the short bucket");
        }
    }
}

// ==================== the netting gate ====================

/// @notice RiskParamsLib.overlapAffordable on two staged buckets: a gain is always netted; a loss
///         is netted when it fits what backs the two netted slices — free capital above the
///         reserve, the ledger's arrears and the slices' own seizure — less what the bucket that
///         survives the netting needs to close at its bankruptcy price without a deficit. And
///         RiskParamsLib.tryNetBuckets spends only what that gate lets it.
contract OverlapGateTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 50_000e18;
    /// @dev Slack for the pro-rata shares the netting and the gate round on their own.
    uint256 internal constant ROUNDING = 1_000;

    NettingHarness internal h;

    function setUp() public {
        h = new NettingHarness();
        h.seedCollateral(1_000_000e18);
    }

    /// @dev The canonical standing pair: a long bucket from $60k bankrupt at $58k ($2k seized)
    ///      against a short bucket from $48k bankrupt at $49k ($1k seized). Netting it loses the
    ///      $12k entry gap against the $3k the two slices bring.
    function _standingPair() internal {
        h.setBucket(true, SCALE, 60_000 * SCALE, 58_000 * SCALE, 2_000 * SCALE, 0);
        h.setBucket(false, SCALE, 48_000 * SCALE, 49_000 * SCALE, 1_000 * SCALE, 0);
    }

    /// @notice A gain is always affordable, whatever the fund holds: the ledger pays it, or owes it.
    function test_gate_gainIsAlwaysAffordable() public {
        // Long from $40k bankrupt at $38k against a short from $48k: netting gains the $8k gap.
        // The fund holds the two earmarks and nothing more.
        h.setBucket(true, SCALE, 40_000 * SCALE, 38_000 * SCALE, 2_000 * SCALE, 0);
        h.setBucket(false, SCALE, 48_000 * SCALE, 49_000 * SCALE, 1_000 * SCALE, 0);
        h.seedInsurance(3_000 * SCALE);

        assertTrue(h.overlapAffordable(PRICE, 0), "a gain needs no backing");
        assertEq(h.tryNet(PRICE, 0), SCALE, "netted");
        assertEq(h.inventorySize(), 0, "both buckets gone");
        assertEq(h.insuranceFundBalance(), 3_000 * SCALE + 8_000 * SCALE, "the gain collected from the ledger");
        assertEq(h.deposits(), 1_000_000e18 - 8_000 * SCALE, "the ledger paid it");
        assertEq(h.arrears(), 0, "paid in full");
    }

    /// @notice A loss is affordable up to free capital plus the slices' own seizure, to the wei.
    function test_gate_lossWithinFreeCapitalAndTheSlicesSeizure() public {
        _standingPair();
        h.seedInsurance(3_000 * SCALE + 9_000 * SCALE); // $9k free above the two earmarks
        assertTrue(h.overlapAffordable(PRICE, 0), "$9k free + $3k seizure carry the $12k loss");

        h.seedInsurance(3_000 * SCALE + 9_000 * SCALE - 1);
        assertFalse(h.overlapAffordable(PRICE, 0), "a wei short");
        assertEq(h.tryNet(PRICE, 0), 0, "refused: nothing moves");
        assertEq(h.inventorySize(), 2 * SCALE, "both buckets stand");
        assertEq(h.insuranceFundBalance(), 3_000 * SCALE + 9_000 * SCALE - 1, "the fund untouched");
    }

    /// @notice The reserve is not spendable on a netting: with a 10% target cached, the one unit of
    ///         open interest the buckets count for at $50k reserves $500 (ADL_RESERVE_BP of the
    ///         target on it), and the netting needs that much more free capital.
    function test_gate_reserveComesOffFreeCapital() public {
        _standingPair();
        h.seedInsurance(3_000 * SCALE + 9_000 * SCALE); // affordable with no reserve
        h.seedTargetRatio(1_000);
        assertFalse(h.overlapAffordable(PRICE, 0), "the $500 reserve on the unit of open interest is held back");

        h.seedInsurance(3_000 * SCALE + 9_500 * SCALE);
        assertTrue(h.overlapAffordable(PRICE, 0), "$500 more carries it");
    }

    /// @notice The ledger's arrears back a loss: the netting pays the slices' seizure first, then
    ///         nets what the ledger owes, and draws free capital only for the rest.
    function test_gate_arrearsBackTheLoss_paidAfterTheSeizure() public {
        _standingPair();
        h.seedInsurance(4_000 * SCALE); // $1k free
        h.seedArrears(8_000 * SCALE);
        assertTrue(h.overlapAffordable(PRICE, 0), "$1k free + $8k arrears + $3k seizure = the $12k loss");

        assertEq(h.tryNet(PRICE, 0), SCALE, "netted");
        assertEq(h.arrears(), 0, "the $8k owed was netted off the payment");
        assertEq(h.insuranceFundBalance(), 0, "$3k of seizure and $1k free paid in cash");
        assertEq(h.deficit(), 0, "covered in full");
        assertEq(h.deposits(), 1_000_000e18 + 4_000 * SCALE, "the ledger received the cash part");
    }

    /// @notice The gate keeps what the surviving bucket needs to close at its bankruptcy price out
    ///         of the netting's reach. Long 10 @ $100 against $30 of cash and $65 of arrears, the
    ///         vault having paid $2 a unit of funding while holding it, is bankrupt at $90.50;
    ///         closing it there needs $85 beyond its earmark — the $65 the ledger never paid and
    ///         the $20 of funding — $8.50 a unit. The fund holds nothing above the earmarks.
    ///         Netting the short bucket, 4 @ $87 against $3 and entered at the live index, loses
    ///         $52 on the entry gap and $8 on the funding the long bucket paid: $60 against the
    ///         overlap's $12 of earmark and the short's $3, $45 beyond their own backing.
    function test_gate_keepsTheSurvivorsBankruptcyCloseBacked() public {
        h.setBucket(true, 10 * SCALE, 1_000 * SCALE, 905 * SCALE, 30 * SCALE, 0);
        int256 idx = int256(2 * SCALE);
        h.setBucket(false, 4 * SCALE, 348 * SCALE, 351 * SCALE, 3 * SCALE, idx);
        h.seedArrears(65 * SCALE);
        h.seedInsurance(33 * SCALE);

        (, uint256 needed) = h.survivorBacking(90 * SCALE, idx);
        assertEq(needed, 85 * SCALE, "premise: the long bucket's bankruptcy close needs $85 beyond its earmark");
        // The 6 surviving units need $51, so $14 of the $65 is spendable: $29 with the slices' own
        // backing, short of the $60. Without the hold-back the $65 and the $15 would carry it.
        assertFalse(h.overlapAffordable(90 * SCALE, idx), "refused: the survivor's $51 is held back");
        assertEq(h.tryNet(90 * SCALE, idx), 0, "nothing netted");

        // $31 more of arrears is exactly what the hold-back costs the netting.
        h.seedArrears(96 * SCALE);
        assertTrue(h.overlapAffordable(90 * SCALE, idx), "$96 - $51 + $15 = $60: affordable");
        h.seedArrears(96 * SCALE - 1);
        assertFalse(h.overlapAffordable(90 * SCALE, idx), "a wei short");
    }

    // ---------------- the netting spends only what the gate lets it ----------------

    struct OverlapCase {
        uint256 longSize;
        uint256 shortSize;
        uint256 longEntry;
        uint256 shortEntry;
        uint256 longCash;
        uint256 shortCash;
        uint256 longOwed;
        uint256 shortOwed;
        uint256 orphan;
        uint256 free;
        uint256 longIdx;
        uint256 shortIdx;
        uint256 liveIdx;
        uint256 target;
        uint256 longOI;
        uint256 shortOI;
        uint256 trailingOi;
        uint256 ledger;
        uint256 price;
    }

    /// @dev Bounds and stages `c`: two buckets of 1 to 40 units, each entered $85 to $115 a unit,
    ///      with up to $20 a unit of collateral seized in cash and up to $10 a unit the ledger
    ///      never paid, carried as arrears alongside up to $20 no bucket relies on; each bucket's
    ///      bankruptcy price is its entry displaced by both. Entry indices and the live index sit
    ///      within $5 a unit of each other either way. The fund holds the two earmarks and up to
    ///      $200 above them under a target of up to 30%, live open interest of up to 40 units a
    ///      side beside the buckets and a trailing reading at or below it, and the ledger holds up
    ///      to $200. The mark runs from $50 to $150.
    /// @return price The mark the gate is read at
    /// @return idx The live funding index
    function _stageOverlap(OverlapCase memory c) internal returns (uint256 price, int256 idx) {
        c.longSize = bound(c.longSize, 1, 40);
        c.shortSize = bound(c.shortSize, 1, 40);
        c.longEntry = bound(c.longEntry, 85, 115);
        c.shortEntry = bound(c.shortEntry, 85, 115);
        c.longCash = bound(c.longCash, 0, 20);
        c.shortCash = bound(c.shortCash, 0, 20);
        c.longOwed = bound(c.longOwed, 0, 10);
        c.shortOwed = bound(c.shortOwed, 0, 10);
        int256 longIdx = (int256(bound(c.longIdx, 0, 10)) - 5) * int256(SCALE);
        int256 shortIdx = (int256(bound(c.shortIdx, 0, 10)) - 5) * int256(SCALE);
        idx = (int256(bound(c.liveIdx, 0, 10)) - 5) * int256(SCALE);
        h.setBucket(
            true,
            c.longSize * SCALE,
            c.longSize * c.longEntry * SCALE,
            c.longSize * (c.longEntry - c.longCash - c.longOwed) * SCALE,
            c.longSize * c.longCash * SCALE,
            longIdx
        );
        h.setBucket(
            false,
            c.shortSize * SCALE,
            c.shortSize * c.shortEntry * SCALE,
            c.shortSize * (c.shortEntry + c.shortCash + c.shortOwed) * SCALE,
            c.shortSize * c.shortCash * SCALE,
            shortIdx
        );
        h.seedArrears((c.longSize * c.longOwed + c.shortSize * c.shortOwed + bound(c.orphan, 0, 20)) * SCALE);
        h.seedInsurance((c.longSize * c.longCash + c.shortSize * c.shortCash + bound(c.free, 0, 200)) * SCALE);
        h.seedCollateral(bound(c.ledger, 0, 200) * SCALE);
        c.longOI = bound(c.longOI, 0, 40);
        c.shortOI = bound(c.shortOI, 0, 40);
        h.seedOI(c.longOI * SCALE, c.shortOI * SCALE, c.longOI * 100 * SCALE, c.shortOI * 100 * SCALE);
        h.seedTargetRatio(bound(c.target, 0, 3_000));
        uint256 longSide = c.longOI + c.longSize;
        uint256 shortSide = c.shortOI + c.shortSize;
        h.seedTrailingOi(bound(c.trailingOi, 0, longSide > shortSide ? longSide : shortSide) * SCALE);
        price = bound(c.price, 50, 150) * SCALE;
    }

    /// @notice Across both sides, entry gaps of either sign, funding paid or received, earmarks
    ///         split between cash and arrears, arrears an earlier inventory left, reserves above
    ///         and below free capital sized on live or trailing open interest, and ledgers too
    ///         thin to pay a gain: a netting the gate refuses moves nothing, and a netting the
    ///         gate passes retires the whole overlap, books no deficit, moves the fund's balance
    ///         plus arrears by exactly the overlap's realization, conserves cash, and leaves the
    ///         surviving bucket reading no less than the smaller of the gate's reading before and
    ///         what that bucket needs to close at its bankruptcy price.
    /// @param c The book, bounded and staged by _stageOverlap
    function testFuzz_netting_spendsOnlyWhatTheGateLetsIt(OverlapCase memory c) public {
        (uint256 price, int256 idx) = _stageOverlap(c);
        (uint256 o, int256 pnl,) = h.overlapOf();
        bool affordable = h.overlapAffordable(price, idx);
        (uint256 backingBefore,) = h.survivorBacking(price, idx);
        uint256 value = h.insuranceFundBalance() + h.arrears();
        uint256 cash = h.insuranceFundBalance() + h.deposits();
        uint256 longBefore = h.bucket(true).size;
        uint256 shortBefore = h.bucket(false).size;

        uint256 netted = h.tryNet(price, idx);

        if (!affordable) {
            assertLt(pnl, 0, "only a loss is ever refused");
            assertEq(netted, 0, "refused: nothing netted");
            assertEq(h.bucket(true).size, longBefore, "long bucket untouched");
            assertEq(h.bucket(false).size, shortBefore, "short bucket untouched");
            assertEq(h.insuranceFundBalance() + h.arrears(), value, "the fund untouched");
            assertEq(h.insuranceFundBalance() + h.deposits(), cash, "cash untouched");
            return;
        }
        assertEq(netted, o, "the whole overlap netted");
        assertEq(h.bucket(true).size, longBefore - o, "long bucket decremented by the overlap");
        assertEq(h.bucket(false).size, shortBefore - o, "short bucket decremented by the overlap");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(
            int256(h.insuranceFundBalance() + h.arrears()), int256(value) + pnl, "the netting alone moves the fund"
        );
        assertEq(h.insuranceFundBalance() + h.deposits(), cash, "cash is conserved");
        (uint256 backing, uint256 needed) = h.survivorBacking(price, idx);
        assertGe(
            backing + ROUNDING,
            Math.min(backingBefore, needed),
            "the bucket left keeps its backing as the gate reads it"
        );
    }
}

// ==================== ADL execution guards ====================

/// @notice Harness that owns its own ADL state and forwards into AdlLib.executeAdlCore.
///         Lets us construct edge-case position states (size > 0, collateral = 0) without
///         standing up a full BazaarPair.
contract AdlHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.FeeEscrow internal feeEscrow;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;

    function setPosition(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
    }

    /// @dev Stage one of the vault's two buckets, backed by `seized`.
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
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    function vaultDeficit() external view returns (uint256) {
        return vault.deficit;
    }

    function setVaultInsurance(uint256 insuranceFundBalance) external {
        vault.insuranceFundBalance = insuranceFundBalance;
    }

    function setVaultCollateral(uint256 totalCollateralDeposited) external {
        vault.totalCollateralDeposited = totalCollateralDeposited;
    }

    // -------- accounting accessors for conservation tests --------
    function vaultInsurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function vaultCollateral() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function positionCollateral(address u) external view returns (uint256) {
        return positionBuckets[u].collateral;
    }

    function positionSize(address u) external view returns (uint256) {
        return positionBuckets[u].size;
    }

    /// @dev Seed OI fields so the ADL close-path doesn't underflow when decrementing them.
    function setOI(
        uint256 totalLongOI,
        uint256 totalShortOI,
        uint256 longWeightedEntrySum,
        uint256 shortWeightedEntrySum
    ) external {
        vault.totalLongOI = totalLongOI;
        vault.totalShortOI = totalShortOI;
        vault.longWeightedEntrySum = longWeightedEntrySum;
        vault.shortWeightedEntrySum = shortWeightedEntrySum;
    }

    // -------- ADL window-deposit state (epoch-tagged score freeze) --------
    uint64 public adlEpoch;
    mapping(address => uint64) internal adlDepositEpoch;
    mapping(address => uint256) internal adlWindowDeposits;

    /// @dev One batch: the first cohort closes the long bucket (shorts), the second the short
    ///      bucket (longs).
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
}

/// @notice Zero-collateral winners in ADL. Score collateral floors at 1 wei: dividing by the raw
///         zero would Panic(0x12), and skipping the position instead would make a winner who
///         withdrew ALL collateral (allowed: the equity gate passes on unrealized PnL alone)
///         ADL-IMMUNE — the exact opposite of intent. With the floor a pure-profit account ranks
///         effectively infinite and is closed FIRST, with its credit computed on its real (zero)
///         collateral.
contract Phase3AdlGuardTest is Test {
    AdlHarness harness;
    uint256 constant SCALE = 1e18;

    address constant BAD_USER = address(0xBAD);

    function setUp() public {
        harness = new AdlHarness();
        // Warp far enough forward that `block.timestamp - 15 minutes` doesn't underflow.
        vm.warp(1_700_000_000);
    }

    // Canonical scenario throughout: LONGS got liquidated (the vault holds a long bucket), so the
    // cohort is the opposite side — the winning SHORTS, submitted as longBucketWinners.
    function _params() internal view returns (BazaarTypes.AdlParams memory) {
        return BazaarTypes.AdlParams({
            adlAuctionStartTs: block.timestamp - 15 minutes, // ADL_AUCTION_DURATION → threshold = 1
            currentPrice: 100 * SCALE,
            currentFundingIndex: 0,
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xBAB)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev A long bucket of `size` units bankrupt at `bankruptcyNotional`, with no earmark: the
    ///      estates' collateral was consumed in full, so the entry basis is the bankruptcy notional.
    function _longBucket(uint256 size, uint256 bankruptcyNotional) internal {
        harness.setBucket({
            isLong: true,
            size: size,
            entryNotional: bankruptcyNotional,
            bankruptcyNotional: bankruptcyNotional,
            seized: 0,
            entryFundingIndex: 0
        });
    }

    /// @notice A zero-collateral winner neither panics nor is skipped: it scores on the 1-wei
    ///         floor (effectively infinite), is closed, and its credit is its PnL on its real
    ///         (zero) collateral.
    function test_ZeroCollateral_WinnerClosedNotSkipped() public {
        // Vault holds 2 units at bankruptcy $100/u, marked at $90 against a $10 fund: the size
        // that restores health exceeds the single unit this winner can cover, so the close is
        // bounded by the winner and not by the batch cap.
        _longBucket(2 * SCALE, 200 * SCALE);
        harness.setOI({
            totalLongOI: 0, totalShortOI: 1 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 150 * SCALE
        });
        harness.setVaultInsurance(10 * SCALE);
        harness.setVaultCollateral(1_000 * SCALE);

        // Short winner: size = 1, entry = $150, collateral = 0 (everything withdrawn on
        // unrealized-PnL equity). At the $90 mark: totalPnl = $60 → score floors to max.
        harness.setPosition({user: BAD_USER, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 0});

        address[] memory winners = new address[](1);
        winners[0] = BAD_USER;

        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 90 * SCALE; // below the bankruptcy price: the vault is in real loss

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, _none(), p);
        assertEq(r.longBucket.eligibleCount, 1, "pure-profit winner is eligible, not skipped");
        assertEq(r.longBucket.closedSize, 1 * SCALE, "closed in full");
        assertEq(r.longBucket.settlementPrice, 100 * SCALE, "settled at the bucket's bankruptcy price");
        assertEq(harness.positionCollateral(BAD_USER), 50 * SCALE, "credit = PnL on real (zero) collateral");
        // Closed at its own basis, the inventory moves the fund only by the executor's 2 bp of
        // the unit at the $90 mark, $0.018, more than 0.1% of the $10 the close averted.
        assertEq(
            harness.vaultInsurance(), 10 * SCALE - 0.018e18, "inventory closed at its own basis: only the reward leaves"
        );
        assertEq(harness.bucket(true).size, 1 * SCALE, "one unit of the bucket left");
    }

    /// @notice Zero-collateral winner ranks FIRST (descending-score order) ahead of a normal
    ///         winner, and both are processed.
    function test_ZeroCollateral_RanksFirst_BothProcessed() public {
        address validUser = address(0xC001);

        _longBucket(2 * SCALE, 200 * SCALE);
        // Seed short-side OI matching the winners so the close-path's OI decrement doesn't underflow.
        harness.setOI({
            totalLongOI: 0, totalShortOI: 2 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 300 * SCALE
        });
        // An empty fund can finish nothing inside the band, so the size that restores health is
        // the whole exposure: the batch cap leaves room for both closes.
        harness.setVaultInsurance(0);
        harness.setVaultCollateral(1_000 * SCALE);

        // Pure-profit winner (short): size > 0, collateral = 0 → floored score (max).
        harness.setPosition({user: BAD_USER, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 0});
        // Normal winner (short): $130 pnl on $10 collateral at the $20 mark → score 13e18.
        harness.setPosition({
            user: validUser, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 10 * SCALE
        });

        // Submitted in the wrong order: the batch sorts by descending score and closes the
        // pure-profit winner first.
        address[] memory winners = new address[](2);
        winners[0] = validUser;
        winners[1] = BAD_USER;

        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 20 * SCALE; // below the $100 bankruptcy price: the vault is in real loss

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, _none(), p);
        assertEq(r.longBucket.eligibleCount, 2, "both winners eligible");
        assertEq(r.longBucket.closedSize, 2 * SCALE, "both closed");
        assertEq(r.longBucket.highestAdlScore, 130 * SCALE * SCALE, "the floored score ranks first: $130 over a wei");
        assertEq(r.longBucket.lowestAdlScore, 13 * SCALE, "the normal winner ranks last: $130 over $10");
        assertEq(harness.positionCollateral(BAD_USER), 50 * SCALE, "pure-profit credit = pnl");
        assertEq(harness.positionCollateral(validUser), 60 * SCALE, "normal credit = collateral + pnl");
    }

    /// @notice The batch cap spares the winners the exposure does not need, and it stops at a
    ///         size rather than at a winner boundary: with 6 eligible units and the fund $85
    ///         short of what finishing them at the band edge would cost, 1.48 units close — the
    ///         second winner partially, the last four not at all. Rounding the stop up to whole
    ///         winners would deleverage the rest of the second for nothing.
    function test_BatchCap_SparesRemainingWinnersOnceTheFundIsRestored() public {
        // Long-side liq: vault inherited longs at bankruptcy $200; current price = $150 →
        // per-unit exposure = $50. Six total units in the long bucket. Winners are shorts.
        _longBucket(6 * SCALE, 1_200 * SCALE);
        harness.setOI({
            totalLongOI: 0, totalShortOI: 6 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 1_200 * SCALE
        });

        // Finishing the 6 units at the band edge ($142.50, the $150 mark less the 5% band) would
        // cost 6 × $57.50 = $345 against a $260 fund, none of it earmarked, so $85 must come off.
        // Each unit closed at the $200 bankruptcy price removes $57.50 of that and hands $0.05 of
        // it to the executor (0.1% of the $50 it averts, more than 2 bp of its notional at the
        // mark), so the cap lands at 85 / 57.45 = 1.48 units.
        harness.setVaultInsurance(260 * SCALE);

        // Six valid short winners, each with 1-unit position, $200 entry, $10 collateral —
        // positive PnL at the $150 mark ($50/unit).
        address[] memory winners = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            address w = address(uint160(uint256(keccak256(abi.encode("winner", i)))));
            harness.setPosition({
                user: w, isLong: false, size: 1 * SCALE, entryValue: 200 * SCALE, collateral: 10 * SCALE
            });
            winners[i] = w;
        }
        // Identical positions score identically, and the batch breaks the tie by ascending
        // address; sorted here the same way so the assertions can name the ranked order.
        for (uint256 i = 1; i < 6; i++) {
            for (uint256 j = i; j > 0 && winners[j] < winners[j - 1]; j--) {
                (winners[j], winners[j - 1]) = (winners[j - 1], winners[j]);
            }
        }

        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 150 * SCALE;

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, _none(), p);

        // All six pre-qualify in the scan; the cap decides how much of that eligible size the
        // close pass actually consumes.
        assertEq(r.longBucket.eligibleSize, 6 * SCALE, "all six pre-qualified");
        assertApproxEqRel(r.longBucket.closedSize, 1.479547e18, 0.0001e18, "$85 excess / $57.45 per unit");

        assertEq(harness.positionSize(winners[0]), 0, "first winner closed in full");
        assertEq(harness.positionSize(winners[1]), 2 * SCALE - r.longBucket.closedSize, "second closed only to the cap");
        assertEq(harness.positionSize(winners[2]), 1 * SCALE, "third untouched");
        assertEq(harness.positionSize(winners[3]), 1 * SCALE, "fourth untouched");
        assertEq(harness.positionSize(winners[4]), 1 * SCALE, "fifth untouched");
        assertEq(harness.positionSize(winners[5]), 1 * SCALE, "sixth untouched");
    }

    /// @notice The band the batch is sized against reads the lower of the current rate and the
    ///         lagged minimum. With the current rate at the 5% cap but a 2.5% minimum over the
    ///         day, finishing at the narrower edge ($146.25) costs $53.75 a unit against the same
    ///         $260 fund, so the cap lands at 62.5 / 53.70 = 1.16 units rather than 1.48.
    function test_BatchCap_BandReadsTheLaggedMinimum() public {
        _longBucket(6 * SCALE, 1_200 * SCALE);
        harness.setOI({
            totalLongOI: 0, totalShortOI: 6 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 1_200 * SCALE
        });
        harness.setVaultInsurance(260 * SCALE);
        address[] memory winners = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            address w = address(uint160(uint256(keccak256(abi.encode("winner", i)))));
            harness.setPosition({
                user: w, isLong: false, size: 1 * SCALE, entryValue: 200 * SCALE, collateral: 10 * SCALE
            });
            winners[i] = w;
        }
        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 150 * SCALE;
        p.marginRequirements.laggedMmrBp = 250;

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, _none(), p);
        assertApproxEqRel(r.longBucket.closedSize, 1.163873e18, 0.001e18, "$62.5 excess / $53.70 per unit");
        assertLt(r.longBucket.closedSize, 1.48e18, "narrower band, smaller batch than at the 5% cap");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║   ADL ACCOUNTING CONSERVATION — inventory settled by insurance ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Canonical scenario: the vault inherited 1 unit of longs, estate entry $250 and
    ///      bankruptcy $200 (a $50 seizure sitting in the fund), one short winner entered at
    ///      $250 with $10 collateral (+$50 at the $200 settlement), profitable at the $150
    ///      mark. Returns the winner address.
    function _setupFundedWinner(uint256 insurance, uint256 collateralTracked) internal returns (address winner) {
        harness.setBucket({
            isLong: true,
            size: 1 * SCALE,
            entryNotional: 250 * SCALE,
            bankruptcyNotional: 200 * SCALE,
            seized: 50 * SCALE,
            entryFundingIndex: 0
        });
        harness.setOI({
            totalLongOI: 0, totalShortOI: 1 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 250 * SCALE
        });
        harness.setVaultInsurance(insurance);
        harness.setVaultCollateral(collateralTracked);

        winner = address(0xBEEF);
        harness.setPosition({
            user: winner, isLong: false, size: 1 * SCALE, entryValue: 250 * SCALE, collateral: 10 * SCALE
        });
    }

    function _fundedWinnerParams() internal view returns (BazaarTypes.AdlParams memory p) {
        p = _params();
        p.currentPrice = 150 * SCALE; // short is +$100 here → eligible
    }

    /// @notice The inventory slice realizes its loss from the estate's entry to the settlement
    ///         price ($200 − $250 = −$50, exactly the seizure) as an I → D transfer, and the
    ///         winner is credited their full $50 PnL. The two coincide here because the winner
    ///         entered at the estate's entry; `insurance + totalCollateralDeposited` is conserved.
    function test_Conservation_VaultLossReturnsSeizureToLedger() public {
        // The fund holds exactly the $50 it seized off the estate and no free capital, so the
        // size that restores health is the whole unit and the winner closes in full.
        address winner = _setupFundedWinner({insurance: 50 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();

        uint256 iBefore = harness.vaultInsurance();
        uint256 tBefore = harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, _none(), p);

        assertEq(iBefore - harness.vaultInsurance(), 50 * SCALE, "insurance returned the seizure to the ledger");
        assertEq(harness.vaultCollateral() - tBefore, 50 * SCALE, "deposits ledger grew by the vault's loss");
        assertEq(harness.positionCollateral(winner), 60 * SCALE, "winner credited entry collateral + PnL");
        assertEq(harness.vaultDeficit(), 0, "no bad debt");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(),
            iBefore + tBefore,
            "insurance + totalCollateralDeposited conserved (Check-3 invariant holds)"
        );
    }

    /// @notice No free capital: the fund holds exactly the $50 seizure and the live index charges
    ///         the long inventory $5 more, so the vault's loss is $55. The seizure is returned to
    ///         the ledger, the $5 the fund cannot back is withheld from the winner's own $5 of
    ///         funding income, nothing is booked as deficit, and the pair stays solvent.
    function test_Conservation_CarryShortfall_WithheldFromWinnerFunding() public {
        address winner = _setupFundedWinner({insurance: 50 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();
        p.currentFundingIndex = int256(5 * SCALE); // shorts receive $5/unit; the vault's long pays it

        uint256 sumBefore = harness.vaultInsurance() + harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, _none(), p);

        assertEq(harness.vaultInsurance(), 0, "seizure fully returned to the ledger");
        assertEq(harness.vaultCollateral() - 1_000 * SCALE, 50 * SCALE, "ledger grew by what the fund could pay");
        assertEq(harness.positionCollateral(winner), 60 * SCALE, "price PnL $50 paid in full, $5 funding withheld");
        assertEq(harness.vaultDeficit(), 0, "a withheld carry is not bad debt");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(),
            sumBefore,
            "insurance + totalCollateralDeposited conserved"
        );
    }

    /// @notice The fund holds less than the seizure it earmarked ($20 against $50) and the
    ///         inventory owes $5 of funding: the $35 shortfall exceeds the winner's $5 funding
    ///         income, so that income is withheld and the remaining $30 is recorded as deficit.
    ///         The winner's $50 price PnL is never touched.
    function test_Conservation_EarmarkBreach_RecordsDeficitBeyondWinnerFunding() public {
        address winner = _setupFundedWinner({insurance: 20 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();
        p.currentFundingIndex = int256(5 * SCALE);

        uint256 sumBefore = harness.vaultInsurance() + harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, _none(), p);

        assertEq(harness.vaultInsurance(), 0, "insurance fully drawn");
        assertEq(harness.vaultCollateral() - 1_000 * SCALE, 20 * SCALE, "ledger grew only by the funded amount");
        assertEq(harness.positionCollateral(winner), 60 * SCALE, "price PnL intact, funding income withheld");
        assertEq(harness.vaultDeficit(), 30 * SCALE, "unbacked remainder recorded as deficit");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(), sumBefore, "the deficit is bookkeeping: I + D unmoved"
        );
    }

    /// @notice Direction regression: positions on the SAME side as the bucket (here longs, since
    ///         the vault holds a long bucket) must never qualify as that leg's winners, even with
    ///         positive PnL — only the opposite side closes a bucket.
    function test_SameSideAsLiquidation_NeverEligible() public {
        _longBucket(1 * SCALE, 100 * SCALE);

        // A long that entered cheap enough to be in profit at the $100 mark.
        address cheapLong = address(0x10);
        harness.setPosition({
            user: cheapLong, isLong: true, size: 1 * SCALE, entryValue: 50 * SCALE, collateral: 10 * SCALE
        });

        address[] memory winners = new address[](1);
        winners[0] = cheapLong;

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        harness.execAdl(winners, _none(), _params());
    }
}

// ==================== vault health / ADL trigger ====================

/// @notice Harness exposing VaultHealthLib.checkLiqExposure for direct testing.
contract VaultHealthHarness {
    BazaarTypes.Vault public vault;

    /// @dev Warmup MMR; the unload band it derives is capped at 5% of the price.
    uint256 constant MMR_BP = 1_000;

    /// @dev Stage one of the vault's two buckets.
    function setBucket(
        bool isLong,
        uint256 size,
        uint256 entryNotional,
        uint256 bankruptcyNotional,
        uint256 seized,
        int256 entryFundingIndex
    ) external {
        _write(isLong, size, entryNotional, bankruptcyNotional, seized, entryFundingIndex);
    }

    /// @dev Stage one bucket and the fund. `seizedCollateral` reconstructs the entry basis the
    ///      loss is measured from: a long's equity reaches zero that far BELOW entry, a short's
    ///      that far above. The two must stay consistent because insuranceFundBalance is expected
    ///      to already hold that collateral — a fixture with a large gap and a tiny fund is not a
    ///      state the protocol can reach.
    function setVault(
        uint256 insuranceFundBalance,
        uint256 size,
        uint256 bankruptcyNotional,
        bool isLong,
        uint256 seizedCollateral
    ) external {
        vault.insuranceFundBalance = insuranceFundBalance;
        _write(
            isLong,
            size,
            isLong ? bankruptcyNotional + seizedCollateral : bankruptcyNotional - seizedCollateral,
            bankruptcyNotional,
            seizedCollateral,
            0
        );
    }

    function setInsurance(uint256 insuranceFundBalance) external {
        vault.insuranceFundBalance = insuranceFundBalance;
    }

    function setEntryFundingIndex(bool isLong, int256 i) external {
        BazaarTypes.Inventory storage b = isLong ? vault.longInv : vault.shortInv;
        b.entryFundingIndex = int192(i);
    }

    /// @dev Stage the entry basis independently of the bankruptcy notional, for fixtures where
    ///      the bankruptcy price also carries funding the estate accrued before liquidation.
    function setEntryNotional(bool isLong, uint256 x) external {
        BazaarTypes.Inventory storage b = isLong ? vault.longInv : vault.shortInv;
        b.entryNotional = x;
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    function check(uint256 currentPrice, bool isAdlPending, uint256 adlPendingSince)
        external
        view
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(vault, currentPrice, isAdlPending, adlPendingSince, int256(0), MMR_BP);
    }

    function checkWithFunding(uint256 currentPrice, int256 currentFundingIndex)
        external
        view
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(vault, currentPrice, false, 0, currentFundingIndex, MMR_BP);
    }

    function _write(
        bool isLong,
        uint256 size,
        uint256 entryNotional,
        uint256 bankruptcyNotional,
        uint256 seized,
        int256 entryFundingIndex
    ) internal {
        BazaarTypes.Inventory storage b = isLong ? vault.longInv : vault.shortInv;
        b.size = size;
        b.entryNotional = entryNotional;
        b.bankruptcyNotional = bankruptcyNotional;
        b.seized = seized;
        b.entryFundingIndex = int192(entryFundingIndex);
    }
}

/// @notice Tests for the vault expected-loss calculation: what closing the inherited inventory
///         would take out of the fund, measured on the liquidatees' entry basis over both
///         buckets, and the window it opens, holds and releases.
contract Phase3VaultHealthTest is Test {
    VaultHealthHarness h;
    uint256 constant SCALE = 1e18;

    function setUp() public {
        h = new VaultHealthHarness();
    }

    /// @notice Long-side loss: entry $250, P = $100, size = 1 → loss = $150.
    function test_LongLiq_LossAtBelowBankruptcy() public {
        // size 1, bankruptcy $200 with $50 of collateral seized → entry basis $250
        h.setVault({
            insuranceFundBalance: 1_000_000 * SCALE, // huge so threshold not tripped
            size: 1 * SCALE,
            bankruptcyNotional: 200 * SCALE,
            isLong: true,
            seizedCollateral: 50 * SCALE
        });
        // current price $100 → loss = $250 - $100 = $150
        // Free capital is $1M with nothing cached as a target; $150 nowhere near, healthy=true.
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0);
        assertTrue(r.healthy);
        assertFalse(r.newIsAdlPending);
    }

    /// @notice Short-side loss: entry $50, P = $200, size = 1 → loss = $150.
    function test_ShortLiq_LossAtAboveBankruptcy() public {
        h.setVault({
            insuranceFundBalance: 1_000_000 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE, // bankruptcy $100, above a short's entry
            isLong: false,
            seizedCollateral: 50 * SCALE // → entry basis $50
        });
        // current price $200; a short loses as price rises → loss = $200 - $50 = $150.
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, false, 0);
        assertTrue(r.healthy);
    }

    /// @notice Vault long position in PROFIT against the entry basis → no loss, no ADL. The
    ///         inventory closes for more than it was inherited at, so nothing leaves the fund.
    function test_LongLiq_AboveEntry_NoExposure() public {
        // entry $1,200 (bankruptcy $1,000 + $200 seized), current $1,500 — vault is up money
        h.setVault({
            insuranceFundBalance: 200 * SCALE, // holds the seizure and nothing more
            size: 10 * SCALE,
            bankruptcyNotional: 1_000 * SCALE, // 10 × $100
            isLong: true,
            seizedCollateral: 200 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(150 * SCALE, false, 0);
        assertTrue(r.healthy, "vault in profit, no exposure");
        assertFalse(r.newIsAdlPending, "ADL must not trigger");
    }

    /// @notice Inventory still inside the collateral taken in costs the fund nothing on net,
    ///         however thin the fund is. The seizure covers exactly this stretch, so a gate that
    ///         counted the loss without also discounting the seizure would fire on every fresh
    ///         liquidation — a position liquidated at its margin boundary has lost its collateral
    ///         by construction.
    function test_LongLiq_WithinSeizedCollateral_NoTrigger() public {
        // entry $1,200, bankruptcy $1,000 ($200 seized), current $1,100 — between the two
        h.setVault({
            insuranceFundBalance: 200 * SCALE, // the seizure and nothing more
            size: 10 * SCALE,
            bankruptcyNotional: 1_000 * SCALE,
            isLong: true,
            seizedCollateral: 200 * SCALE
        });
        // $100 of inventory loss against $200 of collateral → episode is $100 ahead.
        VaultHealthLib.LiqExposureResult memory r = h.check(110 * SCALE, false, 0);
        assertTrue(r.healthy, "loss inside the collateral is not an exposure");
        assertFalse(r.newIsAdlPending);
    }

    /// @notice Past the collateral, the gate must fire against the capital that existed BEFORE
    ///         the seizure. Comparing the overrun to the raw balance instead scales the trigger
    ///         with the position taken on, so the larger the liquidation the harder it becomes
    ///         to fire — and the fund drains to nothing without the auction ever opening.
    function test_LongLiq_BeyondCollateral_FiresAgainstPreSeizureCapital() public {
        // $10 fund before, $100 seized → balance $110. Entry $1,000, bankruptcy $900.
        // Current $850 is $50 past the collateral: closing here leaves the fund at −$40.
        h.setVault({
            insuranceFundBalance: 110 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 900 * SCALE,
            isLong: true,
            seizedCollateral: 100 * SCALE
        });
        // Overrun $50 vs the $10 of free capital above the seizure.
        VaultHealthLib.LiqExposureResult memory r = h.check(850 * SCALE, false, 0);
        assertFalse(r.healthy, "overrun past the collateral must open the auction");
        assertTrue(r.newIsAdlPending);
    }

    /// @notice Funding accrued on the inventory is part of the claim: a vault holding longs
    ///         while the index rises owes that leg on unload, and a price-only gate would miss it.
    function test_LongLiq_FundingLegCountedInTrigger() public {
        // entry $110, current $110 — flat on price alone
        h.setVault({
            insuranceFundBalance: 100 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE,
            isLong: true,
            seizedCollateral: 10 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory flat = h.checkWithFunding(110 * SCALE, 0);
        assertTrue(flat.healthy, "no price gap and no funding -> nothing owed");

        // $101/unit of funding accrued against the vault's longs: $91 owed beyond the $10 seizure,
        // against $90 of free capital above it.
        VaultHealthLib.LiqExposureResult memory owed = h.checkWithFunding(110 * SCALE, 101 * int256(SCALE));
        assertFalse(owed.healthy, "funding owed on the inventory triggers ADL on its own");
    }

    /// @notice The funding an estate accrued before liquidation is counted once. It sits inside
    ///         the bankruptcy price and inside the funding leg the vault realizes from the estate's
    ///         entry, so the seizure has to be the collateral the fund actually received rather
    ///         than the gap between the two notionals: with $10 of pre-liquidation funding on a
    ///         $50 seizure, the inventory is whole exactly at its $220 bankruptcy price.
    function test_LongLiq_PreLiquidationFundingCountedOnce() public {
        // entry $260, $50 seized, $10/unit paid before liquidation → bankruptcy $220 (= 260 − 50 + 10).
        h.setVault({
            insuranceFundBalance: 50 * SCALE, // the seizure and nothing more: any loss trips the gate
            size: 1 * SCALE,
            bankruptcyNotional: 220 * SCALE,
            isLong: true,
            seizedCollateral: 50 * SCALE
        });
        h.setEntryNotional(true, 260 * SCALE);
        h.setEntryFundingIndex(true, -10 * int256(SCALE)); // live index 0: $10/unit accrued since entry

        assertTrue(h.checkWithFunding(220 * SCALE, 0).healthy, "whole at the bankruptcy price");
        assertFalse(h.checkWithFunding(219 * SCALE, 0).healthy, "a dollar under it is a loss the fund cannot carry");
    }

    /// @notice Deep underwater must trigger: entry $250, current $50 → $200 claim against a
    ///         $100 fund.
    function test_LongLiq_DeepUnderwater_TriggersAdl() public {
        h.setVault({
            insuranceFundBalance: 100 * SCALE, // small fund
            size: 1 * SCALE,
            bankruptcyNotional: 200 * SCALE,
            isLong: true,
            seizedCollateral: 50 * SCALE
        });
        // Free capital above the $50 seizure is $50; the $200 claim clears it.
        VaultHealthLib.LiqExposureResult memory r = h.check(50 * SCALE, false, 0);
        assertFalse(r.healthy, "deep underwater must trigger ADL");
        assertTrue(r.newIsAdlPending);
        assertEq(r.newAdlPendingSince, block.timestamp, "the window's clock starts now");
    }

    /// @notice A short bucket opens the window by the same rule: shorts liquidated on a spike,
    ///         entry $50, current $200, loss $150 against no free capital beyond the seizure.
    function test_ShortLiq_BeyondCollateral_OpensTheWindow() public {
        h.setVault({
            insuranceFundBalance: 50 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE,
            isLong: false,
            seizedCollateral: 50 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, false, 0);
        assertFalse(r.healthy, "$100 past the seizure against nothing free");
        assertTrue(r.newIsAdlPending, "shorts liquidated -> the window opens all the same");
        assertEq(h.bucket(true).size, 0, "the long bucket plays no part");
    }

    /// @notice A vault whose inventory sits at its entry basis owes nothing, so no ADL — there
    ///         is no floor under expectedLoss that would trip on the fund's size alone.
    function test_NoFloor_BreakEven_NoFalseAdl() public {
        // entry = $100 (no collateral left to seize), current = $100 — exactly break-even
        h.setVault({
            insuranceFundBalance: 1 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE,
            isLong: true,
            seizedCollateral: 0
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0);
        assertTrue(r.healthy, "no floor: break-even is healthy regardless of fund size");
        assertFalse(r.newIsAdlPending);
    }

    /// @notice A seizure that dwarfs the fund it lands in must not open an auction by itself.
    ///         The inventory arrives having consumed its collateral, so charging that against a
    ///         balance the same collateral just inflated would halt trading on essentially every
    ///         liquidation into a thin fund.
    function test_LargeSeizureIntoThinFund_NoSpuriousTrigger() public {
        // $2 fund before the liquidation, $100 of collateral seized → balance $102.
        // Inventory sits exactly at bankruptcy: closing it pays back the $100 and leaves $2.
        h.setVault({
            insuranceFundBalance: 102 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE,
            isLong: true,
            seizedCollateral: 100 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0);
        assertTrue(r.healthy, "episode is whole: the seizure covers the inventory exactly");
        assertFalse(r.newIsAdlPending);
    }

    // ---------------- two buckets ----------------

    /// @notice An estate seized onto the side opposite the inventory mid-window, because the fund
    ///         could not afford to net it, is inventory like any other: its loss beyond its seizure
    ///         joins the figure, and nothing else about the window changes. The window holds while
    ///         the net exposure's finish at the band edge is past the base, and its clock is the
    ///         one it opened with.
    function test_OppositeBucketSeededMidWindow_WindowHolds_ClockPreserved() public {
        vm.warp(1_700_000_000);
        uint256 since = block.timestamp - 1 hours;

        // The window opened on a short bucket: 1 unit bankrupt at $100, $50 seized, fund $100.
        // At $200 finishing it at the $210 band edge costs $110 against $50 of free capital.
        h.setVault({
            insuranceFundBalance: 100 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE,
            isLong: false,
            seizedCollateral: 50 * SCALE
        });
        assertFalse(h.check(200 * SCALE, true, since).healthy, "premise: the short bucket alone holds the window");

        // A long estate the fund could not net joins the long bucket: 0.5 units from $150/u,
        // bankrupt at $100/u, $25 seized with it, which the fund now holds too.
        h.setBucket(true, SCALE / 2, 75 * SCALE, 50 * SCALE, 25 * SCALE, 0);
        h.setInsurance(125 * SCALE);

        // The overlap, half a unit from $150 against half a unit from $50, loses $50 whatever the
        // price, which its $50 of seizure covers; the net short half-unit loses $55 at the $210
        // edge against $50 of free capital: the window holds.
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, true, since);
        assertFalse(r.healthy, "the net exposure's finish is past the base");
        assertTrue(r.newIsAdlPending, "still pending");
        assertEq(r.newAdlPendingSince, since, "termination clock NOT reset by the second bucket");
        assertFalse(r.adlTimeoutExpired);
    }

    /// @notice Two equal buckets are a hedged pair: the overlap's loss is the gap between the two
    ///         bankruptcy prices, fixed whatever the price does, so the window a fund short of it
    ///         opens holds at any mark — the band edge adds nothing to a nil net exposure — and
    ///         releases at any mark once the fund carries it.
    function test_OverlapOnly_LossIsFixed_WindowHoldsAtAnyPrice() public {
        vm.warp(1_700_000_000);
        uint256 since = block.timestamp - 1 hours;
        // Long 1 unit from $150, bankrupt at $100 ($50 seized); short 1 unit from $50, bankrupt at
        // $90 ($40 seized): the overlap is $10 under water at every price. $5 of free capital.
        h.setBucket(true, 1 * SCALE, 150 * SCALE, 100 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 1 * SCALE, 50 * SCALE, 90 * SCALE, 40 * SCALE, 0);
        h.setInsurance(95 * SCALE);

        assertFalse(h.check(100 * SCALE, false, 0).healthy, "$10 of fixed loss over $5 of base opens the window");
        assertFalse(h.check(50 * SCALE, true, since).healthy, "held at $50");
        assertFalse(h.check(500 * SCALE, true, since).healthy, "held at $500");
        assertEq(h.check(500 * SCALE, true, since).newAdlPendingSince, since, "clock untouched");

        h.setInsurance(100 * SCALE);
        assertTrue(h.check(50 * SCALE, true, since).healthy, "$10 of base carries the overlap: released at $50");
        assertTrue(h.check(500 * SCALE, true, since).healthy, "and at $500");
        assertTrue(h.check(100 * SCALE, false, 0).healthy, "and nothing opens");
    }

    /// @notice A pending window whose remainder no longer threatens the fund is released outright,
    ///         clock cleared: a short bucket bankrupt at $100 against a $1,000 fund, marked $110,
    ///         costs $15.50 to finish at the $115.50 band edge against $950 of free capital.
    function test_PendingResolved_WindowReleased_ClockCleared() public {
        vm.warp(1_700_000_000);
        uint256 since = block.timestamp - 1 hours;

        h.setVault({
            insuranceFundBalance: 1_000 * SCALE,
            size: 1 * SCALE,
            bankruptcyNotional: 100 * SCALE,
            isLong: false,
            seizedCollateral: 50 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(110 * SCALE, true, since);
        assertTrue(r.healthy);
        assertFalse(r.newIsAdlPending, "ADL no longer necessary - cleared");
        assertEq(r.newAdlPendingSince, 0, "clock cleared");
    }

    /// @notice A second bucket does not open the window by existing: two buckets whose overlap
    ///         loses $5 at every price, against $10 of base, are healthy at the mark that leaves
    ///         the long bucket whole and at one that puts it $100 under — the net exposure is nil,
    ///         so only the fixed $5 counts.
    function test_OppositeBucket_DoesNotOpenTheWindowByItself() public {
        // Long 1 unit from $150, bankrupt at $100 ($50 seized); short 1 unit from $50, bankrupt at
        // $95 ($45 seized). $10 free above the $95 of earmarks.
        h.setBucket(true, 1 * SCALE, 150 * SCALE, 100 * SCALE, 50 * SCALE, 0);
        h.setBucket(false, 1 * SCALE, 50 * SCALE, 95 * SCALE, 45 * SCALE, 0);
        h.setInsurance(105 * SCALE);

        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0);
        assertTrue(r.healthy, "$5 of overlap loss inside the $10 base");
        assertFalse(r.newIsAdlPending, "no window");
        r = h.check(200 * SCALE, false, 0);
        assertTrue(r.healthy, "the same at $200: the price cancels on the pair");
        assertFalse(r.newIsAdlPending, "no window");
    }
}

// ==================== ERC20 transfer safety ====================

/// @notice ERC20 return-value handling. Uses vm.mockCall to make USDC.transfer / transferFrom
///         return `false` silently instead of reverting — the non-standard-token case a bare
///         `.call` would read as success. Every such transfer must revert instead.
contract Phase1TransferSafetyTest is Test {
    bytes32 constant BTC_USD_FEED_ID = bytes32(uint256(1));
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    BazaarFactory factory;
    BazaarPair pair;
    MockUSDC usdc;
    address user;

    function setUp() public {
        user = makeAddr("user");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));

        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);

        address deployer = makeAddr("deployer");
        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        usdc.mint(user, 1_000 * USDC_SCALE);
    }

    /// @notice The deposit must revert because SafeERC20 detects the `false` return value from
    ///         transferFrom. An unchecked low-level call would read it as success and credit
    ///         collateral that never arrived.
    function test_depositCollateral_SilentFailingTransferFrom_Reverts() public {
        uint256 amount = 100 * BAZAAR_SCALE;

        vm.prank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);

        // Make USDC.transferFrom return false silently for any args.
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false));

        vm.prank(user);
        vm.expectRevert(); // SafeERC20: revert without specific selector
        pair.depositCollateral(amount, 0, 0, 0, "", "");
    }

    /// @notice Same regression for withdrawCollateral path (contract → user transfer).
    function test_withdrawCollateral_SilentFailingTransfer_Reverts() public {
        uint256 amount = 100 * BAZAAR_SCALE;

        // Deposit first (normal flow)
        vm.prank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        vm.prank(user);
        pair.depositCollateral(amount, 0, 0, 0, "", "");

        // Now make USDC.transfer return false silently
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));

        bytes[] memory emptyPu = new bytes[](0);
        vm.prank(user);
        vm.expectRevert();
        pair.withdrawCollateral(amount / 2, emptyPu, 0, 0, 0, "");
    }
}
