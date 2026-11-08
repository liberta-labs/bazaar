import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts"
import { createMockedFunction, newMockEvent } from "matchstick-as/assembly/index"
import {
  PairDeployed,
  PairDeploymentProposalVoided,
  PairDeploymentProposed,
  UmaIdentifierUpgradeDisputed,
  UmaIdentifierUpgradeProposed,
} from "../generated/BazaarFactory/BazaarFactory"
import {
  InsurerLevyCharged,
  SettlementPriceFixed,
  StalePairTerminated,
  TerminationProposalAccepted,
  TerminationProposalSubmitted,
} from "../generated/BazaarPairTerminator/BazaarPairTerminator"
import {
  AdlExecuted,
  AdlResolved,
  AdlTriggered,
  FeeAccrued,
  FeesClaimed,
  InsuranceDeposited,
  InsuranceShareEpochBumped,
  InsuranceWithdrawalExecuted,
  InsuranceWithdrawalLocked,
  InsuranceWithdrawalRequested,
  NewPriceUpdateAdded,
  OrderAmended,
  OrderUpdated,
  PairTerminated,
  PositionBucketUpdated,
  PositionLiquidated,
  PositionModified,
  Trade,
  TriggerBountyEscrowed,
  TriggerBountyReleased,
  UserAdld,
} from "../generated/templates/BazaarPair/BazaarPair"
import { handlePairDeployed } from "../src/factory"

export const FACTORY = Address.fromString("0x00000000000000000000000000000000000000f1")
export const TERMINATOR = Address.fromString("0x00000000000000000000000000000000000000f2")
export const PAIR = Address.fromString("0x00000000000000000000000000000000000000a1")
export const PAIR_ID = Bytes.fromHexString("0x1111111111111111111111111111111111111111111111111111111111111111")
export const FEED_ID = Bytes.fromHexString("0x2222222222222222222222222222222222222222222222222222222222222222")
export const IDENTIFIER = Bytes.fromHexString("0x4153534552545f54525554483200000000000000000000000000000000000000")
export const DEPLOYER = Address.fromString("0x00000000000000000000000000000000000000d1")
export const ALICE = Address.fromString("0x0000000000000000000000000000000000000a11")
export const BOB = Address.fromString("0x0000000000000000000000000000000000000b0b")
export const CAROL = Address.fromString("0x00000000000000000000000000000000000ca401")
export const KEEPER = Address.fromString("0x0000000000000000000000000000000000000cee")
export const INTEGRATOR = Address.fromString("0x00000000000000000000000000000000000001e7")
export const ZERO_ADDRESS = Address.zero()

export const E18 = BigInt.fromString("1000000000000000000")
export const SEED = BigInt.fromI32(3000).times(E18)

export function e18(units: i32): BigInt {
  return BigInt.fromI32(units).times(E18)
}

export function uint(value: i32): ethereum.Value {
  return ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(value))
}

export function big(value: BigInt): ethereum.Value {
  return ethereum.Value.fromUnsignedBigInt(value)
}

// Mock events share one transaction hash, so every event gets its own log index to keep the IDs
// of immutable records apart. Tests move time forward with setBlock.
let nextLogIndex = 0
let blockNumber = BigInt.fromI32(1000)
let blockTimestamp = BigInt.fromI32(1800000000)

export function setBlock(number: i32, timestamp: i32): void {
  blockNumber = BigInt.fromI32(number)
  blockTimestamp = BigInt.fromI32(timestamp)
}

export function mockEvent(address: Address): ethereum.Event {
  let event = newMockEvent()
  event.address = address
  event.logIndex = BigInt.fromI32(nextLogIndex)
  nextLogIndex = nextLogIndex + 1
  event.block.number = blockNumber
  event.block.timestamp = blockTimestamp
  event.parameters = new Array<ethereum.EventParam>()
  return event
}

function param(name: string, value: ethereum.Value): ethereum.EventParam {
  return new ethereum.EventParam(name, value)
}

// ---------------------------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------------------------

