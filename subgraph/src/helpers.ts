import { Address, BigInt, Bytes, ethereum, log } from "@graphprotocol/graph-ts"
import {
  Account,
  FeeBalance,
  InsuranceProvider,
  IntegratorStats,
  Order,
  Pair,
  Position,
  Protocol,
} from "../generated/schema"
import {
  PAIR_SCHEDULED,
  PAIR_SETTLEMENT_FIXED,
  PAIR_TERMINATED,
  PROTOCOL_ID,
  SCALE,
  STATUS_PENDING,
  ZERO,
  ZERO_ADDRESS,
} from "./constants"

// The ID of an immutable record: one per log.
export function eventId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32())
}

export function notional(size: BigInt, price: BigInt): BigInt {
  return size.times(price).div(SCALE)
}

export function getProtocol(): Protocol {
  let protocol = Protocol.load(PROTOCOL_ID)
  if (protocol == null) {
    protocol = new Protocol(PROTOCOL_ID)
    protocol.pairCount = 0
    protocol.accountCount = 0
    protocol.tradeCount = ZERO
    protocol.volumeNotional = ZERO
    protocol.makerFees = ZERO
    protocol.takerFees = ZERO
    protocol.liquidationCount = ZERO
  }
  return protocol as Protocol
}

// Loads the account, creating and saving it on first sight.
export function getOrCreateAccount(address: Address, timestamp: BigInt): Account {
  let account = Account.load(address)
  if (account == null) {
    account = new Account(address)
    account.firstSeenTimestamp = timestamp
    account.tradeCount = ZERO
    account.makerVolumeNotional = ZERO
    account.takerVolumeNotional = ZERO
    account.feesPaid = ZERO
    account.realizedPnl = ZERO
    account.liquidationCount = 0
    account.liquidationsExecuted = 0
    account.triggerBountiesEarned = ZERO
    account.triggerExecutions = 0
    account.adlBatchesExecuted = 0
    account.feesAccrued = ZERO
    account.feesClaimed = ZERO
    account.seedRefundOwedUsdc = ZERO
    account.save()

    let protocol = getProtocol()
    protocol.accountCount = protocol.accountCount + 1
    protocol.save()
  }
  return account as Account
}

// Every pair event arrives through the template the factory handler creates, after it has saved
// the Pair. A null here means the pair's events reached the subgraph without its PairDeployed,
// which only a start block later than the pair's deployment can cause.
export function loadPair(address: Address): Pair | null {
  let pair = Pair.load(address)
  if (pair == null) {
    log.warning("Event from pair {} that has no Pair entity", [address.toHexString()])
  }
  return pair
}

export function orderEntityId(pair: Bytes, orderId: BigInt): string {
  return pair.toHexString() + "-" + orderId.toString()
}

// The order, or a placeholder for one whose creation event has not been seen yet. A trigger
// order's bounty is escrowed before its OrderUpdated(Created) in the same transaction, so the
// escrow handler can be the first to touch it; Created then fills in every field. The caller
// saves the entity.
export function getOrCreateOrder(pair: Bytes, orderId: BigInt, owner: Address, event: ethereum.Event): Order {
  let id = orderEntityId(pair, orderId)
  let order = Order.load(id)
  if (order == null) {
    order = new Order(id)
    order.pair = pair
    order.orderId = orderId
    order.owner = owner
    order.orderType = "Market"
    order.isLong = false
    order.isPostOnly = false
    order.timeInForce = "GTC"
    order.integrator = ZERO_ADDRESS
    order.size = ZERO
    order.filledSize = ZERO
    order.remaining = ZERO
    order.triggerPrice = ZERO
    order.limitPrice = ZERO
    order.maxSlippageBp = ZERO
    order.expiryBlock = ZERO
    order.prioritySeq = orderId
    order.status = STATUS_PENDING
    order.inBook = false
    order.cancelReason = "None"
    order.createdBlock = event.block.number
    order.createdTimestamp = event.block.timestamp
    order.createdTx = event.transaction.hash
    order.triggerCount = 0
    order.updatedTimestamp = event.block.timestamp
    order.amendCount = 0
    order.fillCount = 0
    order.bountyEscrowed = ZERO
    order.bountyHeld = ZERO
    order.bountyPaidToKeepers = ZERO
    order.bountyRefunded = ZERO
  }
  return order as Order
}

