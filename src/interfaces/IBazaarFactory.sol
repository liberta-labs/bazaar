// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/// @title IBazaarFactory
/// @notice The external interface of BazaarFactory: UMA-approved pair listings, the registry of
///         deployed pairs, and the governed UMA identifier.
/// @dev Declares every function, event and error in the factory's ABI.
///      `script/check-interfaces.sh`, which `make abis` and CI run, fails on any difference
///      between this interface and that ABI in a name, a type, an indexed flag or a state mutability.
///      MIT-licensed, unlike the AGPL implementation, so integrators can compile it into their own code.
interface IBazaarFactory {
    // -------------------- Types --------------------

    /// @notice A listing proposal, keyed by its UMA assertion id.
    struct PairDeploymentProposal {
        address deployer;
        bytes32 baseFeedId;
        bool isContinuouslyTraded;
        uint256 seedAmount; // BAZAAR_SCALE (1e18): the insurance seed, the deposit less the UMA bond
        uint256 seedAmountUsdc; // the seed in USDC decimals (1e6)
        string description;
        bytes32 pairId;
        uint256 proposalTs;
        bool resolved;
        bool deployed;
    }

    /// @notice An identifier-upgrade proposal, keyed by its UMA assertion id. `disputed` is set
    ///         when UMA reports a dispute of the assertion.
    struct UmaIdentifierUpgradeProposal {
        address proposer;
        bytes32 newIdentifier;
        uint256 proposalTs;
        bool resolved;
        bool settlementResolution;
        bool disputed;
    }

    // -------------------- Events --------------------

    // Declared in BazaarFactory
    event PairDeployed(
        bytes32 indexed pairId,
        address indexed pairAddress,
        address indexed deployer,
        bytes32 baseFeedId,
        bool isContinuouslyTraded,
        uint256 seedAmount,
        string description
    );
    event PairDeploymentProposed(
        bytes32 indexed pairId,
        bytes32 indexed assertionId,
        address indexed deployer,
        bytes32 baseFeedId,
        string description,
        uint256 seedAmount
    );
    event PairDeploymentProposalDisputed(bytes32 indexed assertionId);
    event PairDeploymentProposalResolved(bytes32 indexed assertionId, bool assertedTruthfully, bool deployed);
    event PairDeploymentProposalExpired(bytes32 indexed assertionId, address indexed deployer);
    event PairDeploymentProposalVoided(bytes32 indexed assertionId, address indexed deployer);
    event SeedRefundCredited(bytes32 indexed assertionId, address indexed deployer, uint256 amountUsdc);
    event SeedRefundClaimed(address indexed deployer, uint256 amountUsdc);
    event UmaIdentifierUpgradeProposed(bytes32 indexed assertionId, address indexed proposer, bytes32 newIdentifier);
    event UmaIdentifierUpgradeDisputed(bytes32 indexed assertionId);
    event UmaIdentifierUpgradeQueued(bytes32 indexed assertionId, bytes32 newIdentifier, uint256 effectiveTs);
    event UmaIdentifierUpgraded(bytes32 indexed assertionId, bytes32 oldIdentifier, bytes32 newIdentifier);
    event UmaIdentifierUpgradeCanceled(bytes32 indexed assertionId, bytes32 newIdentifier);
    event UmaIdentifierUpgradeExpired(bytes32 indexed assertionId, address indexed proposer);

    // -------------------- Errors --------------------

    // Declared in BazaarFactory
    error Factory__ZeroAddress();
    error Factory__WiringMismatch();
    error Factory__PairAlreadyExists(bytes32 pairId);
    error Factory__ProposalAlreadyPending(bytes32 pairId);
    error Factory__OnlyUmaOracle();
    error Factory__ProposalNotFound(bytes32 assertionId);
    error Factory__ProposalAlreadyResolved(bytes32 assertionId);
    error Factory__SeedBelowMinimum();
    error Factory__DescriptionInvalid();
    error Factory__CompositePairMustBeNonContinuous();
    error Factory__FeedNotOnPyth(bytes32 feedId);
    error Factory__IdentifierUpgradeStillPending();
    error Factory__IdentifierUpgradeNoChange();
    error Factory__InvalidIdentifier();
    error Factory__IdentifierNotWhitelisted(bytes32 identifier);
    error Factory__IdentifierNotAssertTruth(bytes32 identifier);
    error Factory__NoQueuedIdentifierUpgrade();
    error Factory__IdentifierUpgradeTimelocked(uint256 opensAt);
    error Factory__NoPendingIdentifierUpgrade();
    error Factory__IdentifierUpgradeNotExpired(uint256 expiryTs);
    error Factory__NoPendingDeployment(bytes32 pairId);
    error Factory__DeploymentNotExpired(uint256 expiryTs);
    error Factory__NoSeedRefund();
    error Factory__BaseFeedAlreadyListed(bytes32 rawBaseFeed, address pair);