export function mockFactoryReads(): void {
  createMockedFunction(FACTORY, "umaIdentifier", "umaIdentifier():(bytes32)").returns([
    ethereum.Value.fromFixedBytes(IDENTIFIER),
  ])
}

export function pairDeployed(seed: BigInt): PairDeployed {
  let event = changetype<PairDeployed>(mockEvent(FACTORY))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("pairAddress", ethereum.Value.fromAddress(PAIR)))
  event.parameters.push(param("deployer", ethereum.Value.fromAddress(DEPLOYER)))
  event.parameters.push(param("baseFeedId", ethereum.Value.fromFixedBytes(FEED_ID)))
  event.parameters.push(param("isContinuouslyTraded", ethereum.Value.fromBoolean(true)))
  event.parameters.push(param("seedAmount", big(seed)))
  event.parameters.push(param("description", ethereum.Value.fromString("Bitcoin / US Dollar")))
  return event
}

// Deploys the test pair with the standard seed.
export function deployPair(): void {
  mockFactoryReads()
  handlePairDeployed(pairDeployed(SEED))
}

export function pairDeploymentProposed(assertionId: Bytes): PairDeploymentProposed {
  let event = changetype<PairDeploymentProposed>(mockEvent(FACTORY))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("assertionId", ethereum.Value.fromFixedBytes(assertionId)))
  event.parameters.push(param("deployer", ethereum.Value.fromAddress(DEPLOYER)))
  event.parameters.push(param("baseFeedId", ethereum.Value.fromFixedBytes(FEED_ID)))
  event.parameters.push(param("description", ethereum.Value.fromString("Bitcoin / US Dollar")))
  event.parameters.push(param("seedAmount", big(SEED)))
  return event
}

export function pairDeploymentProposalVoided(assertionId: Bytes): PairDeploymentProposalVoided {
  let event = changetype<PairDeploymentProposalVoided>(mockEvent(FACTORY))
  event.parameters.push(param("assertionId", ethereum.Value.fromFixedBytes(assertionId)))
  event.parameters.push(param("deployer", ethereum.Value.fromAddress(DEPLOYER)))
  return event
}

export function identifierUpgradeProposed(assertionId: Bytes, proposer: Address): UmaIdentifierUpgradeProposed {
  let event = changetype<UmaIdentifierUpgradeProposed>(mockEvent(FACTORY))
  event.parameters.push(param("assertionId", ethereum.Value.fromFixedBytes(assertionId)))
  event.parameters.push(param("proposer", ethereum.Value.fromAddress(proposer)))
  event.parameters.push(param("newIdentifier", ethereum.Value.fromFixedBytes(IDENTIFIER)))
  return event
}

export function identifierUpgradeDisputed(assertionId: Bytes): UmaIdentifierUpgradeDisputed {
  let event = changetype<UmaIdentifierUpgradeDisputed>(mockEvent(FACTORY))
  event.parameters.push(param("assertionId", ethereum.Value.fromFixedBytes(assertionId)))
  return event
}

// ---------------------------------------------------------------------------------------------
// Orders and trades
// ---------------------------------------------------------------------------------------------

export class OrderArgs {
  action: i32 = 0
  orderType: i32 = 1
  isLong: boolean = true
  isPostOnly: boolean = false
  size: BigInt = e18(1)
  filledSize: BigInt = BigInt.zero()
  triggerPrice: BigInt = BigInt.zero()
  limitPrice: BigInt = e18(100)
  canceledBlock: BigInt = BigInt.zero()
  expiryBlock: BigInt = BigInt.fromI32(500000)
  prioritySeq: BigInt = BigInt.zero()
  tif: i32 = 0
  integrator: Address = Address.zero()
  cancelReason: i32 = 0
}

