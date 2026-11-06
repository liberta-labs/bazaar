import { BigInt, log } from "@graphprotocol/graph-ts"
import {
  AdlExecuted,
  AdlResolved,
  AdlTerminationArmed,
  AdlTriggered,
  PositionLiquidated,
  UserAdld,
} from "../../generated/templates/BazaarPair/BazaarPair"
import { AdlBatch, AdlFill, AdlWindow, Liquidation } from "../../generated/schema"
import { ONE } from "../constants"
import { eventId, getOrCreateAccount, getOrCreatePosition, getProtocol, loadPair, notional } from "../helpers"
import { getPairDayData, getProtocolDayData } from "../market"

// A window is named by the pair and the epoch of the AdlTriggered that opened it.
function adlWindowId(pair: string, epoch: BigInt): string {
  return pair + "-" + epoch.toString()
}

export function handlePositionLiquidated(event: PositionLiquidated): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let timestamp = event.block.timestamp
  let size = event.params.size
  let price = event.params.triggerPrice
  let value = notional(size, price)
  let seized = event.params.collateralSeized

  let account = getOrCreateAccount(event.params.liquidatedUser, timestamp)
  account.liquidationCount = account.liquidationCount + 1
  account.save()
  let liquidator = getOrCreateAccount(event.params.liquidator, timestamp)
  liquidator.liquidationsExecuted = liquidator.liquidationsExecuted + 1
  liquidator.save()

  let position = getOrCreatePosition(pair.id, event.params.liquidatedUser, event)
  position.liquidationCount = position.liquidationCount + 1
  position.save()

  let record = new Liquidation(eventId(event))
  record.pair = pair.id
  record.account = account.id
  record.liquidator = liquidator.id
  record.size = size
  record.isLong = event.params.isLong
  record.bankruptcyPrice = event.params.bankruptcyPrice
  record.price = price
  record.notional = value
  record.collateralSeized = seized
  record.blockNumber = event.block.number
  record.timestamp = timestamp
  record.transactionHash = event.transaction.hash
  record.save()

  pair.liquidationCount = pair.liquidationCount.plus(ONE)
  pair.liquidatedSize = pair.liquidatedSize.plus(size)
  pair.liquidatedNotional = pair.liquidatedNotional.plus(value)
  pair.collateralSeized = pair.collateralSeized.plus(seized)
  pair.save()

  let pairDay = getPairDayData(pair, timestamp)
  pairDay.liquidationCount = pairDay.liquidationCount + 1
  pairDay.liquidatedNotional = pairDay.liquidatedNotional.plus(value)
  pairDay.save()

  let protocolDay = getProtocolDayData(timestamp)
  protocolDay.liquidationCount = protocolDay.liquidationCount + 1
  protocolDay.save()

  let protocol = getProtocol()
  protocol.liquidationCount = protocol.liquidationCount.plus(ONE)
  protocol.save()
}

// AdlTriggered fires once per window, when it opens, and the pair's epoch advances only then, so
// every trigger opens a new window. AdlResolved or PairTerminated closes it.
export function handleAdlTriggered(event: AdlTriggered): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let epoch = event.params.adlEpoch
  let open = pair.currentAdlWindow
  if (open != null) {
    log.warning("AdlTriggered epoch {} arrived while window {} is still open", [epoch.toString(), open as string])
  }
  let window = new AdlWindow(adlWindowId(pair.id.toHexString(), epoch))
  window.pair = pair.id
  window.epoch = epoch
  window.openedAt = event.block.timestamp
  window.openedPrice = event.params.price
  window.openedFundingIndex = event.params.fundingIndex
  window.endedByTermination = false
  window.batchCount = 0
  window.save()

  pair.isAdlPending = true
  pair.adlEpoch = epoch
  pair.currentAdlWindow = window.id
  pair.save()
}

export function handleAdlTerminationArmed(event: AdlTerminationArmed): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  pair.adlTerminationTs = event.params.adlTerminationTs
  let currentId = pair.currentAdlWindow
  if (currentId != null) {
    let window = AdlWindow.load(currentId as string)
    if (window != null) {
      window.terminationTs = event.params.adlTerminationTs
      window.save()
    }
  }
  pair.save()
}

export function handleAdlResolved(event: AdlResolved): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let currentId = pair.currentAdlWindow
  if (currentId != null) {
    let window = AdlWindow.load(currentId as string)
    if (window != null) {
      window.resolvedAt = event.block.timestamp
      window.save()
    }
  }
  pair.isAdlPending = false
  pair.currentAdlWindow = null
  pair.adlTerminationTs = null
  pair.save()
}

export function handleAdlExecuted(event: AdlExecuted): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let submitter = getOrCreateAccount(event.params.submitter, event.block.timestamp)
  submitter.adlBatchesExecuted = submitter.adlBatchesExecuted + 1
  submitter.save()

  let batch = new AdlBatch(eventId(event))
  batch.pair = pair.id
  batch.adlId = event.params.adlId
  batch.submitter = submitter.id
  batch.longBucketClosed = event.params.longBucketClosed
  batch.longBucketSettlementPrice = event.params.longBucketSettlementPrice
  batch.shortBucketClosed = event.params.shortBucketClosed
  batch.shortBucketSettlementPrice = event.params.shortBucketSettlementPrice
  batch.netted = event.params.netted
  batch.blockNumber = event.block.number
  batch.timestamp = event.block.timestamp
  batch.transactionHash = event.transaction.hash

  let currentId = pair.currentAdlWindow
  if (currentId != null) {
    batch.window = currentId
    let window = AdlWindow.load(currentId as string)
    if (window != null) {
      window.batchCount = window.batchCount + 1
      window.save()
    }
  }
  batch.save()

  pair.adlBatchCount = pair.adlBatchCount.plus(ONE)
  pair.save()
}

export function handleUserAdld(event: UserAdld): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let timestamp = event.block.timestamp
  let credit = event.params.realizedPnl

  let account = getOrCreateAccount(event.params.user, timestamp)
  account.realizedPnl = account.realizedPnl.plus(credit)
  account.save()

  let position = getOrCreatePosition(pair.id, event.params.user, event)
  position.adlCount = position.adlCount + 1
  position.realizedPnl = position.realizedPnl.plus(credit)
  position.save()

  let fill = new AdlFill(eventId(event))
  fill.pair = pair.id
  fill.account = account.id
  fill.isLong = event.params.isLong
  fill.closedSize = event.params.closedSize
  fill.credit = credit
  fill.remainingCollateral = event.params.remainingCollateral
  fill.adlScore = event.params.adlScore
  fill.settlementPrice = event.params.adlSettlementPrice
  fill.withheldFunding = event.params.withheldFunding
  fill.blockNumber = event.block.number
  fill.timestamp = timestamp
  fill.transactionHash = event.transaction.hash
  fill.save()
}
