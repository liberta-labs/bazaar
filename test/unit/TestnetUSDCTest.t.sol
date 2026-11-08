// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestnetUSDC} from "../mocks/TestnetUSDC.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {OwnedMockOptimisticOracleV3} from "../mocks/OwnedMockOptimisticOracleV3.sol";

contract TestnetUSDCTest is Test {
    address internal constant CIRCLE_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    TestnetUSDC internal usdc;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new TestnetUSDC(owner);
    }

    function test_matchesUsdcDecimals() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.owner(), owner);
    }

    function test_claim_paysOncePerCooldown() public {
        uint256 start = block.timestamp;
        uint256 next = start + usdc.FAUCET_COOLDOWN();

        vm.prank(alice);
        usdc.claim();
        assertEq(usdc.balanceOf(alice), usdc.FAUCET_AMOUNT());
        assertEq(usdc.lastClaimTs(alice), start);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestnetUSDC.TestnetUSDC__FaucetCooldown.selector, next));
        usdc.claim();

        vm.warp(next - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestnetUSDC.TestnetUSDC__FaucetCooldown.selector, next));
        usdc.claim();

        vm.warp(next);
        vm.prank(alice);
        usdc.claim();
        assertEq(usdc.balanceOf(alice), 2 * usdc.FAUCET_AMOUNT());
    }

    function test_claim_cooldownIsPerAddress() public {
        vm.prank(alice);
        usdc.claim();
        vm.prank(bob);
        usdc.claim();
        assertEq(usdc.balanceOf(bob), usdc.FAUCET_AMOUNT());
    }

    function test_claim_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(usdc));
        emit TestnetUSDC.FaucetClaimed(alice, usdc.FAUCET_AMOUNT());
        vm.prank(alice);
        usdc.claim();
    }

    function test_mint_ownerMintsAnyAmount() public {
        vm.prank(owner);
        usdc.mint(bob, 5_000_000 * 1e6);
        assertEq(usdc.balanceOf(bob), 5_000_000 * 1e6);
    }

    function test_mint_refusesNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        usdc.mint(alice, 1);
    }

    /// @dev Both settings in one test: the flag is a process environment variable, which two tests
    ///      running in parallel would race on.
    function test_sepoliaConfig_followsTheOfficialUsdcFlag() public {
        vm.chainId(421614);

        vm.setEnv("SEPOLIA_OFFICIAL_USDC", "false");
        (, address usdcAddr, address oo,) = new HelperConfig().activeNetworkConfig();
        assertTrue(usdcAddr != CIRCLE_USDC);
        assertEq(TestnetUSDC(usdcAddr).decimals(), 6);
        assertEq(TestnetUSDC(usdcAddr).owner(), DEFAULT_SENDER);
        assertEq(address(OwnedMockOptimisticOracleV3(oo).currency()), usdcAddr);

        vm.setEnv("SEPOLIA_OFFICIAL_USDC", "true");
        (, usdcAddr, oo,) = new HelperConfig().activeNetworkConfig();
        vm.setEnv("SEPOLIA_OFFICIAL_USDC", "false");
        assertEq(usdcAddr, CIRCLE_USDC);
        assertEq(address(OwnedMockOptimisticOracleV3(oo).currency()), CIRCLE_USDC);
    }
}
