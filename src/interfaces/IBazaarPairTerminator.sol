// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/// @title IBazaarPairTerminator
/// @notice The external interface of BazaarPairTerminator: termination by UMA claim or insurer
///         vote, and the calls that fix a terminated pair's settlement price.
/// @dev Declares every function, event and error in the terminator's ABI.
///      `script/check-interfaces.sh`, which `make abis` and CI run, fails on any difference
///      between this interface and that ABI in a name, a type, an indexed flag or a state mutability.
///      MIT-licensed, unlike the AGPL implementation, so integrators can compile it into their own code.
interface IBazaarPairTerminator {
    // -------------------- Events --------------------

    // Declared in BazaarPairTerminator
    event PairRegistered(address indexed pair);
    event TerminationProposalSubmitted(
        address indexed pair,
        bytes32 indexed assertionId,
        address indexed proposer,
        uint8 category,
        uint256 lastTradingTs,
        string reason
    );
    event TerminationProposalDisputed(bytes32 indexed assertionId);
    event TerminationProposalAccepted(address indexed pair, bytes32 indexed assertionId, uint256 lastTradingTs);
    event TerminationScheduleRefused(address indexed pair, bytes32 indexed assertionId);
    event TerminationProposalSuperseded(address indexed pair, bytes32 indexed assertionId);
    event TerminationProposalRejected(address indexed pair, bytes32 indexed assertionId);
    event StalePairTerminated(address indexed pair, uint256 terminationPrice, uint256 oracleLastUpdateTs);
    event SettlementPriceFixed(address indexed pair, uint256 settlementPrice);
    event InsurerTerminationProposed(
        address indexed pair,
        bytes32 indexed id,
        address indexed proposer,
        uint256 cutoffTs,
        uint256 windowOpenTs,
        bool claimBacked
    );
    event InsurerTerminationSnapshot(
        address indexed pair, bytes32 indexed id, uint256 snapshotTotalShares, uint64 shareEpoch
    );
    event InsurerTerminationVoted(
        address indexed pair, bytes32 indexed id, address indexed voter, uint256 amount, uint256 totalYesShares
    );
    event InsurerTerminationScheduled(
        address indexed pair, bytes32 indexed id, uint256 cutoffTs, uint256 yesShares, uint256 totalShares
    );
    event InsurerTerminationFailed(
        address indexed pair,
        bytes32 indexed id,
        uint256 cutoffTs,
        uint256 yesShares,
        uint256 totalShares,
        bool thresholdMet
    );
    event InsurerTerminationBondRefundFailed(
        address indexed pair, bytes32 indexed id, address proposer, uint256 amount
    );
    event InsurerTerminationPreempted(address indexed pair, bytes32 indexed id);
    event InsurerTerminationVoided(address indexed pair, bytes32 indexed id);
    event InsurerTerminationRejected(address indexed pair, bytes32 indexed id);
    event InsurerTerminationOutcome(
        address indexed pair, bytes32 indexed id, uint8 outcome, bool costed, uint16 levyBp
    );
    event InsurerLevyCharged(
        address indexed pair,
        bytes32 indexed id,
        address indexed voter,
        uint256 votedShares,
        uint256 levyShares,
        address recipient
    );

    // -------------------- Errors --------------------

    // Declared in BazaarPairTerminator
    error BazaarPairTerminator__ZeroAddress();
    error BazaarPairTerminator__OnlyFactory();
    error BazaarPairTerminator__OnlyUmaOracle();
    error BazaarPairTerminator__ScheduleOutOfGas();
    error BazaarPairTerminator__PairNotRegistered();
    error BazaarPairTerminator__AlreadyTerminated();
    error BazaarPairTerminator__SettlementAlreadyFixed();
    error BazaarPairTerminator__CutoffNotEarlier(uint256 lastTradingTs, uint256 umaCutoff);
    error BazaarPairTerminator__LastTradingTsTooSoon(uint256 lastTradingTs, uint256 minimum);
    error BazaarPairTerminator__InvalidReason(uint256 length);
    error BazaarPairTerminator__InvalidCategory(uint8 category);
    error BazaarPairTerminator__UnknownAssertion();
    error BazaarPairTerminator__AlreadyResolved();
    error BazaarPairTerminator__NoScheduledTermination();
    error BazaarPairTerminator__TerminationTimeNotReached(uint256 scheduledTs, uint256 currentTs);
    error BazaarPairTerminator__OracleNotStaleEnough(uint256 lastUpdate, uint256 threshold);
    error BazaarPairTerminator__InsufficientPythFee(uint256 provided, uint256 required);
    error BazaarPairTerminator__EthRefundFailed();
    error BazaarPairTerminator__UmaIdentifierNotLive();
    error BazaarPairTerminator__OracleBusy();
    error BazaarPairTerminator__InsurerScheduleSettlesPair();
    error BazaarPairTerminator__InsurerActiveProposal();
    error BazaarPairTerminator__InsurerCutoffTooSoon(uint64 cutoffTs, uint64 minCutoffTs);
    error BazaarPairTerminator__InsurerCutoffTooLate(uint64 cutoffTs, uint64 maxCutoffTs);
    error BazaarPairTerminator__InsurerCutoffNotEarlier(uint256 scheduledTs);
    error BazaarPairTerminator__InsurerNoMatureShares();
    error BazaarPairTerminator__InsurerNoActiveProposal();
    error BazaarPairTerminator__InsurerVoteNotOpen(uint256 windowOpenTs);
    error BazaarPairTerminator__InsurerVotingClosed();
    error BazaarPairTerminator__InsurerThresholdNotMet(uint256 yesShares, uint256 required);
    error BazaarPairTerminator__InsurerInsufficientUnlockedShares(uint256 unlocked, uint256 requested);
    error BazaarPairTerminator__InsurerZeroVoteAmount();
    error BazaarPairTerminator__InsurerTooManyLiveVotes(uint256 max);
    error BazaarPairTerminator__InsurerVerdictPending(uint256 deadline);
    error BazaarPairTerminator__OnlyPair();

