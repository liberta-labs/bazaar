import { Bytes } from "@graphprotocol/graph-ts"
import {
  BazaarFactory,
  PairDeployed,
  PairDeploymentProposalDisputed,
  PairDeploymentProposalExpired,
  PairDeploymentProposalResolved,
  PairDeploymentProposed,
  SeedRefundClaimed,
  SeedRefundCredited,
  UmaIdentifierUpgradeCanceled,
  UmaIdentifierUpgradeDisputed,
  UmaIdentifierUpgradeExpired,
  UmaIdentifierUpgradeProposed,
  UmaIdentifierUpgradeQueued,
  UmaIdentifierUpgraded,
} from "../generated/BazaarFactory/BazaarFactory"
import { BazaarPair as BazaarPairTemplate } from "../generated/templates"
import {
  IdentifierUpgradeProposal,
  InsuranceEvent,
  ListingLookup,
  ListingProposal,
  Pair,
  Protocol,
} from "../generated/schema"
import { DEPLOYMENT_LIVENESS, IDENTIFIER_UPGRADE_LIVENESS, PAIR_ACTIVE, ZERO } from "./constants"
import { eventId, getOrCreateAccount, getOrCreateInsuranceProvider, getProtocol } from "./helpers"

// Records the factory address and, the first time, the identifier the factory was deployed with:
// UmaIdentifierUpgraded reports every later change, but the initial value is in no event.
function protocolFor(factory: BazaarFactory): Protocol {
  let protocol = getProtocol()
  if (protocol.factory === null) {
    protocol.factory = factory._address
  }
  if (protocol.umaIdentifier === null) {
    let identifier = factory.try_umaIdentifier()
    if (!identifier.reverted) {
      protocol.umaIdentifier = identifier.value
    }
  }
  return protocol
}

export function handlePairDeployed(event: PairDeployed): void {
  let timestamp = event.block.timestamp
  let protocol = protocolFor(BazaarFactory.bind(event.address))
  protocol.pairCount = protocol.pairCount + 1
  protocol.save()

  let deployer = getOrCreateAccount(event.params.deployer, timestamp)
  let seed = event.params.seedAmount

  let pair = new Pair(event.params.pairAddress)
  pair.pairId = event.params.pairId
  pair.factory = event.address
  pair.deployer = deployer.id
  pair.baseFeedId = event.params.baseFeedId
  pair.description = event.params.description
  pair.isContinuouslyTraded = event.params.isContinuouslyTraded
  pair.seedAmount = seed
  pair.createdAtBlock = event.block.number
  pair.createdAtTimestamp = timestamp
  pair.createdTx = event.transaction.hash
  pair.status = PAIR_ACTIVE
  pair.fundingIndex = ZERO
  pair.priceUpdateCount = ZERO
  pair.tradeCount = ZERO
  pair.volumeSize = ZERO
  pair.volumeNotional = ZERO
  pair.makerFees = ZERO
  pair.takerFees = ZERO
  pair.vaultFillCount = ZERO
  pair.vaultFillSize = ZERO
  pair.vaultFillNotional = ZERO
  pair.openInterestLong = ZERO
  pair.openInterestShort = ZERO
  pair.openPositionCount = 0
  pair.orderCount = ZERO
  pair.restingBidCount = 0
  pair.restingAskCount = 0
  pair.totalInsuranceShares = seed
  pair.insuranceShareEpoch = ZERO
  pair.insuranceDeposited = seed
  pair.insuranceWithdrawn = ZERO
  pair.insuranceCredited = ZERO
  pair.insuranceProviderCount = 0
  pair.liquidationCount = ZERO
  pair.liquidatedSize = ZERO
  pair.liquidatedNotional = ZERO
  pair.collateralSeized = ZERO
  pair.isAdlPending = false
  pair.adlEpoch = ZERO
  pair.adlBatchCount = ZERO

  let lookup = ListingLookup.load(event.params.pairId)
  if (lookup != null) {
    pair.listing = lookup.listing
    let listing = ListingProposal.load(lookup.listing)
    if (listing != null) {
      listing.pair = pair.id
      listing.status = "Deployed"
      listing.save()
    }
  }

  // The pair mints its seed 1:1 to the deployer as genesis insurance shares when it initializes,
  // which no pair event reports.
  if (!seed.isZero()) {
    let provider = getOrCreateInsuranceProvider(pair, event.params.deployer, timestamp)
    provider.shares = provider.shares.plus(seed)
    provider.deposited = provider.deposited.plus(seed)
    provider.depositCount = provider.depositCount + 1
    provider.save()

    let record = new InsuranceEvent(eventId(event))
    record.pair = pair.id
    record.provider = provider.id
    record.account = event.params.deployer
    record.kind = "Deposit"
    record.amount = seed
    record.shares = seed
    record.blockNumber = event.block.number
    record.timestamp = timestamp
    record.transactionHash = event.transaction.hash
    record.save()
  }

  pair.save()
  BazaarPairTemplate.create(event.params.pairAddress)
}

export function handlePairDeploymentProposed(event: PairDeploymentProposed): void {
  protocolFor(BazaarFactory.bind(event.address)).save()
  let deployer = getOrCreateAccount(event.params.deployer, event.block.timestamp)

  let listing = new ListingProposal(event.params.assertionId)
  listing.pairId = event.params.pairId
  listing.deployer = deployer.id
  listing.baseFeedId = event.params.baseFeedId
  listing.description = event.params.description
  listing.seedAmount = event.params.seedAmount
  listing.status = "Pending"
  listing.disputed = false
  listing.proposedAt = event.block.timestamp
  listing.livenessEndsAt = event.block.timestamp.plus(DEPLOYMENT_LIVENESS)
  listing.transactionHash = event.transaction.hash
  listing.save()

  let lookup = new ListingLookup(event.params.pairId)
  lookup.listing = listing.id
  lookup.save()
}

