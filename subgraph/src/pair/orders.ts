import { Address, BigInt, ethereum, log } from "@graphprotocol/graph-ts"
import {
  BazaarPair,
  OrderAmendSkipped,
  OrderAmended,
  OrderUpdated,
  TriggerBountyEscrowed,
  TriggerBountyReleased,
} from "../../generated/templates/BazaarPair/BazaarPair"
import { Order, OrderEvent, Position, TriggerBountyRelease } from "../../generated/schema"
import { addToBook, removeFromBook } from "../book"
import {
  ACTION_CANCELED,
  ACTION_CREATED,
  ACTION_TRIGGERED,
  ORDER_TYPE_LIMIT,
  ORDER_TYPE_STOP_LIMIT,
  STATUS_CANCELED,
  STATUS_FIRED,
  STATUS_PENDING,
  STATUS_RESTING,
  STATUS_WAITING,
  TIF_GTC,
  ZERO,
  ZERO_ADDRESS,
  amendSkipReasonName,
  cancelReasonName,
  isTriggerGated,
  orderTypeName,
  timeInForceName,
} from "../constants"
import {
  eventId,
  getOrCreateAccount,
  getOrCreateIntegratorStats,
  getOrCreateOrder,
  getOrCreatePosition,
  loadPair,
  orderEntityId,
  positionId,
} from "../helpers"

function saveOrderEvent(event: ethereum.Event, order: Order, action: string, cancelReason: string): OrderEvent {
  let record = new OrderEvent(eventId(event))
  record.order = order.id
  record.pair = order.pair
  record.owner = order.owner
  record.action = action
  record.cancelReason = cancelReason
  record.size = order.size
  record.filledSize = order.filledSize
  record.limitPrice = order.limitPrice
  record.triggerPrice = order.triggerPrice
  record.prioritySeq = order.prioritySeq
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.logIndex = event.logIndex
  return record
}

function isProtective(order: Order): boolean {
  return order.orderType == "TakeProfit" || order.orderType == "StopLoss"
}

// A position holds at most one TakeProfit and one StopLoss.
function linkProtectiveOrder(order: Order, event: ethereum.Event): void {
  if (!isProtective(order)) return
  let position = getOrCreatePosition(order.pair, Address.fromBytes(order.owner), event)
  if (order.orderType == "TakeProfit") {
    position.takeProfitOrder = order.id
  } else {
    position.stopLossOrder = order.id
  }
  position.save()
}

export function unlinkProtectiveOrder(order: Order): void {
  if (!isProtective(order)) return
  let position = Position.load(positionId(order.pair, order.owner))
  if (position == null) return
  let changed = false
  let takeProfit = position.takeProfitOrder
  if (takeProfit != null && takeProfit == order.id) {
    position.takeProfitOrder = null
    changed = true
  }
  let stopLoss = position.stopLossOrder
  if (stopLoss != null && stopLoss == order.id) {
    position.stopLossOrder = null
    changed = true
  }
  if (changed) position.save()
}

// Whether a StopLimit that just fired ended its transaction resting in the book. Its walk can also
// leave the remainder fired outside the book (a node budget that ran out, the owner's own order at
// the head, a fill its margin could not carry, or too little of its life left to rest) and no event
// tells those apart, so the order's stored book flag is read. The read sees the state at the end
// of the block; a later transaction in the same block that fills or cancels the order reports that
// through its own events, which the handlers apply on top.
function stopLimitRests(pair: Address, orderId: BigInt): boolean {
  let stored = BazaarPair.bind(pair).try_orders(orderId)
  if (stored.reverted) {
    log.warning("orders({}) reverted on pair {}", [orderId.toString(), pair.toHexString()])
    return false
  }
  return stored.value.getInBook()
}