    // OpenZeppelin
    error ReentrancyGuardReentrantCall();
    error SafeERC20FailedOperation(address token);
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    // -------------------- Functions --------------------

    // ---- UMA-claim termination ----
    function proposeTermination(address pair, uint8 category, uint256 lastTradingTs, string calldata reason)
        external
        returns (bytes32 assertionId);
    function settleTerminationProposal(bytes32 assertionId) external;
    function requiredTerminationBond() external view returns (uint256);
    function terminationProposals(bytes32)
        external
        view
        returns (
            address pair,
            address proposer,
            uint256 lastTradingTs,
            string memory reason,
            uint256 proposalTs,
            bool resolved,
            uint8 category
        );
    function acceptedTerminationAssertionId(address) external view returns (bytes32);
    function assertionOo(bytes32) external view returns (address);

    // ---- Insurer-vote termination ----
    function proposeInsurerTermination(address pair, uint64 cutoffTs) external returns (bytes32 id);
    function voteForInsurerTermination(address pair, bytes32 id, uint256 amount) external;
    function executeInsurerTermination(address pair, bytes32 id) external;
    function insurerProposals(bytes32)
        external
        view
        returns (
            address pair,
            address proposer,
            uint64 proposalTs,
            uint64 shareEpoch,
            uint256 cutoffTs,
            uint256 windowOpenTs,
            uint256 yesShares,
            uint256 snapshotTotalShares,
            bool snapshotTaken,
            bool claimBacked,
            bool resolved,
            bool scheduled,
            bool costed,
            uint8 verdict,
            uint8 outcome,
            uint16 levyBp
        );
    function insurerScheduleId(address) external view returns (bytes32);
    function insurerScheduled(address pair) external view returns (bool);
    function umaCutoffCap(address) external view returns (uint256);
    function getLockedShares(address pair, address user) external view returns (uint256 locked);
    function getInsurerVote(address pair, address voter, bytes32 id) external view returns (uint256);

    // ---- Fixing the settlement price ----
    function terminateScheduledPair(address pair, bytes[] calldata priceUpdate) external payable;
    function terminateStalePair(address pair) external;
    function settlementRule(address pair)
        external
        view
        returns (
            uint8 rule,
            uint256 firstTarget,
            uint256 latestPublishTs,
            uint256 lastResortTs,
            uint256 verdictDeadline
        );

    // ---- UMA callbacks ----
    // Accept only the oracle the assertion was made through.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external;

    // ---- Wiring ----
    // `registerPair` accepts only the factory, `consumeInsurerLevy` only a registered pair.
    function factory() external view returns (address);
    function isPair(address addr) external view returns (bool);
    function registerPair(address pair) external;
    function consumeInsurerLevy(address user, uint256 shareAmount)
        external
        returns (uint256 levyShares, address recipient);

    // ---- Constants ----
    function TERMINATION_PROPOSAL_BOND() external view returns (uint256);
    function TERMINATION_PROPOSAL_LIVENESS() external view returns (uint256);
    function MAX_REASON_LENGTH() external view returns (uint256);
    function CATEGORY_ORACLE_DECOMMISSION() external view returns (uint8);
    function CATEGORY_ASSET_CESSATION() external view returns (uint8);
    function CATEGORY_STRUCTURAL_CHANGE() external view returns (uint8);
    function CATEGORY_PYTH_VERIFIER_MIGRATION() external view returns (uint8);
    function SETTLEMENT_SAMPLE_COUNT() external view returns (uint256);
    function SETTLEMENT_SAMPLE_SPACING() external view returns (uint256);
    function SETTLE_NOTHING() external view returns (uint8);
    function SETTLE_TICK() external view returns (uint8);
    function SETTLE_CHAIN() external view returns (uint8);
    function SETTLE_AWAIT_VERDICT() external view returns (uint8);
    function VERDICT_PENDING() external view returns (uint8);
    function VERDICT_TRUE() external view returns (uint8);
    function VERDICT_FALSE() external view returns (uint8);
    function OUTCOME_NONE() external view returns (uint8);
    function OUTCOME_TRUE() external view returns (uint8);
    function OUTCOME_FALSE() external view returns (uint8);
    function OUTCOME_UNJUDGED() external view returns (uint8);
}
