// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/// @title IBazaarOracle
/// @notice The external interface of BazaarOracle, the Pyth adapter every pair prices through:
///         fresh and stale reads, update-and-fetch, the settlement samplers, and composite feeds
///         that price an asset in USD from its native-currency feed and an FX feed.
/// @dev Declares every function, event and error in the oracle's ABI.
///      `script/check-interfaces.sh`, which `make abis` and CI run, fails on any difference
///      between this interface and that ABI in a name, a type, an indexed flag or a state mutability.
///      MIT-licensed, unlike the AGPL implementation, so integrators can compile it into their own code.
interface IBazaarOracle {
    // -------------------- Events --------------------

    // Declared in BazaarOracle
    event CompositeFeedRegistered(
        bytes32 indexed compositeId, bytes32 indexed baseId, bytes32 indexed quoteId, bool invertQuote
    );

    // -------------------- Errors --------------------

    // Declared in BazaarOracle
    error BazaarOracle__ZeroAddress();
    error BazaarOracle__InvalidPrice(bytes32 feedId, int64 price, int32 expo);
    error BazaarOracle__ConfidenceTooHigh(uint256 confidence, uint256 price);
    error BazaarOracle__InvalidCompositeLegs(bytes32 baseId, bytes32 quoteId);
    error BazaarOracle__SampleCountMismatch(uint256 updates, uint256 expected);
    error BazaarOracle__SampleFeeMismatch(uint256 supplied, uint256 required);

    // -------------------- Functions --------------------

    // ---- Price reads ----
    function tryReadFreshPrice(bytes32 baseFeedId, uint256 maxStaleness)
        external
        view
        returns (bool found, uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime);
    function tryReadStalePrice(bytes32 baseFeedId)
        external
        view
        returns (bool found, uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime);
    function getUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);
    function getSampleSetFee(bytes32 baseFeedId, bytes[] calldata priceUpdate) external view returns (uint256 fee);

    // ---- Price updates ----
    // msg.value pays Pyth's update fee.
    function updateAndFetchPrice(bytes32 baseFeedId, bytes[] calldata priceUpdate, uint256 maxStaleness)
        external
        payable
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime);
    function fetchFirstPriceAtOrAfter(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (uint256 spotPrice);
    function fetchChainedMedian(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 firstTarget,
        uint64 maxPublishTime,
        uint64 spacing,
        uint256 count
    ) external payable returns (uint256 medianPrice);

    // ---- Composite feeds ----
    // `registerComposite` is permissionless and idempotent.
    function registerComposite(bytes32 baseId, bytes32 quoteId, bool invertQuote) external returns (bytes32 compositeId);
    function getCompositeId(bytes32 baseId, bytes32 quoteId, bool invertQuote) external pure returns (bytes32);
    function composites(bytes32) external view returns (bytes32 baseId, bytes32 quoteId, bool invertQuote);

    // ---- Wiring and constants ----
    function pyth() external view returns (address);
    function BAZAAR_EXPONENT() external view returns (int32);
    function BAZAAR_SCALE() external view returns (uint256);
    function BP_SCALE() external view returns (uint256);
    function MAX_CONFIDENCE_BP() external view returns (uint256);
}
