// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice What the factory does once UMA removes an identifier from its live whitelist: a queued
///         upgrade may activate early, a proposal disputed after the removal is discarded at once,
///         and an undisputed listing approved under a removed identifier is voided. Each rule reads
///         the identifier the assertion was made under, and a whitelist lookup that fails or
///         replies with garbage is never read as a removal.
contract IdentifierRemovalTest is Test {
    bytes32 constant ETH_USD_FEED_ID = bytes32(uint256(2));
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant PROPOSAL_TOTAL = 5_000 * 1e18;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;
    bytes32 constant SUCCESSOR = "ASSERT_TRUTH3";

    BazaarFactory factory;
    MockUSDC usdc;
    MockOptimisticOracleV3 mockOOv3;

    address deployer;
    address disputer;
    address proposer;

    bytes32 incumbent;
    uint256 bondUsdc;
    uint256 seedUsdc;

    function setUp() public {
        deployer = makeAddr("deployer");
        disputer = makeAddr("disputer");
        proposer = makeAddr("proposer");

        DeployBazaar script = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = script.deploy(makeAddr("bugBounty"));
        (, address usdcContract, address optimisticOracleV3,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(optimisticOracleV3);

        BazaarOracle oracle = factory.oracle();

        incumbent = factory.umaIdentifier();
        bondUsdc = factory.DEPLOYMENT_BOND_USDC();
        seedUsdc = PROPOSAL_TOTAL_USDC - bondUsdc;

        usdc.mint(deployer, 100_000 * USDC_SCALE);
        usdc.mint(disputer, 100_000 * USDC_SCALE);
        usdc.mint(proposer, 100_000 * USDC_SCALE);
    }

    // -------------------- helpers --------------------

    function _proposeListing() internal returns (bytes32 assertionId) {
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    function _proposeUpgrade(bytes32 candidate) internal returns (bytes32 assertionId) {
        uint256 bond = factory.requiredIdentifierUpgradeBond();
        vm.startPrank(proposer);
        usdc.approve(address(factory), bond);
        assertionId = factory.proposeUmaIdentifierUpgrade(candidate);
        vm.stopPrank();
    }

    function _dispute(bytes32 assertionId, uint256 bond) internal {
        vm.startPrank(disputer);
        usdc.approve(address(mockOOv3), bond);
        mockOOv3.disputeAssertion(assertionId, disputer);
        vm.stopPrank();
    }

    /// @dev Proposes the successor, lets its liveness pass undisputed and settles it.
    /// @return approvedAt When the upgrade was queued
    function _queueUpgrade() internal returns (uint256 approvedAt) {
        bytes32 assertionId = _proposeUpgrade(SUCCESSOR);
        vm.warp(vm.getBlockTimestamp() + factory.IDENTIFIER_UPGRADE_LIVENESS() + 1);
        factory.settleIdentifierUpgradeProposal(assertionId);
        approvedAt = vm.getBlockTimestamp();
    }

    function _removeIncumbent() internal {
        mockOOv3.setIdentifierSupported(incumbent, false);
    }

    /// @dev Makes the whitelist lookup for `id` revert, the way a lookup starved of gas fails.
    function _breakLookup(bytes32 id) internal {
        vm.mockCallRevert(
            address(mockOOv3), abi.encodeWithSelector(MockOptimisticOracleV3.isIdentifierSupported.selector, id), "down"
        );
    }

    function _expectTimelocked(uint256 opensAt) internal {
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierUpgradeTimelocked.selector, opensAt));
    }

    function _expectListingNotExpired(uint256 expiryTs) internal {
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__DeploymentNotExpired.selector, expiryTs));
    }

    function _expectUpgradeNotExpired(uint256 expiryTs) internal {
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierUpgradeNotExpired.selector, expiryTs));
    }

    function _listingGraceEnd(uint256 proposedAt) internal view returns (uint256) {
        return proposedAt + factory.DEPLOYMENT_LIVENESS() + factory.DVM_DISPUTE_GRACE();
    }

    function _upgradeGraceEnd(uint256 proposedAt) internal view returns (uint256) {
        return proposedAt + factory.IDENTIFIER_UPGRADE_LIVENESS() + factory.DVM_DISPUTE_GRACE();
    }

    // -------------------- early activation --------------------

    /// @notice The removed-incumbent floor must stay shorter than the timelock it replaces.
    function test_NoticeFloorIsShorterThanTimelock() public view {
        assertLt(factory.IDENTIFIER_UPGRADE_MIN_NOTICE(), factory.IDENTIFIER_UPGRADE_TIMELOCK());
    }

    /// @notice While the incumbent is on the whitelist the full timelock applies.
    function test_EarlyActivation_RefusedWhileIncumbentLive() public {
        uint256 approvedAt = _queueUpgrade();
        uint256 effectiveTs = approvedAt + factory.IDENTIFIER_UPGRADE_TIMELOCK();

        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        _expectTimelocked(effectiveTs);
        factory.activateIdentifierUpgrade();

        vm.warp(effectiveTs);
        factory.activateIdentifierUpgrade();
        assertEq(factory.umaIdentifier(), SUCCESSOR, "activates at the timelock's end");
    }

    /// @notice Once the incumbent is removed, activation opens the notice floor after approval, and
    ///         a call before that reports the opening time.
    function test_EarlyActivation_OpensAtNoticeFloorOnceIncumbentRemoved() public {
        uint256 approvedAt = _queueUpgrade();
        _removeIncumbent();
        uint256 opensAt = approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE();

        vm.warp(opensAt - 1);
        _expectTimelocked(opensAt);
        factory.activateIdentifierUpgrade();

        vm.warp(opensAt);
        factory.activateIdentifierUpgrade();
        assertEq(factory.umaIdentifier(), SUCCESSOR, "activated at the floor");
        assertTrue(factory.umaIdentifierIsLive(), "the protocol is back on a live identifier");
    }

    /// @notice A removal that lands after the floor has passed opens activation at once.
    function test_EarlyActivation_RemovalAfterFloorOpensAtOnce() public {
        uint256 approvedAt = _queueUpgrade();
        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE() + 1 days);

        _expectTimelocked(approvedAt + factory.IDENTIFIER_UPGRADE_TIMELOCK());
        factory.activateIdentifierUpgrade();

        _removeIncumbent();
        factory.activateIdentifierUpgrade();
        assertEq(factory.umaIdentifier(), SUCCESSOR, "activated as soon as the incumbent left");
    }

    /// @notice A new proposal's auto-activation of the queued upgrade follows the same rule.
    function test_EarlyActivation_ProposalAutoActivatesUnderSameRule() public {
        uint256 approvedAt = _queueUpgrade();
        _removeIncumbent();
        uint256 bond = factory.requiredIdentifierUpgradeBond();

        vm.startPrank(proposer);
        usdc.approve(address(factory), bond);
        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE() - 1);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");

        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");
        vm.stopPrank();

        assertEq(factory.umaIdentifier(), SUCCESSOR, "the queued upgrade activated first");
    }

    /// @notice A whitelist lookup that fails is not a removal: the full timelock still applies.
    function test_EarlyActivation_FailedLookupKeepsTimelock() public {
        uint256 approvedAt = _queueUpgrade();
        uint256 effectiveTs = approvedAt + factory.IDENTIFIER_UPGRADE_TIMELOCK();
        _breakLookup(incumbent);

        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        _expectTimelocked(effectiveTs);
        factory.activateIdentifierUpgrade();
    }

    /// @notice A whitelist reply that is not a boolean is no answer: the gates close and the
    ///         timelock still applies.
    function test_EarlyActivation_MalformedWhitelistReplyKeepsTimelock() public {
        uint256 approvedAt = _queueUpgrade();
        uint256 effectiveTs = approvedAt + factory.IDENTIFIER_UPGRADE_TIMELOCK();
        vm.mockCall(
            address(mockOOv3),
            abi.encodeWithSelector(MockOptimisticOracleV3.isIdentifierSupported.selector, incumbent),
            abi.encode(uint256(2))
        );
        assertFalse(factory.umaIdentifierIsLive(), "an unreadable reply closes the gates");

        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        _expectTimelocked(effectiveTs);
        factory.activateIdentifierUpgrade();
    }

    /// @notice A finder reply that is not a clean address is no answer, even with the incumbent
    ///         actually removed: the timelock still applies.
    function test_EarlyActivation_DirtyFinderReplyKeepsTimelock() public {
        uint256 approvedAt = _queueUpgrade();
        uint256 effectiveTs = approvedAt + factory.IDENTIFIER_UPGRADE_TIMELOCK();
        _removeIncumbent();
        vm.mockCall(
            address(mockOOv3),
            abi.encodeWithSelector(MockOptimisticOracleV3.finder.selector),
            abi.encode((uint256(1) << 160) | uint256(uint160(address(mockOOv3))))
        );
        assertFalse(factory.umaIdentifierIsLive(), "an unreadable reply closes the gates");

        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        _expectTimelocked(effectiveTs);
        factory.activateIdentifierUpgrade();
    }

    /// @notice A successor removed along with the incumbent still cancels at activation.
    function test_EarlyActivation_RemovedSuccessorStillCancels() public {
        uint256 approvedAt = _queueUpgrade();
        _removeIncumbent();
        mockOOv3.setIdentifierSupported(SUCCESSOR, false);

        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), incumbent, "incumbent kept");
        (,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(effectiveTs, 0, "queue cleared");
    }

    // -------------------- disputes and removals --------------------

    /// @notice A listing disputed after its identifier was removed is discarded at once: both slots
    ///         freed and the seed refundable, with no wait for the grace. A ruling that reaches the
    ///         oracle later changes nothing and credits nothing twice.
    function test_DeadDispute_ListingDisputedAfterRemovalDiscardedAtOnce() public {
        bytes32 assertionId = _proposeListing();
        _removeIncumbent();
        _dispute(assertionId, bondUsdc);

        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalExpired(assertionId, deployer);
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);

        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "pair slot freed");
        assertEq(factory.pendingDeploymentByBaseFeed(ETH_USD_FEED_ID), bytes32(0), "feed slot freed");
        assertEq(factory.seedRefundOwed(deployer), seedUsdc, "seed refundable");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "nothing deployed");

        mockOOv3.mockDvmResolve(assertionId, true);
        mockOOv3.settleAndGetAssertionResult(assertionId);
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "a late ruling deploys nothing");
        assertEq(factory.seedRefundOwed(deployer), seedUsdc, "credited once");
    }

    /// @notice A dispute filed while the identifier was live keeps the grace after a later removal:
    ///         its request may have reached the DVM, so its ruling must still be able to land.
    function test_DeadDispute_DisputeBeforeRemovalKeepsGrace() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        bytes32 assertionId = _proposeListing();
        _dispute(assertionId, bondUsdc);
        _removeIncumbent();

        _expectListingNotExpired(_listingGraceEnd(proposedAt));
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
    }

    /// @notice A lookup that fails while the dispute is filed records nothing, so the proposal keeps
    ///         the grace even once the lookup works again.
    function test_DeadDispute_FailedLookupAtDisputeKeepsGrace() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        bytes32 assertionId = _proposeListing();
        _removeIncumbent();
        _breakLookup(incumbent);
        _dispute(assertionId, bondUsdc);
        vm.clearMockedCalls();

        _expectListingNotExpired(_listingGraceEnd(proposedAt));
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
    }

    /// @notice A lookup that fails at expiry keeps the grace for a proposal disputed after the
    ///         removal.
    function test_DeadDispute_FailedLookupAtExpiryKeepsGrace() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        bytes32 assertionId = _proposeListing();
        _removeIncumbent();
        _dispute(assertionId, bondUsdc);
        _breakLookup(incumbent);

        _expectListingNotExpired(_listingGraceEnd(proposedAt));
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
    }

    /// @notice An identifier UMA whitelists again before expiry restores the grace: a refused
    ///         request could then be filed with the DVM after all.
    function test_DeadDispute_ReWhitelistedIdentifierKeepsGrace() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        bytes32 assertionId = _proposeListing();
        _removeIncumbent();
        _dispute(assertionId, bondUsdc);
        mockOOv3.setIdentifierSupported(incumbent, true);

        _expectListingNotExpired(_listingGraceEnd(proposedAt));
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
    }

    /// @notice An upgrade disputed after the incumbent it was asserted under was removed is
    ///         discarded at once, and the freed slot takes a new proposal, asserted under the
    ///         proposed identifier.
    function test_DeadDispute_UpgradeDisputedAfterRemovalDiscardedAtOnce_SlotReopens() public {
        bytes32 assertionId = _proposeUpgrade(SUCCESSOR);
        _removeIncumbent();
        _dispute(assertionId, factory.requiredIdentifierUpgradeBond());

        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeExpired(assertionId, proposer);
        factory.expireStuckIdentifierUpgradeProposal();
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot freed");

        bytes32 retry = _proposeUpgrade(SUCCESSOR);
        assertEq(mockOOv3.assertionIdentifier(retry), SUCCESSOR, "retry asserted under the successor");
    }

    /// @notice The rule reads the assertion's own identifier: an upgrade the factory asserted under
    ///         the live successor, because the incumbent was already removed, keeps the grace when
    ///         disputed.
    function test_DeadDispute_RoutedUpgradeUnderLiveSuccessorKeepsGrace() public {
        _removeIncumbent();
        uint256 proposedAt = vm.getBlockTimestamp();
        bytes32 assertionId = _proposeUpgrade(SUCCESSOR);
        assertEq(mockOOv3.assertionIdentifier(assertionId), SUCCESSOR, "routed under the successor");
        _dispute(assertionId, factory.requiredIdentifierUpgradeBond());

        _expectUpgradeNotExpired(_upgradeGraceEnd(proposedAt));
        factory.expireStuckIdentifierUpgradeProposal();
    }

    /// @notice A lookup that fails at expiry keeps the grace for an upgrade disputed after the
    ///         removal.
    function test_DeadDispute_UpgradeFailedLookupAtExpiryKeepsGrace() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        bytes32 assertionId = _proposeUpgrade(SUCCESSOR);
        _removeIncumbent();
        _dispute(assertionId, factory.requiredIdentifierUpgradeBond());
        _breakLookup(incumbent);

        _expectUpgradeNotExpired(_upgradeGraceEnd(proposedAt));
        factory.expireStuckIdentifierUpgradeProposal();
    }

    /// @notice A removal alone never shortens an undisputed proposal's liveness: both expiry paths
    ///         still wait for it.
    function test_UndisputedProposalsStillWaitOutLiveness() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        _proposeListing();
        _proposeUpgrade(SUCCESSOR);
        _removeIncumbent();
        uint256 listingExpiry = proposedAt + factory.DEPLOYMENT_LIVENESS();
        uint256 upgradeExpiry = proposedAt + factory.IDENTIFIER_UPGRADE_LIVENESS();

        _expectListingNotExpired(listingExpiry);
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
        _expectUpgradeNotExpired(upgradeExpiry);
        factory.expireStuckIdentifierUpgradeProposal();
    }

    // -------------------- voided listings --------------------

    /// @notice An undisputed listing that settles after its identifier was removed is voided: no
    ///         pair, both slots freed, the seed refundable and the bond back from UMA.
    function test_Void_UndisputedListingSettledAfterRemoval() public {
        bytes32 assertionId = _proposeListing();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        _removeIncumbent();
        uint256 balanceBefore = usdc.balanceOf(deployer);

        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalVoided(assertionId, deployer);
        factory.settleDeploymentProposal(assertionId);

        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "nothing deployed");
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "pair slot freed");
        assertEq(factory.pendingDeploymentByBaseFeed(ETH_USD_FEED_ID), bytes32(0), "feed slot freed");
        assertEq(factory.seedRefundOwed(deployer), seedUsdc, "seed refundable");
        assertEq(usdc.balanceOf(deployer) - balanceBefore, bondUsdc, "UMA returned the bond");

        vm.prank(deployer);
        factory.claimSeedRefund();
        assertEq(usdc.balanceOf(deployer) - balanceBefore, bondUsdc + seedUsdc, "seed claimed");
    }

    /// @notice The void also applies where the expiry path approves an undisputed proposal whose
    ///         settlement cannot run, here because UMA's bond payout to the deployer reverts. A
    ///         settlement that lands later pays the bond and changes nothing else.
    function test_Void_AppliesOnExpiryApproval() public {
        bytes32 assertionId = _proposeListing();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        _removeIncumbent();
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, deployer, bondUsdc),
            bytes("Blacklistable: blacklisted")
        );
        uint256 balanceBefore = usdc.balanceOf(deployer);

        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalVoided(assertionId, deployer);
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);

        assertEq(usdc.balanceOf(deployer), balanceBefore, "settlement did not run: the bond is still on the oracle");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "nothing deployed");
        assertEq(factory.seedRefundOwed(deployer), seedUsdc, "seed refundable");

        vm.clearMockedCalls();
        mockOOv3.settleAndGetAssertionResult(assertionId);
        assertEq(usdc.balanceOf(deployer) - balanceBefore, bondUsdc, "the late settlement pays the bond");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "and deploys nothing");
        assertEq(factory.seedRefundOwed(deployer), seedUsdc, "and credits nothing twice");
    }

    /// @notice A disputed listing the DVM ruled TRUE deploys even after its identifier was removed.
    function test_Void_NotAppliedToDvmRuling() public {
        bytes32 assertionId = _proposeListing();
        _dispute(assertionId, bondUsdc);
        mockOOv3.mockDvmResolve(assertionId, true);
        _removeIncumbent();

        factory.settleDeploymentProposal(assertionId);
        assertTrue(factory.getPairAddress(ETH_USD_FEED_ID) != address(0), "ruled TRUE, so deployed");
    }

    /// @notice A whitelist lookup that fails at settlement is not a removal: the listing deploys.
    function test_Void_FailedLookupDeploys() public {
        bytes32 assertionId = _proposeListing();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        _breakLookup(incumbent);

        factory.settleDeploymentProposal(assertionId);
        assertTrue(factory.getPairAddress(ETH_USD_FEED_ID) != address(0), "deployed");
    }

    /// @notice An assertion the oracle cannot read back is not voided, even with its identifier
    ///         removed: the listing deploys.
    function test_Void_FailedAssertionReadDeploys() public {
        bytes32 assertionId = _proposeListing();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        _removeIncumbent();
        vm.mockCallRevert(
            address(mockOOv3), abi.encodeWithSelector(MockOptimisticOracleV3.getAssertion.selector, assertionId), "down"
        );

        factory.settleDeploymentProposal(assertionId);
        assertTrue(factory.getPairAddress(ETH_USD_FEED_ID) != address(0), "deployed");
    }

    /// @notice The void reads the assertion's own identifier, not the current one: a listing made
    ///         under the old identifier is voided once that identifier is removed, even after the
    ///         protocol has moved to a live successor.
    function test_Void_ReadsTheAssertionsIdentifier() public {
        bytes32 listing = _proposeListing();
        uint256 approvedAt = _queueUpgrade();
        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_TIMELOCK());
        factory.activateIdentifierUpgrade();
        assertEq(factory.umaIdentifier(), SUCCESSOR, "upgraded on the full timelock");

        _removeIncumbent();
        assertTrue(factory.umaIdentifierIsLive(), "the current identifier is unaffected");

        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalVoided(listing, deployer);
        factory.settleDeploymentProposal(listing);
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "voided");
    }

    // -------------------- a migration end to end --------------------

    /// @notice A listing in flight when UMA retires the incumbent: the upgrade queued meanwhile
    ///         activates at the notice floor, and proposing the asset again settles the stale
    ///         listing first, which voids it, then asserts the new one under the successor.
    function test_Migration_StaleListingVoidedByTheRelisting() public {
        bytes32 listing = _proposeListing();
        bytes32 upgrade = _proposeUpgrade(SUCCESSOR);

        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleIdentifierUpgradeProposal(upgrade);
        uint256 approvedAt = vm.getBlockTimestamp();

        _removeIncumbent();
        vm.warp(approvedAt + factory.IDENTIFIER_UPGRADE_MIN_NOTICE());
        factory.activateIdentifierUpgrade();

        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalVoided(listing, deployer);
        bytes32 again = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        assertEq(mockOOv3.assertionIdentifier(again), SUCCESSOR, "relisted under the successor");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "the stale listing never deployed");
    }
}
