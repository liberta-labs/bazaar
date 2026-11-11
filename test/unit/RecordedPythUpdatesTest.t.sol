// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {LazerPayloadLib} from "../../src/libraries/LazerPayloadLib.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {MockPythLazer} from "../mocks/MockPythLazer.sol";
import {LazerPayloadReader} from "./LazerPayloadLibTest.t.sol";

/// @dev Exposes the deploy script's verifier probe.
contract DeployProbe is DeployBazaar {
    function probe(address pythLazer) external {
        _assertVerifierAcceptsPyth(pythLazer);
    }
}

/// @notice Updates Pyth Pro's own signer signed, as Pyth's archive serves them, run through
///         BazaarOracle with a verifier that trusts that signer. Every other test builds its updates
///         with LazerUpdate; these pin the parser, the live and latest-price paths and both
///         settlement rules to bytes Pyth produces. The AAPL updates span a real close: its
///         post-market session ends at 20:00 New York time on a Friday, and the feed is quiet until
///         its overnight session opens at 20:00 on the Sunday.
contract RecordedPythUpdatesTest is Test {
    /// @dev The key Pyth signs its Pro updates with, as its verifier on Arbitrum lists it.
    address internal constant PYTH_SIGNER = 0x26FB61A864c758AE9fBA027a96010480658385B9;
    bytes32 internal constant BTC = bytes32(uint256(1));
    bytes32 internal constant ETH = bytes32(uint256(2));
    bytes32 internal constant AAPL = bytes32(uint256(922));

    /// @dev The Friday post-market close the AAPL updates straddle, and a Monday regular-session second.
    uint64 internal constant CLOSE = 1794013200;
    uint64 internal constant REGULAR = 1794236400;
    /// @dev The last price before the close was generated 50 ms before it, in this second.
    uint256 internal constant LAST_BEFORE_CLOSE = 1794013199;
    uint64 internal constant SATURDAY_NOON = 1794070800;
    uint64 internal constant CHAIN_CUTOFF = 1794012900;
    uint64 internal constant CHAIN_LAST_TICK = 1794187802;

    bytes internal constant AAPL_REGULAR =
        hex"2a22999a8d5b6fba7dac287ad316fba03e8236d62a804184238c1ba64581f02d209f27027b4b3105ebeb580cfccc9c5690f2289d520cb1d6357561f19429e8d7e843e3b201003293c7d37500065fd93743dc0004010000039a0400000000000213478b04fffb0500000000000022bc0c0100065fd93743dc00";
    bytes internal constant BTC_ETH_REGULAR =
        hex"2a22999a19358f8c810243297f20a36a2a87e7038ca55531c3c47442da7b25bee2c6eb345971b90bf9900b5519c2814a31675ea578117037576da72c6042954b5a2b35fe01005693c7d37500065fd93743dc000402000000010400000006cdcbaa1e6d04fff80500000001705b87530c0100065fd93743dc00000000020400000000318523f19a04fff805000000000ac1a9b10c0100065fd93743dc00";
    bytes internal constant AAPL_CLOSE_PLUS_30 =
        hex"2a22999aa30e4e507f46e5b01d2fcf03b67bfb14fbca09f8fcb29c2012401d654dbc15b41deb01bde27ea767838a9d9d613b92de8e413c6ee51706334a789f1c3a80899c00003293c7d37500065fa5414be78004010000039a040000000000020af8e104fffb0500000000000021390c0100065fa53f8160b0";
    bytes internal constant AAPL_CLOSE_PLUS_90 =
        hex"2a22999a097ca17788e3be88662a2d00341909caa0388c21778034394b73ced6765bbff50ed4dfcebbc1c59f1f9537d54964dd51cc4fa326b16aafdaeb96de889835e48301003293c7d37500065fa544df6e8004010000039a040000000000020af8e104fffb0500000000000021390c0100065fa53f8160b0";
    bytes internal constant AAPL_SATURDAY_NOON =
        hex"2a22999a20910f9018587c3a14db0ec4b3a0e88dfb74e5dbcb35a5bcd86b4ee5c98145890f3fd883a259407610bf4824da1b997d0e4a5f5db1a1cc8ba21b32571d6b2b1901003293c7d37500065fb2a8bc640004010000039a040000000000020af8e104fffb0500000000000021390c0100065fa53f8160b0";
    bytes internal constant AAPL_CHAIN_0 =
        hex"2a22999aa0163bb9241d17fa972267c3799b6fef3e5e980d2c3bae7913d4b24c5321e121161cf6d20dbd6d63a3abd25bb228520abdab5e0548450f4408fdc5491c85bede00003293c7d37500065fa52da0810004010000039a040000000000020aed2c04fffb05000000000000213c0c0100065fa52da08100";
    bytes internal constant AAPL_CHAIN_1 =
        hex"2a22999aa86664a8105f68db735041deab130592d32daa7fbe72aacb9f78ddb402c118802414f0b924da489227997c49d6ce4e6a75451d54827c9d167a0e31b8756ccddb01003293c7d37500065fcd7b40264004010000039a040000000000020af8e104fffb0500000000000021390c0100065fa53f8160b0";
    bytes internal constant AAPL_CHAIN_2 =
        hex"2a22999af60b12f2d82ca9ac813f07082fe5b8ac1014d97fb582c35163896296c434424947c177bc74086e0e2130e4646a5835c00172fa984f95b0a6324d6eb9a7e450d700003293c7d37500065fcd7b4f688004010000039a040000000000020b73e804fffb0500000000000000010c0100065fcd7b4f6880";
    bytes internal constant AAPL_CHAIN_3 =
        hex"2a22999aa37d3997a4766955e663b81d559334590c97039346eabd96c7d5e697b004d74a6b5f65c7c4807dd6365f90e6af14edcde114110bc00fef0b455a783d721df41600003293c7d37500065fcd9f12ae8004010000039a040000000000020de4e804fffb0500000000000000010c0100065fcd9f12ae80";
    bytes internal constant AAPL_CHAIN_4 =
        hex"2a22999a81afdd8637290bf2704811e5071dc3916546fe8587090207ade5351f5f5e7654015f640bbc170a5e248ec5664d11444fb95d0fd049da39632da9e9af0a46784301003293c7d37500065fcdc2d5f48004010000039a040000000000020cb43804fffb0500000000000000010c0100065fcdc2d5f480";
    bytes internal constant AAPL_CHAIN_5 =
        hex"2a22999a6ba04de56564a350e0e750a84417ddc9adf13d82cef49260efb2ee7b598c3dc6251404aa99dc76c3d1dbeeb14bc5eab3ae1936a8e1de0938bcc72ea8b91cd53100003293c7d37500065fcde6993a8004010000039a040000000000020c79a004fffb0500000000000000010c0100065fcde6993a80";

    MockPythLazer internal verifier;
    BazaarOracle internal oracle;
    LazerPayloadReader internal reader;

    function setUp() public {
        verifier = new MockPythLazer(0);
        verifier.updateTrustedSigner(PYTH_SIGNER, type(uint256).max);
        oracle = new BazaarOracle(address(verifier));
        reader = new LazerPayloadReader();
    }

    function _one(bytes memory u) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = u;
    }

    function _chain() internal pure returns (bytes[] memory u) {
        u = new bytes[](6);
        u[0] = AAPL_CHAIN_0;
        u[1] = AAPL_CHAIN_1;
        u[2] = AAPL_CHAIN_2;
        u[3] = AAPL_CHAIN_3;
        u[4] = AAPL_CHAIN_4;
        u[5] = AAPL_CHAIN_5;
    }

    /// @notice Pyth's signer signed the update, and the verifier hands back the payload that follows
    ///         the 71-byte envelope header, which LazerPayloadLib reads field by field.
    function test_SignedByPythAndReadFieldByField() public {
        (bytes memory payload, address signer) = verifier.verifyUpdate(AAPL_REGULAR);
        assertEq(signer, PYTH_SIGNER, "Pyth's signer");
        (uint64 timestamp, uint8 channel, LazerPayloadLib.Feed memory aapl,) = reader.readFeeds(payload, 922, 0);
        assertEq(timestamp, uint64(REGULAR) * 1e6, "stamped on the second");
        assertEq(channel, LazerPayloadLib.CHANNEL_FIXED_RATE_1000, "one-second channel");
        assertTrue(aapl.found, "AAPL in the update");
        assertEq(aapl.price, 34817931, "price mantissa");
        assertEq(aapl.exponent, -5, "exponent");
        assertEq(aapl.confidence, 8892, "confidence mantissa");
        assertEq(aapl.feedUpdateTimestamp, uint64(REGULAR) * 1e6, "generated on the second");
    }

    /// @notice The live path reads a single feed and a composite of two from real updates.
    function test_LivePrice() public {
        vm.warp(REGULAR);
        (uint256 spot, uint256 low, uint256 high, uint256 publishTime) =
            oracle.verifyAndFetchPrice(AAPL, _one(AAPL_REGULAR), 3);
        assertEq(spot, 348_179_310_000_000_000_000, "AAPL spot");
        assertEq(low, 348_090_390_000_000_000_000, "spot - confidence");
        assertEq(high, 348_268_230_000_000_000_000, "spot + confidence");
        assertEq(publishTime, REGULAR, "generated on the second");

        (spot,,,) = oracle.verifyAndFetchPrice(BTC, _one(BTC_ETH_REGULAR), 3);
        assertEq(spot, 74_809_549_860_930_000_000_000, "BTC spot");
        bytes32 btcInEth = oracle.registerComposite(BTC, ETH, true);
        (spot,,,) = oracle.verifyAndFetchPrice(btcInEth, _one(BTC_ETH_REGULAR), 3);
        assertApproxEqRel(spot, uint256(7480954986093) * 1e18 / 212687122842, 1e6, "BTC priced in ETH");
    }

    /// @notice Thirty seconds after the close Pyth's update still carries the last price, generated
    ///         before the close. The live path refuses it as stale; the latest-price path accepts it
    ///         as Pyth's latest, dated when it was generated.
    function test_LatestPrice_CarriedPastTheClose() public {
        vm.warp(CLOSE + 30);
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__StalePrice.selector, AAPL, LAST_BEFORE_CLOSE));
        oracle.verifyAndFetchPrice(AAPL, _one(AAPL_CLOSE_PLUS_30), 3);

        (uint256 spot,,, uint256 publishTime) = oracle.verifyAndFetchLatestPrice(AAPL, _one(AAPL_CLOSE_PLUS_30), 3, 60);
        assertEq(spot, 342_735_050_000_000_000_000, "the last price before the close");
        assertEq(publishTime, LAST_BEFORE_CLOSE, "dated when it was generated");
    }

    /// @notice Ninety seconds after the close the carried price is older than the minute allowed.
    function test_LatestPrice_CarriedTooLong() public {
        vm.warp(CLOSE + 90);
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__StalePrice.selector, AAPL, LAST_BEFORE_CLOSE));
        oracle.verifyAndFetchLatestPrice(AAPL, _one(AAPL_CLOSE_PLUS_90), 3, 60);
    }

    /// @notice An update issued more than three seconds before the block proves nothing about the
    ///         seconds since, so it is refused whatever it carries.
    function test_LatestPrice_UpdateIssuedTooLongAgo() public {
        vm.warp(CLOSE + 34);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__StaleUpdate.selector, uint64(CLOSE + 30) * 1e6)
        );
        oracle.verifyAndFetchLatestPrice(AAPL, _one(AAPL_CLOSE_PLUS_30), 3, 60);
    }

    /// @notice UMA's rule: Saturday noon's one-second update carries Friday's last price.
    function test_TickRule_WeekendCarriesTheClose() public {
        vm.warp(SATURDAY_NOON + 1);
        assertEq(oracle.fetchPriceAtTick(AAPL, _one(AAPL_SATURDAY_NOON), SATURDAY_NOON), 342_735_050_000_000_000_000);
    }

    /// @notice The chain rule across the weekend: one sample at the Friday cutoff, then the second
    ///         target falls in the closure, so its sample is proven by two updates: the last second
    ///         still carrying Friday's price, and the first one with Sunday's overnight price.
    function test_ChainRule_AcrossTheWeekend() public {
        vm.warp(CHAIN_LAST_TICK + 1);
        uint256 median = oracle.fetchChainedMedian(AAPL, _chain(), CHAIN_CUTOFF, type(uint64).max, 600, 5);
        assertEq(median, 343_720_000_000_000_000_000, "median of the five samples");
    }

    /// @notice Without the quiet update the first price after the gap proves nothing about the
    ///         seconds before it, so the set is refused.
    function test_ChainRule_QuietUpdateRequired() public {
        bytes[] memory full = _chain();
        bytes[] memory dropped = new bytes[](full.length - 1);
        dropped[0] = full[0];
        for (uint256 i = 2; i < full.length; i++) {
            dropped[i - 1] = full[i];
        }
        vm.warp(CHAIN_LAST_TICK + 1);
        vm.expectPartialRevert(BazaarOracle.BazaarOracle__SampleNotProven.selector);
        oracle.fetchChainedMedian(AAPL, dropped, CHAIN_CUTOFF, type(uint64).max, 600, 5);
    }

    /// @notice The deploy script's probe passes against a verifier that trusts Pyth's signer, and
    ///         refuses one that trusts only the public test key.
    function test_DeployProbe_AcceptsPythsVerifierOnly() public {
        DeployProbe probe = new DeployProbe();
        probe.probe(address(verifier));

        MockPythLazer testOnly = new MockPythLazer(0);
        vm.expectRevert(bytes("invalid signer"));
        probe.probe(address(testOnly));
    }

    /// @notice The probe pays the verification fee when Pyth charges one.
    function test_DeployProbe_PaysTheFee() public {
        verifier.setVerificationFee(1);
        new DeployProbe().probe(address(verifier));
        assertEq(address(verifier).balance, 1, "fee paid");
    }
}
