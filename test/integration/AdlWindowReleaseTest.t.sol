// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {IntegrationBase} from "./IntegrationBase.sol";

/// @title AdlWindowReleaseTest
/// @notice An opposite-side liquidation the fund cannot afford to net is seized into the vault's
///         bucket on its own side, and the two buckets stand under one window until each is closed
///         against its own counterparties or the fund can afford to net their overlap. Whatever
///         moves the fund's means re-tests that netting: the batch that restores the fund nets the
///         overlap it leaves, and a fund recovered without a batch nets at the next unload walk.
contract AdlWindowReleaseTest is IntegrationBase {
    uint256 constant ESTATE_SIZE = 72 * BAZAAR_SCALE / 100;
    uint256 constant SHORT_SIZE = 88 * BAZAAR_SCALE / 100;

    bytes32 constant USER_ADLD_SIG =
        keccak256("UserAdld(bytes32,address,bool,uint256,int256,uint256,uint256,uint256,uint256)");
    bytes32 constant ADL_EXECUTED_SIG =
        keccak256("AdlExecuted(bytes32,uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)");

    // ---------------------------- fixture ----------------------------

    /// @dev dave long and bob short 0.72 at $80k; alice short and carol long 0.88 at $30k. Nobody
    ///      is seized.
    function _openBothPairs() internal {
        _deposit(dave, 19_200 * BAZAAR_SCALE);
        _deposit(bob, 16_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, ESTATE_SIZE, 80_000 * BAZAAR_SCALE, 80_000);
        _roll(2);
        _placeLimitAt(bob, false, ESTATE_SIZE, 80_000 * BAZAAR_SCALE, 80_000);
        assertEq(_posSize(bob), ESTATE_SIZE, "fixture: dave and bob crossed");

        _deposit(alice, 13_200 * BAZAAR_SCALE);
        _deposit(carol, 13_200 * BAZAAR_SCALE);
        _placeLimitAt(carol, true, SHORT_SIZE, 30_000 * BAZAAR_SCALE, 30_000);
        _roll(2);
        _placeLimitAt(alice, false, SHORT_SIZE, 30_000 * BAZAAR_SCALE, 30_000);
        assertEq(_posSize(alice), SHORT_SIZE, "fixture: alice and carol crossed");
    }

    /// @dev Opens a window and seizes alice inside it. Seizing dave at $30k hands the vault a 0.72
    ///      long whose $36,000 loss is far past his $19,200 and the seed, so the window opens; the
    ///      $30k pair is opened first because the window freezes matching. At $43k alice is below
    ///      maintenance but not under water. Netting her against the vault's long would realize
    ///      the $50k entry gap on 0.72 — past the two slices' seizure plus the fund's free capital
    ///      above its reserve — so she is seized into the short bucket and both buckets stand.
    function _seizeAliceInsideWindow() internal {
        _openBothPairs();

        assertEq(_liquidateAt(dave, 30_000), 1, "fixture: dave seized");
        assertTrue(pair.isAdlPending(), "fixture: the estate's loss exceeds the fund");

        assertEq(_liquidateAt(alice, 43_000), 1, "fixture: alice seized");
        assertEq(_posSize(alice), 0, "fixture: her position is gone");
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        assertEq(l.size, ESTATE_SIZE, "fixture: the long bucket holds dave's estate");
        assertEq(s.size, SHORT_SIZE, "fixture: the short bucket holds alice's");
        assertGt(_overlapUncovered(), _freeCapital(), "fixture: netting the overlap is beyond the fund");
        assertTrue(pair.isAdlPending(), "fixture: the window stays open");
    }

    /// @dev Liquidate one account as the keeper, at a fresh price four seconds on.
    function _liquidateAt(address user, uint256 priceUsd) internal returns (uint256) {
        return _liquidateAt(_arr1(user), priceUsd);
    }

    function _liquidateAt(address[] memory users, uint256 priceUsd) internal returns (uint256) {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        return pair.liquidate(users, pu);
    }

    /// @dev Seizes dave and alice in one call at $55k, with whatever rests in the book for the
    ///      call's inline unload to sell the vault's long into. At $55k dave keeps $1,200 of his
    ///      $19,200, so the 0.72 long the vault inherits carries no loss beyond its seizure; alice
    ///      is $8,800 past bankruptcy. Netting 0.72 of her against the long would realize the $50k
    ///      entry gap, $36,000, against the two slices' seizure of $30,000 plus the fund above its
    ///      reserve, which is at most the $4,000 seed, so she is seized into the short bucket.
    function _seizeDaveAndAlice() internal {
        address[] memory users = new address[](2);
        users[0] = dave;
        users[1] = alice;
        assertEq(_liquidateAt(users, 55_000), 2, "dave and alice seized");
        assertEq(_posSize(dave), 0, "dave is closed");
        assertEq(_posSize(alice), 0, "alice is closed");
    }

    /// @dev Unload as the keeper at a fresh price four seconds on.
    function _unloadAt(uint256 priceUsd) internal returns (uint256 unloaded) {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        unloaded = pair.unloadVault(0, pu);
    }

    /// @dev One batch as the keeper at `priceUsd`, past the Dutch decay so every profitable
    ///      account clears the threshold; returns the recorded logs.
    function _executeAdlAt(address[] memory longBucketWinners, address[] memory shortBucketWinners, uint256 priceUsd)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.recordLogs();
        vm.prank(seq);
        pair.executeAdl(longBucketWinners, shortBucketWinners, pu);
        logs = vm.getRecordedLogs();
    }

    // ---------------------------- readers ----------------------------

    function _deficitOf() internal view returns (uint256 d) {
        (,,,,,, d,,,,,) = pair.pairVault();
    }

    /// @dev The fund less the seizure earmarked against both buckets.
    function _freeCapital() internal view returns (uint256) {
        uint256 fund = _insuranceBal();
        uint256 seized = _seizedTotal();
        return fund > seized ? fund - seized : 0;
    }

    /// @dev What netting the two buckets' overlap would cost the fund beyond the two netted
    ///      slices' seizure (RiskParamsLib.overlap): the gap between the sides' entry bases on the
    ///      overlap plus the offset of their entry clocks, less the seizure pro rata. 0 when the
    ///      netting is a gain or either bucket is empty.
    function _overlapUncovered() internal view returns (uint256) {
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        uint256 o = l.size < s.size ? l.size : s.size;
        if (o == 0) return 0;
        int256 pnl = int256(Math.mulDiv(s.entryNotional, o, s.size)) - int256(Math.mulDiv(l.entryNotional, o, l.size))
            + (l.entryFundingIndex - s.entryFundingIndex) * int256(o) / int256(BAZAAR_SCALE);
        int256 net = pnl + int256(Math.mulDiv(l.seized, o, l.size) + Math.mulDiv(s.seized, o, s.size));
        return net < 0 ? uint256(-net) : 0;
    }

    /// @dev A bucket's average bankruptcy price, rounded toward the vault as the leg settles it: up
    ///      for the long bucket, down for the short.
    function _bankruptcyPrice(BazaarTypes.Inventory memory b, bool isLong) internal pure returns (uint256) {
        return
            Math.mulDiv(b.bankruptcyNotional, BAZAAR_SCALE, b.size, isLong ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @dev The size `user`'s UserAdld closes settled, checking every one settled at `price`.
    function _closedAt(Vm.Log[] memory logs, address user, uint256 price) internal pure returns (uint256 closed) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != USER_ADLD_SIG) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != user) continue;
            (, uint256 size,,,, uint256 settledAt,) =
                abi.decode(logs[i].data, (bool, uint256, int256, uint256, uint256, uint256, uint256));
            assertEq(settledAt, price, "a leg settles every close at its one settlement price");
            closed += size;
        }
    }

    /// @dev The batch's AdlExecuted figures: what each leg closed and what the batch netted.
    function _adlExecuted(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 longClosed, uint256 shortClosed, uint256 netted)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != ADL_EXECUTED_SIG) continue;
            (longClosed,, shortClosed,, netted,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            return (longClosed, shortClosed, netted);
        }
        revert("AdlExecuted not emitted");
    }

    // ---------------------------- tests ----------------------------

    /// @notice A batch with the long bucket's cohort alone. bob is closed against the long bucket
    ///         at its bankruptcy price, only as far as restoring the fund takes, and the short
    ///         bucket's cohort is not submitted. The batch's end nets what it leaves: with the fund
    ///         able to finish the remainder inside the band, the overlap's fixed loss is within
    ///         what the fund may spend, so the long bucket's remainder is netted against the same
    ///         size of the short bucket and the window releases with the short bucket's excess as
    ///         the only inventory.
    function test_windowResolvedByBatch_closesTheLongBucketAndNetsItsRemainder() public {
        _seizeAliceInsideWindow();

        Vm.Log[] memory logs = _executeAdlAt(_arr1(bob), new address[](0), 43_000);

        assertFalse(pair.isAdlPending(), "the batch resolved the window");
        uint256 bobLeft = _posSize(bob);
        assertGt(bobLeft, 0, "bob keeps the units the fund did not need closed");
        assertLt(bobLeft, ESTATE_SIZE, "bob took part of the close");
        assertEq(_posSize(carol), SHORT_SIZE, "carol, the short bucket's cohort, was not submitted and is untouched");

        (uint256 longClosed, uint256 shortClosed, uint256 netted) = _adlExecuted(logs);
        assertEq(longClosed, ESTATE_SIZE - bobLeft, "the long leg closed what bob gave up");
        assertEq(shortClosed, 0, "no short leg ran");
        assertEq(netted, bobLeft, "the long bucket's remainder was netted at the end of the batch");

        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        assertEq(l.size, 0, "the long bucket is gone: closed against bob, the rest netted");
        assertEq(s.size, SHORT_SIZE - bobLeft, "the short bucket keeps its excess over the netted overlap");
        assertEq(_deficitOf(), 0, "nothing went unpaid");
        _assertBooks("after the batch");
    }

    /// @notice A window resolved by something other than a batch leaves both buckets standing.
    ///         Capital credited through the terminator, the route a forfeited insurer-termination
    ///         bond takes, judges no vault health, so the window survives it; the next refresh
    ///         finds the fund able to finish the inventory inside the band and resolves the window
    ///         with no batch having run and nothing netted, since a refresh moves no inventory. The
    ///         recovered fund can now afford the netting, and the next unload walk, which re-tests
    ///         it at its tail, nets the long bucket against the same size of the short one and pays
    ///         the keeper the rate on what it retired.
    function test_windowResolvedByRefresh_bothBucketsStand_untilTheNextWalkNetsTheOverlap() public {
        _seizeAliceInsideWindow();

        // An insurance deposit is refused while the window is pending, so the capital arrives as
        // a credit: USDC moved to the pair, then booked into the fund by the terminator.
        vm.prank(deployer);
        usdc.transfer(address(pair), 20_000 * USDC_SCALE);
        vm.prank(pair.umaContract());
        pair.creditInsurance(20_000 * BAZAAR_SCALE);
        assertTrue(pair.isAdlPending(), "a credit does not judge vault health");

        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory pu = _priceAt(43_000);
        vm.prank(seq);
        pair.refreshPrice(pu);

        assertFalse(pair.isAdlPending(), "the refresh resolved the window");
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        assertEq(l.size, ESTATE_SIZE, "the long bucket stands: a refresh nets nothing");
        assertEq(s.size, SHORT_SIZE, "so does the short bucket");
        assertLe(_overlapUncovered(), _freeCapital(), "the recovered fund can now afford the netting");

        uint256 owedBefore = _escrowOwed(seq);
        assertEq(_unloadAt(43_000), 0, "the book is empty, so the walk fills nothing");

        (l, s) = _vaultBuckets();
        assertEq(l.size, 0, "the walk's tail netted the whole long bucket");
        assertEq(s.size, SHORT_SIZE - ESTATE_SIZE, "against the same size of the short bucket");
        assertEq(
            _escrowOwed(seq) - owedBefore,
            Math.mulDiv(Math.mulDiv(ESTATE_SIZE, 43_000 * BAZAAR_SCALE, BAZAAR_SCALE), 200, 1_000_000),
            "the keeper earns the rate on what the netting retired"
        );
        assertEq(_deficitOf(), 0, "the netting's loss beyond the two slices' seizure came from free capital");
        assertFalse(pair.isAdlPending(), "the remaining short bucket is covered");
        _assertBooks("after the walk");
    }

    /// @notice A liquidation that seizes both estates and then sells the long bucket in its own
    ///         inline unload reaches the health check with only the short bucket, whose $8,800 loss
    ///         beyond its seizure holds the window open on its own. erin's bid, one unload band
    ///         under the $55k oracle and above the long's $53,333 bankruptcy price, takes the whole
    ///         long at no cost to the fund; nothing rests for the short. The short bucket's own
    ///         cohort, carol, then closes it at its bankruptcy price, as far as restoring the fund
    ///         takes, and the window releases.
    function test_walkSellsTheLongBucket_shortBucketHoldsTheWindow_itsOwnCohortClosesIt() public {
        _openBothPairs();

        address erin = makeAddr("erin");
        usdc.mint(erin, INITIAL_USER_BALANCE);
        _deposit(erin, 12_000 * BAZAAR_SCALE);
        _placeLimitAt(erin, true, ESTATE_SIZE, 54_000 * BAZAAR_SCALE, 55_000);
        assertEq(_posSize(erin), 0, "fixture: erin's bid rests");

        _seizeDaveAndAlice();

        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        assertEq(l.size, 0, "the inline unload sold the whole long");
        assertEq(_posSize(erin), ESTATE_SIZE, "to erin");
        assertEq(s.size, SHORT_SIZE, "the short bucket is held");
        assertTrue(pair.isAdlPending(), "its loss beyond the seizure holds the window open alone");
        _assertBooks("after the liquidation");

        uint256 bankruptcyPrice = _bankruptcyPrice(s, false);
        assertLt(bankruptcyPrice, 55_000 * BAZAAR_SCALE, "fixture: the short bucket is under water at $55k");
        uint256 carolCollBefore = _posCollateral(carol);
        Vm.Log[] memory logs = _executeAdlAt(new address[](0), _arr1(carol), 55_000);

        uint256 closed = _closedAt(logs, carol, bankruptcyPrice);
        assertGt(closed, 0, "carol closed part of the short bucket at its bankruptcy price");
        assertLt(closed, SHORT_SIZE, "and keeps the rest of her long");
        assertEq(_posSize(carol), SHORT_SIZE - closed, "her position shrank by the close");
        assertGt(_posCollateral(carol), carolCollBefore, "credited her PnL at the bankruptcy price");
        (l, s) = _vaultBuckets();
        assertEq(l.size, 0, "no long bucket to net against");
        assertEq(s.size, SHORT_SIZE - closed, "the short bucket keeps what the fund can carry");
        assertFalse(pair.isAdlPending(), "the window released");
        assertEq(_deficitOf(), 0, "a close at the bankruptcy price costs the fund nothing");
        _assertBooks("after the batch");
    }

    /// @notice Control for the test above: the same liquidation with nothing resting to sell into
    ///         keeps both buckets, and the health check finds their loss beyond the seizure past
    ///         the fund. The overlap's fixed loss is more than the fund may spend on netting it, so
    ///         the two stand hedged until each is closed against its own cohort.
    function test_walkSellsNothing_windowOpens_bothBucketsStand() public {
        _openBothPairs();

        _seizeDaveAndAlice();

        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        assertEq(l.size, ESTATE_SIZE, "the long is still held");
        assertEq(s.size, SHORT_SIZE, "alongside the short");
        assertGt(_overlapUncovered(), _freeCapital(), "netting the overlap is beyond the fund's free capital");
        assertTrue(pair.isAdlPending(), "the loss beyond the seizure opens the window");
        _assertBooks("after the liquidation");
    }

    // ------------------ a batch against two buckets under water ------------------

    /// @notice Both buckets under water at $50k: the long against its $53,333 bankruptcy price,
    ///         the short against its $45,000 one. Each leg settles at its bucket's bankruptcy price,
    ///         where its own cohort pays the bucket's shortfall and the fund pays nothing; the
    ///         larger bucket's leg runs first and each is sized to restoring the fund. The overlap
    ///         the two legs leave is netted at the end of the batch, so exactly one bucket is left,
    ///         holding the difference between the two remainders, and the window releases.
    function test_bothUnderWater_eachLegAtItsBankruptcyPrice_overlapNettedAtTheEnd() public {
        _openBothPairs();
        _seizeDaveAndAlice();
        assertTrue(pair.isAdlPending(), "fixture: the window is open");
        (BazaarTypes.Inventory memory l, BazaarTypes.Inventory memory s) = _vaultBuckets();
        uint256 longBankruptcy = _bankruptcyPrice(l, true);
        uint256 shortBankruptcy = _bankruptcyPrice(s, false);
        assertGt(longBankruptcy, 50_000 * BAZAAR_SCALE, "fixture: the long bucket is under water at $50k");
        assertLt(shortBankruptcy, 50_000 * BAZAAR_SCALE, "fixture: so is the short bucket");

        Vm.Log[] memory logs = _executeAdlAt(_arr1(bob), _arr1(carol), 50_000);

        uint256 bobClosed = _closedAt(logs, bob, longBankruptcy);
        uint256 carolClosed = _closedAt(logs, carol, shortBankruptcy);
        assertGt(bobClosed, 0, "bob closed part of the long bucket at its bankruptcy price");
        assertLt(bobClosed, ESTATE_SIZE, "but not all of it");
        assertGt(carolClosed, 0, "carol closed part of the short bucket at its bankruptcy price");
        assertLt(carolClosed, SHORT_SIZE, "but not all of it");
        assertEq(_posSize(bob), ESTATE_SIZE - bobClosed, "bob keeps the rest of his short");
        assertEq(_posSize(carol), SHORT_SIZE - carolClosed, "carol keeps the rest of her long");

        (uint256 longClosed, uint256 shortClosed, uint256 netted) = _adlExecuted(logs);
        assertEq(longClosed, bobClosed, "the long leg's figure is bob's close");
        assertEq(shortClosed, carolClosed, "the short leg's figure is carol's close");
        uint256 longLeft = ESTATE_SIZE - bobClosed;
        uint256 shortLeft = SHORT_SIZE - carolClosed;
        assertEq(netted, longLeft < shortLeft ? longLeft : shortLeft, "the smaller remainder was netted whole");

        (l, s) = _vaultBuckets();
        assertTrue(l.size == 0 || s.size == 0, "the netting leaves one bucket at most");
        assertEq(
            l.size + s.size,
            longLeft > shortLeft ? longLeft - shortLeft : shortLeft - longLeft,
            "holding the difference between the two remainders"
        );
        assertFalse(pair.isAdlPending(), "the window released");
        assertEq(_deficitOf(), 0, "nothing went unpaid");
        _assertBooks("after the batch");
    }
}
