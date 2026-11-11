// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/// @title IBazaarOracle
/// @notice The external interface of BazaarOracle, the Pyth Pro adapter every pair prices through:
///         the live price read out of caller-supplied updates, the settlement samplers, and
///         composite feeds that price an asset in USD from its native-currency feed and an FX feed.
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
    error BazaarOracle__InvalidFeedId(bytes32 feedId);
    error BazaarOracle__InvalidPrice(bytes32 feedId, int64 price, int32 expo);
    error BazaarOracle__ConfidenceTooHigh(uint256 confidence, uint256 price);
    error BazaarOracle__InvalidCompositeLegs(bytes32 baseId, bytes32 quoteId);
    error BazaarOracle__FeeMismatch(uint256 supplied, uint256 required);
    error BazaarOracle__FeedNotInUpdate(bytes32 feedId);
    error BazaarOracle__IncompleteFeed(bytes32 feedId);
    error BazaarOracle__StalePrice(bytes32 feedId, uint256 generatedTs);
    error BazaarOracle__StaleUpdate(uint64 timestampUs);
    error BazaarOracle__WrongTick(uint64 timestampUs, uint8 channel);
    error BazaarOracle__SampleCountMismatch(uint256 updates, uint256 expected);
    error BazaarOracle__SampleNotProven(bytes32 feedId, uint64 target, uint64 tick);
    error BazaarOracle__SampleTooLate(bytes32 feedId, uint64 tick, uint64 maxPublishTime);

    // Declared in LazerPayloadLib
    error LazerPayloadLib__Malformed();

    // -------------------- Functions --------------------

    // ---- Fees ----
    function getUpdateFee(uint256 updates) external view returns (uint256);

    // ---- Prices ----
    // Every `priceUpdate` is a list of signed Pyth Pro updates, and msg.value must equal
    // getUpdateFee of their count.
    function verifyAndFetchPrice(bytes32 baseFeedId, bytes[] calldata priceUpdate, uint256 maxStaleness)
        external
        payable
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime);
    function verifyAndFetchLatestPrice(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint256 maxIssueAge,
        uint256 maxPriceAge
    ) external payable returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime);
    function fetchPriceAtTick(bytes32 baseFeedId, bytes[] calldata priceUpdate, uint64 tick)
        external
        payable
        returns (uint256 spotPrice);
    function fetchChainedMedian(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 firstTarget,
        uint64 maxPublishTime,
        uint64 spacing,
        uint256 count
    ) external payable returns (uint256 medianPrice);

    // ---- Feed IDs and composite feeds ----
    // `registerComposite` is permissionless and idempotent.
    function isRawFeedId(bytes32 feedId) external pure returns (bool);
    function registerComposite(bytes32 baseId, bytes32 quoteId, bool invertQuote) external returns (bytes32 compositeId);
    function getCompositeId(bytes32 baseId, bytes32 quoteId, bool invertQuote) external pure returns (bytes32);
    function composites(bytes32) external view returns (bytes32 baseId, bytes32 quoteId, bool invertQuote);

    // ---- Wiring and constants ----
    function pythLazer() external view returns (address);
    function BAZAAR_EXPONENT() external view returns (int32);
    function BAZAAR_SCALE() external view returns (uint256);
    function BP_SCALE() external view returns (uint256);
    function MAX_CONFIDENCE_BP() external view returns (uint256);
}