export function positionId(pair: Bytes, account: Bytes): string {
  return pair.toHexString() + "-" + account.toHexString()
}

// The caller saves the entity.
export function getOrCreatePosition(pair: Bytes, account: Address, event: ethereum.Event): Position {
  let id = positionId(pair, account)
  let position = Position.load(id)
  if (position == null) {
    getOrCreateAccount(account, event.block.timestamp)
    position = new Position(id)
    position.pair = pair
    position.account = account
    position.isLong = false
    position.size = ZERO
    position.entryValue = ZERO
    position.entryPrice = ZERO
    position.collateral = ZERO
    position.entryFundingIndex = ZERO
    position.fundingIndexAtUpdate = ZERO
    position.imrBp = ZERO
    position.mmrBp = ZERO
    position.isOpen = false
    position.realizedPnl = ZERO
    position.feesPaid = ZERO
    position.tradeCount = 0
    position.volumeSize = ZERO
    position.volumeNotional = ZERO
    position.collateralDeposited = ZERO
    position.collateralWithdrawn = ZERO
    position.liquidationCount = 0
    position.adlCount = 0
    position.updatedAtBlock = event.block.number
    position.updatedAtTimestamp = event.block.timestamp
  }
  return position as Position
}

// The caller saves the entity.
export function getOrCreateFeeBalance(pair: Bytes, recipient: Address, timestamp: BigInt): FeeBalance {
  let id = pair.toHexString() + "-" + recipient.toHexString()
  let balance = FeeBalance.load(id)
  if (balance == null) {
    getOrCreateAccount(recipient, timestamp)
    balance = new FeeBalance(id)
    balance.pair = pair
    balance.recipient = recipient
    balance.accrued = ZERO
    balance.claimed = ZERO
    balance.claimable = ZERO
  }
  return balance as FeeBalance
}

// A new provider is linked at the head of the pair's provider list, which a share-generation reset
// walks to zero every balance. The caller saves both the provider and the pair.
export function getOrCreateInsuranceProvider(pair: Pair, account: Address, timestamp: BigInt): InsuranceProvider {
  let id = pair.id.toHexString() + "-" + account.toHexString()
  let provider = InsuranceProvider.load(id)
  if (provider == null) {
    getOrCreateAccount(account, timestamp)
    provider = new InsuranceProvider(id)
    provider.pair = pair.id
    provider.account = account
    provider.shares = ZERO
    provider.deposited = ZERO
    provider.withdrawn = ZERO
    provider.depositCount = 0
    provider.requestedShares = ZERO
    provider.levyChargedShares = ZERO
    provider.levyReceivedShares = ZERO
    provider.createdTimestamp = timestamp
    provider.previous = pair.lastInsuranceProvider
    pair.lastInsuranceProvider = id
    pair.insuranceProviderCount = pair.insuranceProviderCount + 1
  }
  return provider as InsuranceProvider
}

// The caller saves the entity.
export function getOrCreateIntegratorStats(integrator: Bytes, timestamp: BigInt): IntegratorStats {
  let stats = IntegratorStats.load(integrator)
  if (stats == null) {
    stats = new IntegratorStats(integrator)
    stats.orderCount = ZERO
    stats.fillCount = ZERO
    stats.makerVolumeNotional = ZERO
    stats.takerVolumeNotional = ZERO
    stats.firstOrderTimestamp = timestamp
  }
  return stats as IntegratorStats
}

function pairStatusRank(status: string): i32 {
  if (status == PAIR_TERMINATED) return 3
  if (status == PAIR_SETTLEMENT_FIXED) return 2
  if (status == PAIR_SCHEDULED) return 1
  return 0
}

// A pair only moves forward through Active, Scheduled, SettlementFixed and Terminated. The
// caller saves the pair.
export function advancePairStatus(pair: Pair, status: string): void {
  if (pairStatusRank(status) > pairStatusRank(pair.status)) {
    pair.status = status
  }
}
