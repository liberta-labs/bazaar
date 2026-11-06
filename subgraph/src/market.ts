import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import { AccountDayData, Candle, Pair, PairDayData, ProtocolDayData } from "../generated/schema"
import { CANDLE_INTERVALS, SECONDS_PER_DAY, ZERO } from "./constants"

export function updateCandles(pair: Bytes, price: BigInt, size: BigInt, notional: BigInt, timestamp: BigInt): void {
  for (let i = 0; i < CANDLE_INTERVALS.length; i++) {
    let interval = CANDLE_INTERVALS[i]
    let length = BigInt.fromI32(interval)
    let start = timestamp.minus(timestamp.mod(length))
    let id = pair.toHexString() + "-" + interval.toString() + "-" + start.toString()
    let candle = Candle.load(id)
    if (candle == null) {
      candle = new Candle(id)
      candle.pair = pair
      candle.interval = interval
      candle.periodStart = start
      candle.open = price
      candle.high = price
      candle.low = price
      candle.close = price
      candle.volumeSize = ZERO
      candle.volumeNotional = ZERO
      candle.tradeCount = 0
    } else {
      if (price.gt(candle.high)) candle.high = price
      if (price.lt(candle.low)) candle.low = price
      candle.close = price
    }
    candle.volumeSize = candle.volumeSize.plus(size)
    candle.volumeNotional = candle.volumeNotional.plus(notional)
    candle.tradeCount = candle.tradeCount + 1
    candle.save()
  }
}

function dayIndex(timestamp: BigInt): BigInt {
  return timestamp.div(SECONDS_PER_DAY)
}

// The caller saves the entity.
export function getPairDayData(pair: Pair, timestamp: BigInt): PairDayData {
  let day = dayIndex(timestamp)
  let id = pair.id.toHexString() + "-" + day.toString()
  let data = PairDayData.load(id)
  if (data == null) {
    data = new PairDayData(id)
    data.pair = pair.id
    data.date = day.times(SECONDS_PER_DAY)
    data.volumeSize = ZERO
    data.volumeNotional = ZERO
    data.tradeCount = 0
    data.makerFees = ZERO
    data.takerFees = ZERO
    data.liquidationCount = 0
    data.liquidatedNotional = ZERO
    data.openInterestLong = pair.openInterestLong
    data.openInterestShort = pair.openInterestShort
    data.fundingIndex = pair.fundingIndex
    data.insuranceDeposited = ZERO
    data.insuranceWithdrawn = ZERO
  }
  return data as PairDayData
}

// The caller saves the entity.
export function getProtocolDayData(timestamp: BigInt): ProtocolDayData {
  let day = dayIndex(timestamp)
  let id = day.toString()
  let data = ProtocolDayData.load(id)
  if (data == null) {
    data = new ProtocolDayData(id)
    data.date = day.times(SECONDS_PER_DAY)
    data.volumeNotional = ZERO
    data.tradeCount = 0
    data.makerFees = ZERO
    data.takerFees = ZERO
    data.liquidationCount = 0
    data.uniqueTraders = 0
  }
  return data as ProtocolDayData
}

// The caller saves the entity. A trader's first record of the day counts once toward the
// protocol's unique traders, so the caller passes the day's protocol record to update.
export function getAccountDayData(account: Bytes, timestamp: BigInt, protocolDay: ProtocolDayData): AccountDayData {
  let day = dayIndex(timestamp)
  let id = account.toHexString() + "-" + day.toString()
  let data = AccountDayData.load(id)
  if (data == null) {
    data = new AccountDayData(id)
    data.account = account
    data.date = day.times(SECONDS_PER_DAY)
    data.makerVolumeNotional = ZERO
    data.takerVolumeNotional = ZERO
    data.tradeCount = 0
    data.feesPaid = ZERO
    data.realizedPnl = ZERO
    protocolDay.uniqueTraders = protocolDay.uniqueTraders + 1
  }
  return data as AccountDayData
}
