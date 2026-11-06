import { BigInt } from "@graphprotocol/graph-ts"
import { assert, beforeEach, clearStore, describe, test } from "matchstick-as/assembly/index"
import { handleFeeAccrued, handleFeesClaimed, handleNewPriceUpdateAdded } from "../src/pair/lifecycle"
import { handleOrderUpdated } from "../src/pair/orders"
import { handlePositionBucketUpdated, handlePositionModified } from "../src/pair/positions"
import { handlePositionLiquidated } from "../src/pair/risk"
import { handleTrade } from "../src/pair/trades"
import {
  ALICE,
  BOB,
  KEEPER,
  OrderArgs,
  PAIR,
  bucketUpdated,
  deployPair,
  e18,
  feeAccrued,
  feesClaimed,
  orderUpdated,
  positionLiquidated,
  positionModified,
  priceUpdate,
  setBlock,
  trade,
} from "./utils"

const ZERO = BigInt.zero()

function positionId(account: string): string {
  return PAIR.toHexString() + "-" + account
}

describe("positions", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("open interest and the open count follow each position's reported size and side", () => {
    handlePositionBucketUpdated(bucketUpdated(ALICE, true, e18(2), e18(200), e18(50), 1000))
    handlePositionBucketUpdated(bucketUpdated(BOB, false, e18(2), e18(200), e18(50), 1000))
    assert.fieldEquals("Pair", PAIR.toHexString(), "openInterestLong", e18(2).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "openInterestShort", e18(2).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "openPositionCount", "2")
    assert.fieldEquals("Position", positionId(ALICE.toHexString()), "entryPrice", e18(100).toString())

    // Alice flips to a 1-unit short; Bob closes.
    handlePositionBucketUpdated(bucketUpdated(ALICE, false, e18(1), e18(100), e18(40), 1000))
    handlePositionBucketUpdated(bucketUpdated(BOB, false, ZERO, ZERO, e18(55), 1000))
    assert.fieldEquals("Pair", PAIR.toHexString(), "openInterestLong", "0")
    assert.fieldEquals("Pair", PAIR.toHexString(), "openInterestShort", e18(1).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "openPositionCount", "1")
    assert.fieldEquals("Position", positionId(BOB.toHexString()), "isOpen", "false")
    assert.fieldEquals("Position", positionId(BOB.toHexString()), "entryPrice", "0")
    assert.entityCount("PositionSnapshot", 4)
  })

  test("a terminal settlement that reports no margin rates keeps the last ones reported", () => {
    handlePositionBucketUpdated(bucketUpdated(ALICE, true, e18(2), e18(200), e18(50), 1000))
    handlePositionBucketUpdated(bucketUpdated(ALICE, true, ZERO, ZERO, e18(50), 0))
    assert.fieldEquals("Position", positionId(ALICE.toHexString()), "imrBp", "1000")
    assert.fieldEquals("Position", positionId(ALICE.toHexString()), "mmrBp", "500")
    assert.fieldEquals("Pair", PAIR.toHexString(), "imrBp", "1000")
  })

  test("realized PnL and fees accumulate on the position, the account and the account's day", () => {
    handlePositionModified(positionModified(ALICE, e18(-1), e18(1), e18(5)))
    handlePositionModified(positionModified(ALICE, e18(-1), e18(1), e18(-2)))
    assert.fieldEquals("Position", positionId(ALICE.toHexString()), "realizedPnl", e18(3).toString())
    assert.fieldEquals("Position", positionId(ALICE.toHexString()), "feesPaid", e18(2).toString())
    assert.fieldEquals("Account", ALICE.toHexString(), "realizedPnl", e18(3).toString())
    assert.entityCount("PositionChange", 2)
    assert.entityCount("AccountDayData", 1)
  })

  test("a liquidation is recorded and counted for the account, the liquidator and the pair", () => {
    handlePositionLiquidated(positionLiquidated(ALICE, e18(2), e18(95), e18(10)))
    assert.entityCount("Liquidation", 1)
    assert.fieldEquals("Account", ALICE.toHexString(), "liquidationCount", "1")
    assert.fieldEquals("Account", KEEPER.toHexString(), "liquidationsExecuted", "1")
    assert.fieldEquals("Pair", PAIR.toHexString(), "liquidatedNotional", e18(190).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "collateralSeized", e18(10).toString())
    assert.fieldEquals("Protocol", "bazaar", "liquidationCount", "1")
  })
})