    // OpenZeppelin
    error FailedDeployment();
    error InsufficientBalance(uint256 balance, uint256 needed);
    error ReentrancyGuardReentrantCall();
    error SafeERC20FailedOperation(address token);
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    // -------------------- Functions --------------------

    // ---- Listing ----
    function proposePairDeployment(
        bytes32 baseFeedId,
        bool isContinuouslyTraded,
        uint256 totalAmount,
        string calldata description
    ) external returns (bytes32 assertionId);
    function settleDeploymentProposal(bytes32 assertionId) external;
    function expireStuckDeploymentProposal(bytes32 pairId) external;
    function claimSeedRefund() external;
    function requiredDeploymentBond() external view returns (uint256);

    // ---- UMA identifier governance ----
    function proposeUmaIdentifierUpgrade(bytes32 newIdentifier) external returns (bytes32 assertionId);
    function settleIdentifierUpgradeProposal(bytes32 assertionId) external;
    function expireStuckIdentifierUpgradeProposal() external;
    function activateIdentifierUpgrade() external;
    function requiredIdentifierUpgradeBond() external view returns (uint256);
    function umaIdentifierIsLive() external view returns (bool);

    // ---- UMA callbacks ----
    // Accept only the oracle the assertion was made through.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external;

    // ---- Pair registry ----
    function getAllPairs() external view returns (address[] memory);
    function pairsCount() external view returns (uint256);
    function isPair(address addr) external view returns (bool);
    function getPairAddress(bytes32 pairId) external view returns (address);
    function pairAddressById(bytes32) external view returns (address);
    function pairAddressByBaseFeed(bytes32) external view returns (address);

    // ---- Proposal state ----
    function getDeploymentProposal(bytes32 assertionId) external view returns (PairDeploymentProposal memory);
    function deploymentProposals(bytes32)
        external
        view
        returns (
            address deployer,
            bytes32 baseFeedId,
            bool isContinuouslyTraded,
            uint256 seedAmount,
            uint256 seedAmountUsdc,
            string memory description,
            bytes32 pairId,
            uint256 proposalTs,
            bool resolved,
            bool deployed
        );
    function getPendingDeploymentsAssertionId(bytes32 pairId) external view returns (bytes32);
    function pendingDeploymentByPairId(bytes32) external view returns (bytes32);
    function pendingDeploymentByBaseFeed(bytes32) external view returns (bytes32);
    function deploymentDisputed(bytes32) external view returns (bool);
    function seedRefundOwed(address) external view returns (uint256);
    function getIdentifierUpgradeProposal(bytes32 assertionId)
        external
        view
        returns (UmaIdentifierUpgradeProposal memory);
    function identifierUpgradeProposals(bytes32)
        external
        view
        returns (
            address proposer,
            bytes32 newIdentifier,
            uint256 proposalTs,
            bool resolved,
            bool settlementResolution,
            bool disputed
        );
    function pendingIdentifierUpgradeAssertionId() external view returns (bytes32);
    function queuedIdentifierUpgrade()
        external
        view
        returns (bytes32 assertionId, bytes32 newIdentifier, uint256 effectiveTs);
    function assertionOo(bytes32) external view returns (address);

    // ---- Wiring ----
    function usdc() external view returns (address);
    function oracle() external view returns (address);
    function pairImplementation() external view returns (address);
    function lens() external view returns (address);
    function pairTerminator() external view returns (address);
    function bugBountyAddress() external view returns (address);
    function oo() external view returns (address);
    function umaIdentifier() external view returns (bytes32);

    // ---- Constants ----
    function MIN_DEPLOYMENT_AMOUNT() external view returns (uint256);
    function DEPLOYMENT_BOND_USDC() external view returns (uint256);
    function DEPLOYMENT_LIVENESS() external view returns (uint64);
    function IDENTIFIER_UPGRADE_BOND_USDC() external view returns (uint256);
    function IDENTIFIER_UPGRADE_LIVENESS() external view returns (uint64);
    function IDENTIFIER_UPGRADE_TIMELOCK() external view returns (uint256);
    function IDENTIFIER_UPGRADE_MIN_NOTICE() external view returns (uint256);
    function DVM_DISPUTE_GRACE() external view returns (uint256);
}
