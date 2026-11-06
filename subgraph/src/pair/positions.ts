import { Address, BigInt, ethereum } from "@graphprotocol/graph-ts"
import {
  CollateralDeposited,
  CollateralWithdrawn,
  PositionBucketUpdated,
  PositionModified,
} from "../../generated/templates/BazaarPair/BazaarPair"
import { CollateralTransfer, PositionChange, PositionSnapshot } from "../../generated/schema"
import { SCALE, ZERO } from "../constants"
import { eventId, getOrCreateAccount, getOrCreatePosition, loadPair } from "../helpers"
import { getAccountDayData, getPairDayData, getProtocolDayData } from "../market"

// Every path that changes a position emits PositionBucketUpdated with the full stored state, so
// the Position entity mirrors this event alone and open interest follows from the change it
// reports.
export function handlePositionBucketUpdated(event: PositionBucketUpdated): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let timestamp = event.block.timestamp
  let position = getOrCreatePosition(pair.id, event.params.owner, event)

  let oldSize = position.size
  let wasOpen = oldSize.gt(ZERO)
  if (wasOpen) {
    if (position.isLong) {
      pair.openInterestLong = pair.openInterestLong.minus(oldSize)
    } else {
      pair.openInterestShort = pair.openInterestShort.minus(oldSize)
    }
  }
  let size = event.params.size
  let isOpen = size.gt(ZERO)
  if (isOpen) {
    if (event.params.isLong) {
      pair.openInterestLong = pair.openInterestLong.plus(size)
    } else {
      pair.openInterestShort = pair.openInterestShort.plus(size)
    }
  }
  if (!wasOpen && isOpen) {
    pair.openPositionCount = pair.openPositionCount + 1
    position.openedAtTimestamp = timestamp
  } else if (wasOpen && !isOpen) {
    pair.openPositionCount = pair.openPositionCount - 1
    position.closedAtTimestamp = timestamp
  }

  position.isLong = event.params.isLong
  position.size = size
  position.entryValue = event.params.entryValue
  position.entryPrice = isOpen ? event.params.entryValue.times(SCALE).div(size) : ZERO
  position.collateral = event.params.collateral
  position.entryFundingIndex = event.params.entryFundingIndex
  position.fundingIndexAtUpdate = event.params.globalFundingIndex
  position.isOpen = isOpen
  position.updatedAtBlock = event.block.number
  position.updatedAtTimestamp = timestamp

  // Terminal settlement reports no margin rates (both zero); keep the last ones reported.
  let imrBp = event.params.imrBp
  let mmrBp = event.params.mmrBp
  if (!imrBp.isZero() || !mmrBp.isZero()) {
    position.imrBp = imrBp
    position.mmrBp = mmrBp
    pair.imrBp = imrBp
    pair.mmrBp = mmrBp
  }
  position.save()

  let snapshot = new PositionSnapshot(eventId(event))
  snapshot.position = position.id
  snapshot.pair = pair.id
  snapshot.account = event.params.owner
  snapshot.isLong = event.params.isLong
  snapshot.size = size
  snapshot.entryValue = event.params.entryValue
  snapshot.collateral = event.params.collateral
  snapshot.entryFundingIndex = event.params.entryFundingIndex
  snapshot.globalFundingIndex = event.params.globalFundingIndex
  snapshot.imrBp = imrBp
  snapshot.mmrBp = mmrBp
  snapshot.blockNumber = event.block.number
  snapshot.timestamp = timestamp
  snapshot.transactionHash = event.transaction.hash
  snapshot.logIndex = event.logIndex
  snapshot.save()

  if (wasOpen || isOpen) {
    let day = getPairDayData(pair, timestamp)
    day.openInterestLong = pair.openInterestLong
    day.openInterestShort = pair.openInterestShort
    day.save()
  }
  pair.save()
}

// The maker's effect per fill, and the taker's once per order walk at the walk's volume-weighted
// price. realizedPnl is the price PnL of the closed size; the funding settled on it goes to
// collateral and shows in the position's collateral rather than here.
export function handlePositionModified(event: PositionModified): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let timestamp = event.block.timestamp
  let user = event.params.user
  let fee = event.params.fee
  let pnl = event.params.realizedPnl

  let position = getOrCreatePosition(pair.id, user, event)
  position.realizedPnl = position.realizedPnl.plus(pnl)
  position.feesPaid = position.feesPaid.plus(fee)
  position.save()

  let account = getOrCreateAccount(user, timestamp)
  account.realizedPnl = account.realizedPnl.plus(pnl)
  account.feesPaid = account.feesPaid.plus(fee)
  account.save()

  let protocolDay = getProtocolDayData(timestamp)
  let accountDay = getAccountDayData(user, timestamp, protocolDay)
  accountDay.realizedPnl = accountDay.realizedPnl.plus(pnl)
  accountDay.feesPaid = accountDay.feesPaid.plus(fee)
  accountDay.save()
  protocolDay.save()

  let change = new PositionChange(eventId(event))
  change.position = position.id
  change.pair = pair.id
  change.account = user
  change.isLong = event.params.isLong
  change.sizeDelta = event.params.sizeDelta
  change.newSize = event.params.newSize
  change.newEntryValue = event.params.newEntryValue
  change.newCollateral = event.params.newCollateral
  change.executionPrice = event.params.executionPrice
  change.fee = fee
  change.realizedPnl = pnl
  change.blockNumber = event.block.number
  change.timestamp = timestamp
  change.transactionHash = event.transaction.hash
  change.logIndex = event.logIndex
  change.save()
}

function recordCollateral(event: ethereum.Event, user: Address, amount: BigInt, isDeposit: boolean): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let position = getOrCreatePosition(pair.id, user, event)
  if (isDeposit) {
    position.collateralDeposited = position.collateralDeposited.plus(amount)
  } else {
    position.collateralWithdrawn = position.collateralWithdrawn.plus(amount)
  }
  position.save()

  let transfer = new CollateralTransfer(eventId(event))
  transfer.pair = pair.id
  transfer.account = user
  transfer.isDeposit = isDeposit
  transfer.amount = amount
  transfer.blockNumber = event.block.number
  transfer.timestamp = event.block.timestamp
  transfer.transactionHash = event.transaction.hash
  transfer.save()
}

export function handleCollateralDeposited(event: CollateralDeposited): void {
  recordCollateral(event, event.params.user, event.params.amount, true)
}

export function handleCollateralWithdrawn(event: CollateralWithdrawn): void {
  recordCollateral(event, event.params.user, event.params.amount, false)
}
