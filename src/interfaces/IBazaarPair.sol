// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {BazaarTypes} from "../libraries/BazaarTypes.sol";

/// @title IBazaarPair
/// @notice The external interface of a Bazaar market. Every market is an EIP-1167 clone of one
///         BazaarPair implementation, so this interface covers every pair the factory deploys.
/// @dev Declares every function, event and error in the pair's ABI, including the events and
///      errors of the external libraries the pair links: they run by DELEGATECALL in the pair's
///      context, so their logs carry the pair's address and their reverts surface from its calls.
///      `script/check-interfaces.sh`, which `make abis` and CI run, fails on any difference
///      between this interface and that ABI in a name, a type, an indexed flag or a state mutability.
///      MIT-licensed, unlike the AGPL implementation, so integrators can compile it into their own code.
///      Behaviour, units and access rules are documented at each definition in BazaarPair.sol
///      and in the docs' contract reference.
interface IBazaarPair {
    // -------------------- Types --------------------

    /// @notice The configuration the factory initializes each clone with. `umaContract` is the
    ///         terminator, the one caller every wiring function but `initialize` accepts.
    struct InitParams {
        bytes32 pairId;
        address oracle;
        address usdc;
        address bugBountyAddress;
        bytes32 baseFeedId;
        address umaContract;
        bool isContinuouslyTraded;
        address deployer;
        uint256 seedAmount;
    }

    // -------------------- Events --------------------

    // Declared in BazaarPair
    event InsuranceCredited(bytes32 indexed pairId, address indexed from, uint256 amountBazaarPrecision);
    event AdlTriggered(bytes32 indexed pairId, uint64 indexed adlEpoch, uint256 price, int256 fundingIndex);
    event AdlTerminationArmed(bytes32 indexed pairId, uint256 adlTerminationTs);
    event AdlResolved(bytes32 indexed pairId, uint64 indexed adlEpoch);
    event InsolvencySettlementFixed(bytes32 indexed pairId, uint256 settlementPrice, uint8 reason);
    event NewPriceUpdateAdded(
        bytes32 indexed pairId, uint256 indexed targetPublishTs, uint256 spotPrice, int32 exponent, int256 fundingIndex
    );
    event PermitExecutionFailed(address indexed owner);

    // Declared in BazaarTypes
    event Trade(
        bytes32 indexed pairId,
        address indexed maker,
        address indexed taker,
        uint256 makerOrderId,
        uint256 takerOrderId,
        bool takerIsLong,
        uint256 fillSize,
        uint256 price,
        uint256 makerFee,
        uint256 takerFee,
        uint256 makerRemaining,
        uint256 takerRemaining
    );
    event PositionModified(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        int256 sizeDelta,
        uint256 newSize,
        uint256 newEntryValue,
        uint256 newCollateral,
        uint256 executionPrice,
        uint256 fee,
        int256 realizedPnl
    );
    event OrderUpdated(
        bytes32 indexed pairId, uint256 indexed orderId, address indexed owner, BazaarTypes.OrderUpdatePayload payload
    );
    event OrderAmended(
        bytes32 indexed pairId,
        uint256 indexed orderId,
        address indexed owner,
        uint256 limitPrice,
        uint256 size,
        uint256 prioritySeq
    );
    event OrderAmendSkipped(
        bytes32 indexed pairId, uint256 indexed orderId, address indexed owner, BazaarTypes.AmendSkipReason reason
    );
    event PositionBucketUpdated(
        bytes32 indexed pairId,
        address indexed owner,
        bool isLong,
        uint256 size,
        uint256 entryValue,
        uint256 collateral,
        int256 entryFundingIndex,
        int256 globalFundingIndex,
        uint256 imrBp,
        uint256 mmrBp
    );
    event MetaTransactionExecuted(
        bytes32 indexed pairId,
        address indexed user,
        address indexed relayer,
        bytes32 functionId,
        uint256 nonce,
        uint256 relayerFee
    );
    event CollateralDeposited(bytes32 indexed pairId, address indexed user, uint256 amount);
    event FeeAccrued(bytes32 indexed pairId, address indexed recipient, uint256 amount);
    event TriggerBountyEscrowed(bytes32 indexed pairId, uint256 indexed orderId, uint256 amount);
    event TriggerBountyReleased(
        bytes32 indexed pairId, uint256 indexed orderId, address indexed recipient, uint256 amount
    );
    event FeesClaimed(bytes32 indexed pairId, address indexed recipient, uint256 amount);
    event CollateralWithdrawn(bytes32 indexed pairId, address indexed user, uint256 amount);
    event TerminalRatiosRefrozen(bytes32 indexed pairId, uint256 unfunded, uint256 principalRatio, uint256 profitRatio);
    event InsuranceDeposited(bytes32 indexed pairId, address indexed user, uint256 amount, uint256 sharesReceived);
    event InsuranceWithdrawalRequested(bytes32 indexed pairId, address indexed user, uint256 shareAmount);
    event InsuranceWithdrawalExecuted(
        bytes32 indexed pairId, address indexed user, uint256 shareAmount, uint256 usdcAmount
    );
    event InsuranceWithdrawalLocked(
        bytes32 indexed pairId, address indexed user, uint256 shareAmount, uint256 lockedAmount, uint256 claimOpensTs
    );

