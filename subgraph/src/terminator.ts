import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts"
import { BazaarPair } from "../generated/BazaarPairTerminator/BazaarPair"
import {
  InsurerLevyCharged,
  InsurerTerminationBondRefundFailed,
  InsurerTerminationFailed,
  InsurerTerminationOutcome,
  InsurerTerminationPreempted,
  InsurerTerminationProposed,
  InsurerTerminationRejected,
  InsurerTerminationScheduled,
  InsurerTerminationSnapshot,
  InsurerTerminationVoided,
  InsurerTerminationVoted,
  SettlementPriceFixed,
  StalePairTerminated,
  TerminationProposalAccepted,
  TerminationProposalDisputed,
  TerminationProposalRejected,
  TerminationProposalSubmitted,
  TerminationProposalSuperseded,
  TerminationScheduleRefused,
} from "../generated/BazaarPairTerminator/BazaarPairTerminator"
import {
  InsuranceEvent,
  InsurerLevy,
  InsurerProposal,
  InsurerVote,
  Pair,
  TerminationProposal,
} from "../generated/schema"
import { PAIR_SCHEDULED, PAIR_SETTLEMENT_FIXED, TERMINATION_PROPOSAL_LIVENESS, ZERO, ZERO_ADDRESS } from "./constants"
import { advancePairStatus, eventId, getOrCreateAccount, getOrCreateInsuranceProvider, loadPair } from "./helpers"

// Reads the cutoff from the pair. The events that schedule a pair do not settle the question on
// their own: an acceptance can leave an earlier insurer cutoff in force, and the pair raises a
// cutoff that comes too soon to its minimum lead.
function refreshSchedule(pair: Pair): void {
  let scheduled = BazaarPair.bind(Address.fromBytes(pair.id)).try_scheduledTerminationTs()
  if (scheduled.reverted || scheduled.value.isZero()) return
  pair.scheduledTerminationTs = scheduled.value
  advancePairStatus(pair, PAIR_SCHEDULED)
}

// ---------------------------------------------------------------------------------------------
// UMA termination claims
// ---------------------------------------------------------------------------------------------

export function handleTerminationProposalSubmitted(event: TerminationProposalSubmitted): void {
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  let proposer = getOrCreateAccount(event.params.proposer, event.block.timestamp)
  let proposal = new TerminationProposal(event.params.assertionId)
  proposal.pair = pair.id
  proposal.proposer = proposer.id
  proposal.category = event.params.category
  proposal.lastTradingTs = event.params.lastTradingTs
  proposal.reason = event.params.reason
  proposal.status = "Pending"
  proposal.disputed = false
  proposal.submittedAt = event.block.timestamp
  proposal.livenessEndsAt = event.block.timestamp.plus(TERMINATION_PROPOSAL_LIVENESS)
  proposal.transactionHash = event.transaction.hash
  proposal.save()
}

export function handleTerminationProposalDisputed(event: TerminationProposalDisputed): void {
  let proposal = TerminationProposal.load(event.params.assertionId)
  if (proposal == null) return
  proposal.disputed = true
  if (proposal.status == "Pending") proposal.status = "Disputed"
  proposal.save()
}

function resolveTermination(assertionId: Bytes, status: string, event: ethereum.Event): TerminationProposal | null {
  let proposal = TerminationProposal.load(assertionId)
  if (proposal == null) return null
  proposal.status = status
  proposal.resolvedAt = event.block.timestamp
  return proposal
}

export function handleTerminationProposalAccepted(event: TerminationProposalAccepted): void {
  let proposal = resolveTermination(event.params.assertionId, "Accepted", event)
  if (proposal != null) {
    proposal.acceptedCutoffTs = event.params.lastTradingTs
    proposal.save()
  }
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  refreshSchedule(pair)
  pair.save()
}

