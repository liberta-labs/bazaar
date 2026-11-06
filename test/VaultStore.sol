// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {BazaarTypes} from "../src/libraries/BazaarTypes.sol";

interface IVaultRead {
    function pairVault()
        external
        view
        returns (
            uint256 totalLongOI,
            uint256 totalShortOI,
            uint256 longWeightedEntrySum,
            uint256 shortWeightedEntrySum,
            uint256 totalCollateralDeposited,
            uint256 insuranceFundBalance,
            uint256 deficit,
            uint256 targetInsuranceRatioBp,
            uint256 ledgerArrears,
            uint128 trailingOiSize,
            BazaarTypes.Inventory memory longInv,
            BazaarTypes.Inventory memory shortInv
        );
}

/// @title VaultStore
/// @notice Stages the pair's vault buckets and a few vault scalars directly in storage, for tests
///         that need inventory the trading path cannot produce (an already-seized estate, a
///         bucket with a chosen bankruptcy price). The one place in test/ that names a
///         `pairVault()` tuple depth.
/// @dev Depths index the words of the pairVault() getter's return data, which stdstore locates
///      the backing slot of: 0 totalLongOI, 1 totalShortOI, 2 longWeightedEntrySum,
///      3 shortWeightedEntrySum, 4 totalCollateralDeposited, 5 insuranceFundBalance, 6 deficit,
///      7 targetInsuranceRatioBp, 8 ledgerArrears, 9 trailingOiSize, 10..15 longInv (size,
///      entryNotional, bankruptcyNotional, seized, entryFundingIndex, seizedTs), 16..21 shortInv
///      in the same order. Every bucket field sits alone in its slot, so no write clobbers a
///      neighbour.
library VaultStore {
    using stdStorage for StdStorage;

    uint256 internal constant DEPTH_TOTAL_COLLATERAL_DEPOSITED = 4;
    uint256 internal constant DEPTH_INSURANCE_FUND_BALANCE = 5;
    uint256 internal constant DEPTH_DEFICIT = 6;
    uint256 internal constant DEPTH_TARGET_INSURANCE_RATIO_BP = 7;
    uint256 internal constant DEPTH_LEDGER_ARREARS = 8;
    uint256 internal constant DEPTH_TRAILING_OI_SIZE = 9;
    uint256 internal constant DEPTH_LONG_INV = 10;
    uint256 internal constant DEPTH_SHORT_INV = 16;

    /// @dev The depth of a bucket's first word.
    function base(bool isLong) internal pure returns (uint256) {
        return isLong ? DEPTH_LONG_INV : DEPTH_SHORT_INV;
    }

    /// @dev Write every field of one bucket.
    function stage(StdStorage storage s, address pair, bool isLong, BazaarTypes.Inventory memory inv) internal {
        uint256 b = base(isLong);
        s.target(pair).sig("pairVault()").depth(b).checked_write(inv.size);
        s.target(pair).sig("pairVault()").depth(b + 1).checked_write(inv.entryNotional);
        s.target(pair).sig("pairVault()").depth(b + 2).checked_write(inv.bankruptcyNotional);
        s.target(pair).sig("pairVault()").depth(b + 3).checked_write(inv.seized);
        s.target(pair).sig("pairVault()").depth(b + 4).checked_write_int(inv.entryFundingIndex);
        s.target(pair).sig("pairVault()").depth(b + 5).checked_write(uint256(inv.seizedTs));
    }

    /// @dev Stage a bucket from its size, entry basis and seizure, with a bankruptcy notional the
    ///      seizure displaces from the entry (below it for longs, above it for shorts), the live
    ///      entry index as its funding anchor and no seizure stamp (the walk treats it as fully
    ///      aged).
    function stage(
        StdStorage storage s,
        address pair,
        bool isLong,
        uint256 size,
        uint256 entryNotional,
        uint256 seized,
        int256 entryFundingIndex
    ) internal {
        stage(
            s,
            pair,
            isLong,
            BazaarTypes.Inventory({
                size: size,
                entryNotional: entryNotional,
                bankruptcyNotional: isLong ? entryNotional - seized : entryNotional + seized,
                seized: seized,
                entryFundingIndex: entryFundingIndex,
                seizedTs: 0
            })
        );
    }

    function setSize(StdStorage storage s, address pair, bool isLong, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(base(isLong)).checked_write(v);
    }

    function setEntryNotional(StdStorage storage s, address pair, bool isLong, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(base(isLong) + 1).checked_write(v);
    }

    function setBankruptcyNotional(StdStorage storage s, address pair, bool isLong, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(base(isLong) + 2).checked_write(v);
    }

    function setSeized(StdStorage storage s, address pair, bool isLong, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(base(isLong) + 3).checked_write(v);
    }

    function setEntryFundingIndex(StdStorage storage s, address pair, bool isLong, int256 v) internal {
        s.target(pair).sig("pairVault()").depth(base(isLong) + 4).checked_write_int(v);
    }

    function setSeizedTs(StdStorage storage s, address pair, bool isLong, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(base(isLong) + 5).checked_write(v);
    }

    /// @dev Empty one bucket.
    function clear(StdStorage storage s, address pair, bool isLong) internal {
        BazaarTypes.Inventory memory none;
        stage(s, pair, isLong, none);
    }

    function setInsuranceFundBalance(StdStorage storage s, address pair, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(DEPTH_INSURANCE_FUND_BALANCE).checked_write(v);
    }

    function setTotalCollateralDeposited(StdStorage storage s, address pair, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(DEPTH_TOTAL_COLLATERAL_DEPOSITED).checked_write(v);
    }

    function setDeficit(StdStorage storage s, address pair, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(DEPTH_DEFICIT).checked_write(v);
    }

    function setTargetInsuranceRatioBp(StdStorage storage s, address pair, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(DEPTH_TARGET_INSURANCE_RATIO_BP).checked_write(v);
    }

    function setLedgerArrears(StdStorage storage s, address pair, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(DEPTH_LEDGER_ARREARS).checked_write(v);
    }

    function setTrailingOiSize(StdStorage storage s, address pair, uint256 v) internal {
        s.target(pair).sig("pairVault()").depth(DEPTH_TRAILING_OI_SIZE).checked_write(v);
    }

    /// @dev Read one bucket through the getter.
    function read(address pair, bool isLong) internal view returns (BazaarTypes.Inventory memory) {
        (,,,,,,,,,, BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = IVaultRead(pair).pairVault();
        return isLong ? l : s;
    }

    /// @dev Both buckets' size.
    function inventorySize(address pair) internal view returns (uint256) {
        (,,,,,,,,,, BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = IVaultRead(pair).pairVault();
        return l.size + s.size;
    }
}