    // Declared in AdlLib
    event UserAdld(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        uint256 closedSize,
        int256 realizedPnl,
        uint256 remainingCollateral,
        uint256 adlScore,
        uint256 adlSettlementPrice,
        uint256 withheldFunding
    );
    event AdlExecuted(
        bytes32 indexed pairId,
        uint256 indexed adlId,
        address indexed submitter,
        uint256 longBucketClosed,
        uint256 longBucketSettlementPrice,
        uint256 shortBucketClosed,
        uint256 shortBucketSettlementPrice,
        uint256 netted,
        uint256 timestamp
    );

    // Declared in InsuranceVaultLib
    event InsuranceShareEpochBumped(uint256 newEpoch);

    // Declared in LiquidationLib
    event PositionLiquidated(
        bytes32 indexed pairId,
        address indexed liquidatedUser,
        address indexed liquidator,
        uint256 size,
        bool isLong,
        uint256 bankruptcyPrice,
        uint256 triggerPrice,
        uint256 collateralSeized,
        uint256 timestamp
    );

    // Declared in TerminationLib
    event PairTerminated(
        bytes32 indexed pairId,
        uint256 settlementPrice,
        uint256 owedToTraders,
        uint256 registeredClaims,
        uint256 badDebt,
        int256 estateValue,
        uint256 pot,
        uint256 principalRatio,
        uint256 profitRatio,
        uint256 insuranceFundBalanceAfter,
        bool sweepComplete,
        uint256 timestamp
    );

    // OpenZeppelin
    event Initialized(uint64 version);

    // -------------------- Errors --------------------

    // Declared in BazaarPair
    error BazaarPair__TransferFailed();
    error BazaarPair__PairScheduledForTermination();
    error BazaarPair__EthRefundFailed();
    error BazaarPair__TradingHalted();
    error BazaarPair__TradingFrozenAdlPending();
    error BazaarPair__ExceedsMaxCancelsPerCall();
    error BazaarPair__AdlNotPending();
    error BazaarPair__AdlPriceStale();
    error BazaarPair__AmountLteRelayerFee();
    error BazaarPair__AlreadyTerminated();
    error BazaarPair__NoPriceUpdatesProvided();
    error BazaarPair__InsufficientPythFee();
    error BazaarPair__OnlyUma();
    error BazaarPair__ZeroAddress();
    error BazaarPair__SeedBelowMinimum();
    error BazaarPair__TerminationAlreadyScheduled();
    error BazaarPair__UnauthorizedInsuranceCreditor();
    error BazaarPair__RelayerFeeExceedsDeposit();
    error BazaarPair__WithdrawalsFrozenAdlPending();
    error BazaarPair__InsuranceWithdrawalRequiresFreshPrice();
    error BazaarPair__InsuranceDepositRequiresFreshPrice();
    error BazaarPair__EmptyLiquidationList();
    error BazaarPair__LiquidationPriceTooOld();
    error BazaarPair__RequestorIsNotOrderOwner();
    error BazaarPair__SweepWindowActive();

