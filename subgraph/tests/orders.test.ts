import { BigInt } from "@graphprotocol/graph-ts"
import { assert, beforeEach, clearStore, describe, test } from "matchstick-as/assembly/index"
import {
  handleOrderAmended,
  handleOrderUpdated,
  handleTriggerBountyEscrowed,
  handleTriggerBountyReleased,
} from "../src/pair/orders"
import { handleTrade } from "../src/pair/trades"
import {
  ALICE,
  BOB,
  INTEGRATOR,
  KEEPER,
  OrderArgs,
  PAIR,
  bountyEscrowed,
  bountyReleased,
  deployPair,
  e18,
  mockStoredOrder,
  orderAmended,
  orderUpdated,
  trade,
} from "./utils"

const ZERO = BigInt.zero()

function orderId(id: i32): string {
  return PAIR.toHexString() + "-" + id.toString()
}

function bidLevel(price: BigInt): string {
  return PAIR.toHexString() + "-bid-" + price.toString()
}

function askLevel(price: BigInt): string {
  return PAIR.toHexString() + "-ask-" + price.toString()
}

function tenths(n: i32): BigInt {
  return e18(n).div(BigInt.fromI32(10))
}

// A Market order selling `size`, terminal inside its creation transaction.
function marketSell(size: BigInt): OrderArgs {
  let args = new OrderArgs()
  args.orderType = 0
  args.isLong = false
  args.size = size
  args.tif = 1
  return args
}

function canceled(args: OrderArgs, reason: i32): OrderArgs {
  args.action = 2
  args.cancelReason = reason
  args.canceledBlock = BigInt.fromI32(1000)
  return args
}

describe("resting limit orders", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("a GTC limit rests at its price, shrinks with each fill and leaves the book when filled", () => {
    handleOrderUpdated(orderUpdated(1, ALICE, new OrderArgs()))
    assert.fieldEquals("Order", orderId(1), "status", "Resting")
    assert.fieldEquals("Order", orderId(1), "inBook", "true")
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "size", e18(1).toString())
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "orderCount", "1")
    assert.fieldEquals("Pair", PAIR.toHexString(), "restingBidCount", "1")

    handleOrderUpdated(orderUpdated(2, BOB, marketSell(tenths(4))))
    assert.fieldEquals("Order", orderId(2), "status", "Pending")
    handleTrade(trade(ALICE, BOB, 1, 2, false, tenths(4), e18(100), tenths(6), ZERO))
    assert.fieldEquals("Order", orderId(1), "remaining", tenths(6).toString())
    assert.fieldEquals("Order", orderId(1), "filledSize", tenths(4).toString())
    assert.fieldEquals("Order", orderId(1), "status", "Resting")
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "size", tenths(6).toString())
    assert.fieldEquals("Order", orderId(2), "status", "Filled")

    handleOrderUpdated(orderUpdated(3, BOB, marketSell(tenths(6))))
    handleTrade(trade(ALICE, BOB, 1, 3, false, tenths(6), e18(100), ZERO, ZERO))
    assert.fieldEquals("Order", orderId(1), "status", "Filled")
    assert.fieldEquals("Order", orderId(1), "inBook", "false")
    assert.fieldEquals("Order", orderId(1), "fillCount", "2")
    assert.notInStore("BookLevel", bidLevel(e18(100)))
    assert.fieldEquals("Pair", PAIR.toHexString(), "restingBidCount", "0")
    assert.fieldEquals("Pair", PAIR.toHexString(), "tradeCount", "2")
    assert.entityCount("Trade", 2)
  })

  test("two orders share a level and an owner cancel removes only its own size", () => {
    handleOrderUpdated(orderUpdated(1, ALICE, new OrderArgs()))
    let second = new OrderArgs()
    second.size = e18(3)
    handleOrderUpdated(orderUpdated(2, BOB, second))
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "size", e18(4).toString())
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "orderCount", "2")

    handleOrderUpdated(orderUpdated(1, ALICE, canceled(new OrderArgs(), 1)))
    assert.fieldEquals("Order", orderId(1), "status", "Canceled")
    assert.fieldEquals("Order", orderId(1), "cancelReason", "Owner")
    assert.fieldEquals("Order", orderId(1), "remaining", "0")
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "size", e18(3).toString())
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "orderCount", "1")
    assert.entityCount("OrderEvent", 3)
  })

  test("an amendment moves the order to its new level with its new size and queue position", () => {
    handleOrderUpdated(orderUpdated(1, ALICE, new OrderArgs()))
    handleOrderAmended(orderAmended(1, ALICE, e18(99), e18(2), 7))
    assert.notInStore("BookLevel", bidLevel(e18(100)))
    assert.fieldEquals("BookLevel", bidLevel(e18(99)), "size", e18(2).toString())
    assert.fieldEquals("Order", orderId(1), "limitPrice", e18(99).toString())
    assert.fieldEquals("Order", orderId(1), "prioritySeq", "7")
    assert.fieldEquals("Order", orderId(1), "amendCount", "1")
    assert.fieldEquals("Pair", PAIR.toHexString(), "restingBidCount", "1")
  })

  test("an amendment keeps the filled part out of the level", () => {
    handleOrderUpdated(orderUpdated(1, ALICE, new OrderArgs()))
    handleOrderUpdated(orderUpdated(2, BOB, marketSell(tenths(4))))
    handleTrade(trade(ALICE, BOB, 1, 2, false, tenths(4), e18(100), tenths(6), ZERO))
    // New total size 2, of which 0.4 has filled: 1.6 rests at the new price.
    handleOrderAmended(orderAmended(1, ALICE, e18(101), e18(2), 9))
    assert.fieldEquals("BookLevel", bidLevel(e18(101)), "size", tenths(16).toString())
    assert.fieldEquals("Order", orderId(1), "remaining", tenths(16).toString())
  })
})