export function handleTerminationScheduleRefused(event: TerminationScheduleRefused): void {
  let proposal = resolveTermination(event.params.assertionId, "ScheduleRefused", event)
  if (proposal != null) proposal.save()
}

export function handleTerminationProposalSuperseded(event: TerminationProposalSuperseded): void {
  let proposal = resolveTermination(event.params.assertionId, "Superseded", event)
  if (proposal != null) proposal.save()
}

export function handleTerminationProposalRejected(event: TerminationProposalRejected): void {
  let proposal = resolveTermination(event.params.assertionId, "Rejected", event)
  if (proposal != null) proposal.save()
}

// ---------------------------------------------------------------------------------------------
// Settlement price
// ---------------------------------------------------------------------------------------------

// Emitted just before the SettlementPriceFixed of the same call, so the source it records is
// already in place when that handler runs.
export function handleStalePairTerminated(event: StalePairTerminated): void {
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  pair.settlementSource = "Stale"
  pair.staleOracleLastUpdateTs = event.params.oracleLastUpdateTs
  pair.save()
}

export function handleSettlementPriceFixed(event: SettlementPriceFixed): void {
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  pair.settlementPrice = event.params.settlementPrice
  pair.settlementFixedAt = event.block.timestamp
  if (pair.settlementSource == null) pair.settlementSource = "Cutoff"
  advancePairStatus(pair, PAIR_SETTLEMENT_FIXED)
  pair.save()
}

// ---------------------------------------------------------------------------------------------
// Insurer votes
// ---------------------------------------------------------------------------------------------

export function handleInsurerTerminationProposed(event: InsurerTerminationProposed): void {
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  let proposer = getOrCreateAccount(event.params.proposer, event.block.timestamp)
  let proposal = new InsurerProposal(event.params.id)
  proposal.pair = pair.id
  proposal.proposer = proposer.id
  proposal.cutoffTs = event.params.cutoffTs
  proposal.windowOpenTs = event.params.windowOpenTs
  proposal.claimBacked = event.params.claimBacked
  proposal.yesShares = ZERO
  proposal.status = "Open"
  proposal.bondRefundFailed = false
  proposal.createdAt = event.block.timestamp
  proposal.transactionHash = event.transaction.hash
  proposal.save()
}

export function handleInsurerTerminationSnapshot(event: InsurerTerminationSnapshot): void {
  let proposal = InsurerProposal.load(event.params.id)
  if (proposal == null) return
  proposal.snapshotTotalShares = event.params.snapshotTotalShares
  proposal.snapshotShareEpoch = event.params.shareEpoch
  proposal.save()
}

export function handleInsurerTerminationVoted(event: InsurerTerminationVoted): void {
  let proposal = InsurerProposal.load(event.params.id)
  if (proposal == null) return
  proposal.yesShares = event.params.totalYesShares
  proposal.save()

  let voter = getOrCreateAccount(event.params.voter, event.block.timestamp)
  let vote = new InsurerVote(eventId(event))
  vote.proposal = proposal.id
  vote.pair = proposal.pair
  vote.voter = voter.id
  vote.amount = event.params.amount
  vote.totalYesShares = event.params.totalYesShares
  vote.blockNumber = event.block.number
  vote.timestamp = event.block.timestamp
  vote.transactionHash = event.transaction.hash
  vote.save()
}

function resolveInsurer(id: Bytes, status: string, event: ethereum.Event): InsurerProposal | null {
  let proposal = InsurerProposal.load(id)
  if (proposal == null) return null
  proposal.status = status
  proposal.resolvedAt = event.block.timestamp
  return proposal
}

export function handleInsurerTerminationScheduled(event: InsurerTerminationScheduled): void {
  let proposal = resolveInsurer(event.params.id, "Scheduled", event)
  if (proposal != null) {
    proposal.yesShares = event.params.yesShares
    proposal.save()
  }
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  refreshSchedule(pair)
  pair.save()
}

