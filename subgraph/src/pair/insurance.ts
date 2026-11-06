import { Address, BigInt, ethereum } from "@graphprotocol/graph-ts"
import {
  BazaarPair,
  InsuranceCredited,
  InsuranceDeposited,
  InsuranceShareEpochBumped,
  InsuranceWithdrawalExecuted,
  InsuranceWithdrawalLocked,
  InsuranceWithdrawalRequested,
} from "../../generated/templates/BazaarPair/BazaarPair"
import { InsuranceCredit, InsuranceEpochReset, InsuranceEvent, InsuranceProvider, Pair } from "../../generated/schema"
import { ZERO } from "../constants"
import { eventId, getOrCreateInsuranceProvider, loadPair } from "../helpers"
import { getPairDayData } from "../market"

// The pair's share supply. A deposit into a fund with no live shares also mints locked orphan
// shares to address(0), which no event reports, so the supply is read from the pair rather than
// summed from events; `fallback` is the summed figure, used only if the read fails.
function totalShares(pair: Address, fallback: BigInt): BigInt {
  let total = BazaarPair.bind(pair).try_totalInsuranceShares()
  return total.reverted ? fallback : total.value
}

function saveInsuranceEvent(
  event: ethereum.Event,
  pair: Pair,
  provider: InsuranceProvider,
  kind: string,
  amount: BigInt,
  shares: BigInt,
): InsuranceEvent {
  let record = new InsuranceEvent(eventId(event))
  record.pair = pair.id
  record.provider = provider.id
  record.account = provider.account
  record.kind = kind
  record.amount = amount
  record.shares = shares
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  return record
}

function clearRequest(provider: InsuranceProvider): void {
  provider.requestedShares = ZERO
  provider.requestedAt = null
  provider.lockedAmount = null
  provider.claimOpensTs = null
}

export function handleInsuranceDeposited(event: InsuranceDeposited): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let amount = event.params.amount
  let shares = event.params.sharesReceived
  let provider = getOrCreateInsuranceProvider(pair, event.params.user, event.block.timestamp)
  provider.shares = provider.shares.plus(shares)
  provider.deposited = provider.deposited.plus(amount)
  provider.depositCount = provider.depositCount + 1
  provider.save()
  saveInsuranceEvent(event, pair, provider, "Deposit", amount, shares).save()

  pair.insuranceDeposited = pair.insuranceDeposited.plus(amount)
  pair.totalInsuranceShares = totalShares(event.address, pair.totalInsuranceShares.plus(shares))
  pair.save()

  let day = getPairDayData(pair, event.block.timestamp)
  day.insuranceDeposited = day.insuranceDeposited.plus(amount)
  day.save()
}

// Filing again replaces the request in force and voids any lock it made.
export function handleInsuranceWithdrawalRequested(event: InsuranceWithdrawalRequested): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let provider = getOrCreateInsuranceProvider(pair, event.params.user, event.block.timestamp)
  provider.requestedShares = event.params.shareAmount
  provider.requestedAt = event.block.timestamp
  provider.lockedAmount = null
  provider.claimOpensTs = null
  provider.save()
  saveInsuranceEvent(event, pair, provider, "WithdrawalRequested", ZERO, event.params.shareAmount).save()
  pair.save()
}

// The first execute call inside the window records what the requested shares are worth and pays
// nothing; the paying call opens at claimOpensTs.
export function handleInsuranceWithdrawalLocked(event: InsuranceWithdrawalLocked): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let provider = getOrCreateInsuranceProvider(pair, event.params.user, event.block.timestamp)
  provider.lockedAmount = event.params.lockedAmount
  provider.claimOpensTs = event.params.claimOpensTs
  provider.save()
  let record = saveInsuranceEvent(
    event,
    pair,
    provider,
    "WithdrawalLocked",
    event.params.lockedAmount,
    event.params.shareAmount,
  )
  record.claimOpensTs = event.params.claimOpensTs
  record.save()
  pair.save()
}

// `shareAmount` is the shares this call redeemed. While the vault holds inventory a payout can be
// held to the fund's headroom; the shares it did not redeem stay requested under the same lock,
// scaled to what is left.
export function handleInsuranceWithdrawalExecuted(event: InsuranceWithdrawalExecuted): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let paid = event.params.shareAmount
  let usdc = event.params.usdcAmount
  let provider = getOrCreateInsuranceProvider(pair, event.params.user, event.block.timestamp)

  let shares = provider.shares.minus(paid)
  provider.shares = shares.lt(ZERO) ? ZERO : shares
  provider.withdrawn = provider.withdrawn.plus(usdc)

  let requested = provider.requestedShares
  let rest = requested.minus(paid)
  if (rest.le(ZERO)) {
    clearRequest(provider)
  } else {
    let locked = provider.lockedAmount
    if (locked !== null) provider.lockedAmount = (locked as BigInt).times(rest).div(requested)
    provider.requestedShares = rest
  }
  provider.save()
  saveInsuranceEvent(event, pair, provider, "WithdrawalExecuted", usdc, paid).save()

  pair.insuranceWithdrawn = pair.insuranceWithdrawn.plus(usdc)
  let fallback = pair.totalInsuranceShares.minus(paid)
  pair.totalInsuranceShares = totalShares(event.address, fallback.lt(ZERO) ? ZERO : fallback)
  pair.save()

  let day = getPairDayData(pair, event.block.timestamp)
  day.insuranceWithdrawn = day.insuranceWithdrawn.plus(usdc)
  day.save()
}

// A dead-pool reset: bad debt wiped the fund below 1 USD while shares existed, and the deposit
// rescuing it starts a new share generation in which every earlier balance reads 0. The pair
// invalidates balances lazily; the subgraph zeroes them eagerly by walking every provider the
// pair has had. A request in force dies with its shares. The rescuing deposit's
// InsuranceDeposited follows in the same transaction and sets the new supply.
export function handleInsuranceShareEpochBumped(event: InsuranceShareEpochBumped): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  let reset = 0
  let cursor = pair.lastInsuranceProvider
  while (cursor != null) {
    let provider = InsuranceProvider.load(cursor as string)
    if (provider == null) break
    if (!provider.shares.isZero() || !provider.requestedShares.isZero()) {
      provider.shares = ZERO
      clearRequest(provider)
      provider.save()
      reset = reset + 1
    }
    cursor = provider.previous
  }

  pair.insuranceShareEpoch = event.params.newEpoch
  pair.totalInsuranceShares = ZERO
  pair.save()

  let record = new InsuranceEpochReset(eventId(event))
  record.pair = pair.id
  record.newEpoch = event.params.newEpoch
  record.providersReset = reset
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}

export function handleInsuranceCredited(event: InsuranceCredited): void {
  let pair = loadPair(event.address)
  if (pair == null) return
  pair.insuranceCredited = pair.insuranceCredited.plus(event.params.amountBazaarPrecision)
  pair.save()

  let record = new InsuranceCredit(eventId(event))
  record.pair = pair.id
  record.from = event.params.from
  record.amount = event.params.amountBazaarPrecision
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}