export function orderUpdated(orderId: i32, owner: Address, args: OrderArgs): OrderUpdated {
  let event = changetype<OrderUpdated>(mockEvent(PAIR))
  let payload = new ethereum.Tuple()
  payload.push(uint(args.action))
  payload.push(uint(args.orderType))
  payload.push(ethereum.Value.fromBoolean(args.isLong))
  payload.push(ethereum.Value.fromBoolean(args.isPostOnly))
  payload.push(big(args.size))
  payload.push(big(args.filledSize))
  payload.push(big(args.triggerPrice))
  payload.push(big(args.limitPrice))
  payload.push(uint(0))
  payload.push(big(args.canceledBlock))
  payload.push(uint(0))
  payload.push(big(args.expiryBlock))
  payload.push(big(args.prioritySeq.isZero() ? BigInt.fromI32(orderId) : args.prioritySeq))
  payload.push(uint(args.tif))
  payload.push(ethereum.Value.fromAddress(args.integrator))
  payload.push(uint(args.cancelReason))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("orderId", uint(orderId)))
  event.parameters.push(param("owner", ethereum.Value.fromAddress(owner)))
  event.parameters.push(param("payload", ethereum.Value.fromTuple(payload)))
  return event
}

export function orderAmended(orderId: i32, owner: Address, limitPrice: BigInt, size: BigInt, prioritySeq: i32): OrderAmended {
  let event = changetype<OrderAmended>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("orderId", uint(orderId)))
  event.parameters.push(param("owner", ethereum.Value.fromAddress(owner)))
  event.parameters.push(param("limitPrice", big(limitPrice)))
  event.parameters.push(param("size", big(size)))
  event.parameters.push(param("prioritySeq", uint(prioritySeq)))
  return event
}

export function trade(
  maker: Address,
  taker: Address,
  makerOrderId: i32,
  takerOrderId: i32,
  takerIsLong: boolean,
  fillSize: BigInt,
  price: BigInt,
  makerRemaining: BigInt,
  takerRemaining: BigInt,
): Trade {
  let event = changetype<Trade>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("maker", ethereum.Value.fromAddress(maker)))
  event.parameters.push(param("taker", ethereum.Value.fromAddress(taker)))
  event.parameters.push(param("makerOrderId", uint(makerOrderId)))
  event.parameters.push(param("takerOrderId", uint(takerOrderId)))
  event.parameters.push(param("takerIsLong", ethereum.Value.fromBoolean(takerIsLong)))
  event.parameters.push(param("fillSize", big(fillSize)))
  event.parameters.push(param("price", big(price)))
  event.parameters.push(param("makerFee", big(E18.div(BigInt.fromI32(100)))))
  event.parameters.push(param("takerFee", big(E18.div(BigInt.fromI32(50)))))
  event.parameters.push(param("makerRemaining", big(makerRemaining)))
  event.parameters.push(param("takerRemaining", big(takerRemaining)))
  return event
}

export function bountyEscrowed(orderId: i32, amount: BigInt): TriggerBountyEscrowed {
  let event = changetype<TriggerBountyEscrowed>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("orderId", uint(orderId)))
  event.parameters.push(param("amount", big(amount)))
  return event
}

export function bountyReleased(orderId: i32, recipient: Address, amount: BigInt): TriggerBountyReleased {
  let event = changetype<TriggerBountyReleased>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("orderId", uint(orderId)))
  event.parameters.push(param("recipient", ethereum.Value.fromAddress(recipient)))
  event.parameters.push(param("amount", big(amount)))
  return event
}

// The pair's stored order, as a StopLimit's Triggered handler reads it back.
export function mockStoredOrder(orderId: i32, owner: Address, inBook: boolean): void {
  createMockedFunction(
    PAIR,
    "orders",
    "orders(uint256):(address,uint64,uint8,bool,bool,uint8,address,uint64,bool,uint24,uint128,uint128,uint128,uint128,uint48,uint64,uint32,uint16,uint48,uint48)",
  )
    .withArgs([uint(orderId)])
    .returns([
      ethereum.Value.fromAddress(owner),
      uint(0),
      uint(2),
      ethereum.Value.fromBoolean(true),
      ethereum.Value.fromBoolean(false),
      uint(0),
      ethereum.Value.fromAddress(Address.zero()),
      uint(500000),
      ethereum.Value.fromBoolean(inBook),
      uint(0),
      big(e18(95)),
      big(e18(100)),
      big(e18(2)),
      big(BigInt.zero()),
      uint(orderId),
      uint(0),
      uint(0),
      uint(0),
      uint(0),
      uint(0),
    ])
}

