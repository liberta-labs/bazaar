import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import { assert, beforeEach, clearStore, describe, test } from "matchstick-as/assembly/index"
import {
  handlePairDeployed,
  handlePairDeploymentProposalVoided,
  handlePairDeploymentProposed,
  handleUmaIdentifierUpgradeDisputed,
  handleUmaIdentifierUpgradeProposed,
} from "../src/factory"
import { eventId } from "../src/helpers"
import { handlePairTerminated } from "../src/pair/lifecycle"
import { handlePositionBucketUpdated } from "../src/pair/positions"
import { handleAdlExecuted, handleAdlResolved, handleAdlTriggered, handleUserAdld } from "../src/pair/risk"
import {
  handleSettlementPriceFixed,
  handleStalePairTerminated,
  handleTerminationProposalAccepted,
  handleTerminationProposalSubmitted,
} from "../src/terminator"
import {
  ALICE,
  CAROL,
  PAIR,
  SEED,
  adlExecuted,
  adlResolved,
  adlTriggered,
  bucketUpdated,
  deployPair,
  e18,
  identifierUpgradeDisputed,
  identifierUpgradeProposed,
  mockFactoryReads,
  mockSchedule,
  pairDeployed,
  pairDeploymentProposalVoided,
  pairDeploymentProposed,
  pairTerminated,
  settlementPriceFixed,
  stalePairTerminated,
  terminationAccepted,
  terminationSubmitted,
  userAdld,
} from "./utils"

const ASSERTION_A = Bytes.fromHexString("0xaaaa000000000000000000000000000000000000000000000000000000000000")
const ASSERTION_B = Bytes.fromHexString("0xbbbb000000000000000000000000000000000000000000000000000000000000")

describe("listings and identifier upgrades", () => {
  beforeEach(() => {
    clearStore()
  })

  test("a deployed pair is linked to the listing that proposed it", () => {
    mockFactoryReads()
    handlePairDeploymentProposed(pairDeploymentProposed(ASSERTION_A))
    assert.fieldEquals("ListingProposal", ASSERTION_A.toHexString(), "status", "Pending")
    handlePairDeployed(pairDeployed(SEED))
    assert.fieldEquals("ListingProposal", ASSERTION_A.toHexString(), "status", "Deployed")
    assert.fieldEquals("ListingProposal", ASSERTION_A.toHexString(), "pair", PAIR.toHexString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "listing", ASSERTION_A.toHexString())
    assert.fieldEquals("Protocol", "bazaar", "pairCount", "1")
    assert.fieldEquals("Protocol", "bazaar", "umaIdentifier", "0x4153534552545f54525554483200000000000000000000000000000000000000")
  })

  test("a listing voided after its identifier's removal is marked Voided", () => {
    mockFactoryReads()
    handlePairDeploymentProposed(pairDeploymentProposed(ASSERTION_A))
    handlePairDeploymentProposalVoided(pairDeploymentProposalVoided(ASSERTION_A))
    assert.fieldEquals("ListingProposal", ASSERTION_A.toHexString(), "status", "Voided")
    assert.fieldEquals("ListingProposal", ASSERTION_A.toHexString(), "resolvedAt", "1800000000")
  })

  test("a disputed upgrade the next proposal replaces is marked Rejected", () => {
    mockFactoryReads()
    handleUmaIdentifierUpgradeProposed(identifierUpgradeProposed(ASSERTION_A, CAROL))
    handleUmaIdentifierUpgradeDisputed(identifierUpgradeDisputed(ASSERTION_A))
    assert.fieldEquals("IdentifierUpgradeProposal", ASSERTION_A.toHexString(), "status", "Disputed")
    handleUmaIdentifierUpgradeProposed(identifierUpgradeProposed(ASSERTION_B, CAROL))
    assert.fieldEquals("IdentifierUpgradeProposal", ASSERTION_A.toHexString(), "status", "Rejected")
    assert.fieldEquals("IdentifierUpgradeProposal", ASSERTION_B.toHexString(), "status", "Pending")
    assert.fieldEquals("Protocol", "bazaar", "pendingIdentifierUpgrade", ASSERTION_B.toHexString())
    // The proposer is the only account seen, and creating it is counted once.
    assert.fieldEquals("Protocol", "bazaar", "accountCount", "1")
  })
})

