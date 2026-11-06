// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title VaultHealthLib
/// @notice External library for the ADL gate: whether the insurance fund's free capital above
///         its reserve carries the inventory the vault holds in its two buckets. Linked as an
///         external library so the gate's code lives outside the pair's EIP-170 budget;
///         RiskParamsLib carries the exposure math it calls.
library VaultHealthLib {
    // -------------------- Constants --------------------

    /// @notice Maximum duration ADL can remain pending before triggering emergency termination
    uint256 internal constant ADL_TIMEOUT_DURATION = 24 hours;

    // -------------------- Structs --------------------

    /// @notice Result of Check 1: liquidation exposure vs insurance fund
    struct LiqExposureResult {
        bool healthy; // True when the fund above its reserve carries the inventory (see checkLiqExposure)
        bool adlTimeoutExpired; // True if ADL has been pending longer than ADL_TIMEOUT_DURATION
        // New ADL state — caller should apply these to storage
        bool newIsAdlPending;
        uint256 newAdlPendingSince;
    }

    // -------------------- Functions --------------------

    /// @notice Check 1: the vault's inventory against the insurance fund's free capital above its
    ///         reserve.
    /// @dev Returns a result struct with new ADL state values for the caller to apply. The
    ///      figures come from RiskParamsLib.vaultAdlExposure, which values both buckets against
    ///      the collateral seized alongside them and nets the reserve out of the fund: the
    ///      overlap of the two buckets carries a loss the price does not move, and the net
    ///      exposure a loss that does. The window opens when that capital cannot carry the
    ///      inventory at the mark. While open it stays open until the capital could finish the
    ///      remaining inventory at the unload band's edge — the figure the auction sizes its
    ///      batches to — so the walk that resumes afterwards can sell the remainder inside the
    ///      band without reopening the window. The gap between the two conditions is one band of
    ///      the remaining net exposure, so the boundary cannot flap on a tick.
    ///
    ///      One rule for both buckets. An estate seized onto the side opposite the inventory,
    ///      because the fund could not afford to net it, is inventory like any other: its loss
    ///      beyond its seizure counts here, and nothing else about the window changes. Both of a
    ///      batch's legs rank their cohort at the live price, so a bucket that appears while a
    ///      window is open needs no side re-targeted and no snapshot retaken.
    /// @param pairVault The pair's vault aggregates
    /// @param currentPrice Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param isAdlPending Whether a window is open
    /// @param adlPendingSince When the open window opened; 0 when none is open
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @return r The verdict and the ADL state the caller should store
    function checkLiqExposure(
        BazaarTypes.Vault storage pairVault,
        uint256 currentPrice,
        bool isAdlPending,
        uint256 adlPendingSince,
        int256 currentFundingIndex,
        uint256 mmrBp
    ) public view returns (LiqExposureResult memory r) {
        r.healthy = true;
        // Preserve existing state as defaults
        r.newIsAdlPending = isAdlPending;
        r.newAdlPendingSince = adlPendingSince;

        (uint256 expectedLoss, uint256 base, uint256 worstFinish,) =
            RiskParamsLib.vaultAdlExposure(pairVault, currentPrice, currentFundingIndex, mmrBp);

        bool uncovered = isAdlPending ? worstFinish > base : expectedLoss > base;

        if (uncovered) {
            r.healthy = false;
            if (!isAdlPending) {
                // First time triggering ADL
                r.newIsAdlPending = true;
                r.newAdlPendingSince = block.timestamp;
            } else {
                r.newIsAdlPending = true;
                if (adlPendingSince > 0 && block.timestamp - adlPendingSince > ADL_TIMEOUT_DURATION) {
                    // ADL timeout exceeded — caller should trigger emergency termination
                    r.adlTimeoutExpired = true;
                }
            }
        } else {
            // Pressure resolved — clear ADL state
            r.healthy = true;
            r.newIsAdlPending = false;
            r.newAdlPendingSince = 0;
        }
    }
}
