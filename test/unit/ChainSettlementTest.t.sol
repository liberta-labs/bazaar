// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPythLazer} from "../mocks/MockPythLazer.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {LazerChain} from "../LazerChain.sol";
import {LazerUpdate} from "../LazerUpdate.sol";

/// @notice The chain rule a bare insurer vote settles under: the median of five prices, the first
///         from the earliest one-second tick carrying a price generated at or after the cutoff and
///         each later one from the earliest carrying a price generated at least ten minutes after
///         the tick before. Every sample is proven against a target the contract computes, by the
///         tick itself or by the quiet tick before it, so the set is fixed by the feed's history:
///         other ticks, another order, or a short set are refused, a close-timed cutoff settles on
///         prices from the reopen, and a feed that dies before five samples settles at the stored
///         price only once the last resort opens.
contract ChainSettlementTest is Test {
    bytes32 constant BTC_USD_FEED_ID = bytes32(uint256(1));
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant INSURER_BOND_USDC = 1_000 * 1e6; // mirror of INSURER_TERMINATION_BOND_USDC
    uint256 constant MAJORITY_SHARES = 20_000 * BAZAAR_SCALE;
    uint256 constant STORED_PRICE = 50_000 * BAZAAR_SCALE;
    uint256 constant DEAD_THRESHOLD = 21 days; // mirror of ORACLE_DEAD_THRESHOLD
    uint64 constant SPACING = 10 minutes; // mirror of SETTLEMENT_SAMPLE_SPACING

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPythLazer mockPyth;

    address deployer = makeAddr("deployer");
    address insurer = makeAddr("insurer"); // files the bare proposal from a small mature stake
    address majority = makeAddr("majority"); // holds the voting majority of mature shares

    bytes32 voteId;
    uint64 cutoffTs;

    /// @dev Refunds of unspent Pyth fees land here.
    receive() external payable {}

    function setUp() public {
        vm.etch(address(0x64), address(new MockArbSys()).code);
        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));
        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        terminator = factory.pairTerminator();
        mockPyth = MockPythLazer(address(factory.oracle().pythLazer()));

        usdc.mint(deployer, PROPOSAL_TOTAL / 1e12);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL / 1e12);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        _depositInsurance(insurer, 100 * BAZAAR_SCALE);
        _depositInsurance(majority, MAJORITY_SHARES);
        vm.warp(vm.getBlockTimestamp() + 8 days); // the shares mature

        // The pair's stored price: the last price before the cutoff.
        bytes[] memory pu = LazerUpdate.one(LazerUpdate.live(BTC_USD_FEED_ID, 50_000e8, 50e8, -8, _now()));
        pair.refreshPrice{value: factory.oracle().getUpdateFee(pu.length)}(pu);
        (uint256 stored,,,,) = pair.lastPairPrice();
        assertEq(stored, STORED_PRICE, "fixture: the stored price");

        // A bare vote schedules the pair a day out: the chain rule applies.
        cutoffTs = _now() + 1 days;
        usdc.mint(insurer, INSURER_BOND_USDC);
        vm.startPrank(insurer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        voteId = terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();
        vm.prank(majority);
        terminator.voteForInsurerTermination(address(pair), voteId, MAJORITY_SHARES);
        terminator.executeInsurerTermination(address(pair), voteId);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "fixture: the vote scheduled the pair");
    }

    // -------------------- Helpers --------------------

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _depositInsurance(address user, uint256 amountBazaar) internal {
        uint256 amountUsdc = amountBazaar / 1e12;
        usdc.mint(user, amountUsdc);
        vm.startPrank(user);
        usdc.approve(address(pair), amountUsdc);
        pair.depositToInsurance(amountBazaar, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev The one-second update for `tickTs`, its price generated in second `generatedTs`.
    function _tick(uint256 priceUsd, uint64 tickTs, uint64 generatedTs) internal pure returns (bytes memory) {
        return LazerChain.tick(BTC_USD_FEED_ID, priceUsd, tickTs, generatedTs);
    }

    /// @dev A chain at $50,000 for a feed that produces a price on the cutoff and on every target.
    function _flat() internal view returns (bytes[] memory) {
        return LazerChain.flat(BTC_USD_FEED_ID, 50_000, cutoffTs);
    }

    function _setFee(bytes[] memory pu) internal view returns (uint256) {
        return factory.oracle().getUpdateFee(pu.length);
    }

    function _settle(bytes[] memory pu) internal {
        uint256 fee = _setFee(pu);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
    }

    /// @dev The fee is read before the cheatcode: expectRevert applies to the next external call.
    function _expectSettleRevert(bytes[] memory pu, bytes memory revertData) internal {
        uint256 fee = _setFee(pu);
        vm.expectRevert(revertData);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
    }

    function _settlementPrice() internal view returns (uint256) {
        return pair.auxState().settlementPrice;
    }

    /// @dev The refusal of a set of `updates` updates that ran out when the chain went to read
    ///      update number `needed`, or still held more once all five samples were read (`needed`
    ///      then being how many it had read).
    function _countMismatch(uint256 updates, uint256 needed) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, updates, needed);
    }

    function _notProven(uint64 target, uint64 tick) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleNotProven.selector, BTC_USD_FEED_ID, target, tick);
    }

    // -------------------- The median --------------------

    /// @notice The pair settles at the median of the five chained samples: neither the first nor
    ///         the last, and not their order in time.
    function test_SettlesAtTheMedianOfFiveChainedSamples() public {
        bytes[] memory pu =
            LazerChain.chain(BTC_USD_FEED_ID, [uint256(50_000), 53_000, 47_000, 52_000, 61_000], cutoffTs, cutoffTs, 0);
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _settle(pu);
        assertEq(_settlementPrice(), 52_000 * BAZAAR_SCALE, "the median of the five samples");
    }

    /// @notice A single price far off the others moves nothing: one sample cannot be the median.
    function test_OneOutlierSampleMovesNothing() public {
        bytes[] memory pu =
            LazerChain.chain(BTC_USD_FEED_ID, [uint256(5_000), 50_000, 50_100, 49_900, 50_000], cutoffTs, cutoffTs, 0);
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _settle(pu);
        assertEq(_settlementPrice(), 50_000 * BAZAAR_SCALE, "a 90% move at the cutoff is outvoted");
    }

    // -------------------- The proof --------------------

    /// @notice A sample taken from a later tick than its target's, with nothing to show the feed
    ///         was quiet in between, is refused: here the third sample comes a second late.
    function test_SampleFromALaterTickWithoutTheQuietTickRefused() public {
        bytes[] memory pu = _flat();
        uint64 target3 = cutoffTs + 2 * SPACING;
        pu[2] = _tick(50_000, target3 + 1, target3 + 1);
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _expectSettleRevert(pu, _notProven(target3, target3 + 1));
    }

    /// @notice A later tick is the sample only behind a tick that shows the feed quiet since
    ///         before the target. A "quiet" tick whose price was in fact generated at or after the
    ///         target is itself a candidate, and not being the target's own tick it is refused.
    function test_QuietTickThatIsNotQuietRefused() public {
        bytes[] memory head = new bytes[](2);
        head[0] = _tick(50_000, cutoffTs + 4, cutoffTs + 2); // generated after the cutoff: not quiet
        head[1] = _tick(50_000, cutoffTs + 5, cutoffTs + 5);
        bytes[] memory pu = head;
        for (uint64 k = 1; k < 5; k++) {
            pu = LazerChain.append(pu, _tick(50_000, cutoffTs + 5 + k * SPACING, cutoffTs + 5 + k * SPACING));
        }
        vm.warp(LazerChain.lastTick(cutoffTs + 5) + 1);
        _expectSettleRevert(pu, _notProven(cutoffTs, cutoffTs + 4));
    }

    /// @notice The quiet tick and the sample must be consecutive seconds: a gap between them could
    ///         hide an earlier price.
    function test_QuietTickNotAdjacentToTheSampleRefused() public {
        bytes[] memory head = new bytes[](2);
        head[0] = _tick(50_000, cutoffTs + 3, cutoffTs - 1); // quiet through cutoff + 3
        head[1] = _tick(50_000, cutoffTs + 5, cutoffTs + 5); // skips cutoff + 4
        bytes[] memory pu = head;
        for (uint64 k = 1; k < 5; k++) {
            pu = LazerChain.append(pu, _tick(50_000, cutoffTs + 5 + k * SPACING, cutoffTs + 5 + k * SPACING));
        }
        vm.warp(LazerChain.lastTick(cutoffTs + 5) + 1);
        _expectSettleRevert(pu, _notProven(cutoffTs, cutoffTs + 5));
    }

    /// @notice A sample from a tick before its target, less than the spacing after the sample
    ///         before, is refused.
    function test_SampleBeforeItsTargetRefused() public {
        bytes[] memory pu = _flat();
        pu[1] = _tick(50_000, cutoffTs + SPACING - 60, cutoffTs + SPACING - 60);
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _expectSettleRevert(pu, _notProven(cutoffTs + SPACING, cutoffTs + SPACING - 60));
    }

    /// @notice The samples must come in the order the chain defines: swapping two valid samples is
    ///         refused, so the submitter cannot reorder them either.
    function test_SamplesOutOfOrderRefused() public {
        bytes[] memory pu = _flat();
        (pu[1], pu[2]) = (pu[2], pu[1]);
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _expectSettleRevert(pu, _notProven(cutoffTs + SPACING, cutoffTs + 2 * SPACING));
    }

    /// @notice Only the one-second channel proves a sample: a real-time update stamped on the same
    ///         second, carrying the same price, is refused.
    function test_SampleFromAnotherChannelRefused() public {
        bytes[] memory pu = _flat();
        pu[0] = LazerUpdate.live(BTC_USD_FEED_ID, 50_000e8, 50e8, -8, cutoffTs);
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _expectSettleRevert(
            pu,
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__WrongTick.selector, uint64(cutoffTs) * 1e6, LazerUpdate.CHANNEL_REAL_TIME
            )
        );
    }

    /// @notice The set holds exactly five samples: a short set, a long one and no data at all are
    ///         refused before the last resort opens.
    function test_ShortOrLongSetsRefused() public {
        bytes[] memory full = _flat();
        bytes[] memory shortSet = new bytes[](4);
        for (uint256 k = 0; k < 4; k++) {
            shortSet[k] = full[k];
        }
        uint64 sixth = LazerChain.lastTick(cutoffTs) + SPACING;
        bytes[] memory longSet = LazerChain.append(full, _tick(50_000, sixth, sixth));
        vm.warp(sixth + 1);

        _expectSettleRevert(shortSet, _countMismatch(4, 5));
        _expectSettleRevert(longSet, _countMismatch(6, 5));
        _expectSettleRevert(new bytes[](0), _countMismatch(0, 1));
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed by a refused set");
    }

    // -------------------- Quiet feeds --------------------

    /// @notice A cutoff at a session's close: the close is generated on the cutoff and the feed is
    ///         silent until Monday's open, every tick in between carrying the close forward. The
    ///         second sample is the open, proven by the quiet tick before it, and the next three
    ///         follow it at ten-minute steps, so the median is a price from the reopened session
    ///         rather than the close or the opening price alone. Repeating the opening proof in
    ///         the later slots, which a set measured from the cutoff alone would accept, is refused.
    function test_CloseTimedCutoff_SettlesOnTheReopen() public {
        uint64 reopen = cutoffTs + 65 hours + 30 minutes;
        bytes[] memory open = LazerChain.sample(BTC_USD_FEED_ID, 44_000, cutoffTs + SPACING, reopen, 50_000, cutoffTs);
        bytes[] memory pu = LazerUpdate.one(_tick(50_000, cutoffTs, cutoffTs)); // the close
        pu = LazerChain.concat(pu, open); // the feed's next price: the open
        pu = LazerChain.append(pu, _tick(44_500, reopen + SPACING, reopen + SPACING));
        pu = LazerChain.append(pu, _tick(45_000, reopen + 2 * SPACING, reopen + 2 * SPACING));
        pu = LazerChain.append(pu, _tick(45_500, reopen + 3 * SPACING, reopen + 3 * SPACING));
        vm.warp(reopen + 3 * SPACING + 1);

        bytes[] memory collapsed = LazerUpdate.one(_tick(50_000, cutoffTs, cutoffTs));
        for (uint256 k = 1; k < 5; k++) {
            collapsed = LazerChain.concat(collapsed, open);
        }
        _expectSettleRevert(collapsed, _notProven(reopen + SPACING, reopen - 1));

        _settle(pu);
        assertEq(_settlementPrice(), 45_000 * BAZAAR_SCALE, "a price from the reopened session");
    }

    /// @notice A tick still carrying the price from before the cutoff is no sample, however long
    ///         after the cutoff it is stamped: a feed that stays quiet yields nothing to settle on.
    function test_CarriedForwardPriceIsNoSample() public {
        bytes[] memory pu = new bytes[](2);
        pu[0] = _tick(50_000, cutoffTs + 1 hours, cutoffTs - 1);
        pu[1] = _tick(50_000, cutoffTs + 1 hours + 1, cutoffTs - 1);
        vm.warp(cutoffTs + 2 hours);
        _expectSettleRevert(pu, _notProven(cutoffTs, cutoffTs + 1 hours + 1));
    }

    /// @notice A feed that produces two prices after the cutoff and then dies never yields a full
    ///         chain: nothing settles the pair until the last resort opens, ORACLE_DEAD_THRESHOLD
    ///         after the cutoff, and from then on the short set, or no data at all, settles it at
    ///         the stored price.
    function test_FeedDiesMidChain_StoredPriceAtTheLastResort() public {
        bytes[] memory twoSamples =
            LazerChain.sample(BTC_USD_FEED_ID, 48_000, cutoffTs, cutoffTs + 5, 50_000, cutoffTs - 1);
        twoSamples = LazerChain.append(twoSamples, _tick(47_000, cutoffTs + 5 + SPACING, cutoffTs + 5 + SPACING));

        vm.warp(cutoffTs + DEAD_THRESHOLD);
        _expectSettleRevert(twoSamples, _countMismatch(3, 4));
        _expectSettleRevert(new bytes[](0), _countMismatch(0, 1));

        vm.warp(cutoffTs + DEAD_THRESHOLD + 1);
        uint256 fee = _setFee(twoSamples);
        vm.expectEmit(true, false, false, true, address(terminator));
        emit BazaarPairTerminator.SettlementPriceFixed(address(pair), STORED_PRICE);
        terminator.terminateScheduledPair{value: fee}(address(pair), twoSamples);
        assertEq(_settlementPrice(), STORED_PRICE, "the stored price as the last resort");
    }

    // -------------------- Fees --------------------

    /// @notice Each update is its own Pyth verification, so the set costs one fee per update: the
    ///         terminator forwards exactly that, refuses less, and refunds any excess.
    function test_FeePerUpdate_UnderpaymentRefused_ExcessRefunded() public {
        mockPyth.setVerificationFee(7);
        bytes[] memory pu = _flat();
        assertEq(_setFee(pu), 35, "seven wei for each of five updates");
        vm.warp(LazerChain.lastTick(cutoffTs) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InsufficientPythFee.selector, 34, 35)
        );
        terminator.terminateScheduledPair{value: 34}(address(pair), pu);

        uint256 balanceBefore = address(this).balance;
        terminator.terminateScheduledPair{value: 135}(address(pair), pu);
        assertEq(balanceBefore - address(this).balance, 35, "only the fee was kept");
        assertEq(_settlementPrice(), 50_000 * BAZAAR_SCALE, "settled");
    }

    // -------------------- What keepers read --------------------

    /// @notice settlementRule names the chain for a bare vote: the first target is the cutoff, no
    ///         UMA cutoff bounds the samples, and the last resort opens ORACLE_DEAD_THRESHOLD
    ///         later. Once the price is fixed there is nothing left to settle.
    function test_SettlementRule_BareVoteIsTheChain() public {
        (uint8 rule, uint256 firstTarget, uint256 latestPublishTs, uint256 lastResortTs, uint256 verdictDeadline) =
            terminator.settlementRule(address(pair));
        assertEq(rule, terminator.SETTLE_CHAIN(), "the chain rule");
        assertEq(firstTarget, cutoffTs, "chained from the cutoff");
        assertEq(latestPublishTs, type(uint64).max, "no UMA cutoff bounds the samples");
        assertEq(lastResortTs, cutoffTs + DEAD_THRESHOLD, "the last resort");
        assertEq(verdictDeadline, 0, "no verdict to wait for");

        vm.warp(LazerChain.lastTick(cutoffTs) + 1);
        _settle(_flat());
        (rule,,,,) = terminator.settlementRule(address(pair));
        assertEq(rule, terminator.SETTLE_NOTHING(), "the price is fixed");
    }
}