export function handleInsurerTerminationFailed(event: InsurerTerminationFailed): void {
  let proposal = resolveInsurer(event.params.id, "Failed", event)
  if (proposal == null) return
  proposal.yesShares = event.params.yesShares
  proposal.thresholdMet = event.params.thresholdMet
  proposal.save()
}

export function handleInsurerTerminationPreempted(event: InsurerTerminationPreempted): void {
  let proposal = resolveInsurer(event.params.id, "Preempted", event)
  if (proposal != null) proposal.save()
}

export function handleInsurerTerminationVoided(event: InsurerTerminationVoided): void {
  let proposal = resolveInsurer(event.params.id, "Voided", event)
  if (proposal != null) proposal.save()
}

export function handleInsurerTerminationRejected(event: InsurerTerminationRejected): void {
  let proposal = resolveInsurer(event.params.id, "Rejected", event)
  if (proposal != null) proposal.save()
}

export function handleInsurerTerminationOutcome(event: InsurerTerminationOutcome): void {
  let proposal = InsurerProposal.load(event.params.id)
  if (proposal == null) return
  proposal.outcome = event.params.outcome
  proposal.costed = event.params.costed
  proposal.levyBp = event.params.levyBp
  proposal.save()
}

export function handleInsurerTerminationBondRefundFailed(event: InsurerTerminationBondRefundFailed): void {
  let proposal = InsurerProposal.load(event.params.id)
  if (proposal == null) return
  proposal.bondRefundFailed = true
  proposal.save()
}

// A yes-voter's redemption on a terminated pair forfeits part of the voted stake. The shares move
// to the recipient inside the same redemption, ahead of the pair's InsuranceWithdrawalExecuted,
// and come out of the shares the redemption was requested for.
export function handleInsurerLevyCharged(event: InsurerLevyCharged): void {
  let pair = loadPair(event.params.pair)
  if (pair == null) return
  let levy = event.params.levyShares
  let timestamp = event.block.timestamp

  let voter = getOrCreateInsuranceProvider(pair, event.params.voter, timestamp)
  let shares = voter.shares.minus(levy)
  voter.shares = shares.lt(ZERO) ? ZERO : shares
  let requested = voter.requestedShares.minus(levy)
  voter.requestedShares = requested.lt(ZERO) ? ZERO : requested
  voter.levyChargedShares = voter.levyChargedShares.plus(levy)
  voter.save()
  saveInsuranceEvent(event, pair, voter.id, event.params.voter, "LevyCharged", levy, 0)

  let recipient = event.params.recipient
  if (!recipient.equals(ZERO_ADDRESS)) {
    let receiver = getOrCreateInsuranceProvider(pair, recipient, timestamp)
    receiver.shares = receiver.shares.plus(levy)
    receiver.levyReceivedShares = receiver.levyReceivedShares.plus(levy)
    receiver.save()
    saveInsuranceEvent(event, pair, receiver.id, recipient, "LevyReceived", levy, 1)
  }
  pair.save()

  let record = new InsurerLevy(eventId(event))
  record.proposal = event.params.id
  record.pair = pair.id
  record.voter = event.params.voter
  record.votedShares = event.params.votedShares
  record.levyShares = levy
  record.recipient = recipient
  record.blockNumber = event.block.number
  record.timestamp = timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}

// One levy log produces two insurance records; `slot` keeps their IDs apart.
function saveInsuranceEvent(
  event: ethereum.Event,
  pair: Pair,
  providerId: string,
  account: Address,
  kind: string,
  shares: BigInt,
  slot: i32,
): void {
  let record = new InsuranceEvent(eventId(event).concatI32(slot))
  record.pair = pair.id
  record.provider = providerId
  record.account = account
  record.kind = kind
  record.amount = ZERO
  record.shares = shares
  record.blockNumber = event.block.number
  record.timestamp = event.block.timestamp
  record.transactionHash = event.transaction.hash
  record.save()
}
