// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";

/// @notice Minimal stand-in exposing only the IBazaarPairView selectors the Lens reads, with
///         settable state — lets us drive the Lens's computed getters without a full pair deploy.
contract MockPairForLens {
    uint256 public totalInsuranceShares;
    uint256 public insuranceFundBalance;
    mapping(address => uint256) public insuranceShares;
    bool public isAdlPending;
    bool public isContinuouslyTraded = true;
    uint256 public adlPendingSince;
    uint256 public adlAuctionStartTs;
    mapping(address => BazaarTypes.PositionBucket) internal buckets;
    mapping(address => uint256) public adlScoreDeposit;
    mapping(address => uint256) public terminalProfitClaim;
    uint256 public fixedSettlementPrice;
    uint256 public settlementPriceFixedTs;
    bool public isPairTerminated;
    uint256 public scheduledTerminationTs;
    // No token behind it: the lens reads an unreadable USDC balance as no shortfall.
    address public usdc;
    // The deposits ledger, set high enough that it never caps a withdrawal quote.
    uint256 internal deposited_ = 1e30;
    // The vault's two buckets of liquidation inventory.
    BazaarTypes.Inventory internal longInv_;
    BazaarTypes.Inventory internal shortInv_;
    int256 internal fundingIdx_;
    uint256 internal frozenPrincipalRatio;
    uint256 internal frozenProfitRatio;
    uint256 internal imrBp_;
    uint256 internal mmrBp_;
    uint256 internal laggedMmrBp_;
    uint256 internal longOrderExposure_;
    uint256 internal shortOrderExposure_;

    function setInsurance(uint256 shares_, uint256 fund_) external {
        totalInsuranceShares = shares_;
        insuranceFundBalance = fund_;
    }

    function setUserShares(address u, uint256 s) external {
        insuranceShares[u] = s;
    }

    // Raw storage the lens reads through extsload, at BazaarPair's slots.
    mapping(bytes32 => bytes32) internal slots;
    uint256 internal constant SLOT_USER_ACTIVE_LIMIT_ORDERS = 2;
    uint256 internal constant SLOT_MARK_PREMIUM_NOTIONAL = 66;
    uint256 internal constant SLOT_FEE_ESCROW_TOTAL = 108;
    uint256 internal constant SLOT_FEE_ESCROW_CLAIMABLE = 109;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    // The mark line: the premium tally at its slot, the anchor and volume tally through auxState.
    uint256 internal markAnchor_;
    uint256 internal markVolume_;
    uint256 internal longOI_;
    uint256 internal shortOI_;

    function setMarkLine(int256 premiumNotional, uint256 anchor, uint256 volume) external {
        slots[bytes32(SLOT_MARK_PREMIUM_NOTIONAL)] = bytes32(uint256(premiumNotional));
        markAnchor_ = anchor;
        markVolume_ = volume;
    }

    function setOpenInterest(uint256 longOI, uint256 shortOI) external {
        longOI_ = longOI;
        shortOI_ = shortOI;
    }

    mapping(address => uint256) internal claimable_;
    uint256 internal claimableTotal_;

    function setClaimable(address who, uint256 amount) external {
        claimableTotal_ = claimableTotal_ - claimable_[who] + amount;
        claimable_[who] = amount;
        slots[keccak256(abi.encode(who, SLOT_FEE_ESCROW_CLAIMABLE))] = bytes32(amount);
        slots[bytes32(SLOT_FEE_ESCROW_TOTAL)] = bytes32(claimableTotal_);
    }

    /// @dev Sets both clocks to `since_`: they coincide on an auction no discontinuity has
    ///      restarted, which is the case every threshold test here exercises. The lens reads
    ///      adlAuctionStartTs — adlPendingSince dates the window and drives termination instead.
    function setAdl(bool pending_, uint256 since_) external {
        isAdlPending = pending_;
        adlPendingSince = since_;
        adlAuctionStartTs = since_;
    }

    /// @dev The live funding index, which every ADL candidate ranks against.
    function setFundingIndex(int256 idx_) external {
        fundingIdx_ = idx_;
    }

    function setBucket(address u, bool isLong_, uint256 size_, uint256 entryValue_, uint256 collateral_) external {
        BazaarTypes.PositionBucket storage b = buckets[u];
        b.isLong = isLong_;
        b.size = uint128(size_);
        b.entryValue = uint128(entryValue_);
        b.collateral = uint128(collateral_);
    }

    function setAdlScoreDeposit(address u, uint256 wd) external {
        adlScoreDeposit[u] = wd;
    }

    function setTerminalClaim(address u, uint256 claim) external {
        terminalProfitClaim[u] = claim;
    }

    function setTerminal(uint256 fixedPrice_, uint256 fixedTs_, uint256 principalRatio_, uint256 profitRatio_)
        external
    {
        fixedSettlementPrice = fixedPrice_;
        settlementPriceFixedTs = fixedTs_;
        frozenPrincipalRatio = principalRatio_;
        frozenProfitRatio = profitRatio_;
    }

    function setContinuouslyTraded(bool v) external {
        isContinuouslyTraded = v;
    }

    function setScheduledTerminationTs(uint256 ts) external {
        scheduledTerminationTs = ts;
    }

    // When the funding index last accrued, which the lens reads through auxState.
    uint256 internal lastFundingUpdateTs_;

    function setLastFundingUpdateTs(uint256 ts) external {
        lastFundingUpdateTs_ = ts;
    }

    function setMarginReqs(uint256 imrBp, uint256 mmrBp, uint256 laggedMmrBp) external {
        imrBp_ = imrBp;
        mmrBp_ = mmrBp;
        laggedMmrBp_ = laggedMmrBp;
    }

    /// @dev Two synthetic resting orders for WINNER, one per side, worth `longExp` and `shortExp`
    ///      at a $100 limit, so size × limit is the exposure and the lens's size-at-mark floor
    ///      reproduces the same figure at a $100 mark (the price these tests pass) or less.
    uint256 internal constant SYNTHETIC_LIMIT = 100e18;

    address internal exposureOwner_;

    function setOrderExposure(address who, uint256 longExp, uint256 shortExp) external {
        exposureOwner_ = who;
        longOrderExposure_ = longExp;
        shortOrderExposure_ = shortExp;
        bytes32 base = keccak256(abi.encode(who, SLOT_USER_ACTIVE_LIMIT_ORDERS));
        slots[base] = bytes32(uint256(2));
        uint256 data = uint256(keccak256(abi.encode(base)));
        slots[bytes32(data)] = bytes32(uint256(1));
        slots[bytes32(data + 1)] = bytes32(uint256(2));
    }

    /// @dev The pair's `orders` getter for the two synthetic orders: id 1 long, id 2 short, each
    ///      sized so remainder × limit equals the exposure set, never expiring.
    function orders(uint256 orderId)
        external
        view
        returns (
            address,
            uint64,
            BazaarTypes.OrderType,
            bool,
            bool,
            BazaarTypes.TimeInForce,
            address,
            uint64,
            bool,
            uint24,
            uint128,
            uint128,
            uint128,
            uint128,
            uint48,
            uint64,
            uint32,
            uint16,
            uint48,
            uint48
        )
    {
        bool isLong = orderId == 1;
        uint256 exposure = isLong ? longOrderExposure_ : shortOrderExposure_;
        uint128 size = uint128(exposure * 1e18 / SYNTHETIC_LIMIT);
        return (
            exposureOwner_,
            0,
            BazaarTypes.OrderType.Limit,
            isLong,
            false,
            BazaarTypes.TimeInForce.GTC,
            address(0),
            type(uint64).max,
            true,
            0,
            0,
            uint128(SYNTHETIC_LIMIT),
            size,
            0,
            uint48(orderId),
            0,
            0,
            0,
            0,
            0
        );
    }

    /// @dev Stage one bucket on `isLong_`'s side and empty the other.
    function setPendingLiq(uint256 size_, uint256 entry_, uint256 bk_, bool isLong_) external {
        BazaarTypes.Inventory storage b = isLong_ ? longInv_ : shortInv_;
        BazaarTypes.Inventory storage other = isLong_ ? shortInv_ : longInv_;
        b.size = size_;
        b.entryNotional = entry_;
        b.bankruptcyNotional = bk_;
        delete other.size;
        delete other.entryNotional;
        delete other.bankruptcyNotional;
        delete other.seized;
        delete other.entryFundingIndex;
        delete other.seizedTs;
    }

    /// @dev The staged bucket: the long one unless only the short one holds inventory.
    function _staged() internal view returns (BazaarTypes.Inventory storage) {
        return shortInv_.size != 0 && longInv_.size == 0 ? shortInv_ : longInv_;
    }

    function setPendingLiqFundingIndex(int256 idx_) external {
        _staged().entryFundingIndex = int192(idx_);
    }

    uint256 internal targetInsuranceRatioBp_;
    uint256 internal mark_;

    function setPendingLiqSeized(uint256 seized_) external {
        _staged().seized = seized_;
    }

    function setPendingLiqSeizedTs(uint64 ts_) external {
        _staged().seizedTs = ts_;
    }

    function setTargetInsuranceRatioBp(uint256 bp) external {
        targetInsuranceRatioBp_ = bp;
    }

    function setMark(uint256 price_) external {
        mark_ = price_;
    }

    function lastPairPrice() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (mark_, 0, 0, 0, 0);
    }

    function positionBuckets(address u)
        external
        view
        returns (bool, uint256, uint256, uint256, int256, uint256, uint256)
    {
        BazaarTypes.PositionBucket storage b = buckets[u];
        return
            (b.isLong, b.size, b.entryValue, b.collateral, b.entryFundingIndex, b.takeProfitOrderId, b.stopLossOrderId);
    }

    function currentFundingIndex() external view returns (int256) {
        return fundingIdx_;
    }

    function marginRequirements() external view returns (uint256, uint256, uint256, uint256) {
        return (imrBp_, mmrBp_, 0, laggedMmrBp_);
    }

    function getLaggedMmr() external view returns (uint256) {
        return laggedMmrBp_;
    }

    function pairId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function pairVault()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint128,
            BazaarTypes.Inventory memory,
            BazaarTypes.Inventory memory
        )
    {
        return (
            longOI_,
            shortOI_,
            0,
            0,
            deposited_,
            insuranceFundBalance,
            0,
            targetInsuranceRatioBp_,
            0,
            0,
            longInv_,
            shortInv_
        );
    }

    function auxState() external view returns (BazaarTypes.AuxState memory a) {
        a.lastFundingUpdateTs = lastFundingUpdateTs_;
        a.lastMarkUpdateTs = markAnchor_;
        a.rollingVolume = markVolume_;
        a.settlementPrice = fixedSettlementPrice;
        a.terminalPrincipalRatio = frozenPrincipalRatio;
        a.terminalProfitRatio = frozenProfitRatio;
        return a;
    }
}