// ---------------------------------------------------------------------------------------------
// Positions and prices
// ---------------------------------------------------------------------------------------------

export function bucketUpdated(
  owner: Address,
  isLong: boolean,
  size: BigInt,
  entryValue: BigInt,
  collateral: BigInt,
  imrBp: i32,
): PositionBucketUpdated {
  let event = changetype<PositionBucketUpdated>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("owner", ethereum.Value.fromAddress(owner)))
  event.parameters.push(param("isLong", ethereum.Value.fromBoolean(isLong)))
  event.parameters.push(param("size", big(size)))
  event.parameters.push(param("entryValue", big(entryValue)))
  event.parameters.push(param("collateral", big(collateral)))
  event.parameters.push(param("entryFundingIndex", ethereum.Value.fromSignedBigInt(BigInt.zero())))
  event.parameters.push(param("globalFundingIndex", ethereum.Value.fromSignedBigInt(BigInt.zero())))
  event.parameters.push(param("imrBp", uint(imrBp)))
  event.parameters.push(param("mmrBp", uint(imrBp / 2)))
  return event
}

export function positionModified(user: Address, sizeDelta: BigInt, fee: BigInt, realizedPnl: BigInt): PositionModified {
  let event = changetype<PositionModified>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("user", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("isLong", ethereum.Value.fromBoolean(true)))
  event.parameters.push(param("sizeDelta", ethereum.Value.fromSignedBigInt(sizeDelta)))
  event.parameters.push(param("newSize", big(BigInt.zero())))
  event.parameters.push(param("newEntryValue", big(BigInt.zero())))
  event.parameters.push(param("newCollateral", big(e18(50))))
  event.parameters.push(param("executionPrice", big(e18(100))))
  event.parameters.push(param("fee", big(fee)))
  event.parameters.push(param("realizedPnl", ethereum.Value.fromSignedBigInt(realizedPnl)))
  return event
}

export function priceUpdate(publishTs: i32, price: BigInt, fundingIndex: BigInt): NewPriceUpdateAdded {
  let event = changetype<NewPriceUpdateAdded>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("targetPublishTs", uint(publishTs)))
  event.parameters.push(param("spotPrice", big(price)))
  event.parameters.push(param("exponent", ethereum.Value.fromI32(-18)))
  event.parameters.push(param("fundingIndex", ethereum.Value.fromSignedBigInt(fundingIndex)))
  return event
}

export function positionLiquidated(user: Address, size: BigInt, price: BigInt, seized: BigInt): PositionLiquidated {
  let event = changetype<PositionLiquidated>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("liquidatedUser", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("liquidator", ethereum.Value.fromAddress(KEEPER)))
  event.parameters.push(param("size", big(size)))
  event.parameters.push(param("isLong", ethereum.Value.fromBoolean(true)))
  event.parameters.push(param("bankruptcyPrice", big(e18(90))))
  event.parameters.push(param("triggerPrice", big(price)))
  event.parameters.push(param("collateralSeized", big(seized)))
  event.parameters.push(param("timestamp", big(blockTimestamp)))
  return event
}

// ---------------------------------------------------------------------------------------------
// Fees
// ---------------------------------------------------------------------------------------------

export function feeAccrued(recipient: Address, amount: BigInt): FeeAccrued {
  let event = changetype<FeeAccrued>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("recipient", ethereum.Value.fromAddress(recipient)))
  event.parameters.push(param("amount", big(amount)))
  return event
}

export function feesClaimed(recipient: Address, amount: BigInt): FeesClaimed {
  let event = changetype<FeesClaimed>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("recipient", ethereum.Value.fromAddress(recipient)))
  event.parameters.push(param("amount", big(amount)))
  return event
}

// ---------------------------------------------------------------------------------------------
// Insurance
// ---------------------------------------------------------------------------------------------