    // Declared in AdlLib
    error AdlLib__EmptySubmission();
    error AdlLib__TooManyWinners(uint256 count, uint256 max);
    error AdlLib__NoPendingLiquidations();
    error AdlLib__NoEligibleWinners();

    // Declared in BazaarMathLib
    error BazaarMathLib__DivisionByZero();
    error BazaarMathLib__OperandTooSmall();
    error BazaarMathLib__ResultOverflow();

    // Declared in CollateralLib
    error CollateralLib__DepositsAreBlocked();
    error CollateralLib__PairScheduledForTermination();
    error CollateralLib__InvalidDepositAmount(uint256 amount, uint256 minAmount);
    error CollateralLib__ZeroWithdrawalAmount();
    error CollateralLib__NothingToClaim();
    error CollateralLib__ClaimTransferFailed();
    error CollateralLib__WithdrawalBlockedVaultUnhealthy();
    error CollateralLib__WithdrawalsFrozenAdlPending();
    error CollateralLib__InsolventPositionBucket(uint256 availableEquity, uint256 minRequiredCollateral);
    error CollateralLib__InsufficientCollateral(uint256 amount, uint256 available);
    error CollateralLib__InsufficientMarginAfterWithdrawal(uint256 amount, uint256 available);
    error CollateralLib__NoPriceUpdateDataProvided();
    error CollateralLib__MustRetainMinimumCollateral(uint256 remaining, uint256 minimum);
    error CollateralLib__WithdrawalRequiresFreshPrice();
    error CollateralLib__LedgerShortfall(uint256 amount, uint256 available);

    // Declared in InsuranceVaultLib
    error InsuranceVaultLib__ZeroDeposit();
    error InsuranceVaultLib__DepositBelowMinimum(uint256 amount, uint256 minimum);
    error InsuranceVaultLib__DepositAboveMaximum(uint256 amount, uint256 maximum);
    error InsuranceVaultLib__PairTerminated();
    error InsuranceVaultLib__PairScheduledForTermination(uint256 scheduledTs);
    error InsuranceVaultLib__DepositTooSmall();
    error InsuranceVaultLib__ZeroShares();
    error InsuranceVaultLib__ExceedsShares();
    error InsuranceVaultLib__NoWithdrawalRequest();
    error InsuranceVaultLib__WithdrawalRequestStaleEpoch();
    error InsuranceVaultLib__AdlBlocking();
    error InsuranceVaultLib__SweepIncomplete(uint256 releaseTs);
    error InsuranceVaultLib__VaultUnhealthy(uint8 reason);
    error InsuranceVaultLib__CooldownNotElapsed();
    error InsuranceVaultLib__WithdrawalWindowExpired();
    error InsuranceVaultLib__ClaimNotOpen(uint256 claimOpensTs);
    error InsuranceVaultLib__LockTooLate(uint256 claimOpensTs, uint256 windowEndTs);
    error InsuranceVaultLib__RateLimitExceeded();
    error InsuranceVaultLib__SharesLockedForVoting();
    error InsuranceVaultLib__TooManyRecentInsuranceDeposits(uint256 windowCount, uint16 cap);
    error InsuranceVaultLib__FundCommittedToInventory();

    // Declared in MatchingEngineLib
    error MatchingEngineLib__InvalidTriggerBatch(uint256 count);
    error MatchingEngineLib__BlockedOracleStale();
    error MatchingEngineLib__FillOrKillUnfilled(uint256 orderId, uint256 remaining);

    // Declared in MetaTxLib
    error MetaTx__InvalidSignature();
    error MetaTx__ExpiredDeadline(uint256 deadline, uint256 currentTime);
    error MetaTx__InvalidNonce(uint256 expected, uint256 provided);
    error MetaTx__RelayerFeeExceedsMax(uint256 fee, uint256 max);
    error MetaTx__DeadlineTooFar(uint256 deadline, uint256 maxDeadline);

    // Declared in OrderBookLib
    error OrderBookLib__AlreadyInBook(uint256 orderId);
    error OrderBookLib__HintRepairExhausted(uint256 orderId);

