import { BigInt } from "@graphprotocol/graph-ts"
import {
  FeeAccrued,
  FeesClaimed,
  InsolvencySettlementFixed,
  MetaTransactionExecuted,
  NewPriceUpdateAdded,
  PairTerminated,
  PermitExecutionFailed,
  TerminalRatiosRefrozen,
} from "../../generated/templates/BazaarPair/BazaarPair"
import {
  AdlWindow,
  FeeAccrual,
  FeeClaim,
  MetaTransaction,
  PairTermination,
  PermitFailure,
  PriceUpdate,
  TerminalRatioUpdate,
} from "../../generated/schema"
import { ONE, PAIR_SETTLEMENT_FIXED, PAIR_TERMINATED, ZERO } from "../constants"
import { advancePairStatus, eventId, getOrCreateAccount, getOrCreateFeeBalance, loadPair } from "../helpers"
import { getPairDayData } from "../market"

// Fires only when a price is stored, and the funding index moves only then, so consecutive
// updates bracket every change in funding.
export function handleNewPriceUpdateAdded(event: NewPriceUpdateAdded): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let publishTs = event.params.targetPublishTs
  let fundingIndex = event.params.fundingIndex
  let previousPublishTs = pair.lastPricePublishTs

  let update = new PriceUpdate(eventId(event))
  update.pair = pair.id
  update.price = event.params.spotPrice
  update.publishTs = publishTs
  update.fundingIndex = fundingIndex
  update.fundingIndexDelta = fundingIndex.minus(pair.fundingIndex)
  update.secondsSincePrevious = ZERO
  if (previousPublishTs !== null) update.secondsSincePrevious = publishTs.minus(previousPublishTs as BigInt)
  update.blockNumber = event.block.number
  update.timestamp = event.block.timestamp
  update.transactionHash = event.transaction.hash
  update.save()

  pair.lastPrice = event.params.spotPrice
  pair.lastPricePublishTs = publishTs
  pair.lastPriceUpdate = update.id
  pair.fundingIndex = fundingIndex
  pair.priceUpdateCount = pair.priceUpdateCount.plus(ONE)
  pair.save()

  let day = getPairDayData(pair, event.block.timestamp)
  day.fundingIndex = fundingIndex
  day.save()
}

// Every third-party payout accrues to a claimable balance on the pair; a trigger bounty's
// assignment emits this alongside TriggerBountyReleased.
export function handleFeeAccrued(event: FeeAccrued): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let amount = event.params.amount
  let balance = getOrCreateFeeBalance(pair.id, event.params.recipient, event.block.timestamp)
  balance.accrued = balance.accrued.plus(amount)
  balance.claimable = balance.claimable.plus(amount)
  balance.save()

  let account = getOrCreateAccount(event.params.recipient, event.block.timestamp)
  account.feesAccrued = account.feesAccrued.plus(amount)
  account.save()

  let record = new FeeAccrual(eventId(event))
  record.pair = pair.id
  record.recipient = event.params.recipient
  record.amount = amount
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}

export function handleFeesClaimed(event: FeesClaimed): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let amount = event.params.amount
  let balance = getOrCreateFeeBalance(pair.id, event.params.recipient, event.block.timestamp)
  balance.claimed = balance.claimed.plus(amount)
  let claimable = balance.claimable.minus(amount)
  balance.claimable = claimable.lt(ZERO) ? ZERO : claimable
  balance.save()

  let account = getOrCreateAccount(event.params.recipient, event.block.timestamp)
  account.feesClaimed = account.feesClaimed.plus(amount)
  account.save()

  let record = new FeeClaim(eventId(event))
  record.pair = pair.id
  record.recipient = event.params.recipient
  record.amount = amount
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}

export function handleMetaTransactionExecuted(event: MetaTransactionExecuted): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let user = getOrCreateAccount(event.params.user, event.block.timestamp)
  let relayer = getOrCreateAccount(event.params.relayer, event.block.timestamp)
  let record = new MetaTransaction(eventId(event))
  record.pair = pair.id
  record.user = user.id
  record.relayer = relayer.id
  record.functionId = event.params.functionId
  record.nonce = event.params.nonce
  record.relayerFee = event.params.relayerFee
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}

export function handlePermitExecutionFailed(event: PermitExecutionFailed): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let record = new PermitFailure(eventId(event))
  record.pair = pair.id
  record.owner = event.params.owner
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}

// The pair's own insolvency verdict fixed the settlement price. Governed paths report the same
// step through the terminator's SettlementPriceFixed.
export function handleInsolvencySettlementFixed(event: InsolvencySettlementFixed): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  pair.settlementPrice = event.params.settlementPrice
  pair.settlementFixedAt = event.block.timestamp
  pair.settlementSource = "Insolvency"
  pair.insolvencyReason = event.params.reason
  advancePairStatus(pair, PAIR_SETTLEMENT_FIXED)
  pair.save()
}

// Finalize clears an ADL window still pending, and PairTerminated is the only event marking
// its end.
export function handlePairTerminated(event: PairTerminated): void {
  let pair = loadPair(event.address)
  if (pair == null) return

  let record = new PairTermination(eventId(event))
  record.pair = pair.id
  record.settlementPrice = event.params.settlementPrice
  record.owedToTraders = event.params.owedToTraders
  record.registeredClaims = event.params.registeredClaims
  record.badDebt = event.params.badDebt
  record.estateValue = event.params.estateValue
  record.pot = event.params.pot
  record.principalRatio = event.params.principalRatio
  record.profitRatio = event.params.profitRatio
  record.insuranceFundBalanceAfter = event.params.insuranceFundBalanceAfter
  record.sweepComplete = event.params.sweepComplete
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()

  let currentId = pair.currentAdlWindow
  if (currentId != null) {
    let window = AdlWindow.load(currentId as string)
    if (window != null) {
      window.endedByTermination = true
      window.save()
    }
  }
  pair.isAdlPending = false
  pair.currentAdlWindow = null
  pair.adlTerminationTs = null

  if (pair.settlementPrice === null) pair.settlementPrice = event.params.settlementPrice
  pair.terminatedAt = event.block.timestamp
  pair.termination = record.id
  pair.terminalPrincipalRatio = event.params.principalRatio
  pair.terminalProfitRatio = event.params.profitRatio
  advancePairStatus(pair, PAIR_TERMINATED)
  pair.save()
}

export function handleTerminalRatiosRefrozen(event: TerminalRatiosRefrozen): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let record = new TerminalRatioUpdate(eventId(event))
  record.pair = pair.id
  record.unfunded = event.params.unfunded
  record.principalRatio = event.params.principalRatio
  record.profitRatio = event.params.profitRatio
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()

  pair.terminalPrincipalRatio = event.params.principalRatio
  pair.terminalProfitRatio = event.params.profitRatio
  pair.save()
}