export function mockTotalShares(total: BigInt): void {
  createMockedFunction(PAIR, "totalInsuranceShares", "totalInsuranceShares():(uint256)").returns([big(total)])
}

export function insuranceDeposited(user: Address, amount: BigInt, shares: BigInt): InsuranceDeposited {
  let event = changetype<InsuranceDeposited>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("user", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("amount", big(amount)))
  event.parameters.push(param("sharesReceived", big(shares)))
  return event
}

export function withdrawalRequested(user: Address, shares: BigInt): InsuranceWithdrawalRequested {
  let event = changetype<InsuranceWithdrawalRequested>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("user", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("shareAmount", big(shares)))
  return event
}

export function withdrawalLocked(user: Address, shares: BigInt, locked: BigInt, opensTs: i32): InsuranceWithdrawalLocked {
  let event = changetype<InsuranceWithdrawalLocked>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("user", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("shareAmount", big(shares)))
  event.parameters.push(param("lockedAmount", big(locked)))
  event.parameters.push(param("claimOpensTs", uint(opensTs)))
  return event
}

export function withdrawalExecuted(user: Address, shares: BigInt, usdc: BigInt): InsuranceWithdrawalExecuted {
  let event = changetype<InsuranceWithdrawalExecuted>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("user", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("shareAmount", big(shares)))
  event.parameters.push(param("usdcAmount", big(usdc)))
  return event
}

export function epochBumped(newEpoch: i32): InsuranceShareEpochBumped {
  let event = changetype<InsuranceShareEpochBumped>(mockEvent(PAIR))
  event.parameters.push(param("newEpoch", uint(newEpoch)))
  return event
}

export function levyCharged(proposalId: Bytes, voter: Address, voted: BigInt, levy: BigInt, recipient: Address): InsurerLevyCharged {
  let event = changetype<InsurerLevyCharged>(mockEvent(TERMINATOR))
  event.parameters.push(param("pair", ethereum.Value.fromAddress(PAIR)))
  event.parameters.push(param("id", ethereum.Value.fromFixedBytes(proposalId)))
  event.parameters.push(param("voter", ethereum.Value.fromAddress(voter)))
  event.parameters.push(param("votedShares", big(voted)))
  event.parameters.push(param("levyShares", big(levy)))
  event.parameters.push(param("recipient", ethereum.Value.fromAddress(recipient)))
  return event
}

// ---------------------------------------------------------------------------------------------
// ADL and termination
// ---------------------------------------------------------------------------------------------

export function adlTriggered(epoch: i32, price: BigInt): AdlTriggered {
  let event = changetype<AdlTriggered>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("adlEpoch", uint(epoch)))
  event.parameters.push(param("price", big(price)))
  event.parameters.push(param("fundingIndex", ethereum.Value.fromSignedBigInt(BigInt.zero())))
  return event
}

// A leg that closed nothing reports a settlement price of 0, as the contract does for a leg that
// did not run; a leg that ran settles at `price`.
export function adlExecuted(
  adlId: i32,
  longBucketClosed: BigInt,
  shortBucketClosed: BigInt,
  netted: BigInt,
  price: BigInt
): AdlExecuted {
  let event = changetype<AdlExecuted>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("adlId", uint(adlId)))
  event.parameters.push(param("submitter", ethereum.Value.fromAddress(KEEPER)))
  event.parameters.push(param("longBucketClosed", big(longBucketClosed)))
  event.parameters.push(param("longBucketSettlementPrice", big(longBucketClosed.isZero() ? BigInt.zero() : price)))
  event.parameters.push(param("shortBucketClosed", big(shortBucketClosed)))
  event.parameters.push(param("shortBucketSettlementPrice", big(shortBucketClosed.isZero() ? BigInt.zero() : price)))
  event.parameters.push(param("netted", big(netted)))
  event.parameters.push(param("timestamp", big(blockTimestamp)))
  return event
}

