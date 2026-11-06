import { Address, BigInt, log } from "@graphprotocol/graph-ts"

export const ZERO = BigInt.zero()
export const ONE = BigInt.fromI32(1)
// BAZAAR precision: every price, size, notional and USD amount carries 18 decimals.
export const SCALE = BigInt.fromString("1000000000000000000")
export const ZERO_ADDRESS = Address.zero()

export const PROTOCOL_ID = "bazaar"
export const SECONDS_PER_DAY = BigInt.fromI32(86400)

// Candle intervals in seconds: 1m, 5m, 15m, 1h, 4h, 1d.
export const CANDLE_INTERVALS: i32[] = [60, 300, 900, 3600, 14400, 86400]

// UMA liveness of each assertion kind, mirrored from the contracts so a keeper can see when an
// undisputed assertion becomes settleable: BazaarFactory.DEPLOYMENT_LIVENESS,
// BazaarFactory.IDENTIFIER_UPGRADE_LIVENESS and BazaarPairTerminator.TERMINATION_PROPOSAL_LIVENESS.
export const DEPLOYMENT_LIVENESS = BigInt.fromI32(48 * 3600)
export const IDENTIFIER_UPGRADE_LIVENESS = BigInt.fromI32(2 * 86400)
export const TERMINATION_PROPOSAL_LIVENESS = BigInt.fromI32(12 * 3600)

// BazaarTypes.OrderType
export const ORDER_TYPE_MARKET: i32 = 0
export const ORDER_TYPE_LIMIT: i32 = 1
export const ORDER_TYPE_STOP_LIMIT: i32 = 2
export const ORDER_TYPE_TAKE_PROFIT: i32 = 3
export const ORDER_TYPE_STOP_LOSS: i32 = 4

// BazaarTypes.OrderAction
export const ACTION_CREATED: i32 = 0
export const ACTION_TRIGGERED: i32 = 1
export const ACTION_CANCELED: i32 = 2

// BazaarTypes.TimeInForce
export const TIF_GTC: i32 = 0

// OrderStatus values
export const STATUS_WAITING = "Waiting"
export const STATUS_PENDING = "Pending"
export const STATUS_RESTING = "Resting"
export const STATUS_FIRED = "Fired"
export const STATUS_FILLED = "Filled"
export const STATUS_CANCELED = "Canceled"

// PairStatus values, in the only order a pair moves through them.
export const PAIR_ACTIVE = "Active"
export const PAIR_SCHEDULED = "Scheduled"
export const PAIR_SETTLEMENT_FIXED = "SettlementFixed"
export const PAIR_TERMINATED = "Terminated"

const ORDER_TYPES: string[] = ["Market", "Limit", "StopLimit", "TakeProfit", "StopLoss"]
const TIME_IN_FORCE: string[] = ["GTC", "IOC", "FOK"]
const CANCEL_REASONS: string[] = [
  "None",
  "Owner",
  "Expired",
  "Unfilled",
  "BelowMinimum",
  "PostOnly",
  "SelfMatch",
  "StepLimit",
  "Margin",
  "PriceBand",
  "PositionClosed",
  "Liquidated",
  "Deleveraged",
]
const AMEND_SKIP_REASONS: string[] = ["Inactive", "Expired", "SizeFilled", "BelowMinimum", "WouldCross"]

// The tables above are the contracts' enums in declaration order. A value outside a table can
// only come from contracts built after this subgraph; it is logged and mapped to the table's
// first entry rather than aborting the handler, which would halt indexing for every pair.
function lookup(table: string[], value: i32, name: string): string {
  if (value < 0 || value >= table.length) {
    log.error("Unknown {} value {}", [name, value.toString()])
    return table[0]
  }
  return table[value]
}

export function orderTypeName(value: i32): string {
  return lookup(ORDER_TYPES, value, "OrderType")
}

export function timeInForceName(value: i32): string {
  return lookup(TIME_IN_FORCE, value, "TimeInForce")
}

export function cancelReasonName(value: i32): string {
  return lookup(CANCEL_REASONS, value, "CancelReason")
}

export function amendSkipReasonName(value: i32): string {
  return lookup(AMEND_SKIP_REASONS, value, "AmendSkipReason")
}

// StopLimit, TakeProfit and StopLoss wait for a trigger before they trade.
export function isTriggerGated(orderType: i32): boolean {
  return (
    orderType == ORDER_TYPE_STOP_LIMIT || orderType == ORDER_TYPE_TAKE_PROFIT || orderType == ORDER_TYPE_STOP_LOSS
  )
}
