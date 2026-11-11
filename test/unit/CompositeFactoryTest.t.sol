// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPythLazer} from "../mocks/MockPythLazer.sol";
import {LazerUpdate} from "../LazerUpdate.sol";

/// @notice Factory-level tests for composite pair deployment: the FX leg forces
///         non-continuous trading, and a composite pair prices end-to-end through BazaarPair.
contract CompositeFactoryTest is Test {
    bytes32 constant ASSET_JPY_FEED = bytes32(uint256(9001));
    bytes32 constant USD_JPY_FEED = bytes32(uint256(9002));
    bytes32 constant ASSET_GBP_FEED = bytes32(uint256(9003));
    bytes32 constant GBP_USD_FEED = bytes32(uint256(9004));
    bytes32 constant JPY_USD_FEED = bytes32(uint256(9005));
    int32 constant PYTH_EXPO = -8;

    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    BazaarFactory factory;
    BazaarOracle oracle;
    MockUSDC usdc;
    MockPythLazer mockPyth;
    MockOptimisticOracleV3 mockOOv3;
    bytes32 compositeId;
    address user1;

    function setUp() public {
        user1 = makeAddr("user1");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar deployer = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = deployer.deploy(makeAddr("bugBounty"));

        (, address usdcContract, address optimisticOracleV3,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(optimisticOracleV3);
        oracle = factory.oracle();
        mockPyth = MockPythLazer(address(oracle.pythLazer()));

        compositeId = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);

        usdc.mint(user1, PROPOSAL_TOTAL_USDC * 2);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function test_DeploymentClaim_NamesEligibleAssetsAndSpotFeedRule() public {
        bytes32 rawFeed = bytes32(uint256(1));
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(rawFeed, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(assertionId);
        // The four eligible asset classes, and what stays out.
        assertTrue(_contains(claim, "(a) the common shares of a publicly traded company, or a depositary receipt"));
        assertTrue(
            _contains(claim, "(b) a currency, as a spot FX rate; (c) a physical commodity; (d) a cryptocurrency;")
        );
        assertTrue(
            _contains(
                claim, "(e) an unleveraged exchange-traded fund that holds the shares of a broad stock market index"
            )
        );
        assertTrue(
            _contains(
                claim,
                "Every other asset is INVALID, including: indices themselves; every other fund, ETF, ETN and trust;"
            )
        );
        assertTrue(_contains(claim, "anything else with an expiry, settlement or resolution date"));
        assertTrue(_contains(claim, "leveraged or inverse products"));
        assertTrue(_contains(claim, "pegged, rebased or managed toward a target price"));
        // One market per asset: the asset's own spot feed where one exists, and its USD-quoted feed
        // where several spot feeds reach the same security.
        assertTrue(_contains(claim, "SPOT FEED ONLY, ONE MARKET PER ASSET"));
        assertTrue(_contains(claim, "a Pyth-computed index, synthetic or 24/7 price of a stock that has its own feed"));
        assertTrue(_contains(claim, "a tokenized, wrapped, bridged or staked version of the asset"));
        assertTrue(_contains(claim, "eligible only if Pyth Pro has NO spot feed for the asset in any currency"));
        assertTrue(_contains(claim, "it may be proposed as a composite only if no USD-quoted feed for it exists"));
        assertTrue(_contains(claim, "only the class with the greater trading volume is eligible"));
        // ETFs on one index are one asset: the most traded one, and only while no other is listed.
        assertTrue(_contains(claim, "ETFs that track the same index are ONE asset"));
        assertTrue(_contains(claim, "highest average daily dollar trading volume over the 30 days before the proposal"));
        assertTrue(_contains(claim, "another ETF tracking that index is live or proposed and pending"));
        // The claim names Pyth Pro's verifier and writes the feed ID as Pyth Pro lists it: in decimal.
        assertTrue(
            _contains(
                claim,
                abi.encodePacked(
                    ". Pyth Pro verifier contract: ",
                    Strings.toHexString(address(oracle.pythLazer())),
                    ". Base feed ID (Pyth Pro): 1."
                )
            )
        );
        assertTrue(_contains(claim, "is the numeric ID of an ACTIVE feed in the Pyth Pro price feed registry"));
        assertTrue(_contains(claim, "Pyth Core feed IDs are a different namespace and are INVALID"));
        assertTrue(_contains(claim, "a funding-rate or redemption-rate feed - is INVALID"));
        assertTrue(_contains(claim, "clock on weekdays but stops over the weekend"));
    }

    function test_DeploymentClaim_CompositeListsBothLegs() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(assertionId);
        assertTrue(_contains(claim, "Composite feed ID (USD price = base leg DIVIDED by quote leg)"));
        assertTrue(_contains(claim, "Base leg feed ID (Pyth Pro, asset in its native currency): 9001."));
        assertTrue(_contains(claim, "Quote leg feed ID (Pyth Pro, FX conversion to USD): 9002."));
        assertTrue(_contains(claim, "Quote leg inverted: true"));
        assertTrue(_contains(claim, "eligible ONLY as a composite, and only if that currency is one of: "));
        assertTrue(
            _contains(claim, "one of: EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH, CNY, KRW, TWD. ")
        );
        assertTrue(_contains(claim, "the Pyth Pro spot FX feed between USD and EXACTLY that currency"));
        assertTrue(_contains(claim, "onshore CNY takes the offshore USD/CNH feed, not USD/CNY"));
        assertTrue(_contains(claim, "The 'quote leg inverted' flag must be accurate"));
        assertTrue(_contains(claim, "FX.USD/XXX is 'true' and FX.XXX/USD is 'false'"));
        assertTrue(_contains(claim, "must be close to the asset's actual US dollar price"));
        assertTrue(_contains(claim, "'false' for shares, ETFs, FX, commodities and every composite"));
    }

    function test_TerminationClaim_ContainsStructuralChangeCatchAll() public {
        // Deploy a composite pair
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 deployAssertionId = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(deployAssertionId);
        address pair = factory.getPairAddress(compositeId);

        // Propose its termination and inspect the UMA claim
        BazaarPairTerminator terminator = factory.pairTerminator();
        vm.startPrank(user1);
        usdc.approve(address(terminator), terminator.TERMINATION_PROPOSAL_BOND());
        bytes32 termAssertionId =
            terminator.proposeTermination(pair, 3, block.timestamp + 7 days, "Reverse split announced for next month.");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(termAssertionId);
        assertTrue(_contains(claim, "will make the asset's price series discontinuous"));
        assertTrue(_contains(claim, "special dividends or other one-time distributions exceeding 5%"));
        assertTrue(_contains(claim, "redenomination of the quote currency of a composite pair"));
        assertTrue(_contains(claim, "market-driven price moves of ANY expected size"));
        // Composite pairs resolve their legs in termination claims too
        assertTrue(_contains(claim, "Base leg feed ID (Pyth Pro): 9001. Quote leg feed ID (Pyth Pro, FX): 9002."));
        assertTrue(
            _contains(
                claim,
                abi.encodePacked(" Pyth Pro verifier contract: ", Strings.toHexString(address(oracle.pythLazer())))
            )
        );
        assertTrue(_contains(claim, "(4) PYTH VERIFIER MIGRATION: The Pyth Pro verifier contract"));
        assertTrue(
            _contains(
                claim, "A Pyth Pro feed listed above has stopped publishing prices or is scheduled to be decommissioned"
            )
        );
        assertTrue(
            _contains(
                claim,
                "settles at the price carried by the Pyth Pro one-second update stamped with the scheduled timestamp, the feed's most recent price as of that second"
            )
        );
        assertTrue(
            _contains(
                claim,
                "For 12 hours after the scheduled timestamp only that update settles the pair; after that, a call that does not bring it, or brings one that carries no price, settles the pair at its own last stored price."
            )
        );
        assertTrue(
            _contains(
                claim,
                "Resolved FALSE: at the median of 5 prices from Pyth Pro one-second updates - the first the earliest update carrying a price generated at or after the timestamp, each later one the earliest carrying a price generated at least 10 minutes after the update before it - and the holders who voted for it forfeit half"
            )
        );
    }

    function test_ProposeCompositePair_RevertsWhenContinuous() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(BazaarFactory.Factory__CompositePairMustBeNonContinuous.selector);
        factory.proposePairDeployment(compositeId, true, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();
    }

    /// @notice A composite ID nobody has registered does not have the form of a Pyth Pro feed ID,
    ///         so it cannot be proposed as a single feed and turned into a composite by registering
    ///         the legs later.
    ///         Once registered it is adjudicated as a composite: the continuous flag is refused and
    ///         the claim names both legs.
    function test_ProposeUnregisteredCompositeId_Reverts() public {
        bytes32 gbpComposite = oracle.getCompositeId(ASSET_GBP_FEED, GBP_USD_FEED, false);

        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__InvalidFeedId.selector, gbpComposite));
        factory.proposePairDeployment(gbpComposite, true, PROPOSAL_TOTAL, "Lloyds on LSE");
        vm.stopPrank();

        oracle.registerComposite(ASSET_GBP_FEED, GBP_USD_FEED, false);

        vm.startPrank(user1);
        vm.expectRevert(BazaarFactory.Factory__CompositePairMustBeNonContinuous.selector);
        factory.proposePairDeployment(gbpComposite, true, PROPOSAL_TOTAL, "Lloyds on LSE");
        bytes32 assertionId = factory.proposePairDeployment(gbpComposite, false, PROPOSAL_TOTAL, "Lloyds on LSE");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(assertionId);
        assertTrue(_contains(claim, "Composite feed ID (USD price = base leg MULTIPLIED by quote leg)"));
        assertTrue(_contains(claim, "Quote leg inverted: false"));
    }

    /// @notice A raw feed ID must be a non-zero 32-bit integer, the form of a Pyth Pro feed ID: zero,
    ///         an ID past 32 bits and a hash are refused before any bond moves, and the largest
    ///         32-bit ID is listable.
    function test_ProposeRawFeed_MustHaveTheFormOfAPythProFeedId() public {
        bytes32 largest = bytes32(uint256(type(uint32).max));
        bytes32[3] memory malformed =
            [bytes32(0), bytes32(uint256(type(uint32).max) + 1), keccak256("test.EQUITY.NOT-AN-ID/USD")];

        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        for (uint256 i = 0; i < malformed.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__InvalidFeedId.selector, malformed[i]));
            factory.proposePairDeployment(malformed[i], false, PROPOSAL_TOTAL, "Malformed");
        }
        assertEq(usdc.balanceOf(user1), PROPOSAL_TOTAL_USDC * 2, "no bond or seed was taken");

        bytes32 assertionId = factory.proposePairDeployment(largest, false, PROPOSAL_TOTAL, "Largest");
        vm.stopPrank();
        assertTrue(assertionId != bytes32(0));
        assertTrue(_contains(mockOOv3.claims(assertionId), "Base feed ID (Pyth Pro): 4294967295."));
    }

    function test_CompositePair_DeploysAndPricesEndToEnd() public {
        // Propose + settle through UMA
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        BazaarPair pair = BazaarPair(payable(factory.getPairAddress(compositeId)));
        assertTrue(address(pair) != address(0));
        assertEq(pair.baseFeedId(), compositeId);
        assertFalse(pair.isContinuouslyTraded());

        // Refresh the pair price with one update carrying both legs:
        // 3000 JPY at USD/JPY 150 => $20
        uint64 nowTs = uint64(block.timestamp);
        pair.refreshPrice(
            LazerUpdate.one(
                LazerUpdate.livePair(
                    LazerUpdate.feed(ASSET_JPY_FEED, 3000e8, 3e8, int16(PYTH_EXPO), nowTs * LazerUpdate.MICROS),
                    LazerUpdate.feed(USD_JPY_FEED, 150e8, 0.15e8, int16(PYTH_EXPO), nowTs * LazerUpdate.MICROS),
                    nowTs
                )
            )
        );

        (uint256 spot,,,,) = pair.lastPairPrice();
        assertEq(spot, 20e18);
    }

    /// @notice A composite pair settles under UMA's rule at its cutoff tick, composed from each
    ///         leg's price at that tick, whether the legs arrive in one update or in one each. A
    ///         leg that was quiet at the cutoff is priced at what the tick carries forward for it.
    function test_CompositePair_SettlesAtTheCutoffTick() public {
        BazaarPairTerminator terminator = factory.pairTerminator();
        BazaarPair pair = BazaarPair(payable(_list(compositeId, false, "Toyota on TSE")));

        uint64 cutoff = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(pair.umaContract());
        pair.setScheduledTermination(cutoff, address(this));

        // 3300 JPY at USD/JPY 150 => $22, the asset leg last generated an hour before the cutoff.
        bytes[] memory perLeg = LazerUpdate.two(
            LazerUpdate.tick(ASSET_JPY_FEED, 3300e8, 0, int16(PYTH_EXPO), cutoff, cutoff - 1 hours),
            LazerUpdate.tick(USD_JPY_FEED, 150e8, 0, int16(PYTH_EXPO), cutoff, cutoff)
        );
        bytes[] memory oneLegOnly = LazerUpdate.one(perLeg[0]);

        vm.warp(cutoff + 1); // within grace
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__FeedNotInUpdate.selector, USD_JPY_FEED));
        terminator.terminateScheduledPair(address(pair), oneLegOnly);

        terminator.terminateScheduledPair(address(pair), perLeg);
        assertEq(pair.auxState().settlementPrice, 22e18, "composed from both legs at the tick");
    }

    /// @notice The same settlement from one update carrying both legs.
    function test_CompositePair_SettlesAtTheCutoffTick_BothLegsInOneUpdate() public {
        BazaarPairTerminator terminator = factory.pairTerminator();
        BazaarPair pair = BazaarPair(payable(_list(compositeId, false, "Toyota on TSE")));

        uint64 cutoff = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(pair.umaContract());
        pair.setScheduledTermination(cutoff, address(this));

        bytes[] memory both = LazerUpdate.one(
            LazerUpdate.sign(
                LazerUpdate.payload(
                    cutoff * LazerUpdate.MICROS,
                    LazerUpdate.CHANNEL_FIXED_RATE_1000,
                    LazerUpdate.feed(
                        ASSET_JPY_FEED, 3300e8, 0, int16(PYTH_EXPO), (cutoff - 1 hours) * LazerUpdate.MICROS
                    ),
                    LazerUpdate.feed(USD_JPY_FEED, 150e8, 0, int16(PYTH_EXPO), cutoff * LazerUpdate.MICROS)
                )
            )
        );

        vm.warp(cutoff + 1); // within grace
        terminator.terminateScheduledPair(address(pair), both);
        assertEq(pair.auxState().settlementPrice, 22e18, "composed from both legs at the tick");
    }

    // ==================== One market per asset ====================

    /// @dev Proposes `feedId` from user1 and settles it approved once liveness has passed.
    function _list(bytes32 feedId, bool continuous, string memory description) internal returns (address pair) {
        usdc.mint(user1, PROPOSAL_TOTAL_USDC);
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(feedId, continuous, PROPOSAL_TOTAL, description);
        vm.stopPrank();
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        pair = factory.getPairAddress(feedId);
        assertTrue(pair != address(0), "pair deployed");
    }

    /// @dev A proposal of `feedId` is refused because `holder` already prices the JPY base leg.
    function _expectBaseLegHeld(bytes32 feedId, address holder) internal {
        usdc.mint(user1, PROPOSAL_TOTAL_USDC);
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarFactory.Factory__BaseFeedAlreadyListed.selector, ASSET_JPY_FEED, holder)
        );
        factory.proposePairDeployment(feedId, false, PROPOSAL_TOTAL, "Toyota again");
        vm.stopPrank();
    }

    /// @notice The same stock through a different FX feed hashes to a different pair ID over the
    ///         same base leg; the factory refuses it while the first market is live.
    function test_OneMarketPerAsset_SameBaseLegThroughAnotherFxFeedIsRefused() public {
        address pair = _list(compositeId, false, "Toyota on TSE");
        assertEq(factory.pairAddressByBaseFeed(ASSET_JPY_FEED), pair, "holder indexed by base leg");

        bytes32 viaJpyUsd = oracle.registerComposite(ASSET_JPY_FEED, JPY_USD_FEED, false);
        assertTrue(viaJpyUsd != compositeId, "distinct pair ID");
        _expectBaseLegHeld(viaJpyUsd, pair);
    }

    /// @notice The opposite inversion flag over the same two legs is another pair ID; refused too.
    function test_OneMarketPerAsset_OppositeInversionIsRefused() public {
        address pair = _list(compositeId, false, "Toyota on TSE");
        bytes32 inverted = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, false);
        _expectBaseLegHeld(inverted, pair);
    }

    /// @notice A composite over a feed that is already listed directly is refused: both would
    ///         price the same asset.
    function test_OneMarketPerAsset_CompositeOverADirectListingIsRefused() public {
        address direct = _list(ASSET_JPY_FEED, false, "Toyota quoted in JPY");
        assertEq(factory.pairAddressByBaseFeed(ASSET_JPY_FEED), direct, "direct listing holds its own feed");
        _expectBaseLegHeld(compositeId, direct);
    }

    /// @notice A direct listing of a live composite's base leg is refused the same way.
    function test_OneMarketPerAsset_DirectListingOverACompositeIsRefused() public {
        address pair = _list(compositeId, false, "Toyota on TSE");
        _expectBaseLegHeld(ASSET_JPY_FEED, pair);
    }

    /// @notice One proposal per asset in flight. A second composite over the same base leg is
    ///         refused while the first is pending, naming the pending proposal's pair ID; a
    ///         rejected first proposal releases the asset, and the second is settled in on the way.
    function test_OneMarketPerAsset_PendingProposalHoldsTheAsset() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 first = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();
        assertEq(factory.pendingDeploymentByBaseFeed(ASSET_JPY_FEED), first, "pending indexed by base leg");

        bytes32 viaJpyUsd = oracle.registerComposite(ASSET_JPY_FEED, JPY_USD_FEED, false);
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalAlreadyPending.selector, compositeId));
        factory.proposePairDeployment(viaJpyUsd, false, PROPOSAL_TOTAL, "Toyota via JPY/USD");
        vm.stopPrank();

        // The first proposal is disputed and voted down; the second proposal settles it on the
        // way in and takes the slot.
        address disputer = makeAddr("disputer");
        uint256 bond = factory.requiredDeploymentBond();
        usdc.mint(disputer, bond);
        vm.startPrank(disputer);
        usdc.approve(address(mockOOv3), bond);
        mockOOv3.disputeAssertion(first, disputer);
        vm.stopPrank();
        mockOOv3.mockDvmResolve(first, false);

        vm.prank(user1);
        bytes32 second = factory.proposePairDeployment(viaJpyUsd, false, PROPOSAL_TOTAL, "Toyota via JPY/USD");
        assertEq(factory.pendingDeploymentByBaseFeed(ASSET_JPY_FEED), second, "second proposal holds the asset");
        assertEq(factory.pendingDeploymentByPairId(compositeId), bytes32(0), "rejected proposal released its pair ID");
        assertEq(factory.pendingDeploymentByPairId(viaJpyUsd), second, "second proposal pending under its pair ID");
        assertEq(factory.getPairAddress(compositeId), address(0), "rejected proposal deployed nothing");
    }

    /// @notice A terminated holder releases the asset: the next market over the same base leg,
    ///         here through the other FX direction, lists and becomes the holder, while the old
    ///         pair ID still resolves to the terminated pair.
    function test_OneMarketPerAsset_ReleasedOnceTheHolderTerminates() public {
        address first = _list(compositeId, false, "Toyota on TSE");
        bytes32 viaJpyUsd = oracle.registerComposite(ASSET_JPY_FEED, JPY_USD_FEED, false);
        _expectBaseLegHeld(viaJpyUsd, first);

        // The pair never stored a price, so once it is older than the oracle-dead threshold the
        // stale-price path settles it, and with no positions open finalize follows at once.
        BazaarPairTerminator terminator = factory.pairTerminator();
        vm.warp(block.timestamp + 21 days + 1);
        terminator.terminateStalePair(first);
        BazaarPair(payable(first)).finalizeTermination();
        assertTrue(BazaarPair(payable(first)).isPairTerminated(), "holder terminated");

        address second = _list(viaJpyUsd, false, "Toyota via JPY/USD");
        assertEq(factory.pairAddressByBaseFeed(ASSET_JPY_FEED), second, "new holder");
        assertEq(factory.getPairAddress(compositeId), first, "old pair ID keeps the terminated pair");
        assertEq(factory.getPairAddress(viaJpyUsd), second, "new pair ID resolves to the new pair");
    }
}