export function userAdld(user: Address, closedSize: BigInt, credit: BigInt): UserAdld {
  let event = changetype<UserAdld>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("user", ethereum.Value.fromAddress(user)))
  event.parameters.push(param("isLong", ethereum.Value.fromBoolean(true)))
  event.parameters.push(param("closedSize", big(closedSize)))
  event.parameters.push(param("realizedPnl", ethereum.Value.fromSignedBigInt(credit)))
  event.parameters.push(param("remainingCollateral", big(e18(10))))
  event.parameters.push(param("adlScore", big(e18(2))))
  event.parameters.push(param("adlSettlementPrice", big(e18(90))))
  event.parameters.push(param("withheldFunding", big(BigInt.zero())))
  return event
}

export function adlResolved(epoch: i32): AdlResolved {
  let event = changetype<AdlResolved>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("adlEpoch", uint(epoch)))
  return event
}

export function mockSchedule(cutoffTs: i32): void {
  createMockedFunction(PAIR, "scheduledTerminationTs", "scheduledTerminationTs():(uint256)").returns([uint(cutoffTs)])
}

export function terminationSubmitted(assertionId: Bytes, cutoffTs: i32): TerminationProposalSubmitted {
  let event = changetype<TerminationProposalSubmitted>(mockEvent(TERMINATOR))
  event.parameters.push(param("pair", ethereum.Value.fromAddress(PAIR)))
  event.parameters.push(param("assertionId", ethereum.Value.fromFixedBytes(assertionId)))
  event.parameters.push(param("proposer", ethereum.Value.fromAddress(CAROL)))
  event.parameters.push(param("category", uint(1)))
  event.parameters.push(param("lastTradingTs", uint(cutoffTs)))
  event.parameters.push(param("reason", ethereum.Value.fromString("Issuer delisted")))
  return event
}

export function terminationAccepted(assertionId: Bytes, cutoffTs: i32): TerminationProposalAccepted {
  let event = changetype<TerminationProposalAccepted>(mockEvent(TERMINATOR))
  event.parameters.push(param("pair", ethereum.Value.fromAddress(PAIR)))
  event.parameters.push(param("assertionId", ethereum.Value.fromFixedBytes(assertionId)))
  event.parameters.push(param("lastTradingTs", uint(cutoffTs)))
  return event
}

export function stalePairTerminated(price: BigInt, oracleTs: i32): StalePairTerminated {
  let event = changetype<StalePairTerminated>(mockEvent(TERMINATOR))
  event.parameters.push(param("pair", ethereum.Value.fromAddress(PAIR)))
  event.parameters.push(param("terminationPrice", big(price)))
  event.parameters.push(param("oracleLastUpdateTs", uint(oracleTs)))
  return event
}

export function settlementPriceFixed(price: BigInt): SettlementPriceFixed {
  let event = changetype<SettlementPriceFixed>(mockEvent(TERMINATOR))
  event.parameters.push(param("pair", ethereum.Value.fromAddress(PAIR)))
  event.parameters.push(param("settlementPrice", big(price)))
  return event
}

export function pairTerminated(price: BigInt): PairTerminated {
  let event = changetype<PairTerminated>(mockEvent(PAIR))
  event.parameters.push(param("pairId", ethereum.Value.fromFixedBytes(PAIR_ID)))
  event.parameters.push(param("settlementPrice", big(price)))
  event.parameters.push(param("owedToTraders", big(e18(1000))))
  event.parameters.push(param("registeredClaims", big(e18(100))))
  event.parameters.push(param("badDebt", big(BigInt.zero())))
  event.parameters.push(param("estateValue", ethereum.Value.fromSignedBigInt(BigInt.zero())))
  event.parameters.push(param("pot", big(e18(1000))))
  event.parameters.push(param("principalRatio", big(E18)))
  event.parameters.push(param("profitRatio", big(E18)))
  event.parameters.push(param("insuranceFundBalanceAfter", big(e18(2000))))
  event.parameters.push(param("sweepComplete", ethereum.Value.fromBoolean(true)))
  event.parameters.push(param("timestamp", big(blockTimestamp)))
  return event
}
