import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts"
import { Trade as TradeEvent } from "../../generated/templates/BazaarPair/BazaarPair"
import { Account, Order, Pair, Trade } from "../../generated/schema"
import { removeFromBook, shrinkInBook } from "../book"
import { ONE, STATUS_FILLED, ZERO_ADDRESS } from "../constants"
import {
  eventId,
  getOrCreateAccount,
  getOrCreateIntegratorStats,
  getOrCreateOrder,
  getOrCreatePosition,
  getProtocol,
  loadPair,
  notional,
} from "../helpers"
import { getAccountDayData, getPairDayData, getProtocolDayData, updateCandles } from "../market"
import { unlinkProtectiveOrder } from "./orders"

// Applies one fill to an order. `remainingAfter` is the order's unfilled size after the fill as the
// Trade reports it, which keeps the entity exact even where the contract sizes an order in ways
// the earlier events only partly show (a firing TakeProfit or StopLoss is capped at its position).
function applyFill(pair: Pair, order: Order, fillSize: BigInt, remainingAfter: BigInt, event: ethereum.Event): void {
  if (order.inBook) {
    if (remainingAfter.isZero()) {
      removeFromBook(pair, order)
    } else {
      shrinkInBook(pair, order, order.remaining.minus(remainingAfter))
    }
  }
  order.filledSize = order.filledSize.plus(fillSize)
  order.remaining = remainingAfter
  order.fillCount = order.fillCount + 1
  order.updatedTimestamp = event.block.timestamp
  if (remainingAfter.isZero()) {
    order.status = STATUS_FILLED
    order.filledBlock = event.block.number
    order.filledTimestamp = event.block.timestamp
    unlinkProtectiveOrder(order)
  }
  order.save()
}

function recordPositionVolume(pair: Bytes, account: Address, size: BigInt, value: BigInt, event: ethereum.Event): void {
  let position = getOrCreatePosition(pair, account, event)
  position.tradeCount = position.tradeCount + 1
  position.volumeSize = position.volumeSize.plus(size)
  position.volumeNotional = position.volumeNotional.plus(value)
  position.save()
}

function recordIntegratorFill(integrator: Bytes, isMaker: boolean, value: BigInt, timestamp: BigInt): void {
  if (integrator.equals(ZERO_ADDRESS)) return
  let stats = getOrCreateIntegratorStats(integrator, timestamp)
  stats.fillCount = stats.fillCount.plus(ONE)
  if (isMaker) {
    stats.makerVolumeNotional = stats.makerVolumeNotional.plus(value)
  } else {
    stats.takerVolumeNotional = stats.takerVolumeNotional.plus(value)
  }
  stats.lastFillTimestamp = timestamp
  stats.save()
}