    // Declared in OrderManagementLib
    error OrderManagementLib__InvalidOrderExpiration(uint64 expirationBlock);
    error OrderManagementLib__OrderNotFound(uint256 orderId);
    error OrderManagementLib__OrderIsNotActive(uint256 orderId);
    error OrderManagementLib__OrderAlreadyExpired(uint256 orderId);
    error OrderManagementLib__InsufficientMarginAfterOrder(uint256 marginRatio, uint256 required);
    error OrderManagementLib__RequestorIsNotOrderOwner(uint256 orderId, address requestor);
    error OrderManagementLib__ZeroSize();
    error OrderManagementLib__ZeroLimitPrice();
    error OrderManagementLib__PostOnlyNotAllowed();
    error OrderManagementLib__InvalidTimeInForce();
    error OrderManagementLib__InvalidSlippage(uint256 maxSlippageBp);
    error OrderManagementLib__ZeroTriggerPrice();
    error OrderManagementLib__StopLimitPriceOnWrongSide();
    error OrderManagementLib__InvalidOrderType();
    error OrderManagementLib__NotionalBelowMinimum(uint256 notional, uint256 minimum);
    error OrderManagementLib__LimitPriceOutsidePlacementBand(uint256 limitPrice, uint256 minPrice, uint256 maxPrice);
    error OrderManagementLib__NoPositionForTpSl();
    error OrderManagementLib__TpSlMustBeOppositeDirection();
    error OrderManagementLib__TpSlOrderAlreadyExists();
    error OrderManagementLib__TooManyActiveLimitOrders();
    error OrderManagementLib__BountyOnUntriggeredType();
    error OrderManagementLib__BountyNotWholeUsdc(uint256 bounty);
    error OrderManagementLib__InvalidAmendBatch();
    error OrderManagementLib__NotAmendable(uint256 orderId);
    error OrderManagementLib__AmendSizeNotAboveFilled(uint256 orderId);
    error OrderManagementLib__AmendWouldCross(uint256 orderId, uint256 limitPrice, uint256 oppositeBest);
    error OrderManagementLib__AmendTooCloseToExpiry(uint256 orderId, uint64 expiryBlock, uint64 minExpiryBlock);

    // Declared in TerminationLib
    error TerminationLib__TerminationPriceRequired();
    error TerminationLib__BalanceOfFailed();

