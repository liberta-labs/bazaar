import { BigInt, Bytes, log, store } from "@graphprotocol/graph-ts"
import { BookLevel, Order, Pair } from "../generated/schema"
import { ZERO } from "./constants"

// Mirror of the pair's resting book, aggregated per price level. The invariant every function here
// keeps: a level's size is the sum of `remaining` over the orders with inBook set at its price and
// side, and its orderCount is how many there are. Callers therefore adjust the level BEFORE they
// change an in-book order's remaining, and save the order and the pair afterwards.

export function bookLevelId(pair: Bytes, isBid: boolean, price: BigInt): string {
  return pair.toHexString() + (isBid ? "-bid-" : "-ask-") + price.toString()
}

export function addToBook(pair: Pair, order: Order): void {
  if (order.inBook) return
  let id = bookLevelId(pair.id, order.isLong, order.limitPrice)
  let level = BookLevel.load(id)
  if (level == null) {
    level = new BookLevel(id)
    level.pair = pair.id
    level.isBid = order.isLong
    level.price = order.limitPrice
    level.size = ZERO
    level.orderCount = 0
  }
  level.size = level.size.plus(order.remaining)
  level.orderCount = level.orderCount + 1
  level.save()

  order.inBook = true
  if (order.isLong) {
    pair.restingBidCount = pair.restingBidCount + 1
  } else {
    pair.restingAskCount = pair.restingAskCount + 1
  }
}

export function removeFromBook(pair: Pair, order: Order): void {
  if (!order.inBook) return
  let id = bookLevelId(pair.id, order.isLong, order.limitPrice)
  let level = BookLevel.load(id)
  if (level == null) {
    log.warning("Order {} is in the book but level {} is missing", [order.id, id])
  } else {
    level.size = level.size.minus(order.remaining)
    level.orderCount = level.orderCount - 1
    if (level.orderCount <= 0) {
      if (!level.size.isZero()) {
        log.warning("Level {} emptied with size {} left", [id, level.size.toString()])
      }
      store.remove("BookLevel", id)
    } else {
      level.save()
    }
  }

  order.inBook = false
  if (order.isLong) {
    pair.restingBidCount = pair.restingBidCount - 1
  } else {
    pair.restingAskCount = pair.restingAskCount - 1
  }
}

// An in-book order's remaining fell by `amount` and it stays in the book.
export function shrinkInBook(pair: Pair, order: Order, amount: BigInt): void {
  if (!order.inBook || amount.isZero()) return
  let id = bookLevelId(pair.id, order.isLong, order.limitPrice)
  let level = BookLevel.load(id)
  if (level == null) {
    log.warning("Order {} is in the book but level {} is missing", [order.id, id])
    return
  }
  level.size = level.size.minus(amount)
  level.save()
}
