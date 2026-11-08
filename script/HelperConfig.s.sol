// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";
import {OwnedMockOptimisticOracleV3} from "../test/mocks/OwnedMockOptimisticOracleV3.sol";
import {TestnetUSDC} from "../test/mocks/TestnetUSDC.sol";

contract HelperConfig is Script {
    // if we are on a local anvil, we deploy mocks
    // Otherwise, grab the existing address from the live network

    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address pythFeed;
        address usdcContract;
        address optimisticOracleV3;
        string name;
    }

    constructor() {
        if (block.chainid == 42161) {
            activeNetworkConfig = getArbitrumMainnetConfig();
        } else if (block.chainid == 421614) {
            activeNetworkConfig = getOrCreateArbitrumSepoliaConfig();
        } else if (block.chainid == 31337) {
            activeNetworkConfig = getOrCreateAnvilConfig();
        } else {
            revert("Network not supported");
        }
    }

    // -------------------- Arbitrum Mainnet --------------------

    /// @dev Every address here is a literal with no on-chain provenance of its own, and each one is
    ///      consumed as an immutable: the factory keeps `usdc` and the OOv3, and BazaarOracle keeps
    ///      the Pyth feed, none with a setter. A wrong entry is therefore not a misconfiguration to
    ///      be corrected but a redeployment of the whole system, so what each slot must hold is
    ///      recorded here and re-checked against its issuer's own published deployment list before a
    ///      mainnet run. DeployBazaar._assertExternalDependencies probes all three at deploy time.
    ///
    ///      - `usdcContract` must be Circle's NATIVE USDC on Arbitrum One, not the bridged USDC.e
    ///        (`0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8`). The two are separate ERC-20s with
    ///        separate liquidity; picking the bridged one would denominate every pair in a token the
    ///        protocol did not intend and could never migrate off. Both happen to carry 6 decimals,
    ///        so the deploy-time decimals probe does not separate them — this is the one entry that
    ///        has to be read character by character.
    ///      - `pythFeed` must be the contract Pyth's own EVM contract-address list names Pyth Core
    ///        for Arbitrum One, not the Pyth Core Compatible contract beside it. The two share an
    ///        interface but not storage, so a price posted to one cannot be read from the other.
    ///        Pyth has cut over to a new deployment before; an address that was right for a prior
    ///        release is not evidence about the current one.
    ///      - `optimisticOracleV3` must be UMA's OptimisticOracleV3 for Arbitrum One. UMA's Finder
    ///        is reached through it at runtime rather than configured here, so this address alone
    ///        determines which UMA deployment adjudicates every listing and termination.
    function getArbitrumMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            pythFeed: 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C,
            usdcContract: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            optimisticOracleV3: 0xa6147867264374F324524E30C02C331cF28aa879,
            name: "Arbitrum-Mainnet"
        });
    }

    // -------------------- Arbitrum Sepolia --------------------
    // Uses Pyth on Arbitrum Sepolia, but deploys its own mock OOv3 instead of UMA's
    // OptimisticOracleV3 on that chain (0x1037A21a30aEfF90c269b01c3933eB9a5285d9b8), which cannot
    // adjudicate Bazaar's assertions: Circle's test USDC is not on its CollateralWhitelist, so every
    // USDC-bonded assertTruth reverts; its default currency is an 18-decimal test token, which
    // cannot stand in for USDC; and its DVM stand-in, MockOracleAncillary, lets anyone push the
    // resolution of any dispute.

    /// @dev Circle's test USDC on Arbitrum Sepolia, read from Circle's published list.
    address internal constant ARBITRUM_SEPOLIA_CIRCLE_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    /// @dev The USDC follows the SEPOLIA_OFFICIAL_USDC environment variable.
    ///
    ///      - Unset or false: the script deploys a TestnetUSDC owned by the broadcaster. Anyone can
    ///        claim from its faucet and the owner mints at will, which a public testnet needs: one
    ///        listing alone takes the factory's MIN_DEPLOYMENT_AMOUNT, far more than Circle's
    ///        rate-limited faucet pays one address.
    ///      - True: it uses Circle's test USDC, sourced like the mainnet entry, so a rehearsal of the
    ///        mainnet deploy runs against the real token — its permit domain, its proxy and its
    ///        transfer costs, at an address the script did not create. A wrong address then surfaces
    ///        as a broken listing flow on the rehearsal rather than on mainnet.
    ///
    ///      `pythFeed` is the Pyth Core contract for the chain, from Pyth's published list. The mock
    ///      OOv3 prices its bonds in the same USDC the deployment uses. It is the owner-gated
    ///      variant, owned by the broadcaster: the chain is public, and the base mock's helpers would
    ///      let anyone settle any assertion with any result, where here only the owner can
    ///      force-settle, resolve disputes, or set the identifier whitelist and the minimum bond.
    function getOrCreateArbitrumSepoliaConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.optimisticOracleV3 == address(0)) {
            bool officialUsdc = vm.envOr("SEPOLIA_OFFICIAL_USDC", false);
            vm.startBroadcast();
            (, address broadcaster,) = vm.readCallers();
            address usdc = officialUsdc ? ARBITRUM_SEPOLIA_CIRCLE_USDC : address(new TestnetUSDC(broadcaster));
            OwnedMockOptimisticOracleV3 mockOO = new OwnedMockOptimisticOracleV3(usdc, 7200, broadcaster);
            vm.stopBroadcast();

            return NetworkConfig({
                pythFeed: 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF,
                usdcContract: usdc,
                optimisticOracleV3: address(mockOO),
                name: "Arbitrum-Sepolia"
            });
        } else {
            return activeNetworkConfig;
        }
    }

    // -------------------- Anvil (local) --------------------
    // If UMA sandbox is deployed, set SANDBOX_OOV3 and SANDBOX_USDC env vars.
    // Otherwise, deploys mocks for everything.

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.pythFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockPyth mockPyth = new MockPyth(0, 0);
        MockUSDC mockUSDC = new MockUSDC();
        MockOptimisticOracleV3 mockOO = new MockOptimisticOracleV3(address(mockUSDC), 7200);
        vm.stopBroadcast();

        return NetworkConfig({
            pythFeed: address(mockPyth),
            usdcContract: address(mockUSDC),
            optimisticOracleV3: address(mockOO),
            name: "Anvil"
        });
    }
}