describe("arriving orders", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("a crossing GTC limit rests only what its walk left", () => {
    let ask = new OrderArgs()
    ask.isLong = false
    handleOrderUpdated(orderUpdated(1, BOB, ask))
    assert.fieldEquals("BookLevel", askLevel(e18(100)), "size", e18(1).toString())

    let bid = new OrderArgs()
    bid.size = e18(2)
    bid.limitPrice = e18(101)
    handleOrderUpdated(orderUpdated(2, ALICE, bid))
    handleTrade(trade(BOB, ALICE, 1, 2, true, e18(1), e18(100), ZERO, e18(1)))

    assert.notInStore("BookLevel", askLevel(e18(100)))
    assert.fieldEquals("BookLevel", bidLevel(e18(101)), "size", e18(1).toString())
    assert.fieldEquals("Order", orderId(2), "status", "Resting")
    assert.fieldEquals("Order", orderId(2), "remaining", e18(1).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "restingAskCount", "0")
    assert.fieldEquals("Pair", PAIR.toHexString(), "restingBidCount", "1")
  })

  test("an IOC remainder is canceled as Unfilled and never enters the book", () => {
    let ask = new OrderArgs()
    ask.isLong = false
    handleOrderUpdated(orderUpdated(1, BOB, ask))
    let bid = new OrderArgs()
    bid.size = e18(3)
    bid.tif = 1
    handleOrderUpdated(orderUpdated(2, ALICE, bid))
    assert.fieldEquals("Order", orderId(2), "inBook", "false")
    handleTrade(trade(BOB, ALICE, 1, 2, true, e18(1), e18(100), ZERO, e18(2)))
    let cancel = new OrderArgs()
    cancel.size = e18(3)
    cancel.filledSize = e18(1)
    cancel.tif = 1
    handleOrderUpdated(orderUpdated(2, ALICE, canceled(cancel, 3)))
    assert.fieldEquals("Order", orderId(2), "status", "Canceled")
    assert.fieldEquals("Order", orderId(2), "cancelReason", "Unfilled")
    assert.entityCount("BookLevel", 0)
  })

  test("orders and fills are credited to the integrator they carry", () => {
    let ask = new OrderArgs()
    ask.isLong = false
    ask.integrator = INTEGRATOR
    handleOrderUpdated(orderUpdated(1, BOB, ask))
    handleOrderUpdated(orderUpdated(2, ALICE, marketSell(e18(1))))
    handleTrade(trade(BOB, ALICE, 1, 2, true, e18(1), e18(100), ZERO, ZERO))
    assert.fieldEquals("IntegratorStats", INTEGRATOR.toHexString(), "orderCount", "1")
    assert.fieldEquals("IntegratorStats", INTEGRATOR.toHexString(), "fillCount", "1")
    assert.fieldEquals("IntegratorStats", INTEGRATOR.toHexString(), "makerVolumeNotional", e18(100).toString())
    assert.fieldEquals("IntegratorStats", INTEGRATOR.toHexString(), "takerVolumeNotional", "0")
  })
})