    // OpenZeppelin
    error InvalidInitialization();
    error NotInitializing();
    error ReentrancyGuardReentrantCall();
    error SafeERC20FailedOperation(address token);
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error SafeCastOverflowedUintToInt(uint256 value);
    error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);
    error ECDSAInvalidSignature();
    error ECDSAInvalidSignatureLength(uint256 length);
    error ECDSAInvalidSignatureS(bytes32 s);

    // -------------------- Functions --------------------

    // Every `priceUpdate` argument is Pyth Pro update data paid for from msg.value, and the pair refunds
    // the caller whatever ETH the call does not spend. The trading, collateral and insurance functions
    // also take (nonce, deadline, relayerFee, signature) and can be relayed: a non-empty signature acts
    // for its EIP-712 signer and accrues the relayer fee to the caller, an empty one acts for the caller.

    // ---- Trading ----
    function createOrder(
        BazaarTypes.OrderSpec calldata spec,
        BazaarTypes.MatchHints calldata hints,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external payable;
    function amendOrders(
        uint256[] calldata amends,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external payable;
    function cancelOrders(
        uint256[] calldata orderIds,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external;

    // ---- Collateral ----
    function depositCollateral(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external;
    function withdrawCollateral(
        uint256 amount,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) external payable;

    // ---- Insurance ----
    function depositToInsurance(
        uint256 amount,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external payable;
    function requestInsuranceWithdrawal(
        uint256 shareAmount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external;
    function executeInsuranceWithdrawal(
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external payable;

    // ---- Payouts ----
    // Pays the caller every payout the pair owes it.
    function claimFees() external;

    // ---- Upkeep (permissionless) ----
    function executeTriggeredOrders(BazaarTypes.TriggerExec[] calldata execs, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 executedCount);
    function liquidate(address[] calldata usersToLiquidate, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 liquidatedCount);
    function unloadVault(uint256 maxSteps, bytes[] calldata priceUpdate) external payable returns (uint256 unloadedSize);
    function executeAdl(
        address[] calldata longBucketWinners,
        address[] calldata shortBucketWinners,
        bytes[] calldata priceUpdate
    ) external payable;
    function refreshPrice(bytes[] calldata priceUpdate) external payable;
    function sweepExpired(uint256[] calldata orderIds) external;
    function finalizeTermination() external;

    // ---- Wiring ----
    // `initialize` runs once, called by the factory as it clones the pair; the other three
    // accept only the terminator (`umaContract`).
    function initialize(InitParams calldata p) external;
    function setScheduledTermination(uint256 lastTradingTs, address proposer) external;
    /// @notice Stage 1 of termination: pins the settlement price and opens the settlement window.
    ///         Stage 2, `finalizeTermination`, is public and freezes the payout ratios once every
    ///         position is settled at this price, or once the escape hatch has elapsed.
    function fixSettlementPrice(uint256 settlementPrice) external;
    /// @notice Credits USDC the terminator has already transferred to the pair (a forfeited
    ///         insurer-termination bond) to the insurance fund's bookkeeping, keeping the pair's
    ///         USDC balance and its insurance accounting in step.
    function creditInsurance(uint256 amountBazaarPrecision) external;

    // ---- Views: identity and wiring ----
    function pairId() external view returns (bytes32);
    function baseFeedId() external view returns (bytes32);
    function isContinuouslyTraded() external view returns (bool);
    function usdc() external view returns (address);
    function oracle() external view returns (address);
    function umaContract() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function metaTxNonces(address) external view returns (uint256);

    // ---- Views: price, margin and funding ----
    function lastPairPrice()
        external
        view
        returns (uint256 spotPrice, uint256 emaVarianceBp, uint256 updateTs, uint256 lowPrice, uint256 highPrice);
    function marginRequirements()
        external
        view
        returns (uint256 imrBp, uint256 mmrBp, uint256 lastUpdateTs, uint256 laggedMmrBp);
    function getLaggedMmr() external view returns (uint256);
    function currentFundingIndex() external view returns (int256);

    // ---- Views: book, orders and positions ----
    function book() external view returns (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount);
    function orders(uint256)
        external
        view
        returns (
            address creator,
            uint64 canceledBlock,
            BazaarTypes.OrderType orderType,
            bool isLong,
            bool isPostOnly,
            BazaarTypes.TimeInForce tif,
            address integrator,
            uint64 expiryBlock,
            bool inBook,
            uint24 maxSlippageBp,
            uint128 triggerPrice,
            uint128 limitPrice,
            uint128 size,
            uint128 filledSize,
            uint48 prioritySeq,
            uint64 filledBlock,
            uint32 restedBlock,
            uint16 restedPremiumPpm,
            uint48 prevInBook,
            uint48 nextInBook
        );
    function positionBuckets(address)
        external
        view
        returns (
            bool isLong,
            uint128 size,
            uint128 entryValue,
            uint128 collateral,
            int256 entryFundingIndex,
            uint64 takeProfitOrderId,
            uint64 stopLossOrderId
        );

    // ---- Views: vault and insurance ----
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
    function totalInsuranceShares() external view returns (uint256);
    function insuranceShares(address user) external view returns (uint256);
    function getSharesAsOf(address user, uint64 atTs) external view returns (uint256);
    function insuranceWithdrawalRequestTs(address) external view returns (uint256);
    function insuranceWithdrawalRequestShareAmount(address) external view returns (uint256);

    // ---- Views: ADL ----
    function isAdlPending() external view returns (bool);
    function adlPendingSince() external view returns (uint256);
    function adlAuctionStartTs() external view returns (uint256);
    function adlScoreDeposit(address user) external view returns (uint256);

    // ---- Views: termination ----
    function isPairTerminated() external view returns (bool);
    function scheduledTerminationTs() external view returns (uint256);
    function settlementPriceFixedTs() external view returns (uint256);
    function terminalProfitClaim(address) external view returns (uint256);

    // ---- Views: batched and raw state ----
    function auxState() external view returns (BazaarTypes.AuxState memory s);
    /// @notice One raw storage word of the pair, for state with no getter. Slots are fixed per
    ///         implementation; read them with `forge inspect BazaarPair storage-layout`.
    function extsload(bytes32 slot) external view returns (bytes32 value);
}