describe("termination", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("an accepted claim schedules the pair at the cutoff the pair stores", () => {
    handleTerminationProposalSubmitted(terminationSubmitted(ASSERTION_A, 1800050000))
    assert.fieldEquals("TerminationProposal", ASSERTION_A.toHexString(), "livenessEndsAt", "1800043200")
    // The pair holds the cutoff raised to its minimum lead, not the one the claim proposed.
    mockSchedule(1800060000)
    handleTerminationProposalAccepted(terminationAccepted(ASSERTION_A, 1800050000))
    assert.fieldEquals("TerminationProposal", ASSERTION_A.toHexString(), "status", "Accepted")
    assert.fieldEquals("Pair", PAIR.toHexString(), "status", "Scheduled")
    assert.fieldEquals("Pair", PAIR.toHexString(), "scheduledTerminationTs", "1800060000")
  })

  test("a stale-oracle termination is recorded as such and the pair moves on to Terminated", () => {
    handleStalePairTerminated(stalePairTerminated(e18(97), 1798000000))
    handleSettlementPriceFixed(settlementPriceFixed(e18(97)))
    assert.fieldEquals("Pair", PAIR.toHexString(), "status", "SettlementFixed")
    assert.fieldEquals("Pair", PAIR.toHexString(), "settlementSource", "Stale")
    assert.fieldEquals("Pair", PAIR.toHexString(), "settlementPrice", e18(97).toString())

    handlePairTerminated(pairTerminated(e18(97)))
    assert.fieldEquals("Pair", PAIR.toHexString(), "status", "Terminated")
    assert.fieldEquals("Pair", PAIR.toHexString(), "terminalProfitRatio", e18(1).toString())
    assert.entityCount("PairTermination", 1)
  })

  test("a cutoff settlement without a stale report is recorded as a cutoff", () => {
    handleSettlementPriceFixed(settlementPriceFixed(e18(97)))
    assert.fieldEquals("Pair", PAIR.toHexString(), "settlementSource", "Cutoff")
  })
})

describe("ADL windows", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("a trigger opens a window, a batch joins it, and the trigger after AdlResolved opens a new one", () => {
    handleAdlTriggered(adlTriggered(1, e18(80)))
    let first = PAIR.toHexString() + "-1"
    assert.entityCount("AdlWindow", 1)
    assert.fieldEquals("AdlWindow", first, "epoch", "1")
    assert.fieldEquals("AdlWindow", first, "openedPrice", e18(80).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "isAdlPending", "true")

    // ALICE is a long winner, so her close comes off the short bucket.
    handlePositionBucketUpdated(bucketUpdated(ALICE, true, e18(2), e18(160), e18(50), 1000))
    handleUserAdld(userAdld(ALICE, e18(1), e18(12)))
    let executed = adlExecuted(1, BigInt.zero(), e18(1), e18(3), e18(78))
    handleAdlExecuted(executed)
    let batch = eventId(executed).toHexString()
    assert.fieldEquals("AdlWindow", first, "batchCount", "1")
    assert.fieldEquals("AdlBatch", batch, "window", first)
    assert.fieldEquals("AdlBatch", batch, "longBucketClosed", "0")
    assert.fieldEquals("AdlBatch", batch, "longBucketSettlementPrice", "0")
    assert.fieldEquals("AdlBatch", batch, "shortBucketClosed", e18(1).toString())
    assert.fieldEquals("AdlBatch", batch, "shortBucketSettlementPrice", e18(78).toString())
    assert.fieldEquals("AdlBatch", batch, "netted", e18(3).toString())
    assert.fieldEquals("Position", PAIR.toHexString() + "-" + ALICE.toHexString(), "realizedPnl", e18(12).toString())
    assert.fieldEquals("Position", PAIR.toHexString() + "-" + ALICE.toHexString(), "adlCount", "1")

    handleAdlResolved(adlResolved(1))
    assert.fieldEquals("Pair", PAIR.toHexString(), "isAdlPending", "false")
    assert.fieldEquals("AdlWindow", first, "resolvedAt", "1800000000")

    handleAdlTriggered(adlTriggered(2, e18(70)))
    assert.entityCount("AdlWindow", 2)
    assert.fieldEquals("Pair", PAIR.toHexString(), "currentAdlWindow", PAIR.toHexString() + "-2")
    assert.fieldEquals("AdlWindow", PAIR.toHexString() + "-2", "openedPrice", e18(70).toString())
  })

  test("termination ends a window still pending", () => {
    handleAdlTriggered(adlTriggered(1, e18(80)))
    handlePairTerminated(pairTerminated(e18(80)))
    assert.fieldEquals("AdlWindow", PAIR.toHexString() + "-1", "endedByTermination", "true")
    assert.fieldEquals("Pair", PAIR.toHexString(), "isAdlPending", "false")
    assert.fieldEquals("Pair", PAIR.toHexString(), "currentAdlWindow", "null")
  })
})