describe("trigger orders", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("a StopLimit waits outside the book and rests when the pair reports it in the book after firing", () => {
    let stop = new OrderArgs()
    stop.orderType = 2
    stop.size = e18(2)
    stop.triggerPrice = e18(95)
    handleOrderUpdated(orderUpdated(4, ALICE, stop))
    assert.fieldEquals("Order", orderId(4), "status", "Waiting")
    assert.entityCount("BookLevel", 0)

    mockStoredOrder(4, ALICE, true)
    stop.action = 1
    stop.prioritySeq = BigInt.fromI32(12)
    handleOrderUpdated(orderUpdated(4, ALICE, stop))
    assert.fieldEquals("Order", orderId(4), "status", "Resting")
    assert.fieldEquals("Order", orderId(4), "prioritySeq", "12")
    assert.fieldEquals("Order", orderId(4), "triggerCount", "1")
    assert.fieldEquals("BookLevel", bidLevel(e18(100)), "size", e18(2).toString())
  })

  test("a StopLimit that fires but cannot rest stays Fired outside the book", () => {
    let stop = new OrderArgs()
    stop.orderType = 2
    stop.size = e18(2)
    handleOrderUpdated(orderUpdated(5, ALICE, stop))
    mockStoredOrder(5, ALICE, false)
    stop.action = 1
    handleOrderUpdated(orderUpdated(5, ALICE, stop))
    assert.fieldEquals("Order", orderId(5), "status", "Fired")
    assert.fieldEquals("Order", orderId(5), "inBook", "false")
    assert.entityCount("BookLevel", 0)
  })

  test("a TakeProfit links to its position and is unlinked when its position closes", () => {
    let takeProfit = new OrderArgs()
    takeProfit.orderType = 3
    takeProfit.isLong = false
    takeProfit.size = e18(1000)
    handleOrderUpdated(orderUpdated(6, ALICE, takeProfit))
    let position = PAIR.toHexString() + "-" + ALICE.toHexString()
    assert.fieldEquals("Position", position, "takeProfitOrder", orderId(6))
    assert.fieldEquals("Order", orderId(6), "status", "Waiting")

    // Fired with the size capped at a 2-unit position, then filled in full.
    takeProfit.action = 1
    takeProfit.size = e18(2)
    handleOrderUpdated(orderUpdated(6, ALICE, takeProfit))
    assert.fieldEquals("Order", orderId(6), "remaining", e18(2).toString())
    let bid = new OrderArgs()
    handleOrderUpdated(orderUpdated(7, BOB, bid))
    handleTrade(trade(BOB, ALICE, 7, 6, false, e18(1), e18(100), ZERO, e18(1)))
    assert.fieldEquals("Order", orderId(6), "status", "Fired")
    assert.fieldEquals("Order", orderId(6), "remaining", e18(1).toString())

    handleOrderUpdated(orderUpdated(6, ALICE, canceled(takeProfit, 10)))
    assert.fieldEquals("Order", orderId(6), "cancelReason", "PositionClosed")
    assert.fieldEquals("Position", position, "takeProfitOrder", "null")
  })

  test("a bounty escrowed ahead of creation survives it, and a keeper's share is told from a refund", () => {
    handleTriggerBountyEscrowed(bountyEscrowed(8, e18(1)))
    let stop = new OrderArgs()
    stop.orderType = 4
    stop.isLong = false
    handleOrderUpdated(orderUpdated(8, ALICE, stop))
    assert.fieldEquals("Order", orderId(8), "owner", ALICE.toHexString())
    assert.fieldEquals("Order", orderId(8), "orderType", "StopLoss")
    assert.fieldEquals("Order", orderId(8), "bountyHeld", e18(1).toString())

    let quarter = e18(1).div(BigInt.fromI32(4))
    handleTriggerBountyReleased(bountyReleased(8, KEEPER, quarter))
    handleTriggerBountyReleased(bountyReleased(8, ALICE, e18(1).minus(quarter)))
    assert.fieldEquals("Order", orderId(8), "bountyHeld", "0")
    assert.fieldEquals("Order", orderId(8), "bountyPaidToKeepers", quarter.toString())
    assert.fieldEquals("Order", orderId(8), "bountyRefunded", e18(1).minus(quarter).toString())
    assert.fieldEquals("Account", KEEPER.toHexString(), "triggerBountiesEarned", quarter.toString())
    assert.fieldEquals("Account", KEEPER.toHexString(), "triggerExecutions", "1")
    assert.entityCount("TriggerBountyRelease", 2)
  })
})
