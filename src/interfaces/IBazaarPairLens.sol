// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {BazaarTypes} from "../libraries/BazaarTypes.sol";

/// @title IBazaarPairLens
/// @notice The external interface of BazaarPairLens: computed read-only views over any pair, from
///         solvency and margin to insurance share prices, ADL scores, book depth and the EIP-712
///         constants a relayer signs against.
/// @dev Declares every function and error in the lens's ABI.
///      `script/check-interfaces.sh`, which `make abis` and CI run, fails on any difference
///      between this interface and that ABI in a name, a type, an indexed flag or a state mutability.
///      MIT-licensed, unlike the AGPL implementation, so integrators can compile it into their own code.
interface IBazaarPairLens {
    // -------------------- Errors --------------------

    // Declared in BazaarPairLens
    error BazaarPairLens__ZeroAddress();

    // Declared in BazaarMathLib
    error BazaarMathLib__DivisionByZero();
    error BazaarMathLib__OperandTooSmall();
    error BazaarMathLib__ResultOverflow();

    // OpenZeppelin
    error SafeCastOverflowedIntToUint(int256 value);

    // -------------------- Functions --------------------

    // ---- Positions and margin ----
    function getPositionBucket(address pair, address user)
        external
        view
        returns (BazaarTypes.PositionBucket memory bucket);
    function checkBucketSolvency(address pair, address user, uint256 currentPrice)
        external
        view
        returns (BazaarTypes.BucketState memory result);
    function getMaxWithdrawable(address pair, address user, uint256 currentPrice)
        external
        view
        returns (uint256 maxAmount);
    function getMinCollateralAmount() external pure returns (uint256);

    // ---- Orders and the book ----
    function nextOrderId(address pair) external view returns (uint256);
    function getUserActiveLimitOrders(address pair, address user)
        external
        view
        returns (uint256[] memory orderIds, uint256 count, uint256 longExposure, uint256 shortExposure);
    function restingTally(address pair, address user) external view returns (BazaarTypes.RestingTally memory t);
    function outstandingOrderExposure(address pair, address user)
        external
        view
        returns (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize);
    function triggerBounty(address pair, uint256 orderId) external view returns (uint256);
    function getBookDepth(address pair, bool isLong, uint64 startId, uint256 maxN)
        external
        view
        returns (uint256[] memory orderIds, uint256[] memory prices, uint64 nextId);
    function findPredecessor(address pair, bool isLong, uint256 limitPrice, uint64 startId, uint256 maxIter)
        external
        view
        returns (uint64 pred, bool found);
    function amendIdWord(uint64 orderId, uint64 pred, uint64 pred2) external pure returns (uint256);
    function bestEffortAmendIdWord(uint64 orderId, uint64 pred, uint64 pred2) external pure returns (uint256);
    function getOrderLifetimeConstants()
        external
        pure
        returns (uint64 minOrderLifetimeBlocks, uint64 maxOrderLifetimeBlocks);

    // ---- Price, mark and funding ----
    function markPrice(address pair) external view returns (uint256);
    function fundingRate(address pair)
        external
        view
        returns (int256 currentRate, int256 accruingRate, int256 fundingIndex);
    function getMarkConstants()
        external
        pure
        returns (
            uint256 makerExposureBlocks,
            uint256 volumeFloorBp,
            uint256 maxAlphaBp,
            uint256 maxMarkDeviationBp,
            uint256 markDecayPeriod
        );
    function getAuxState(address pair) external view returns (BazaarTypes.AuxState memory);

    // ---- Insurance ----
    function getInsuranceSharePrice(address pair) external view returns (uint256);
    function getInsuranceDepositValue(address pair, address user) external view returns (uint256 value);
    function quoteInsuranceDeposit(address pair, uint256 amount, uint256 price) external view returns (uint256);
    function quoteInsuranceWithdrawal(address pair, uint256 shareAmount, uint256 price) external view returns (uint256);
    function getInsuranceWithdrawalBudget(address pair, uint256 price)
        external
        view
        returns (uint256 remaining, uint256 cap, uint256 resetsAt, uint256 coverageRatioBp, uint256 targetRatioBp);
    function getInsuranceWithdrawalLock(address pair, address user)
        external
        view
        returns (bool isLocked, uint256 lockedAmount, uint256 lockTs, uint256 claimOpensTs, uint256 windowEndTs);
    function getInsuranceWithdrawalConstants()
        external
        pure
        returns (
            uint256 cooldown,
            uint256 continuousWindow,
            uint256 sessionWindow,
            uint256 rateLimitPeriod,
            uint256 rateLimitBp,
            uint256 aboveTargetRateLimitBp,
            uint256 aboveTargetFundCapBp,
            uint256 belowTargetFundCapBp
        );

    // ---- Liquidation and ADL ----
    function getPendingLiquidationExposure(address pair)
        external
        view
        returns (BazaarTypes.Inventory memory longInv, BazaarTypes.Inventory memory shortInv);
    function getAdlScoreThreshold(address pair) external view returns (uint256);
    function getAdlScore(address pair, address user) external view returns (uint256 adlScore, bool eligible);
    function adlEpoch(address pair) external view returns (uint64);
    function adlTerminationTs(address pair) external view returns (uint256);
    function getVaultHealthConstants()
        external
        pure
        returns (
            uint256 adlReserveBp,
            uint256 unloadBandCapBp,
            uint256 adlTimeoutDuration,
            uint256 maxAdlWinnersPerBatch
        );
    function getLiquidationRewardConstants() external pure returns (uint256 minReward, uint256 feeEbp, uint256 ebpScale);

    // ---- Termination ----
    function getTerminalEntitlement(address pair, address user)
        external
        view
        returns (
            uint256 collateral,
            uint256 registeredClaim,
            uint256 principalRatio,
            uint256 profitRatio,
            uint256 payout
        );

    // ---- Payouts ----
    function claimableFees(address pair, address recipient) external view returns (uint256 owed, uint256 total);
    function getClaimableFees(address[] calldata pairs, address who) external view returns (uint256[] memory owed);
    function getClaimableFeesAll(address who) external view returns (address[] memory pairs, uint256[] memory owed);

    // ---- Relaying ----
    function getEip712Constants()
        external
        pure
        returns (
            bytes32 domainTypehash,
            bytes32 nameHash,
            bytes32 versionHash,
            uint256 maxRelayerFee,
            uint256 maxDeadlineWindow
        );
    function getTypehashes()
        external
        pure
        returns (
            bytes32 depositCollateral,
            bytes32 withdrawCollateral,
            bytes32 depositToInsurance,
            bytes32 executeInsuranceWithdrawal,
            bytes32 createOrder,
            bytes32 cancelOrders,
            bytes32 requestInsuranceWithdrawal,
            bytes32 amendOrders
        );

    // ---- Wiring ----
    function factory() external view returns (address);
}