/// @dev Stands in for BazaarFactory: the lens only reads getAllPairs() from it.
contract MockFactoryForLens {
    address[] internal pairs;

    function addPair(address p) external {
        pairs.push(p);
    }

    function getAllPairs() external view returns (address[] memory) {
        return pairs;
    }
}

contract BazaarPairLensTest is Test {
    BazaarPairLens internal lens;
    MockPairForLens internal pair;
    MockFactoryForLens internal factory;
    uint256 constant SCALE = 1e18;
    uint256 constant DURATION = BazaarTypes.ADL_AUCTION_DURATION;

    function setUp() public {
        factory = new MockFactoryForLens();
        lens = new BazaarPairLens(address(factory));
        pair = new MockPairForLens();
        vm.warp(1_000_000);
        vm.etch(address(0x64), address(new MockArbSys()).code); // ArbSys precompile the lens expires orders by
    }

    // ---------------- fee escrow views ----------------

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(BazaarPairLens.BazaarPairLens__ZeroAddress.selector);
        new BazaarPairLens(address(0));
    }

    function test_factory_isTheWiredAddress() public view {
        assertEq(lens.factory(), address(factory));
    }

    /// @notice One read per pair, in the order passed, straight from each pair's own getter.
    function test_getClaimableFees_readsEachPairInOrder() public {
        MockPairForLens other = new MockPairForLens();
        address who = makeAddr("keeper");
        pair.setClaimable(who, 3e18);
        other.setClaimable(who, 5e17);

        address[] memory pairs = new address[](2);
        pairs[0] = address(other);
        pairs[1] = address(pair);
        uint256[] memory owed = lens.getClaimableFees(pairs, who);

        assertEq(owed.length, 2);
        assertEq(owed[0], 5e17, "first entry follows the first pair passed");
        assertEq(owed[1], 3e18, "second entry follows the second pair passed");
        assertEq(lens.getClaimableFees(pairs, makeAddr("nobody"))[0], 0, "a stranger is owed nothing");
    }

    /// @notice The whole pair set of the wired factory as parallel arrays, zero entries included.
    function test_getClaimableFeesAll_enumeratesTheWiredFactory() public {
        MockPairForLens other = new MockPairForLens();
        address who = makeAddr("relayer");
        pair.setClaimable(who, 1e18);
        factory.addPair(address(pair));
        factory.addPair(address(other));

        (address[] memory pairs, uint256[] memory owed) = lens.getClaimableFeesAll(who);

        assertEq(pairs.length, 2);
        assertEq(owed.length, 2);
        assertEq(pairs[0], address(pair));
        assertEq(owed[0], 1e18, "owed on the first pair");
        assertEq(pairs[1], address(other));
        assertEq(owed[1], 0, "unfiltered: a zero balance is still listed");
    }

    function test_getClaimableFeesAll_emptyFactory() public view {
        (address[] memory pairs, uint256[] memory owed) = lens.getClaimableFeesAll(address(0xBEEF));
        assertEq(pairs.length, 0);
        assertEq(owed.length, 0);
    }

    // ---------------- constant forwarders (must forward the correct constant) ----------------

    function test_getEip712Constants() public view {
        (bytes32 dom, bytes32 nameH, bytes32 verH, uint256 maxFee, uint256 maxWin) = lens.getEip712Constants();
        assertEq(dom, MetaTxLib.EIP712_DOMAIN_TYPEHASH);
        assertEq(nameH, MetaTxLib.NAME_HASH);
        assertEq(verH, MetaTxLib.VERSION_HASH);
        assertEq(maxFee, MetaTxLib.MAX_RELAYER_FEE);
        assertEq(maxWin, MetaTxLib.MAX_DEADLINE_WINDOW);
    }

    function test_getTypehashes() public view {
        (bytes32 dep, bytes32 wd, bytes32 di, bytes32 ei, bytes32 co, bytes32 ca, bytes32 ri, bytes32 am) =
            lens.getTypehashes();
        assertEq(dep, MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH);
        assertEq(wd, MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH);
        assertEq(di, MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH);
        assertEq(ei, MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH);
        assertEq(co, MetaTxLib.CREATE_ORDER_TYPEHASH);
        assertEq(ca, MetaTxLib.CANCEL_ORDERS_TYPEHASH);
        assertEq(ri, MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH);
        assertEq(am, MetaTxLib.AMEND_ORDERS_TYPEHASH);
    }

    function test_getOrderLifetimeConstants() public view {
        (uint64 minL, uint64 maxL) = lens.getOrderLifetimeConstants();
        assertEq(minL, BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        assertEq(maxL, BazaarTypes.MAX_ORDER_LIFETIME_BLOCKS);
    }

    function test_getMarkConstants() public view {
        (uint256 exposure, uint256 floorBp, uint256 alphaBp, uint256 bandBp, uint256 decay) = lens.getMarkConstants();
        assertEq(exposure, FundingLib.MAKER_EXPOSURE_BLOCKS);
        assertEq(floorBp, FundingLib.VOLUME_FLOOR_BP);
        assertEq(alphaBp, FundingLib.MAX_ALPHA);
        assertEq(bandBp, FundingLib.MAX_MARK_DEVIATION_BP);
        assertEq(decay, FundingLib.MARK_DECAY_PERIOD);
    }

    /// @notice markPrice reads the pair's two tallies over the floor its open interest sets, carried
    ///         on the last stored price, exactly as FundingLib.currentMark reads them, and 0 before
    ///         a mark has formed.
    function test_markPrice_readsTheLineOverTheFloor() public {
        vm.warp(1_700_000_000);
        assertEq(lens.markPrice(address(pair)), 0, "no mark before a line forms");

        pair.setMark(200e18); // the stored price
        pair.setOpenInterest(20e18, 20e18); // $4,000 of notional a side: an $80 floor
        uint256 floorVolume = FundingLib.floorVolumeOf(20e18, 200e18);
        assertEq(floorVolume, 80e18, "fixture: 2% of $4,000");
        uint256 anchor = block.timestamp - 10 minutes;

        // $100 of volume at 3%, ten minutes in: still above the floor, so the ratio stands.
        pair.setMarkLine(3e18, anchor, 100e18);
        assertEq(
            lens.markPrice(address(pair)),
            FundingLib.currentMark(3e18, 100e18, anchor, floorVolume, 200e18),
            "the library's reading, above the floor"
        );
        assertEq(lens.markPrice(address(pair)), 206e18, "3% over $200");

        // $20 of volume at 3%: under the floor, so the premium tally is read over the floor. Ten
        // minutes in, 0.5 of premium tally over $80 is 0.625%.
        pair.setMarkLine(6e17, anchor, 20e18);
        assertEq(
            lens.markPrice(address(pair)),
            FundingLib.currentMark(6e17, 20e18, anchor, floorVolume, 200e18),
            "the library's reading, under the floor"
        );
        assertEq(lens.markPrice(address(pair)), 201_25e16, "0.625% over $200");
    }

    // ---------------- funding rate ----------------

    /// @dev The state the funding tests share: a $200 stored price, $4,000 of open interest a side
    ///      (an $80 floor), a stored funding index of 1, and a mark line anchored ten minutes ago with
    ///      $100 of volume, which stays above the floor past this block, carrying `premiumNotional`.
    function _fundingFixture(int256 premiumNotional) internal {
        vm.warp(1_700_000_000);
        pair.setMark(200e18);
        pair.setOpenInterest(20e18, 20e18);
        pair.setFundingIndex(1e18);
        pair.setMarkLine(premiumNotional, block.timestamp - 10 minutes, 100e18);
    }

    /// @notice A 3% premium on a continuously traded pair: the rate now is the premium over the
    ///         continuous dampener, and a window that opened ten minutes before the line formed is
    ///         charged its average, half the premium, on the stored price for twenty minutes.
    function test_fundingRate_projectsTheLibraryAccrual() public {
        _fundingFixture(3e18);
        pair.setLastFundingUpdateTs(block.timestamp - 20 minutes);

        (int256 currentRate, int256 accruingRate, int256 index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 75e13, "3% / 40: 0.075% an hour");
        assertEq(accruingRate, 375e12, "half of it: the line covers half the window");
        assertEq(index, 1e18 + 25e15, "0.0375% an hour of $200 for a third of an hour");

        uint256 floorVolume = FundingLib.floorVolumeOf(20e18, 200e18);
        FundingLib.MarkState memory line = FundingLib.MarkState(3e18, block.timestamp - 10 minutes, 100e18);
        int256 dampener = int256(FundingLib.FUNDING_DAMPENER_CONTINUOUS);
        assertEq(
            currentRate,
            FundingLib.currentPremium(line.premiumNotional, line.rollingVolume, line.lastMarkUpdateTs, floorVolume)
                / dampener,
            "the library's premium, damped"
        );
        assertEq(
            accruingRate,
            FundingLib.averagePremium(line, floorVolume, block.timestamp - 20 minutes, block.timestamp) / dampener,
            "the library's average, damped"
        );
    }

    /// @notice A pair with trading hours damps the same premium by its own, smaller dampener.
    function test_fundingRate_sessionPairUsesItsCalendar() public {
        _fundingFixture(3e18);
        pair.setLastFundingUpdateTs(block.timestamp - 20 minutes);
        pair.setContinuouslyTraded(false);

        (int256 currentRate, int256 accruingRate, int256 index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 375e13, "3% / 8: 0.375% an hour");
        assertEq(accruingRate, 1875e12, "half of it");
        assertEq(index, 1e18 + 125e15, "0.1875% an hour of $200 for a third of an hour");
    }

    /// @notice A discount charges the other way, and a premium beyond the band reads at the band's
    ///         edge, where the rate is exactly the ceiling.
    function test_fundingRate_signAndCeiling() public {
        _fundingFixture(-3e18);
        pair.setLastFundingUpdateTs(block.timestamp - 20 minutes);
        (int256 currentRate,, int256 index) = lens.fundingRate(address(pair));
        assertEq(currentRate, -75e13, "a discount: shorts pay");
        assertEq(index, 1e18 - 25e15, "the index falls");

        pair.setMarkLine(10e18, block.timestamp - 10 minutes, 100e18);
        (currentRate,,) = lens.fundingRate(address(pair));
        assertEq(currentRate, int256(FundingLib.MAX_FUNDING_RATE_CONTINUOUS), "10% reads as 4%: the ceiling");
    }

    /// @notice The window bounds updateFundingIndex applies: a store more than MAX_FUNDING_GAP after
    ///         the last accrual charges nothing, one more than MAX_FUNDING_AGE after it charges only
    ///         the last MAX_FUNDING_AGE, and one in the same second charges nothing. The rate the mark
    ///         implies does not depend on the window.
    function test_fundingRate_followsTheWindowBounds() public {
        _fundingFixture(3e18);

        pair.setLastFundingUpdateTs(block.timestamp - 13 hours);
        (int256 currentRate, int256 accruingRate, int256 index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 75e13, "the mark's rate");
        assertEq(accruingRate, 0, "past the gap: nothing");
        assertEq(index, 1e18, "the stored index");

        pair.setLastFundingUpdateTs(block.timestamp - 2 hours);
        (, accruingRate, index) = lens.fundingRate(address(pair));
        assertEq(accruingRate, 25e13, "the last half hour, a third of it on the line");
        assertEq(index, 1e18 + 25e15, "0.025% an hour of $200 for half an hour");

        pair.setLastFundingUpdateTs(block.timestamp);
        (, accruingRate, index) = lens.fundingRate(address(pair));
        assertEq(accruingRate, 0, "an empty window");
        assertEq(index, 1e18, "the stored index");
    }

    /// @notice A price published after the scheduled cutoff, or once the settlement price is fixed,
    ///         is never stored, so nothing accrues; one published at the cutoff itself still is.
    function test_fundingRate_stopsWhereThePairStoresNoPrice() public {
        _fundingFixture(3e18);
        pair.setLastFundingUpdateTs(block.timestamp - 20 minutes);

        pair.setScheduledTerminationTs(block.timestamp);
        (int256 currentRate, int256 accruingRate, int256 index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 75e13, "at the cutoff: still charged");
        assertEq(index, 1e18 + 25e15, "at the cutoff: still charged");

        pair.setScheduledTerminationTs(block.timestamp - 1);
        (currentRate, accruingRate, index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 0, "past the cutoff: no rate");
        assertEq(accruingRate, 0, "past the cutoff: no charge");
        assertEq(index, 1e18, "past the cutoff: the stored index");

        pair.setScheduledTerminationTs(0);
        pair.setTerminal(200e18, block.timestamp, 1e18, 1e18);
        (currentRate, accruingRate, index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 0, "settlement fixed: no rate");
        assertEq(accruingRate, 0, "settlement fixed: no charge");
        assertEq(index, 1e18, "settlement fixed: the stored index");
    }

    /// @notice A pair with no mark line and no stored price has nothing to charge.
    function test_fundingRate_zeroWithoutAMarkOrAPrice() public {
        vm.warp(1_700_000_000);
        pair.setFundingIndex(1e18);
        pair.setLastFundingUpdateTs(block.timestamp - 20 minutes);
        (int256 currentRate, int256 accruingRate, int256 index) = lens.fundingRate(address(pair));
        assertEq(currentRate, 0, "no premium");
        assertEq(accruingRate, 0, "no charge");
        assertEq(index, 1e18, "the stored index");
    }

    function test_getMinCollateralAmount() public view {
        assertEq(lens.getMinCollateralAmount(), CollateralLib.MIN_COLLATERAL_AMOUNT);
    }

    function test_getInsuranceWithdrawalConstants() public view {
        (
            uint256 cd,
            uint256 continuousWin,
            uint256 sessionWin,
            uint256 rlp,
            uint256 rlbp,
            uint256 aboveTargetBp,
            uint256 fundCapBp,
            uint256 belowTargetFundCapBp
        ) = lens.getInsuranceWithdrawalConstants();
        assertEq(cd, InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN);
        assertEq(continuousWin, InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW_CONTINUOUS);
        assertEq(sessionWin, InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW_SESSION);
        assertEq(rlp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD);
        assertEq(rlbp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP);
        assertEq(aboveTargetBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP);
        assertEq(fundCapBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP);
        assertEq(belowTargetFundCapBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP);
    }

    function test_getVaultHealthConstants() public view {
        (uint256 reserveBp, uint256 bandCapBp, uint256 timeout, uint256 maxWinners) = lens.getVaultHealthConstants();
        assertEq(reserveBp, BazaarTypes.ADL_RESERVE_BP);
        assertEq(bandCapBp, BazaarTypes.LIQ_MAX_SLIPPAGE_BP);
        assertEq(timeout, VaultHealthLib.ADL_TIMEOUT_DURATION);
        assertEq(maxWinners, AdlLib.MAX_ADL_WINNERS_PER_BATCH);
    }

    // ---------------- computed getters (real logic, via the mock) ----------------

    function test_getInsuranceSharePrice_noShares_isUnitPrice() public view {
        assertEq(lens.getInsuranceSharePrice(address(pair)), SCALE, "no shares => 1.0 price");
    }

    function test_getInsuranceSharePrice_reflectsFundPerShare() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE); // shares, fund
        assertEq(lens.getInsuranceSharePrice(address(pair)), 15 * SCALE / 10, "150/100 = 1.5");
    }

    function test_getInsuranceDepositValue_zeroWhenNoShares() public view {
        assertEq(lens.getInsuranceDepositValue(address(pair), address(this)), 0);
    }

    function test_getInsuranceDepositValue_prorataOfFund() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE);
        pair.setUserShares(address(this), 20 * SCALE);
        // 20 shares * 150 fund / 100 total = 30
        assertEq(lens.getInsuranceDepositValue(address(pair), address(this)), 30 * SCALE);
    }

    /// @notice With inventory whole at the stored mark, the seizure is netted out of the basis and
    ///         its recovery is not paid to a leaver: shares redeem at free capital.
    function test_getInsuranceSharePrice_netsSeizure_ignoresGain() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE); // 100 free once 50 is seized
        pair.setPendingLiq(1 * SCALE, 50 * SCALE, 0, true); // one unit long from 50
        pair.setPendingLiqSeized(50 * SCALE);
        pair.setMark(50 * SCALE); // at entry: net +50, a gain a redemption never collects
        assertEq(lens.getInsuranceSharePrice(address(pair)), SCALE, "free 100 / 100 shares");
        pair.setUserShares(address(this), 20 * SCALE);
        assertEq(lens.getInsuranceDepositValue(address(pair), address(this)), 20 * SCALE, "20 shares at 1.0");
    }

    /// @notice An inventory loss at the stored mark comes off the redemption basis, as far as the
    ///         fund bears it: with no reserve the whole loss counts.
    function test_getInsuranceSharePrice_subtractsInventoryLoss() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE);
        pair.setPendingLiq(1 * SCALE, 60 * SCALE, 10 * SCALE, true); // one unit long from 60
        pair.setPendingLiqSeized(50 * SCALE);
        pair.setMark(5 * SCALE); // pnl -55, net -5: the fund bears 5
        assertEq(lens.getInsuranceSharePrice(address(pair)), 95 * SCALE / 100, "(100 - 5) / 100");
    }

    /// @notice Deposit quotes at a caller-supplied mark: the inventory's gain raises the basis and
    ///         its loss lowers it, both in full while the fund can bear them.
    function test_quoteInsuranceDeposit_gainAndLoss() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE); // 140 free once 10 is seized
        pair.setPendingLiq(10 * SCALE, 500 * SCALE, 490 * SCALE, true); // ten units long from 50
        pair.setPendingLiqSeized(10 * SCALE);
        // Mark 52: pnl +20, net +30 -> basis 170.
        assertEq(lens.quoteInsuranceDeposit(address(pair), 17 * SCALE, 52 * SCALE), 10 * SCALE, "17 / 1.7");
        // Mark 48: pnl -20, net -10 -> basis 130.
        assertEq(lens.quoteInsuranceDeposit(address(pair), 13 * SCALE, 48 * SCALE), 10 * SCALE, "13 / 1.3");
    }

    /// @notice The loss deduction stops at free capital above the reserve. With a 100% target the
    ///         reserve on ten units at 30 is 30, so of a 190 loss the fund bears the 110 above the
    ///         reserve and the basis is the reserve itself — the auction charges the rest to
    ///         winners; a redemption and the stored-mark view price off the same figure.
    function test_quoteInsurance_lossCappedAtFreeAboveReserve() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE);
        pair.setPendingLiq(10 * SCALE, 500 * SCALE, 490 * SCALE, true);
        pair.setPendingLiqSeized(10 * SCALE);
        pair.setTargetInsuranceRatioBp(10_000);
        assertEq(lens.quoteInsuranceDeposit(address(pair), 3 * SCALE, 30 * SCALE), 10 * SCALE, "3 / 0.3");
        assertEq(lens.quoteInsuranceWithdrawal(address(pair), 20 * SCALE, 30 * SCALE), 6 * SCALE, "20 x 0.3");
        pair.setMark(30 * SCALE);
        assertEq(lens.getInsuranceSharePrice(address(pair)), 3 * SCALE / 10, "0.3 at the stored mark");
    }

    /// @notice Quotes mirror the pair's par branches: an empty pool, or one a realized wipe is
    ///         about to reset, mints 1:1.
    function test_quoteInsuranceDeposit_parOnEmptyOrWipedPool() public {
        assertEq(lens.quoteInsuranceDeposit(address(pair), 7 * SCALE, 50 * SCALE), 7 * SCALE, "empty pool: par");
        pair.setInsurance(100 * SCALE, SCALE / 2); // live shares over a fund below $1
        assertEq(lens.quoteInsuranceDeposit(address(pair), 7 * SCALE, 50 * SCALE), 7 * SCALE, "wiped pool: par");
    }

    function test_getAdlScoreThreshold_notPending_isMax() public {
        pair.setAdl(false, block.timestamp);
        assertEq(lens.getAdlScoreThreshold(address(pair)), type(uint256).max);
    }

    function test_getAdlScoreThreshold_auctionStartZero_isMax() public {
        pair.setAdl(true, 0);
        assertEq(lens.getAdlScoreThreshold(address(pair)), type(uint256).max);
    }

    function test_getAdlScoreThreshold_atStart_isMaxScore() public {
        pair.setAdl(true, block.timestamp); // elapsed 0 => remaining^2/duration^2 = 1
        assertEq(lens.getAdlScoreThreshold(address(pair)), 1 + 25 * SCALE);
    }

    function test_getAdlScoreThreshold_afterAuction_isOne() public {
        pair.setAdl(true, block.timestamp);
        vm.warp(block.timestamp + DURATION); // elapsed == duration
        assertEq(lens.getAdlScoreThreshold(address(pair)), 1);
    }

    function test_getAdlScoreThreshold_decaysMonotonically() public {
        pair.setAdl(true, block.timestamp);
        uint256 t0 = block.timestamp;
        uint256 start = lens.getAdlScoreThreshold(address(pair));
        vm.warp(t0 + DURATION / 2);
        uint256 mid = lens.getAdlScoreThreshold(address(pair));
        vm.warp(t0 + DURATION);
        uint256 end = lens.getAdlScoreThreshold(address(pair));
        assertGt(start, mid, "decays over the auction");
        assertGt(mid, end);
        assertEq(end, 1);
    }

    // ---------------- getAdlScore (mirrors AdlLib's ranking scan) ----------------

    address constant WINNER = address(0xA11CE);

    /// @dev Canonical scenario: the vault holds a LONG bucket, so its candidates are SHORTS. The
    ///      stored mark is $100; a short from $150 entry carries $50 PnL per unit there.
    function _setupAdlWindow() internal {
        pair.setAdl(true, block.timestamp);
        pair.setMark(100 * SCALE);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 90 * SCALE, true);
        vm.warp(block.timestamp + DURATION); // decayed threshold = 1: any positive score is eligible
    }

    function test_getAdlScore_notPending_zero() public {
        pair.setMark(100 * SCALE);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 90 * SCALE, true);
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 0, "no ADL pending: no score");
        assertFalse(eligible);
    }

    function test_getAdlScore_flatWrongSideOrLoser_zero() public {
        _setupAdlWindow();
        // Flat.
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), address(0xF1A7));
        assertEq(score, 0, "flat user");
        assertFalse(eligible);
        // A long has nothing to close against: the short bucket is empty.
        pair.setBucket(WINNER, true, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (score, eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 0, "nothing in the bucket opposite the account");
        assertFalse(eligible);
        // Right side but losing at the mark (short from $90 entry, mark $100).
        pair.setBucket(WINNER, false, 1 * SCALE, 90 * SCALE, 10 * SCALE);
        (score, eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 0, "non-positive PnL at the ranking price");
        assertFalse(eligible);
    }

    function test_getAdlScore_normalWinner_pnlOverCollateral() public {
        _setupAdlWindow();
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 5 * SCALE, "$50 pnl / $10 collateral = 5.0");
        assertTrue(eligible, "past the auction: threshold 1");
    }

    function test_getAdlScore_windowDeposit_subtractedFromDenominator() public {
        _setupAdlWindow();
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        pair.setAdlScoreDeposit(WINNER, 9 * SCALE); // mid-window top-up: ranked on $1 pre-window collateral
        (uint256 score,) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 50 * SCALE, "$50 pnl / ($10 - $9) = 50.0");
    }

    function test_getAdlScore_zeroCollateral_flooredDenominator() public {
        _setupAdlWindow();
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 0);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        // Pure-profit claim: denominator floors at 1 wei, ranking effectively infinite.
        assertEq(score, 50 * SCALE * SCALE, "$50 pnl / 1 wei");
        assertTrue(eligible);
    }

    function test_getAdlScore_belowDecayingThreshold_scoredButIneligible() public {
        pair.setAdl(true, block.timestamp); // auction just opened: threshold = 1 + 25e18
        pair.setMark(100 * SCALE);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 90 * SCALE, true);
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 5 * SCALE, "score is reported either way");
        assertFalse(eligible, "5.0 < opening threshold");
    }

    // -------- both sides rank at the stored price and the live funding index --------

    /// @dev A long, a candidate only while the vault holds a SHORT bucket.
    address constant LONG_WINNER = address(0xD1F);

    /// @notice A long closes against the short bucket, and the chain ranks it at the price the
    ///         call resolves, so the lens scores it at the pair's last stored price: a long from
    ///         $80 on $10 is $40 up at the $120 mark.
    function test_getAdlScore_shortBucket_longRanksAtTheStoredPrice() public {
        pair.setAdl(true, block.timestamp);
        vm.warp(block.timestamp + DURATION);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 110 * SCALE, false);
        pair.setMark(120 * SCALE);
        pair.setBucket(LONG_WINNER, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), LONG_WINNER);
        assertEq(score, 4 * SCALE, "$40 pnl at the $120 mark / $10");
        assertTrue(eligible, "past the auction: threshold 1");
    }

    /// @notice The live funding index is part of the ranking: an index of +10 per unit since entry
    ///         debits a long $10, so at a $100 mark the long from $80 is $20 - $10 = $10 up on $10
    ///         collateral.
    function test_getAdlScore_shortBucket_longRanksAtTheLiveFundingIndex() public {
        pair.setAdl(true, block.timestamp);
        vm.warp(block.timestamp + DURATION);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 110 * SCALE, false);
        pair.setMark(100 * SCALE);
        pair.setFundingIndex(10 * int256(SCALE));
        pair.setBucket(LONG_WINNER, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        (uint256 score,) = lens.getAdlScore(address(pair), LONG_WINNER);
        assertEq(score, 1 * SCALE, "($20 price pnl - $10 funding) / $10 at the live index");
    }

    /// @notice No profit at the ranking price is no candidacy: the long from $80 is under water
    ///         at a $75 mark, so it scores 0 although the short bucket is there to close against.
    function test_getAdlScore_shortBucket_longLosingAtTheMark_zero() public {
        pair.setAdl(true, block.timestamp);
        vm.warp(block.timestamp + DURATION);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 110 * SCALE, false);
        pair.setMark(75 * SCALE);
        pair.setBucket(LONG_WINNER, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), LONG_WINNER);
        assertEq(score, 0, "no profit at the ranking price");
        assertFalse(eligible);
    }

    /// @notice A deposit tagged to the live window is subtracted on this side too, as
    ///         AdlLib._scan subtracts it for every candidate: the long from $80 on $10 with a $9
    ///         tag scores $20 / ($10 - $9) at the $100 mark.
    function test_getAdlScore_shortBucket_windowDepositSubtracted() public {
        pair.setAdl(true, block.timestamp);
        vm.warp(block.timestamp + DURATION);
        pair.setPendingLiq(1 * SCALE, 100 * SCALE, 110 * SCALE, false);
        pair.setMark(100 * SCALE);
        pair.setBucket(LONG_WINNER, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        pair.setAdlScoreDeposit(LONG_WINNER, 9 * SCALE);
        (uint256 score,) = lens.getAdlScore(address(pair), LONG_WINNER);
        assertEq(score, 20 * SCALE, "$20 pnl / ($10 - $9)");
    }

    /// @notice The long bucket's counterparties move with the mark and the funding index like
    ///         every candidate: the short from $150 is $30 up at the $120 mark and receives $10 of
    ///         funding at an index of +10, so it scores 4.0, not the 5.0 it carried at $100.
    function test_getAdlScore_winners_followTheMarkAndTheFundingIndex() public {
        _setupAdlWindow();
        pair.setMark(120 * SCALE);
        pair.setFundingIndex(10 * int256(SCALE));
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 4 * SCALE, "($30 price pnl + $10 funding received) / $10 at the $120 mark");
        assertTrue(eligible);
    }

    // ---------------- terminal entitlement ----------------

    function test_getTerminalEntitlement_windowOpen_payoutZero() public {
        pair.setBucket(WINNER, false, 0, 0, 500 * SCALE);
        pair.setTerminalClaim(WINNER, 100 * SCALE);
        pair.setTerminal(50_000 * SCALE, block.timestamp, 0, 0); // window open, ratios not frozen yet
        (uint256 coll, uint256 claim, uint256 principalRatio, uint256 profitRatio, uint256 payout) =
            lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(coll, 500 * SCALE);
        assertEq(claim, 100 * SCALE, "claim registered during the window");
        assertEq(principalRatio, 0, "ratios not frozen until finalize");
        assertEq(profitRatio, 0);
        assertEq(payout, 0, "payout unknown until finalize");
    }

    function test_getTerminalEntitlement_frozenRatios_payout() public {
        pair.setBucket(WINNER, false, 0, 0, 500 * SCALE);
        pair.setTerminalClaim(WINNER, 100 * SCALE);
        pair.setTerminal(50_000 * SCALE, block.timestamp, SCALE, 8 * SCALE / 10); // finalized: profits at 80%
        (uint256 coll, uint256 claim, uint256 principalRatio, uint256 profitRatio, uint256 payout) =
            lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(coll, 500 * SCALE);
        assertEq(claim, 100 * SCALE);
        assertEq(principalRatio, SCALE);
        assertEq(profitRatio, 8 * SCALE / 10);
        assertEq(payout, 580 * SCALE, "500 principal + 100 claim x 80%");

        pair.setTerminal(50_000 * SCALE, block.timestamp, 75 * SCALE / 100, 0); // cash short of principal
        (,,,, payout) = lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(payout, 375 * SCALE, "500 x 75%, claim pays nothing");
    }

    // ---------------- getMaxWithdrawable (mirrors the withdrawCollateral gates) ----------------

    function test_getMaxWithdrawable_flatNoOrders_fullCollateral() public {
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 0), 100 * SCALE);
    }

    function test_getMaxWithdrawable_flatWithOrders_reservesOrderImr() public {
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        pair.setMarginReqs(1_000, 500, 500); // IMR 10%
        pair.setMark(100 * SCALE); // the synthetic orders sit at the mark: no loss is booked
        pair.setOrderExposure(WINNER, 50 * SCALE, 200 * SCALE); // larger side: $200 short
        uint256 makerFee = 250 * SCALE * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0),
            80 * SCALE - makerFee,
            "collateral less 10% of the larger resting side, less the maker fee on both sides"
        );
    }

    function test_getMaxWithdrawable_position_imrSlackBinds() public {
        pair.setMarginReqs(1_000, 500, 500); // IMR 10%
        // Long 1 unit at $100 entry, price $100: equity = collateral = $20.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        // Ceilings: collateral 20; floor mmr 5% x 100 = $5 -> 15; IMR slack 20 - 10%x100 = 10.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 10 * SCALE);
    }

    function test_getMaxWithdrawable_position_retentionFloorBinds() public {
        pair.setMarginReqs(1_000, 500, 500);
        // Long 1 unit at $100 entry, price $300: equity $220 dwarfs the $30 IMR requirement.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        // Ceilings: collateral 20; floor mmr 5% x 300 = $15 -> 5; IMR slack 220 - 30 = 190.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 300 * SCALE), 5 * SCALE);

        // Deeper in profit the floor exceeds the cash on hand: nothing is withdrawable.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 1_000 * SCALE), 0);
    }

    function test_getMaxWithdrawable_position_nonContinuous_imrCashFloor() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setContinuouslyTraded(false);
        // Long 1 unit at $100 entry, price $300: session-bound pairs retain imrBp in cash, so the
        // floor is 10% x 300 = $30 — above the $20 of collateral, nothing is withdrawable even
        // though equity ($220) dwarfs the IMR requirement ($30).
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 300 * SCALE), 0);

        // With $50 of cash the same floor leaves $20 free (IMR slack is far looser at 220).
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 50 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 300 * SCALE), 20 * SCALE);
    }

    function test_getMaxWithdrawable_position_orderExposureWidensImr() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        pair.setMark(100 * SCALE); // the synthetic order sits at the mark: no loss is booked
        pair.setOrderExposure(WINNER, 50 * SCALE, 0); // same-direction resting orders
        // Worst case = $100 position + $50 same-dir orders -> IMR $15 -> slack $5, less the
        // maker fee on the $50 order.
        uint256 makerFee = 50 * SCALE * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 5 * SCALE - makerFee);
    }

    function test_getMaxWithdrawable_frozenStates_zero() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);

        pair.setTerminal(100 * SCALE, block.timestamp, 0, 0); // settlement window open
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 0, "settlement window");
        pair.setTerminal(0, 0, 0, 0);

        pair.setAdl(true, block.timestamp);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 0, "ADL freezes position holders");
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0), 100 * SCALE, "flat users stay withdrawable during ADL"
        );
    }

    function test_getMaxWithdrawable_underwaterPosition_zero() public {
        pair.setMarginReqs(1_000, 500, 500);
        // Long 1 unit at $100 entry, price $50: the $50 loss swamps the $20 collateral.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 50 * SCALE), 0);
    }

    function test_getLiquidationRewardConstants() public view {
        (uint256 minReward, uint256 feeEbp, uint256 ebpScale) = lens.getLiquidationRewardConstants();
        assertEq(minReward, BazaarTypes.MIN_LIQUIDATOR_REWARD);
        assertEq(feeEbp, BazaarTypes.LIQUIDATION_FEE_EBP);
        assertEq(ebpScale, BazaarTypes.EBP_SCALE);
    }

    /// @notice Both buckets come through whole, the entry funding index with the notionals:
    ///         without it a caller can only rebuild the price half of the vault's PnL.
    function test_getPendingLiquidationExposure_forwardsFields() public {
        pair.setPendingLiq(5 * SCALE, 250_000 * SCALE, 240_000 * SCALE, true);
        pair.setPendingLiqFundingIndex(-7 * int256(SCALE));
        pair.setPendingLiqSeizedTs(1_700_000_123);
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) =
            lens.getPendingLiquidationExposure(address(pair));
        assertEq(l.size, 5 * SCALE);
        assertEq(l.entryNotional, 250_000 * SCALE);
        assertEq(l.bankruptcyNotional, 240_000 * SCALE);
        assertEq(l.entryFundingIndex, -7 * int256(SCALE), "entry funding index forwarded, sign preserved");
        assertEq(l.seizedTs, 1_700_000_123, "seizure stamp forwarded: what the unload floor opens from");
        assertEq(s.size, 0, "the short bucket is empty");
    }
}
