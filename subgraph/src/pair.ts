// Handlers for every BazaarPair, which the factory handler starts indexing at its PairDeployed.
// Most of these events are emitted by the libraries the pair runs by DELEGATECALL, so they come
// from the pair's address and are declared in the ABI that script/export-abis.sh writes.
export { handleOrderAmended, handleOrderAmendSkipped, handleOrderUpdated, handleTriggerBountyEscrowed, handleTriggerBountyReleased } from "./pair/orders"
export { handleTrade } from "./pair/trades"
export { handleCollateralDeposited, handleCollateralWithdrawn, handlePositionBucketUpdated, handlePositionModified } from "./pair/positions"
export { handleAdlExecuted, handleAdlResolved, handleAdlTerminationArmed, handleAdlTriggered, handlePositionLiquidated, handleUserAdld } from "./pair/risk"
export { handleInsuranceCredited, handleInsuranceDeposited, handleInsuranceShareEpochBumped, handleInsuranceWithdrawalExecuted, handleInsuranceWithdrawalLocked, handleInsuranceWithdrawalRequested } from "./pair/insurance"
export { handleFeeAccrued, handleFeesClaimed, handleInsolvencySettlementFixed, handleMetaTransactionExecuted, handleNewPriceUpdateAdded, handlePairTerminated, handlePermitExecutionFailed, handleTerminalRatiosRefrozen } from "./pair/lifecycle"
