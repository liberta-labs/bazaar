<div align="center">
  <img src="docs/src/images/bazaar-banner.png" alt="Bazaar" width="440">

  <p>
    <a href="https://docs.bazaar.finance/"><strong>Explore the docs »</strong></a>
  </p>

  <p>
    <a href="https://bazaar.finance/">Website</a>
    ·
    <a href="https://docs.bazaar.finance/guide/quick-start.html">Quick Start</a>
    ·
    <a href="https://docs.bazaar.finance/reference/contracts.html">Contracts</a>
    ·
    <a href="https://github.com/liberta-labs/bazaar/issues/new?labels=bug">Report Bug</a>
    ·
    <a href="https://github.com/liberta-labs/bazaar/security/advisories/new">Report Vulnerability</a>
    ·
    <a href="https://github.com/liberta-labs/bazaar/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

# Bazaar

**Permissionless perpetual futures on anything with a price feed — no admin keys, no whitelists, no off-switch.**

Bazaar is the first-ever fully permissionless perpetual-derivatives protocol, USDC-margined and built for Arbitrum. Any asset with a [Pyth](https://pyth.network) price feed — crypto, equities, FX, commodities — can be listed permissionlessly through an [UMA Optimistic Oracle](https://uma.xyz) assertion and traded on an on-chain central limit order book. The book is **fully on-chain and sorted**, and orders match **on arrival**, inside their own creation transaction — price-time priority and fill prices are enforced by the contract itself, with no trusted matcher anywhere in the fill path.

The protocol is immutable: no owner, no pauser, no upgradeable proxies, no governance token. Every privileged action is either fully permissionless, economically bonded, or adjudicated by UMA's optimistic oracle. The single governed parameter — the UMA identifier those assertions are adjudicated under — moves only through a bonded assertion (at least $5,000), a 2-day public dispute window, and a 7-day activation timelock (4 days once UMA has removed the incumbent).

> ⚠️ **Status: pre-audit, work in progress — testnet only.** The official deployment runs on the Arbitrum Sepolia testnet ([addresses](https://docs.bazaar.finance/reference/networks.html)); there is no mainnet deployment. Do not use with real funds.

## Documentation

**Read the book at [docs.bazaar.finance](https://docs.bazaar.finance/).**

Everything protocol-level — architecture, matching, the risk engine, funding, fees, listing, termination, parameter tables, the contract reference, and role guides for traders, LPs, keepers, and integrators — lives there, built from [`docs/`](docs) and redeployed on every push that touches it. The book is the single source of truth for how the protocol works; this README covers only the repository itself.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recursive <repo-url> && cd bazaar
forge build
forge test
```

CI pins Foundry to v1.4.3 and runs `forge fmt --check`, build, a check that the committed ABIs and interfaces match the build, and the full test suite on every push; EIP-170 size limits are enforced as a test (`test/unit/ContractSizeTest.t.sol`) over production contracts.

For the full local stack on Anvil — mocked Pyth/UMA/USDC, listing a pair, pushing prices, placing orders — see [Local Development](https://docs.bazaar.finance/guide/quick-start.html) in the book; `make help` lists every target. Deploying the protocol to a real network is covered in [Self-Deployment](https://docs.bazaar.finance/guide/deployment.html).

## Repository layout

```
src/
├── BazaarPair.sol              # Core market: orders, positions, insurance, lifecycle
├── BazaarFactory.sol           # UMA-gated listings, EIP-1167 cloning
├── BazaarOracle.sol            # Pyth Pro adapter + composite feeds
├── BazaarPairTerminator.sol    # Wind-down paths
├── BazaarPairLens.sol          # Read-only views
├── interfaces/                 # One MIT interface per contract (IBazaar*), checked against its ABI
└── libraries/                  # twelve DELEGATECALL externals, then inlined helpers
    ├── MatchingEngineLib.sol   # Arrival matching: the walk, insertion, unload
    ├── OrderManagementLib.sol  # Order creation/amend/cancel/cleanup
    ├── CollateralLib.sol       # Deposits/withdrawals incl. terminal modes, resting-order reservation
    ├── LiquidationLib.sol      # Bankruptcy pricing, vault aggregation
    ├── AdlLib.sol              # Dutch-auction auto-deleveraging
    ├── InsuranceVaultLib.sol   # LP shares, cooldowns, rate limits
    ├── RiskParamsLib.sol       # Dynamic IMR/MMR + fee curves
    ├── FundingLib.sol          # Mark price + funding index
    ├── TerminationLib.sol      # Settlement waterfall
    ├── MetaTxLib.sol           # EIP-712 meta-transactions
    ├── VaultHealthLib.sol      # ADL/termination triggers
    ├── ClaimTextLib.sol        # Static UMA claim text (factory + terminator)
    ├── OrderBookLib.sol        # Sorted doubly-linked book lists (insert/unlink)
    ├── BucketLib.sol           # Position solvency math
    ├── MmrSampleLib.sol        # 24h-lagged MMR ring buffer
    ├── FeeEscrowLib.sol        # Claimable-balance escrow behind every payout
    ├── BazaarMathLib.sol       # Fixed-point + effective-price helpers
    └── BazaarTypes.sol         # Structs, enums, protocol constants (MIT)
script/                         # DeployLibraries + DeployBazaar + network config
abi/                            # Committed JSON ABIs (MIT)
examples/                       # Contracts to adapt, e.g. a batching account (MIT)
subgraph/                       # The Graph subgraph (MIT)
test/
├── unit/                       # Per-library and per-mechanism suites
├── integration/                # End-to-end suites, incl. the zero-sum invariant
├── mocks/                      # ArbSys, USDC, UMA OOv3, Pyth Pro verifier
└── *.sol                       # Shared harness helpers (storage probes, signed Pyth Pro updates)
```

## Security

- **Unaudited and on testnet only.** This codebase has not undergone a professional audit. The official deployment runs on the Arbitrum Sepolia testnet, with a faucet USDC and a mock UMA oracle; there is no mainnet deployment.
- No admin keys: there is nothing to compromise, but also no one who can pause a bad deployment — the [termination paths](https://docs.bazaar.finance/protocol/termination.html) are the only brakes.
- **Reporting a vulnerability:** please use GitHub's private vulnerability reporting — go to the [Security tab](../../security/advisories/new) and select *Report a vulnerability*. Do not open a public issue for security findings.
- There is no bug-bounty program at this stage. Valid findings are credited to the reporter in the published advisory. A retroactive reward may be considered for significant findings once the project is funded, but none is promised or guaranteed.
- What is in and out of scope, and the posture a report should assume: [SECURITY.md](SECURITY.md). Full posture and testing detail: [Security & Status](https://docs.bazaar.finance/security.html) in the book.

## License

The protocol is [AGPL-3.0-only](LICENSE). If you fork it and run it as a service, you must open-source your modifications under the same license — including the network-use provision of §13.

What integrators compile against is [MIT](LICENSE-MIT): the five `IBazaar*` interfaces in `src/interfaces/`, `src/libraries/BazaarTypes.sol`, the ABIs in `abi/`, `examples/` and `subgraph/`. The documentation text is [CC BY 4.0](docs/LICENSE). Each Solidity file's SPDX header is authoritative, and [License](https://docs.bazaar.finance/license.html) in the book explains what integrating does and doesn't require.
