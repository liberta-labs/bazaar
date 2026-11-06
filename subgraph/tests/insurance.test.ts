import { Bytes } from "@graphprotocol/graph-ts"
import { assert, beforeEach, clearStore, describe, test } from "matchstick-as/assembly/index"
import {
  handleInsuranceDeposited,
  handleInsuranceShareEpochBumped,
  handleInsuranceWithdrawalExecuted,
  handleInsuranceWithdrawalLocked,
  handleInsuranceWithdrawalRequested,
} from "../src/pair/insurance"
import { handleInsurerLevyCharged } from "../src/terminator"
import {
  ALICE,
  BOB,
  DEPLOYER,
  KEEPER,
  PAIR,
  SEED,
  ZERO_ADDRESS,
  deployPair,
  e18,
  epochBumped,
  insuranceDeposited,
  levyCharged,
  mockTotalShares,
  withdrawalExecuted,
  withdrawalLocked,
  withdrawalRequested,
} from "./utils"

const PROPOSAL = Bytes.fromHexString("0x3333333333333333333333333333333333333333333333333333333333333333")

function providerId(account: string): string {
  return PAIR.toHexString() + "-" + account
}

describe("insurance shares", () => {
  beforeEach(() => {
    clearStore()
    deployPair()
  })

  test("the listing seed is the deployer's genesis stake", () => {
    assert.fieldEquals("InsuranceProvider", providerId(DEPLOYER.toHexString()), "shares", SEED.toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "totalInsuranceShares", SEED.toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "insuranceProviderCount", "1")
  })

  test("a deposit credits the provider and takes the supply from the pair", () => {
    // The pair's supply includes orphan shares no event reports, so it differs from the summed
    // figure here.
    mockTotalShares(SEED.plus(e18(1500)))
    handleInsuranceDeposited(insuranceDeposited(ALICE, e18(1000), e18(1000)))
    assert.fieldEquals("InsuranceProvider", providerId(ALICE.toHexString()), "shares", e18(1000).toString())
    assert.fieldEquals("InsuranceProvider", providerId(ALICE.toHexString()), "deposited", e18(1000).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "totalInsuranceShares", SEED.plus(e18(1500)).toString())
    assert.fieldEquals("Pair", PAIR.toHexString(), "insuranceDeposited", SEED.plus(e18(1000)).toString())
  })

  test("a redemption held to the fund's headroom keeps the rest requested under a scaled lock", () => {
    mockTotalShares(SEED.plus(e18(1000)))
    handleInsuranceDeposited(insuranceDeposited(ALICE, e18(1000), e18(1000)))
    handleInsuranceWithdrawalRequested(withdrawalRequested(ALICE, e18(800)))
    handleInsuranceWithdrawalLocked(withdrawalLocked(ALICE, e18(800), e18(760), 1800000300))
    let provider = providerId(ALICE.toHexString())
    assert.fieldEquals("InsuranceProvider", provider, "lockedAmount", e18(760).toString())

    mockTotalShares(SEED.plus(e18(800)))
    handleInsuranceWithdrawalExecuted(withdrawalExecuted(ALICE, e18(200), e18(190)))
    assert.fieldEquals("InsuranceProvider", provider, "shares", e18(800).toString())
    assert.fieldEquals("InsuranceProvider", provider, "requestedShares", e18(600).toString())
    assert.fieldEquals("InsuranceProvider", provider, "lockedAmount", e18(570).toString())
    assert.fieldEquals("InsuranceProvider", provider, "withdrawn", e18(190).toString())

    mockTotalShares(SEED.plus(e18(200)))
    handleInsuranceWithdrawalExecuted(withdrawalExecuted(ALICE, e18(600), e18(570)))
    assert.fieldEquals("InsuranceProvider", provider, "shares", e18(200).toString())
    assert.fieldEquals("InsuranceProvider", provider, "requestedShares", "0")
    assert.fieldEquals("InsuranceProvider", provider, "lockedAmount", "null")
    assert.fieldEquals("Pair", PAIR.toHexString(), "insuranceWithdrawn", e18(760).toString())
  })

  test("a dead-pool reset zeroes every provider and voids their requests", () => {
    mockTotalShares(SEED.plus(e18(1000)))
    handleInsuranceDeposited(insuranceDeposited(ALICE, e18(500), e18(500)))
    handleInsuranceDeposited(insuranceDeposited(BOB, e18(500), e18(500)))
    handleInsuranceWithdrawalRequested(withdrawalRequested(BOB, e18(100)))

    let bump = epochBumped(1)
    handleInsuranceShareEpochBumped(bump)
    assert.fieldEquals("InsuranceProvider", providerId(DEPLOYER.toHexString()), "shares", "0")
    assert.fieldEquals("InsuranceProvider", providerId(ALICE.toHexString()), "shares", "0")
    assert.fieldEquals("InsuranceProvider", providerId(BOB.toHexString()), "shares", "0")
    assert.fieldEquals("InsuranceProvider", providerId(BOB.toHexString()), "requestedShares", "0")
    assert.fieldEquals("Pair", PAIR.toHexString(), "insuranceShareEpoch", "1")
    let resetId = bump.transaction.hash.concatI32(bump.logIndex.toI32()).toHexString()
    assert.fieldEquals("InsuranceEpochReset", resetId, "providersReset", "3")
  })

  test("a levy moves shares from the voter to the recipient and out of the voter's request", () => {
    mockTotalShares(SEED.plus(e18(1000)))
    handleInsuranceDeposited(insuranceDeposited(ALICE, e18(1000), e18(1000)))
    handleInsuranceWithdrawalRequested(withdrawalRequested(ALICE, e18(1000)))
    handleInsurerLevyCharged(levyCharged(PROPOSAL, ALICE, e18(1000), e18(100), KEEPER))
    assert.fieldEquals("InsuranceProvider", providerId(ALICE.toHexString()), "shares", e18(900).toString())
    assert.fieldEquals("InsuranceProvider", providerId(ALICE.toHexString()), "requestedShares", e18(900).toString())
    assert.fieldEquals("InsuranceProvider", providerId(KEEPER.toHexString()), "shares", e18(100).toString())
    assert.fieldEquals("InsuranceProvider", providerId(KEEPER.toHexString()), "levyReceivedShares", e18(100).toString())

    // A levy to the zero address stays in the fund as orphan shares, held by no provider.
    handleInsurerLevyCharged(levyCharged(PROPOSAL, ALICE, e18(900), e18(50), ZERO_ADDRESS))
    assert.fieldEquals("InsuranceProvider", providerId(ALICE.toHexString()), "shares", e18(850).toString())
    assert.notInStore("InsuranceProvider", providerId(ZERO_ADDRESS.toHexString()))
    assert.entityCount("InsurerLevy", 2)
  })
})