describe("trades and market data", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("a vault fill names the pair as taker and carries no taker order", () => {
    handleOrderUpdated(orderUpdated(1, ALICE, new OrderArgs()))
    handleTrade(trade(ALICE, PAIR, 1, 0, false, e18(1), e18(100), ZERO, ZERO))
    assert.entityCount("Trade", 1)
    assert.fieldEquals("Pair", PAIR.toHexString(), "vaultFillCount", "1")
    assert.fieldEquals("Pair", PAIR.toHexString(), "vaultFillNotional", e18(100).toString())
    assert.fieldEquals("Order", PAIR.toHexString() + "-1", "status", "Filled")
    assert.fieldEquals("Account", ALICE.toHexString(), "makerVolumeNotional", e18(100).toString())
    assert.notInStore("Account", PAIR.toHexString())
  })

  test("fills build candles at every interval and the day's open, high, low and close", () => {
    setBlock(2000, 1800000000)
    handleOrderUpdated(orderUpdated(1, ALICE, new OrderArgs()))
    let quarter = e18(1).div(BigInt.fromI32(4))
    handleTrade(trade(ALICE, BOB, 1, 2, false, quarter, e18(100), e18(1).minus(quarter), ZERO))
    let high = new OrderArgs()
    high.limitPrice = e18(104)
    handleOrderUpdated(orderUpdated(3, ALICE, high))
    setBlock(2001, 1800000030)
    handleTrade(trade(ALICE, BOB, 3, 4, false, e18(1), e18(104), ZERO, ZERO))
    let low = new OrderArgs()
    low.limitPrice = e18(98)
    handleOrderUpdated(orderUpdated(5, ALICE, low))
    handleTrade(trade(ALICE, BOB, 5, 6, false, e18(1), e18(98), ZERO, ZERO))

    assert.entityCount("Candle", 6)
    let minute = PAIR.toHexString() + "-60-1800000000"
    assert.fieldEquals("Candle", minute, "open", e18(100).toString())
    assert.fieldEquals("Candle", minute, "high", e18(104).toString())
    assert.fieldEquals("Candle", minute, "low", e18(98).toString())
    assert.fieldEquals("Candle", minute, "close", e18(98).toString())
    assert.fieldEquals("Candle", minute, "tradeCount", "3")

    let day = PAIR.toHexString() + "-20833"
    assert.fieldEquals("PairDayData", day, "high", e18(104).toString())
    assert.fieldEquals("PairDayData", day, "close", e18(98).toString())
    assert.fieldEquals("PairDayData", day, "tradeCount", "3")
    assert.fieldEquals("ProtocolDayData", "20833", "uniqueTraders", "2")
  })

  test("each stored price records the funding the index accrued since the last one", () => {
    handleNewPriceUpdateAdded(priceUpdate(1800000000, e18(100), BigInt.fromI32(500)))
    handleNewPriceUpdateAdded(priceUpdate(1800000060, e18(101), BigInt.fromI32(800)))
    assert.fieldEquals("Pair", PAIR.toHexString(), "fundingIndex", "800")
    assert.fieldEquals("Pair", PAIR.toHexString(), "lastPrice", e18(101).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "priceUpdateCount", "2")
    assert.entityCount("PriceUpdate", 2)
  })

  test("a fee balance is what accrued less what was claimed", () => {
    handleFeeAccrued(feeAccrued(KEEPER, e18(3)))
    handleFeeAccrued(feeAccrued(KEEPER, e18(2)))
    handleFeesClaimed(feesClaimed(KEEPER, e18(4)))
    let balance = PAIR.toHexString() + "-" + KEEPER.toHexString()
    assert.fieldEquals("FeeBalance", balance, "accrued", e18(5).toString())
    assert.fieldEquals("FeeBalance", balance, "claimed", e18(4).toString())
    assert.fieldEquals("FeeBalance", balance, "claimable", e18(1).toString())
    assert.fieldEquals("Account", KEEPER.toHexString(), "feesAccrued", e18(5).toString())
  })
})