export function handleOrderUpdated(event: OrderUpdated): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let payload = event.params.payload
  let owner = event.params.owner
  let action = payload.action
  let orderType = payload.orderType
  getOrCreateAccount(owner, event.block.timestamp)
  let order = getOrCreateOrder(pair.id, event.params.orderId, owner, event)

  // Leave the book at the price and remaining the entity holds before the payload overwrites them.
  if (action != ACTION_CREATED && order.inBook) removeFromBook(pair, order)

  order.owner = owner
  order.orderType = orderTypeName(orderType)
  order.isLong = payload.isLong
  order.isPostOnly = payload.isPostOnly
  order.timeInForce = timeInForceName(payload.tif)
  order.integrator = payload.integrator
  order.size = payload.size
  order.filledSize = payload.filledSize
  order.triggerPrice = payload.triggerPrice
  order.limitPrice = payload.limitPrice
  order.maxSlippageBp = payload.maxSlippageBp
  order.expiryBlock = payload.expiryBlock
  order.prioritySeq = payload.prioritySeq
  order.updatedTimestamp = event.block.timestamp

  let cancelReason = "None"
  let actionName = "Created"
  if (action == ACTION_CREATED) {
    order.createdBlock = event.block.number
    order.createdTimestamp = event.block.timestamp
    order.createdTx = event.transaction.hash
    order.remaining = payload.size.minus(payload.filledSize)
    pair.orderCount = pair.orderCount.plus(BigInt.fromI32(1))

    // A trigger order waits outside the book until its trigger fires; a GTC Limit rests whatever
    // its arrival walk leaves (fills and cancels in the same transaction adjust it); everything
    // else is terminal within its creation transaction.
    if (isTriggerGated(orderType)) {
      order.status = STATUS_WAITING
    } else if (orderType == ORDER_TYPE_LIMIT && payload.tif == TIF_GTC) {
      order.status = STATUS_RESTING
      addToBook(pair, order)
    } else {
      order.status = STATUS_PENDING
    }
    linkProtectiveOrder(order, event)

    if (!payload.integrator.equals(ZERO_ADDRESS)) {
      let stats = getOrCreateIntegratorStats(payload.integrator, event.block.timestamp)
      stats.orderCount = stats.orderCount.plus(BigInt.fromI32(1))
      stats.save()
    }
  } else if (action == ACTION_TRIGGERED) {
    actionName = "Triggered"
    // For a TakeProfit or StopLoss the payload's size is already capped at the position it closes.
    order.remaining = payload.size.minus(payload.filledSize)
    order.triggerCount = order.triggerCount + 1
    order.lastTriggeredTimestamp = event.block.timestamp
    if (orderType == ORDER_TYPE_STOP_LIMIT && stopLimitRests(event.address, event.params.orderId)) {
      order.status = STATUS_RESTING
      addToBook(pair, order)
    } else {
      order.status = STATUS_FIRED
    }
  } else if (action == ACTION_CANCELED) {
    actionName = "Canceled"
    cancelReason = cancelReasonName(payload.cancelReason)
    order.remaining = ZERO
    order.status = STATUS_CANCELED
    order.cancelReason = cancelReason
    order.canceledBlock = payload.canceledBlock
    order.canceledTimestamp = event.block.timestamp
    unlinkProtectiveOrder(order)
  } else {
    log.error("Unknown OrderAction {} for order {}", [action.toString(), order.id])
    return
  }

  saveOrderEvent(event, order, actionName, cancelReason).save()
  order.save()
  pair.save()
}

// Only a resting GTC Limit can be amended, and an amendment never crosses, so the order stays in
// the book at its new price and size. `size` is the new total size, filled part included.
export function handleOrderAmended(event: OrderAmended): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let order = Order.load(orderEntityId(pair.id, event.params.orderId))
  if (order == null) {
    log.warning("OrderAmended for unknown order {}", [event.params.orderId.toString()])
    return
  }
  if (order.inBook) removeFromBook(pair, order)
  order.limitPrice = event.params.limitPrice
  order.size = event.params.size
  order.prioritySeq = event.params.prioritySeq
  order.remaining = event.params.size.minus(order.filledSize)
  order.amendCount = order.amendCount + 1
  order.status = STATUS_RESTING
  order.updatedTimestamp = event.block.timestamp
  addToBook(pair, order)

  saveOrderEvent(event, order, "Amended", "None").save()
  order.save()
  pair.save()
}

export function handleOrderAmendSkipped(event: OrderAmendSkipped): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let order = Order.load(orderEntityId(pair.id, event.params.orderId))
  if (order == null) {
    log.warning("OrderAmendSkipped for unknown order {}", [event.params.orderId.toString()])
    return
  }
  let record = saveOrderEvent(event, order, "AmendSkipped", "None")
  record.amendSkipReason = amendSkipReasonName(event.params.reason)
  record.save()
}

// Escrowed at creation, before the order's OrderUpdated(Created) in the same transaction.
export function handleTriggerBountyEscrowed(event: TriggerBountyEscrowed): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let order = getOrCreateOrder(pair.id, event.params.orderId, ZERO_ADDRESS, event)
  order.bountyEscrowed = order.bountyEscrowed.plus(event.params.amount)
  order.bountyHeld = order.bountyHeld.plus(event.params.amount)
  order.save()
}

export function handleTriggerBountyReleased(event: TriggerBountyReleased): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let order = Order.load(orderEntityId(pair.id, event.params.orderId))
  if (order == null) {
    log.warning("TriggerBountyReleased for unknown order {}", [event.params.orderId.toString()])
    return
  }
  let amount = event.params.amount
  let recipient = event.params.recipient
  let held = order.bountyHeld.minus(amount)
  order.bountyHeld = held.lt(ZERO) ? ZERO : held

  let account = getOrCreateAccount(recipient, event.block.timestamp)
  let toKeeper = !recipient.equals(order.owner)
  if (toKeeper) {
    order.bountyPaidToKeepers = order.bountyPaidToKeepers.plus(amount)
    account.triggerBountiesEarned = account.triggerBountiesEarned.plus(amount)
    account.triggerExecutions = account.triggerExecutions + 1
    account.save()
  } else {
    order.bountyRefunded = order.bountyRefunded.plus(amount)
  }
  order.save()

  let record = new TriggerBountyRelease(eventId(event))
  record.order = order.id
  record.pair = pair.id
  record.recipient = recipient
  record.amount = amount
  record.toKeeper = toKeeper
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}