export function handlePairDeploymentProposalDisputed(event: PairDeploymentProposalDisputed): void {
  let listing = ListingProposal.load(event.params.assertionId)
  if (listing == null) return
  listing.disputed = true
  if (listing.status == "Pending") listing.status = "Disputed"
  listing.save()
}

export function handlePairDeploymentProposalResolved(event: PairDeploymentProposalResolved): void {
  let listing = ListingProposal.load(event.params.assertionId)
  if (listing == null) return
  listing.status = event.params.deployed ? "Deployed" : "Rejected"
  listing.resolvedAt = event.block.timestamp
  listing.save()
}

export function handlePairDeploymentProposalExpired(event: PairDeploymentProposalExpired): void {
  let listing = ListingProposal.load(event.params.assertionId)
  if (listing == null) return
  listing.status = "Expired"
  listing.resolvedAt = event.block.timestamp
  listing.save()
}

export function handleSeedRefundCredited(event: SeedRefundCredited): void {
  let listing = ListingProposal.load(event.params.assertionId)
  if (listing != null) {
    listing.seedRefundUsdc = event.params.amountUsdc
    listing.save()
  }
  let account = getOrCreateAccount(event.params.deployer, event.block.timestamp)
  account.seedRefundOwedUsdc = account.seedRefundOwedUsdc.plus(event.params.amountUsdc)
  account.save()
}

export function handleSeedRefundClaimed(event: SeedRefundClaimed): void {
  let account = getOrCreateAccount(event.params.deployer, event.block.timestamp)
  let owed = account.seedRefundOwedUsdc.minus(event.params.amountUsdc)
  account.seedRefundOwedUsdc = owed.lt(ZERO) ? ZERO : owed
  account.save()
}

export function handleUmaIdentifierUpgradeProposed(event: UmaIdentifierUpgradeProposed): void {
  // The account first: creating one updates the protocol's account count, which a protocol entity
  // loaded before it would overwrite when saved.
  let proposer = getOrCreateAccount(event.params.proposer, event.block.timestamp)
  let protocol = protocolFor(BazaarFactory.bind(event.address))

  // The factory holds one pending proposal at a time and clears the slot before accepting a new
  // one. A predecessor still pending or disputed here was settled without an event, which happens
  // only when UMA upheld a dispute against it.
  let previousId = protocol.pendingIdentifierUpgrade
  if (previousId !== null) {
    let previous = IdentifierUpgradeProposal.load(previousId as Bytes)
    if (previous != null && (previous.status == "Pending" || previous.status == "Disputed")) {
      previous.status = "Rejected"
      previous.save()
    }
  }

  let upgrade = new IdentifierUpgradeProposal(event.params.assertionId)
  upgrade.proposer = proposer.id
  upgrade.newIdentifier = event.params.newIdentifier
  upgrade.status = "Pending"
  upgrade.disputed = false
  upgrade.proposedAt = event.block.timestamp
  upgrade.livenessEndsAt = event.block.timestamp.plus(IDENTIFIER_UPGRADE_LIVENESS)
  upgrade.transactionHash = event.transaction.hash
  upgrade.save()

  protocol.pendingIdentifierUpgrade = upgrade.id
  protocol.save()
}

export function handleUmaIdentifierUpgradeDisputed(event: UmaIdentifierUpgradeDisputed): void {
  let upgrade = IdentifierUpgradeProposal.load(event.params.assertionId)
  if (upgrade == null) return
  upgrade.disputed = true
  if (upgrade.status == "Pending") upgrade.status = "Disputed"
  upgrade.save()
}

export function handleUmaIdentifierUpgradeQueued(event: UmaIdentifierUpgradeQueued): void {
  let upgrade = IdentifierUpgradeProposal.load(event.params.assertionId)
  if (upgrade != null) {
    upgrade.status = "Queued"
    upgrade.effectiveTs = event.params.effectiveTs
    upgrade.resolvedAt = event.block.timestamp
    upgrade.save()
  }
  let protocol = protocolFor(BazaarFactory.bind(event.address))
  protocol.pendingIdentifierUpgrade = null
  protocol.queuedIdentifierUpgrade = event.params.assertionId
  protocol.save()
}

export function handleUmaIdentifierUpgraded(event: UmaIdentifierUpgraded): void {
  let upgrade = IdentifierUpgradeProposal.load(event.params.assertionId)
  if (upgrade != null) {
    upgrade.status = "Upgraded"
    upgrade.oldIdentifier = event.params.oldIdentifier
    upgrade.save()
  }
  let protocol = protocolFor(BazaarFactory.bind(event.address))
  protocol.umaIdentifier = event.params.newIdentifier
  protocol.queuedIdentifierUpgrade = null
  protocol.save()
}

export function handleUmaIdentifierUpgradeCanceled(event: UmaIdentifierUpgradeCanceled): void {
  let upgrade = IdentifierUpgradeProposal.load(event.params.assertionId)
  if (upgrade != null) {
    upgrade.status = "Canceled"
    upgrade.save()
  }
  let protocol = protocolFor(BazaarFactory.bind(event.address))
  protocol.queuedIdentifierUpgrade = null
  protocol.save()
}

export function handleUmaIdentifierUpgradeExpired(event: UmaIdentifierUpgradeExpired): void {
  let upgrade = IdentifierUpgradeProposal.load(event.params.assertionId)
  if (upgrade != null) {
    upgrade.status = "Expired"
    upgrade.resolvedAt = event.block.timestamp
    upgrade.save()
  }
  let protocol = protocolFor(BazaarFactory.bind(event.address))
  protocol.pendingIdentifierUpgrade = null
  protocol.save()
}