// One Trade per fill. A vault fill (the pair unloading liquidated inventory into a resting order)
// names the pair itself as taker, with no taker order and no taker fee.
export function handleTrade(event: TradeEvent): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let timestamp = event.block.timestamp
  let size = event.params.fillSize
  let price = event.params.price
  let value = notional(size, price)
  let makerFee = event.params.makerFee
  let takerFee = event.params.takerFee
  let isVaultFill = event.params.taker.equals(event.address)

  let maker = getOrCreateAccount(event.params.maker, timestamp)
  let makerOrder = getOrCreateOrder(pair.id, event.params.makerOrderId, event.params.maker, event)
  applyFill(pair, makerOrder, size, event.params.makerRemaining, event)
  recordPositionVolume(pair.id, event.params.maker, size, value, event)

  let trade = new Trade(eventId(event))
  trade.pair = pair.id
  trade.maker = maker.id
  trade.taker = event.params.taker
  trade.makerOrder = makerOrder.id
  trade.isVaultFill = isVaultFill
  trade.takerIsLong = event.params.takerIsLong
  trade.size = size
  trade.price = price
  trade.notional = value
  trade.makerFee = makerFee
  trade.takerFee = takerFee
  trade.makerRemaining = event.params.makerRemaining
  trade.takerRemaining = event.params.takerRemaining
  trade.makerIntegrator = makerOrder.integrator
  trade.takerIntegrator = ZERO_ADDRESS
  trade.txFrom = event.transaction.from
  trade.blockNumber = event.block.number
  trade.timestamp = timestamp
  trade.transactionHash = event.transaction.hash
  trade.logIndex = event.logIndex

  let taker: Account | null = null
  if (isVaultFill) {
    pair.vaultFillCount = pair.vaultFillCount.plus(ONE)
    pair.vaultFillSize = pair.vaultFillSize.plus(size)
    pair.vaultFillNotional = pair.vaultFillNotional.plus(value)
  } else {
    taker = getOrCreateAccount(event.params.taker, timestamp)
    let takerOrder = getOrCreateOrder(pair.id, event.params.takerOrderId, event.params.taker, event)
    applyFill(pair, takerOrder, size, event.params.takerRemaining, event)
    recordPositionVolume(pair.id, event.params.taker, size, value, event)
    trade.takerAccount = taker.id
    trade.takerOrder = takerOrder.id
    trade.takerIntegrator = takerOrder.integrator
  }
  trade.save()

  pair.tradeCount = pair.tradeCount.plus(ONE)
  pair.volumeSize = pair.volumeSize.plus(size)
  pair.volumeNotional = pair.volumeNotional.plus(value)
  pair.makerFees = pair.makerFees.plus(makerFee)
  pair.takerFees = pair.takerFees.plus(takerFee)
  pair.lastTradePrice = price
  pair.lastTradeTimestamp = timestamp
  pair.save()

  let protocol = getProtocol()
  protocol.tradeCount = protocol.tradeCount.plus(ONE)
  protocol.volumeNotional = protocol.volumeNotional.plus(value)
  protocol.makerFees = protocol.makerFees.plus(makerFee)
  protocol.takerFees = protocol.takerFees.plus(takerFee)
  protocol.save()

  updateCandles(pair.id, price, size, value, timestamp)

  let pairDay = getPairDayData(pair, timestamp)
  pairDay.volumeSize = pairDay.volumeSize.plus(size)
  pairDay.volumeNotional = pairDay.volumeNotional.plus(value)
  pairDay.tradeCount = pairDay.tradeCount + 1
  pairDay.makerFees = pairDay.makerFees.plus(makerFee)
  pairDay.takerFees = pairDay.takerFees.plus(takerFee)
  let high = pairDay.high
  let low = pairDay.low
  if (pairDay.open === null) pairDay.open = price
  if (high === null || price.gt(high as BigInt)) pairDay.high = price
  if (low === null || price.lt(low as BigInt)) pairDay.low = price
  pairDay.close = price
  pairDay.save()

  let protocolDay = getProtocolDayData(timestamp)
  protocolDay.volumeNotional = protocolDay.volumeNotional.plus(value)
  protocolDay.tradeCount = protocolDay.tradeCount + 1
  protocolDay.makerFees = protocolDay.makerFees.plus(makerFee)
  protocolDay.takerFees = protocolDay.takerFees.plus(takerFee)

  maker.tradeCount = maker.tradeCount.plus(ONE)
  maker.makerVolumeNotional = maker.makerVolumeNotional.plus(value)
  maker.save()
  let makerDay = getAccountDayData(maker.id, timestamp, protocolDay)
  makerDay.makerVolumeNotional = makerDay.makerVolumeNotional.plus(value)
  makerDay.tradeCount = makerDay.tradeCount + 1
  makerDay.save()
  recordIntegratorFill(makerOrder.integrator, true, value, timestamp)

  if (taker != null) {
    taker.tradeCount = taker.tradeCount.plus(ONE)
    taker.takerVolumeNotional = taker.takerVolumeNotional.plus(value)
    taker.save()
    let takerDay = getAccountDayData(taker.id, timestamp, protocolDay)
    takerDay.takerVolumeNotional = takerDay.takerVolumeNotional.plus(value)
    takerDay.tradeCount = takerDay.tradeCount + 1
    takerDay.save()
    recordIntegratorFill(trade.takerIntegrator, false, value, timestamp)
  }
  protocolDay.save()
}
