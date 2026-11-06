// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";

contract VaultHealthEdgeHarness {
    BazaarTypes.Vault public vault;

    /// @dev Warmup MMR. The band is capped at 5%, so on a one-unit net exposure at the $50k
    ///      oracle the band edge sits $2,500 from the mark.
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

    /// @dev Stage a bucket of estates whose collateral was consumed in full: the entry basis is
    ///      the bankruptcy notional and nothing is earmarked, so the bucket's loss at a price is
    ///      its bankruptcy notional less its notional there.
    function seed(bool isLong, uint256 size, uint256 bankruptcyNotional) external {
        _write(isLong, size, bankruptcyNotional, bankruptcyNotional, 0, 0);
    }

    function setInsurance(uint256 insurance) external {
        vault.insuranceFundBalance = insurance;
    }

    function bucket(bool isLong) external view returns (BazaarTypes.Inventory memory) {
        return isLong ? vault.longInv : vault.shortInv;
    }

    function check(uint256 price, bool isAdlPending, uint256 adlPendingSince)
        external
        view
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(vault, price, isAdlPending, adlPendingSince, int256(0), MMR_BP);
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
        b.entryFundingIndex = entryFundingIndex;
    }
}

/// @notice Pins the ADL gate's two levels, how the two buckets enter them — the overlap's loss
///         is fixed whatever the price, the net exposure is valued at the larger bucket's band
///         edge — and the 24h ADL-timeout boundary: the exact levels at which trading freezes,
///         stays frozen, and finally escalates to termination.
contract VaultHealthEdgeTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant PRICE = 50_000e18;
    uint256 constant FUND = 10_000e18;
    VaultHealthEdgeHarness h;

    function setUp() public {
        h = new VaultHealthEdgeHarness();
        vm.warp(1_700_000_000);
    }

    /// @dev Vault long 1 unit, nothing earmarked and no target cached, so the base is the whole
    ///      $10k fund: expected loss = bankruptcyNotional − currentNotional, and finishing the
    ///      unit at the band edge costs that loss plus $2,500.
    function _seedLoss(uint256 loss) internal {
        h.seed(true, 1 * SCALE, PRICE + loss);
        h.setInsurance(FUND);
    }

    function _since() internal view returns (uint256) {
        return block.timestamp - 5 minutes;
    }

    /// @notice The hysteresis band: a $9,000 loss is healthy when NOT pending (under the $10,000
    ///         base) but unhealthy when pending (finishing at the band edge would cost $11,500) —
    ///         same state, different phase.
    function test_hysteresis_lossInsideTheBandDependsOnPhase() public {
        _seedLoss(9_000e18);
        VaultHealthLib.LiqExposureResult memory quiet = h.check(PRICE, false, 0);
        assertTrue(quiet.healthy, "$9,000 under the $10,000 base: no ADL");
        assertFalse(quiet.newIsAdlPending, "not triggered");

        VaultHealthLib.LiqExposureResult memory pending = h.check(PRICE, true, _since());
        assertFalse(pending.healthy, "$11,500 to finish at the band edge: ADL persists");
        assertTrue(pending.newIsAdlPending, "stays pending");
    }

    /// @notice Past the base, ADL turns on and the window's clock starts.
    function test_hysteresis_lossPastBaseTriggersAdl() public {
        _seedLoss(10_001e18);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, false, 0);
        assertFalse(r.healthy, "over the trigger");
        assertTrue(r.newIsAdlPending, "ADL triggered");
        assertEq(r.newAdlPendingSince, block.timestamp, "auction clock started");
        assertFalse(r.adlTimeoutExpired, "a window that just opened has not timed out");
    }

    /// @notice A pending ADL clears once the base could finish the remainder at the band edge:
    ///         $7,499 of loss plus $2,500 fits under $10,000, $7,501 does not.
    function test_hysteresis_releaseOnceTheBandEdgeFits() public {
        _seedLoss(7_499e18);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, true, _since());
        assertTrue(r.healthy, "the band edge fits under the base");
        assertFalse(r.newIsAdlPending, "ADL cleared");
        assertEq(r.newAdlPendingSince, 0, "clock cleared");

        _seedLoss(7_501e18);
        r = h.check(PRICE, true, _since());
        assertFalse(r.healthy, "$2 over: the band edge no longer fits");
        assertTrue(r.newIsAdlPending, "stays pending");
    }

    /// @notice With no capital above the reserve, a pending ADL still clears once the inventory
    ///         sits above water by more than the band: finishing it costs nothing.
    function test_hysteresis_noBase_releasesOnlyAboveWaterBeyondTheBand() public {
        h.seed(true, 1 * SCALE, PRICE - 3_000e18); // bankruptcy $3,000 under the oracle, no fund
        h.setInsurance(0);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, true, _since());
        assertTrue(r.healthy, "band edge $2,500 under the oracle: finishing costs nothing");
        assertFalse(r.newIsAdlPending, "ADL cleared");

        h.seed(true, 1 * SCALE, PRICE - 2_000e18);
        r = h.check(PRICE, true, _since());
        assertFalse(r.healthy, "$500 to finish at the band edge and nothing to pay it with");
        assertTrue(r.newIsAdlPending, "stays pending");
    }

    // ---------------- two buckets: the overlap and the net exposure ----------------

    /// @notice The overlap of the two buckets loses the gap between their entry bases whatever
    ///         the price: a long entered at $60k against a short entered at $48k loses $12,000
    ///         at any mark and at either band edge, since the price cancels on the hedged pair.
    ///         One fund figure therefore decides both phases alike — $12,000 of base carries the
    ///         pair quiet or pending, a dollar less opens the window and holds it — at $30k as
    ///         at $70k.
    function test_overlap_lossIsPriceIndependent() public {
        h.seed(true, 1 * SCALE, 60_000e18);
        h.seed(false, 1 * SCALE, 48_000e18);

        h.setInsurance(12_000e18);
        assertTrue(h.check(PRICE, false, 0).healthy, "$12,000 of base carries the $12,000 overlap: no window");
        assertTrue(h.check(30_000e18, true, _since()).healthy, "pending at $30k: the edge adds nothing, released");
        assertTrue(h.check(70_000e18, true, _since()).healthy, "pending at $70k: the same");

        h.setInsurance(12_000e18 - 1e18);
        assertFalse(h.check(PRICE, false, 0).healthy, "a dollar short opens the window");
        assertFalse(h.check(30_000e18, true, _since()).healthy, "and holds it at $30k");
        assertFalse(h.check(70_000e18, true, _since()).healthy, "and at $70k");
    }

    /// @notice The band edge the finish is read at is the larger bucket's adverse edge. Long 2
    ///         units and short 1, all entered at the oracle: the overlap unit loses nothing and
    ///         the net long unit is whole at the mark, so no window opens; pending, the finish is
    ///         read at the long edge, $47,500, where the net unit loses $2,500 — read at the short
    ///         edge it would gain that much and finish free. The mirror, short 2 against long 1,
    ///         reads the short edge, $52,500, and loses the same $2,500.
    function test_netSide_bandEdgeFollowsTheLargerBucket() public {
        h.seed(true, 2 * SCALE, 100_000e18);
        h.seed(false, 1 * SCALE, 50_000e18);
        h.setInsurance(2_000e18);
        assertTrue(h.check(PRICE, false, 0).healthy, "nothing lost at the mark: no window opens");
        assertFalse(h.check(PRICE, true, _since()).healthy, "the net long unit loses $2,500 at $47,500: held");

        h.seed(true, 1 * SCALE, 50_000e18);
        h.seed(false, 2 * SCALE, 100_000e18);
        assertTrue(h.check(PRICE, false, 0).healthy, "mirror: nothing lost at the mark");
        assertFalse(h.check(PRICE, true, _since()).healthy, "the net short unit loses $2,500 at $52,500: held");

        h.setInsurance(2_500e18);
        assertTrue(h.check(PRICE, true, _since()).healthy, "$2,500 of base finishes the net unit at its edge: released");
    }

    /// @notice The 24h timeout is strict: one second past fires, exactly at the boundary does not.
    function test_timeout_boundaryIsStrict() public {
        _seedLoss(9_000e18); // the band edge does not fit -> the pending branch (where the timeout lives) runs

        VaultHealthLib.LiqExposureResult memory atBoundary =
            h.check(PRICE, true, block.timestamp - VaultHealthLib.ADL_TIMEOUT_DURATION);
        assertFalse(atBoundary.adlTimeoutExpired, "exactly 24h: not yet expired");

        VaultHealthLib.LiqExposureResult memory past =
            h.check(PRICE, true, block.timestamp - VaultHealthLib.ADL_TIMEOUT_DURATION - 1);
        assertTrue(past.adlTimeoutExpired, "24h + 1s: escalate to termination");
    }
}
