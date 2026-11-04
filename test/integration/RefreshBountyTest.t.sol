// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {PythSeed} from "../PythSeed.sol";

/// @title RefreshBountyTest
/// @notice Covers the insurance-funded refreshPrice bounty (RiskParamsLib.payRefreshBounty):
///         a caller whose refresh stores a fresh price on a pair with more than $1,000 of free
///         insurance capital earns $0.10, debited from the fund and accrued to its claimable
///         balance. The gap the stored price must have aged past follows what the fund has at
///         stake and can spare: 5 minutes while the vault holds at least $1,250 of inventory and
///         free capital exceeds $5,000, a day otherwise. Open interest is not a gate. Each gate is
///         exercised, plus the books invariant (the deduction and the escrow liability must move
///         together).
contract RefreshBountyTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BOUNTY = 0.1e18; // = RiskParamsLib.REFRESH_BOUNTY
    uint256 constant BOUNTY_USDC = 0.1e6;
    uint256 constant GAP = 5 minutes; // = RiskParamsLib.REFRESH_BOUNTY_MIN_GAP
    uint256 constant HEARTBEAT = 1 days; // = RiskParamsLib.REFRESH_BOUNTY_HEARTBEAT
    uint256 constant FAST_FLOOR = 5_000e18; // = RiskParamsLib.REFRESH_BOUNTY_FAST_MIN_INSURANCE
    uint256 constant HEARTBEAT_FLOOR = 1_000e18; // = RiskParamsLib.REFRESH_BOUNTY_HEARTBEAT_MIN_INSURANCE
    uint256 constant INVENTORY_FLOOR_USD = 1_250; // = BazaarTypes.UNLOAD_BOUNTY_MIN_NOTIONAL
    uint256 constant SPOT_USD = 50_000; // what _freshPrice() stores
    bytes32 constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    address keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("keeper");
    }

    /// @dev Qualifying baseline: a live book (0.5 BTC each side at $50k) and $10,000 insurance on
    ///      top of the deployment seed, well past both free-capital floors.
    function _qualifyPair() internal {
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
    }

    /// @dev Stage vault inventory worth `notionalUsd` at the $50k spot, with a 4% seizure behind
    ///      it, so the fund stays healthy and well above the fast cadence's free-capital floor.
    function _holdInventory(uint256 notionalUsd) internal {
        uint256 notional = notionalUsd * BAZAAR_SCALE;
        _stageHeldInventory(pair, notional / SPOT_USD, notional, notional / 25);
    }

    function _refreshAsKeeper() internal {
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
        vm.prank(keeper);
        pair.refreshPrice(pu);
    }

    // ==================== paying path ====================

    function test_RefreshBounty_PaidWhenAllGatesPass() public {
        _qualifyPair();
        _holdInventory(5_000);
        uint256 insuranceBefore = _insuranceBal();
        assertEq(_escrowOwed(keeper), 0, "keeper starts with nothing owed");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);

        bytes[] memory pu = _freshPrice();
        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.FeeAccrued(pair.pairId(), keeper, BOUNTY);
        vm.prank(keeper);
        pair.refreshPrice(pu);

        assertEq(_escrowOwed(keeper), BOUNTY, "keeper owed $0.10");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited exactly the bounty");
        _assertBooksSettled("after accrued bounty");

        // The refresh itself moves no USDC; the keeper pulls the bounty like any other payout.
        assertEq(_claimFees(keeper), BOUNTY_USDC, "keeper claims $0.10");
        assertEq(_escrowOwed(keeper), 0, "claim clears the balance");
        _assertBooksSettled("after claim");
    }

    function test_RefreshBounty_PaysAgainAfterNewGap() public {
        _qualifyPair();
        _holdInventory(5_000);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "first gap paid");

        // Immediately again: the stored price is now fresh, so no second payment.
        vm.warp(vm.getBlockTimestamp() + 4);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "no farming inside the gap");

        // After a full new gap the service is real again and pays again.
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 2 * BOUNTY, "second gap paid");
        _assertBooks("after two bounties");
    }

    /// @notice The fast cadence starts exactly at the unload reward's dust line: inventory worth
    ///         $1,250 at the fresh spot earns the 5-minute gap.
    function test_RefreshBounty_InventoryAtTheFloor_PaysEveryGap() public {
        _qualifyPair();
        _holdInventory(INVENTORY_FLOOR_USD);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "inventory at the floor earns the 5-minute cadence");
    }

    // ==================== lens: where is the money ====================

    /// @notice The lens answers "which pairs owe me" from the pair set of the factory in one call,
    ///         and honours the order passed when handed an explicit list.
    function test_RefreshBounty_LensListsOwedAcrossPairs() public {
        _qualifyPair();
        _holdInventory(5_000);
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper(); // $0.10 owed on the BTC pair, nothing on AAPL

        assertEq(lens.factory(), address(factory), "lens wired to the factory of this deployment");

        (address[] memory pairs, uint256[] memory owed) = lens.getClaimableFeesAll(keeper);
        assertEq(pairs.length, 2, "both deployed pairs listed");
        assertEq(pairs[0], address(pair));
        assertEq(owed[0], BOUNTY, "BTC pair owes the bounty");
        assertEq(pairs[1], address(aaplPair));
        assertEq(owed[1], 0, "AAPL pair owes nothing, still listed");

        address[] memory chosen = new address[](2);
        chosen[0] = address(aaplPair);
        chosen[1] = address(pair);
        uint256[] memory subset = lens.getClaimableFees(chosen, keeper);
        assertEq(subset[0], 0, "follows the order passed");
        assertEq(subset[1], BOUNTY, "follows the order passed");

        _claimFees(keeper);
        (, owed) = lens.getClaimableFeesAll(keeper);
        assertEq(owed[0], 0, "claim clears the BTC entry");
    }

    // ==================== cadence without inventory ====================

    /// @notice With no inventory held the bounty is a heartbeat: a stored price must be a day old.
    ///         Open interest alone does not buy the fast cadence, so a long and a short parked in
    ///         two wallets on a dormant pair draw one bounty per day, not one per 5 minutes.
    ///         Every refresh stores a price whether or not it pays, so refreshing on the fast
    ///         cadence keeps resetting the gap and earns nothing at all.
    function test_RefreshBounty_WithoutInventory_PaysOncePerHeartbeat() public {
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + GAP + 1);
            _refreshAsKeeper();
        }
        assertEq(_escrowOwed(keeper), 0, "the 5-minute cadence pays nothing without inventory");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT - 1 hours);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 0, "inside the heartbeat: nothing");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched so far");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "a day-old stored price earns the heartbeat bounty");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited once");
        _assertBooksSettled("after the heartbeat bounty");
    }

    /// @notice Inventory under the $1,250 line is dust and buys nothing: the heartbeat applies.
    function test_RefreshBounty_DustInventory_HeartbeatOnly() public {
        _qualifyPair();
        _holdInventory(INVENTORY_FLOOR_USD - 250);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 0, "dust inventory does not earn the 5-minute cadence");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "the heartbeat still pays");
    }

    // ==================== floors ====================

    /// @notice The fast cadence stops at its floor and the pair falls back to the heartbeat, rather
    ///         than to nothing. Free capital starts one bounty above the floor, so the first payment
    ///         lands it there exactly. The balance stays far above the floor throughout, since most
    ///         of it is earmarked against the $50,000 of inventory: the floor reads free capital.
    function test_RefreshBounty_FastCadenceFallsBackToHeartbeatAtItsFloor() public {
        _qualifyPair();
        uint256 fund = _insuranceBal();
        _stageHeldInventory(60_000 * BAZAAR_SCALE, fund - (FAST_FLOOR + BOUNTY));
        assertGt(fund - BOUNTY, FAST_FLOOR, "setup: the balance alone would clear the floor");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "above the floor: the 5-minute cadence pays");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "at the floor: the 5-minute cadence is off");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 2 * BOUNTY, "the heartbeat still pays");
    }

    /// @notice A fund between the two floors earns the heartbeat. The fixture's $4,000 seed is real
    ///         money, so the books stay settled through the payment.
    function test_RefreshBounty_HeartbeatPaysBelowTheFastFloor() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        uint256 insuranceBefore = _insuranceBal();
        assertLt(insuranceBefore, FAST_FLOOR, "setup: fund under the fast floor");
        assertGt(insuranceBefore, HEARTBEAT_FLOOR, "setup: fund over the heartbeat floor");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), BOUNTY, "the heartbeat pays a small fund");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited the bounty");
        _assertBooksSettled("after the heartbeat bounty");
    }

    /// @notice A pair listed at the minimum seed earns the heartbeat from the start, which is what
    ///         keeps the smallest listing's stored price inside the stale-termination threshold.
    function test_RefreshBounty_MinimumListing_EarnsHeartbeat() public {
        PythSeed.seed(address(mockPyth), ETH_USD_FEED_ID);
        uint256 total = factory.MIN_DEPLOYMENT_AMOUNT();
        vm.startPrank(carol);
        usdc.approve(address(factory), total * USDC_SCALE / BAZAAR_SCALE);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, total, "ETH/USD");
        vm.stopPrank();
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        BazaarPair eth = BazaarPair(payable(factory.getPairAddress(pairId)));
        assertEq(eth.insuranceShares(carol), BazaarTypes.MIN_INSURANCE_SEED, "setup: listed at the minimum seed");

        for (uint256 i = 1; i <= 2; i++) {
            bytes[] memory pu = _priceUpdateFor(ETH_USD_FEED_ID, 3_000, uint64(vm.getBlockTimestamp()));
            vm.prank(keeper);
            eth.refreshPrice(pu);
            (uint256 owed,) = lens.claimableFees(address(eth), keeper);
            assertEq(owed, i * BOUNTY, "each day-old store is paid");
            vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        }
    }

    // ==================== withheld paths ====================

    function test_RefreshBounty_NotPaidWithinGap() public {
        _qualifyPair();
        _holdInventory(5_000);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP - 60); // 4 minutes: inside the gate
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty inside the gap");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    /// @notice Open interest is not a gate: a pair with a qualifying fund and no positions at all
    ///         still gets its heartbeat, which is what keeps a quiet pair's stored price inside the
    ///         stale-termination threshold when nothing else stores one.
    function test_RefreshBounty_PaidWithoutOpenInterest() public {
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), BOUNTY, "the heartbeat pays with no open interest");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited the bounty");
        _assertBooksSettled("after the heartbeat bounty");
    }

    /// @notice The heartbeat runs a fund down to its floor and stops there: a fund one bounty above
    ///         the floor pays once, which lands it on the floor, and from there nothing pays
    ///         however old the stored price gets. The balance is written below what the pair
    ///         holds, so the pair stays over-backed throughout.
    function test_RefreshBounty_HeartbeatStopsAtItsFloor() public {
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(HEARTBEAT_FLOOR + BOUNTY);

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "one bounty above the floor: paid");
        assertEq(_insuranceBal(), HEARTBEAT_FLOOR, "the payment lands on the floor");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "at the floor: nothing more");
        assertEq(_insuranceBal(), HEARTBEAT_FLOOR, "the floor holds");
    }

    /// @notice The heartbeat's floor reads free capital: a balance far above it pays nothing when
    ///         all but $900 of it is the seizure earmarked against inventory the vault holds.
    function test_RefreshBounty_NotPaidWhenFreeCapitalBelowHeartbeatFloor() public {
        _qualifyPair();
        uint256 fund = _insuranceBal();
        assertGt(fund, FAST_FLOOR, "setup: balance above both floors");
        _stageHeldInventory(60_000 * BAZAAR_SCALE, fund - 900 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty: the earmark is not free capital");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenNothingStored() public {
        // Non-continuous pair served by the stale fallback: the read succeeds but nothing is
        // stored, so repeated calls against the same old timestamp must never pay.
        bytes[] memory seed = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice(seed);

        // Give the pair a qualifying fund directly (nothing moves in a withheld path, so unbacked
        // fund bookkeeping is fine here).
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(5).checked_write(20_000 * BAZAAR_SCALE); // insuranceFundBalance

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);

        (,,,,, uint256 insuranceBefore,,,,,,,,,,,) = aaplPair.pairVault();
        vm.prank(keeper);
        aaplPair.refreshPrice(new bytes[](0)); // stale fallback path: no store

        (uint256 owed,) = lens.claimableFees(address(aaplPair), keeper);
        assertEq(owed, 0, "stale fallback earns nothing");
        (,,,,, uint256 insuranceAfter,,,,,,,,,,,) = aaplPair.pairVault();
        assertEq(insuranceAfter, insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidDuringSweepWindow() public {
        // Settlement price fixed but finalize not yet called: the pair is NOT terminated, yet
        // its insurance already backs the frozen settlement claims. The gate must withhold the
        // bounty for as long as the window is open (and the frozen updateTs blocks it independently).
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        vm.prank(address(factory.pairTerminator()));
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        assertFalse(pair.isPairTerminated(), "setup: window open, not terminated");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty during the sweep window");
        assertEq(_insuranceBal(), insuranceBefore, "settlement-backing insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenTerminated() public {
        _qualifyPair();
        // Terminate for real: fix the price, settle both positions at it, finalize.
        vm.prank(address(factory.pairTerminator()));
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        pair.liquidate(both, new bytes[](0));
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "setup: terminated");
        uint256 residualBefore = _insuranceBal(); // finalize rewrites the fund to the insurers' residual

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "terminated pair pays no bounty");
        assertEq(_insuranceBal(), residualBefore, "insurers' residual untouched");
    }
}
