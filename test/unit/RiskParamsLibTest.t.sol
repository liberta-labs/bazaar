// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Minimal storage host so the external library's storage-pointer functions can be called.
contract RiskParamsHarness {
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.ReopenGapEma internal reopenGapEma;

    function setInsurance(uint256 balance) external {
        pairVault.insuranceFundBalance = balance;
    }

    function setOI(uint256 longOI, uint256 shortOI) external {
        pairVault.totalLongOI = longOI;
        pairVault.totalShortOI = shortOI;
    }

    function setVariance(uint256 emaVarianceBp) external {
        lastPairPrice.emaVarianceBp = emaVarianceBp;
    }

    function takerFeeEbp(uint256 currentPrice) external view returns (uint256 f) {
        (f,) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, currentPrice, true, 0
        );
    }
}

/// @notice Pins the taker insurance fee curve to its intended scale (100 EBP = 1 bp).
///         Guards against the constants regressing to a mis-scaled magnitude — a 100×
///         error here once put the minimum all-in taker fee at ~51 bps.
contract RiskParamsLibTest is Test {
    uint256 internal constant SCALE = 1e18; // BAZAAR_SCALE
    uint256 internal constant PRICE = 1e18; // 1:1 so OI size == OI notional

    RiskParamsHarness internal h;

    function setUp() public {
        h = new RiskParamsHarness();
        h.setOI(1_000_000 * SCALE, 1_000_000 * SCALE); // matched book, $1M OI notional per side at PRICE
    }

    /// @notice Base fee endpoints: 0.75 bp (75 EBP) at the 2% target, 4.25 bp (425 EBP) at the 10% target.
    function test_TakerInsuranceFeeBase_Endpoints() public pure {
        assertEq(RiskParamsLib.getTakerInsuranceFeeBase(200), 75, "0.75 bp at INSURANCE_TARGET_BASE");
        assertEq(RiskParamsLib.getTakerInsuranceFeeBase(1_000), 425, "4.25 bp at INSURANCE_TARGET_MAX");
        // Linear interpolation midway up the target range
        assertEq(RiskParamsLib.getTakerInsuranceFeeBase(600), 250, "interpolated base fee");
    }

    /// @notice Fund exactly at target → base fee, no deficit multiplier: 75 EBP = 0.75 bp.
    function test_TakerInsuranceFee_AtTarget() public {
        h.setInsurance(20_000 * SCALE); // 2% of $1M = the low-vol target
        assertEq(h.takerFeeEbp(PRICE), 75, "0.75 bp when fund is at target");
    }

    /// @notice Fund at 2x target → still the base fee. The base rate is a floor: however
    ///         overfull the fund is, new flow pays for the coverage it consumes.
    function test_TakerInsuranceFee_AboveTargetFloorsAtBase() public {
        h.setInsurance(40_000 * SCALE); // 4% vs 2% target
        assertEq(h.takerFeeEbp(PRICE), 75, "no discount above target");
    }

    /// @notice 75% deficit → fBase x (1 + 49 x 0.75^2) = 75 x 28.5625 → 2,142 EBP ≈ 21.4 bp.
    function test_TakerInsuranceFee_DeficitMultiplier() public {
        h.setInsurance(5_000 * SCALE); // 0.5% vs 2% target → deficit δ = 0.75
        assertEq(h.takerFeeEbp(PRICE), 2_142, "quadratic deficit multiplier");
    }

    /// @notice Extreme vol on a deeply underfunded fund stays under the cap: a 4.5% target gives
    ///         fBase = 184 EBP, and at 1.25% coverage (δ = 0.7222) 184 x (1 + 49 x 0.7222²) =
    ///         4,886 EBP ≈ 48.9 bp is paid in full. An empty fund at this target reaches the cap
    ///         (184 x 50 = 9,200 EBP).
    function test_TakerInsuranceFee_ExtremeVolStaysUnderCap() public {
        h.setVariance(100_000_000); // VARIANCE_EXTREME → 4.5% target, fBase = 184 EBP
        h.setInsurance(12_500 * SCALE); // 1.25% vs 4.5% target → deficit δ = 0.7222
        assertEq(h.takerFeeEbp(PRICE), 4_886, "below the cap the curve is charged untrimmed");
    }

    /// @notice Worst case — vol at the multiplier ceiling, empty fund → uncapped 381 x 50 =
    ///         19,050 EBP, clipped to 5,000 EBP = 50 bp.
    function test_TakerInsuranceFee_CapsAt50Bp() public {
        h.setVariance(247_000_000); // VOL_MULTIPLIER_MAX → 9% target, fBase = 381 EBP
        h.setInsurance(0); // full deficit, δ = 1
        assertEq(h.takerFeeEbp(PRICE), 5_000, "hard cap is 50 bp, not 50%");
    }

    /// @notice No open interest → infinite coverage, which is the above-target arm → base fee.
    function test_TakerInsuranceFee_ZeroOI() public {
        h.setOI(0, 0);
        h.setInsurance(1 * SCALE);
        assertEq(h.takerFeeEbp(PRICE), 75, "infinite coverage still pays the base rate");
    }
}
