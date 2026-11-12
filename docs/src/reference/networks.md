# Deployments

This page is the **canonical registry of official Bazaar deployments**. If an address is not listed here (or reachable from `BazaarFactory.getAllPairs()` on a factory listed here), it is not part of the official deployment — anyone can deploy an AGPL fork, so always verify addresses against this page.

## Arbitrum One (42161) — production target

**Not yet deployed.** Addresses will be published here at launch; until then the only official deployment is the [Arbitrum Sepolia testnet](#arbitrum-sepolia-421614--testnet).

| Contract | Address |
|---|---|
| `BazaarFactory` | *TBD* |
| `BazaarPairTerminator` | *TBD* |
| `BazaarOracle` | *TBD* |
| `BazaarPairLens` | *TBD* |
| `BazaarPair` implementation | *TBD* |

Individual markets are discoverable on-chain from the factory (`getAllPairs()` / `getPairAddress(pairId)`) — the factory is the root of trust for what counts as a real Bazaar pair.

The twelve external libraries these contracts link — eleven by the `BazaarPair` implementation, `ClaimTextLib` by the factory and the terminator — are recorded in `deployments/42161/libraries.args` by deploy step 1 (see [Self-Deployment](../guide/deployment.md)); the record is regenerated whenever the library set changes.

External dependencies on Arbitrum One:

| Contract | Address |
|---|---|
| Pyth Pro verifier (`PythLazer`) | `0xACeA761c27A909d4D3895128EBe6370FDE2dF481` |
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| UMA Optimistic Oracle V3 | `0xa6147867264374F324524E30C02C331cF28aa879` |

## Arbitrum Sepolia (421614) — testnet

**Official Bazaar testnet deployment: live**, built from the contracts tagged `v1.0.0-rc9`. Its USDC is a faucet token and its UMA oracle a mock, so nothing on it has value. Every contract below has verified source on [Arbiscan](https://sepolia.arbiscan.io).

| Contract | Address | Deployed in block |
|---|---|---|
| `BazaarFactory` | `0x9f077B7D49EE7B451ae0858e391dC6960F144612` | 328418565 |
| `BazaarPairTerminator` | `0x59F836254D3781A06d2Af7270ea8697c8c7De4e8` | 328418562 |
| `BazaarOracle` | `0x1E4686fA4855ac3E17E4afd80645d64D4A9D0fA7` | 328418550 |
| `BazaarPairLens` | `0xe312AB284aCCC358dd49e4C66B20E618e4f5B931` | 328418558 |
| `BazaarPair` implementation | `0xfb3bF4205E181f436f778BcAC21Df9a1c20556A3` | 328418554 |

Markets are discoverable from the factory as on mainnet (`getAllPairs()` / `getPairAddress(pairId)`). The testnet's [subgraph](https://github.com/liberta-labs/bazaar/tree/master/subgraph), which indexes its markets, orders, positions and history, is served by Subgraph Studio at `https://api.studio.thegraph.com/query/1764016/bazaar-arbitrum-sepolia/version/latest`.

The twelve external libraries, as recorded in `deployments/421614/libraries.args` by deploy step 1:

| Library | Address |
|---|---|
| `InsuranceVaultLib` | `0xA3F47D353bFdD10916c062c1387D8569FfD5A197` |
| `LiquidationLib` | `0xeb028188E56A0088A438C7e45bF41ED02563b2b3` |
| `OrderManagementLib` | `0x35298bb2D0a5e687496F3D66b1670EbFF370E9B3` |
| `AdlLib` | `0x015bDF5307DD6d07eC1B398D8B6F68E249781Af5` |
| `MatchingEngineLib` | `0xe31Ff90D043eB33c94E42Bb14b65E0122EbF1DcA` |
| `CollateralLib` | `0x8370335B93B4e3D9927a1c2671a60360Cb98E3C1` |
| `RiskParamsLib` | `0xcc0dBE2EfeD990F4358e826d2Bd7b86e8F051131` |
| `FundingLib` | `0x35531A1D7099B72F6035Cb0A93195b34925e7B53` |
| `TerminationLib` | `0xeE1A0f24D69f9AEe894820de8a65f5c5E9779C01` |
| `MetaTxLib` | `0xa7d9BC5507047049be30392e5149C90b498b158B` |
| `VaultHealthLib` | `0x06dffF7fA2B43ae88e1174C6A81C2Baf1862cB74` |
| `ClaimTextLib` | `0x5dc068638D5404E340ef490151640402739a85B9` |

External dependencies on Arbitrum Sepolia:

| Contract | Address |
|---|---|
| Pyth Pro verifier (`PythLazer`) | `0xACeA761c27A909d4D3895128EBe6370FDE2dF481` |
| USDC (testnet) | `0x1c606254587567EfaFED89ac39ad794377AAa836`, a **`TestnetUSDC`** faucet token, so the testnet has enough USDC to list pairs and trade: anyone can call `claim()` for 10,000 USDC once every 24 hours per address, and the deploying account, its owner, mints any amount. Like USDC it has 6 decimals and an ERC-2612 permit |
| UMA OOv3 | `0xc281D6CeD90Ec5eD1Ea5c8666783663d04590Aa3`, a **mock** (`OwnedMockOptimisticOracleV3`) owned by the deploying account, which alone can force-settle assertions, resolve disputes, and set the identifier whitelist and minimum bond (Bazaar's assertions set their own liveness periods). UMA no longer supports an OOv3 on Arbitrum Sepolia, so the testnet runs on this mock |

On the testnet a listing or a termination claim therefore settles after its liveness, as on mainnet, unless the deploying account force-settles it sooner, and a disputed claim is resolved by that account rather than by UMA's voters.

A [self-deployment](../guide/deployment.md) on Arbitrum Sepolia deploys its own `TestnetUSDC` and mock oracle the same way. With `SEPOLIA_OFFICIAL_USDC=true` it uses Circle's test USDC, `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`, instead, to rehearse the mainnet deployment against the real token; Circle's faucet pays out only small amounts.

## Anvil (31337)

`make deploy-anvil` deploys `MockPythLazer` (which trusts a public test signing key, so anyone on the chain can sign a price), `MockUSDC` (mints 10,000 to your wallet), and `MockOptimisticOracleV3` (Bazaar's assertions set their own liveness periods), and etches `MockArbSys` at the `ArbSys` precompile address (`0x64`). Forge deploys the twelve libraries itself in the same run, so no `libraries.args` record is kept for anvil. The Bazaar protocol addresses, with the `MockUSDC` and `MockOptimisticOracleV3` addresses, are written to `.anvil-addresses`, which the other anvil make targets read.

External-dependency configuration for every network lives in `script/HelperConfig.s.sol`.
