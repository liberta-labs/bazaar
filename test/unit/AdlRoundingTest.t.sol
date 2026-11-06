// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";

/// @dev One vault a liquidation and an ADL batch both run against, so a seizure and the close of
///      what it seized are checked end to end without a full BazaarPair.
contract AdlRoundingHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;
    BazaarTypes.FeeEscrow internal feeEscrow;
    mapping(address => uint64) internal adlDepositEpoch;
    mapping(address => uint256) internal adlWindowDeposits;

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

    function setOI(uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum) external {
        vault.totalLongOI = longOI;
        vault.totalShortOI = shortOI;
        vault.longWeightedEntrySum = longSum;
        vault.shortWeightedEntrySum = shortSum;
    }

    function seedCollateral(uint256 amount) external {
        vault.totalCollateralDeposited = amount;
    }

    function seedInsurance(uint256 amount) external {
        vault.insuranceFundBalance = amount;
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
        b.entryFundingIndex = entryFundingIndex;
    }

    function _marginReqs() internal pure returns (BazaarTypes.MarginRequirements memory) {
        return BazaarTypes.MarginRequirements({imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0});
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
                marginReqs: _marginReqs(),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    /// @dev One batch at `price` with the auction fully decayed. The first cohort closes the long
    ///      bucket (shorts), the second the short bucket (longs).
    function execAdl(
        address[] calldata longBucketWinners,
        address[] calldata shortBucketWinners,
        uint256 price,
        int256 fundingIndex
    ) external returns (BazaarTypes.AdlResult memory) {
        return AdlLib.executeAdlCore(
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            longBucketWinners,
            shortBucketWinners,
            BazaarTypes.AdlParams({
                adlAuctionStartTs: block.timestamp - 15 minutes,
                currentPrice: price,
                currentFundingIndex: fundingIndex,
                marginRequirements: _marginReqs(),
                pairId: bytes32("TEST"),
                adlId: 0,
                currentBlock: 1
            }),
            0,
            adlDepositEpoch,
            adlWindowDeposits
        );
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function deposits() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    /// @dev The seizure earmarked against both buckets.
    function seizedTotal() external view returns (uint256) {
        return vault.longInv.seized + vault.shortInv.seized;
    }

    function positionSize(address user) external view returns (uint256) {
        return positionBuckets[user].size;
    }

    function positionCollateral(address user) external view returns (uint256) {
        return positionBuckets[user].collateral;
    }
}

/// @notice A close at the estates' bankruptcy price costs the fund the collateral seized with the
///         inventory and nothing more, so a fund holding exactly that seizure settles it, to the
///         wei, however the figures round. Every scenario here runs with no free capital, no
///         funding accrued while the vault held the inventory and winners that earned no funding,
///         which leaves rounding as the only thing that could go unfunded: a seizure recorded
///         below the estate's true bankruptcy notional, a settlement price rounded away from the
///         fund, or the pro-rata shares of a partial slice.
contract AdlRoundingTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant LEDGER = 1_000_000e18;
    /// @dev One unit of USDC precision, the most of a close's shortfall treated as rounding.
    uint256 internal constant ALLOWANCE = 1e12;

    AdlRoundingHarness internal h;
    address internal loser = makeAddr("loser");
    address internal winner = makeAddr("winner");
    address internal ally = makeAddr("ally");
    address internal ally2 = makeAddr("ally2");

    function setUp() public {
        h = new AdlRoundingHarness();
        vm.warp(1_700_000_000);
        h.seedCollateral(LEDGER);
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

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Liquidate `loser` into a fund holding nothing beyond earmarks: the seizure joins them,
    ///      so free capital stays zero and the liquidator's flat reward is capped to nothing.
    function _seize(uint256 price, int256 fundingIndex) internal {
        BazaarTypes.LiquidateResult memory r = h.liquidate(_one(loser), price, fundingIndex);
        assertEq(r.liquidatedCount, 1, "fixture: the estate was seized");
        assertEq(h.insurance(), h.seizedTotal(), "fixture: the fund holds the seizures and nothing else");
    }

    // ---------------------------- whole inventory ----------------------------

    /// @notice A 3-unit long from $1,000 on $100 is bankrupt at a notional of $2,900, a price
    ///         that does not divide: $966.66… per unit. The seizure records the $2,900 itself and
    ///         the batch settles at the price rounded up, so the vault's sale realizes a wei more
    ///         than the bankruptcy notional, its loss is a wei inside the $100 seized, and a fund
    ///         holding only that seizure pays it with nothing left over to record.
    function test_longEstate_closedInFull_emptyFund_noDeficit() public {
        h.setPosition(loser, true, 3 * SCALE, 3_000 * SCALE, 100 * SCALE, 0);
        h.setPosition(winner, false, 3 * SCALE, 3_300 * SCALE, 300 * SCALE, 0);
        h.setOI(3 * SCALE, 3 * SCALE, 3_000 * SCALE, 3_300 * SCALE);
        _seize(900 * SCALE, 0);

        assertEq(h.bucket(true).bankruptcyNotional, 2_900 * SCALE, "bankruptcy notional = entry - collateral, exactly");
        assertEq(h.bucket(true).seized, 100 * SCALE, "the whole collateral was seized");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), 900 * SCALE, 0);

        assertEq(r.longBucket.settlementPrice, 966_666666666666666667, "2,900 / 3 rounded up: the vault is selling");
        assertEq(r.longBucket.closedSize, 3 * SCALE, "the whole bucket closed");
        assertEq(h.bucket(true).size, 0, "inventory gone");
        assertEq(h.deficit(), 0, "the seizure covered the close");

        // The sale at the rounded price brings 2,900 and one wei, so the winner is credited
        // 3,300 less that and the vault's loss is 100 less one wei.
        uint256 notional = 2_900 * SCALE + 1;
        assertEq(
            h.positionCollateral(winner), 300 * SCALE + (3_300 * SCALE - notional), "winner credited at that price"
        );
        assertEq(h.deposits(), LEDGER - 100 * SCALE + (3_000 * SCALE - notional), "ledger: seizure out, vault loss in");
        // The wei the rounding left in the fund is free capital, which the executor's reward takes.
        assertEq(h.insurance() + h.claimable(address(this)), 1, "the fund kept the rounding");
    }

    /// @notice The same estate carrying funding it had not paid when it was seized: the notional
    ///         moves by that funding to the wei, and the close still fits the seizure once the
    ///         inventory's funding leg settles the same amount.
    function test_longEstate_withAccruedFunding_closedInFull_noDeficit() public {
        int256 index = 7e18 + 3;
        // The long owes (7e18 + 3) x 3 units = 21e18 + 9 of funding at the liquidation index.
        h.setPosition(loser, true, 3 * SCALE, 3_000 * SCALE, 100 * SCALE, 0);
        // The winner entered at the live index: no funding income to withhold a shortfall from.
        h.setPosition(winner, false, 3 * SCALE, 3_300 * SCALE, 300 * SCALE, index);
        h.setOI(3 * SCALE, 3 * SCALE, 3_000 * SCALE, 3_300 * SCALE);
        _seize(900 * SCALE, index);

        assertEq(
            h.bucket(true).bankruptcyNotional,
            3_000 * SCALE - 100 * SCALE + 21 * SCALE + 9,
            "bankruptcy notional = entry - collateral + funding owed, exactly"
        );

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), 900 * SCALE, index);

        assertEq(r.longBucket.closedSize, 3 * SCALE, "the whole bucket closed");
        assertEq(h.deficit(), 0, "the seizure covered the close");
        assertEq(h.insurance() + h.claimable(address(this)), 1, "the fund kept the rounding");
    }

    /// @notice Short inventory mirrors it with the price rounded down, because the vault is
    ///         buying: a 3-unit short from $1,000 on $100 is bankrupt at $3,100, $1,033.33… per
    ///         unit, and buying it back a fraction of a wei per unit lower costs a wei less than
    ///         the bankruptcy notional.
    function test_shortEstate_closedInFull_emptyFund_noDeficit() public {
        h.setPosition(loser, false, 3 * SCALE, 3_000 * SCALE, 100 * SCALE, 0);
        h.setPosition(winner, true, 3 * SCALE, 2_700 * SCALE, 300 * SCALE, 0);
        h.setOI(3 * SCALE, 3 * SCALE, 2_700 * SCALE, 3_000 * SCALE);
        _seize(1_100 * SCALE, 0);

        assertEq(h.bucket(false).bankruptcyNotional, 3_100 * SCALE, "bankruptcy notional = entry + collateral, exactly");

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(winner), 1_100 * SCALE, 0);

        assertEq(r.shortBucket.settlementPrice, 1_033_333333333333333333, "3,100 / 3 rounded down: the vault is buying");
        assertEq(r.shortBucket.closedSize, 3 * SCALE, "the whole bucket closed");
        assertEq(h.deficit(), 0, "the seizure covered the close");
        uint256 notional = 3_100 * SCALE - 1;
        assertEq(
            h.positionCollateral(winner), 300 * SCALE + (notional - 2_700 * SCALE), "winner credited at that price"
        );
        assertEq(h.insurance() + h.claimable(address(this)), 1, "the fund kept the rounding");
    }

    // ---------------------------- partial slices ----------------------------

    /// @dev A 0.7-unit long from $1,000 on $50, bankrupt at $650 or $928.57… per unit, seized at
    ///      $800. A 0.01-unit slice of it carries floor(700 x 0.01 / 0.7) of entry basis and
    ///      floor(50 x 0.01 / 0.7) of earmark, and sells for floor(0.01 x price): three figures
    ///      rounded apart, which here leave the slice's loss one wei past its earmark.
    function _longEstateWithAnUnevenSlice(uint256 winnerEntryValue) internal {
        h.setPosition(loser, true, 7 * SCALE / 10, 700 * SCALE, 50 * SCALE, 0);
        h.setPosition(winner, false, SCALE / 100, winnerEntryValue, 5 * SCALE, 0);
        h.setOI(7 * SCALE / 10, SCALE / 100, 700 * SCALE, winnerEntryValue);
        _seize(800 * SCALE, 0);
    }

    uint256 internal constant SLICE_NOTIONAL = 9_285714285714285714; // floor(0.01 x 928.571428571428571429)
    uint256 internal constant SLICE_ENTRY = 10 * SCALE; // 700 x 0.01 / 0.7
    uint256 internal constant SLICE_EARMARK = 714285714285714285; // floor(50 x 0.01 / 0.7)

    /// @notice The wei a slice's rounding leaves unfunded comes off the winner's credit, though
    ///         the winner earned no funding to withhold it from: the ledger is credited what the
    ///         earmark paid, the bucket what the ledger was credited, the earmark of the inventory
    ///         still open is untouched, and nothing is recorded as bad debt.
    function test_longEstate_partialSlice_roundingComesOffTheCredit() public {
        _longEstateWithAnUnevenSlice(11 * SCALE); // short from $1,100
        assertEq(SLICE_ENTRY - SLICE_NOTIONAL, SLICE_EARMARK + 1, "fixture: the slice's loss is a wei past its earmark");

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), 800 * SCALE, 0);

        assertEq(r.longBucket.settlementPrice, 928_571428571428571429, "650 / 0.7 rounded up");
        assertEq(r.longBucket.closedSize, SCALE / 100, "the slice closed");
        assertEq(h.deficit(), 0, "a rounding wei is not bad debt");
        assertEq(h.positionSize(winner), 0, "winner closed");
        assertEq(h.positionCollateral(winner), 5 * SCALE + (11 * SCALE - SLICE_NOTIONAL) - 1, "credit less the one wei");
        assertEq(h.deposits(), LEDGER - 50 * SCALE + SLICE_EARMARK, "ledger credited what the earmark paid");
        assertEq(h.bucket(true).seized, 50 * SCALE - SLICE_EARMARK, "the rest of the inventory keeps its earmark");
        assertEq(h.insurance(), h.bucket(true).seized, "and the fund still holds exactly that");
    }

    /// @notice A winner that closes at exactly break-even has no credit to take the wei from.
    ///         It is left unrecorded rather than booked as a deficit: the pair is solvent to the
    ///         wei, and a deficit of any size would fix its settlement price.
    function test_longEstate_partialSlice_breakEvenWinner_roundingIsNotBooked() public {
        _longEstateWithAnUnevenSlice(SLICE_NOTIONAL); // entered at the settlement notional itself

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _none(), 800 * SCALE, 0);

        assertEq(r.longBucket.closedSize, SCALE / 100, "the slice closed");
        assertEq(h.positionSize(winner), 0, "winner closed");
        assertEq(h.positionCollateral(winner), 5 * SCALE, "break-even: collateral unchanged");
        assertEq(h.deficit(), 0, "a rounding wei is not bad debt");
        assertEq(h.deposits(), LEDGER - 50 * SCALE + SLICE_EARMARK, "ledger credited what the earmark paid");
        assertEq(h.insurance(), h.bucket(true).seized, "the fund holds the remaining earmark");
    }

    /// @notice The same slice on short inventory: a 0.7-unit short from $1,428.57… on $50 is
    ///         bankrupt at exactly $1,500 per unit, so the price needs no rounding and the wei
    ///         comes from the slice's shares of the entry basis and the earmark alone.
    function test_shortEstate_partialSlice_roundingComesOffTheCredit() public {
        h.setPosition(loser, false, 7 * SCALE / 10, 1_000 * SCALE, 50 * SCALE, 0);
        h.setPosition(winner, true, SCALE / 100, 10 * SCALE, 5 * SCALE, 0); // long from $1,000
        h.setOI(SCALE / 100, 7 * SCALE / 10, 10 * SCALE, 1_000 * SCALE);
        _seize(1_600 * SCALE, 0);

        uint256 sliceEntry = 14_285714285714285714; // floor(1,000 x 0.01 / 0.7)
        assertEq(15 * SCALE - sliceEntry, SLICE_EARMARK + 1, "fixture: the slice's loss is a wei past its earmark");

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _one(winner), 1_600 * SCALE, 0);

        assertEq(r.shortBucket.settlementPrice, 1_500 * SCALE, "1,050 / 0.7");
        assertEq(r.shortBucket.closedSize, SCALE / 100, "the slice closed");
        assertEq(h.deficit(), 0, "a rounding wei is not bad debt");
        assertEq(h.positionCollateral(winner), 5 * SCALE + (15 * SCALE - 10 * SCALE) - 1, "credit less the one wei");
        assertEq(h.deposits(), LEDGER - 50 * SCALE + SLICE_EARMARK, "ledger credited what the earmark paid");
        assertEq(h.insurance(), h.bucket(false).seized, "the fund holds the remaining earmark");
    }

    // ---------------------------- a second bucket, closed in slices ----------------------------

    /// @notice A short estate the fund cannot net against the long bucket it meets is seized into
    ///         the short bucket, and the batch closes that bucket slice by slice against its own
    ///         cohort at its bankruptcy price, the fund holding nothing beyond the two earmarks.
    ///         The first slice lands a wei past its earmark and its winner's credit takes it; the
    ///         last slice takes everything the first left, so it is a wei inside its earmark, and
    ///         the batch ends with the short bucket closed, the long bucket untouched and no
    ///         deficit.
    function test_shortBucket_closedInSlices_emptyFund_noDeficit() public {
        // Long inventory the vault already holds, fully backed, which this batch does not touch:
        // 1 unit from $1,700, bankrupt at $1,690, $10 seized with it.
        h.setBucket(true, 1 * SCALE, 1_700 * SCALE, 1_690 * SCALE, 10 * SCALE, 0);
        h.seedInsurance(10 * SCALE);
        // The short: 0.7 units from $1,428.57… on $50, bankrupt at $1,500, mark $1,600. Netting it
        // against the long bucket would lose the $190 gap between the two entry bases on the 0.7
        // units against $57 of seizure and no free capital, so it is seized into the short bucket.
        h.setPosition(loser, false, 7 * SCALE / 10, 1_000 * SCALE, 50 * SCALE, 0);
        // Its counterparties, both long from $1,000: 0.01 units ranked first, then 0.69.
        h.setPosition(ally, true, SCALE / 100, 10 * SCALE, 1 * SCALE, 0);
        h.setPosition(ally2, true, 69 * SCALE / 100, 690 * SCALE, 100 * SCALE, 0);
        h.setOI(7 * SCALE / 10, 7 * SCALE / 10, 700 * SCALE, 1_000 * SCALE);
        _seize(1_600 * SCALE, 0);
        assertEq(h.bucket(false).size, 7 * SCALE / 10, "fixture: the short bucket holds the estate");
        assertEq(h.bucket(true).size, 1 * SCALE, "fixture: the long bucket stands, the overlap unnetted");

        BazaarTypes.AdlResult memory r = h.execAdl(_none(), _two(ally, ally2), 1_600 * SCALE, 0);

        assertEq(r.shortBucket.settlementPrice, 1_500 * SCALE, "the short bucket's bankruptcy price");
        assertEq(r.shortBucket.closedSize, 7 * SCALE / 10, "the whole short bucket closed");
        assertEq(r.longBucket.closedSize, 0, "no cohort for the long bucket: nothing closed off it");
        assertEq(r.netted, 0, "nothing left to net");
        assertEq(h.bucket(false).size, 0, "short bucket gone");
        assertEq(h.deficit(), 0, "a rounding wei is not bad debt");
        assertEq(h.bucket(true).size, 1 * SCALE, "the vault's long bucket is untouched");
        // (1,500 - 1,000) per unit on each slice, the first less its rounding wei.
        assertEq(h.positionCollateral(ally), 1 * SCALE + 5 * SCALE - 1, "first slice: credit less the one wei");
        assertEq(h.positionCollateral(ally2), 100 * SCALE + 345 * SCALE, "last slice: credited in full");
        // The seizure went back to the ledger less the wei withheld from the first slice, which
        // is the free capital the executor's reward is then capped at.
        assertEq(h.deposits(), LEDGER - 1, "ledger: seizure out, both vault legs back in");
        assertEq(h.insurance(), 10 * SCALE, "the fund holds the untouched bucket's earmark");
        assertEq(h.claimable(address(this)), 1, "reward capped at the wei of free capital");
    }

    // ---------------------------- the allowance is not a tolerance for losses ----------------------------

    /// @notice A fund a dollar below its earmark cannot back the close, and the allowance does
    ///         not hide that: it comes off the credit, and the rest of the dollar is a deficit.
    function test_shortfallPastTheAllowance_isStillBadDebt() public {
        h.setPosition(loser, true, 3 * SCALE, 3_000 * SCALE, 100 * SCALE, 0);
        h.setPosition(winner, false, 3 * SCALE, 3_300 * SCALE, 300 * SCALE, 0);
        h.setOI(3 * SCALE, 3 * SCALE, 3_000 * SCALE, 3_300 * SCALE);
        _seize(900 * SCALE, 0);
        h.seedInsurance(99 * SCALE);

        h.execAdl(_one(winner), _none(), 900 * SCALE, 0);

        // The vault's loss is 100 less a wei against a fund of 99.
        uint256 shortfall = 1 * SCALE - 1;
        assertEq(h.deficit(), shortfall - ALLOWANCE, "the shortfall beyond the allowance is recorded");
        assertEq(
            h.positionCollateral(winner),
            300 * SCALE + (400 * SCALE - 1) - ALLOWANCE,
            "no funding income: only the allowance is withheld"
        );
        assertEq(h.insurance(), 0, "fund fully drawn");
    }
}
