# Using Bazaar

Bazaar is designed to be used as a deployed protocol, not software you need to run. Everything in this guide is written against the **official deployment** — its canonical addresses are listed in [Deployments](../reference/networks.md), and only those addresses (plus pairs discoverable from the listed factory) are the real Bazaar.

> **Testnet only.** The official deployment runs on the Arbitrum Sepolia testnet, with a faucet USDC anyone can claim; mainnet addresses will appear in [Deployments](../reference/networks.md) at launch. Everything in this guide can be exercised there or on a [local stack](quick-start.md).

## Pick your path

| You want to… | Start here | You need |
|---|---|---|
| Trade perps with leverage | [Trading](trading.md) | USDC on Arbitrum |
| Earn yield backstopping a market | [Earning → Insurance LP](earning.md#insurance-lp) | USDC, patience (13-day exit cooldown) |
| Run bots that collect bounties | [Earning → Keeper bounties](earning.md#keeper-bounties) | a bot, gas money |
| Build a frontend/bot and earn referral fees | [Integrators](integrators.md) | just an address |
| Place several orders in one transaction | [Batching Orders](batching.md) | a contract account (an example is in the repo) |
| List a new market | [Markets & Listing](../protocol/listing.md) | ≥ $4,000 (bond + insurance seed) |
| Understand the machine | [Protocol chapters](../protocol/architecture.md) | curiosity |

Every role above is **permissionless** — no signups, no whitelists, no API keys. If you can send a transaction, you can participate.

## The five-minute mental model

- Each market ("pair") is its own contract with its own order book, insurance fund, and USDC collateral pool. One net position per wallet per market.
- Orders match **instantly on arrival** against the fully on-chain book; unfilled remainders rest in the contract's own sorted lists, so price-time priority is enforced by code — there is no matcher to trust, censor you, or go down.
- Margin is dynamic: calmer markets allow up to 25× leverage, wilder ones less. Fall below maintenance margin and anyone may liquidate you.
- Losses that liquidations can't cover cascade through a defined waterfall (the trader's own collateral → the vault → the insurance fund → auto-deleveraging → haircuts on profits) — never first-come-first-served, never socialized by surprise rules.
- Markets on stocks and FX keep working when their venues close, under tightened rules; and any market can be wound down to cash settlement when its underlying dies.

## Reading history: the subgraph

The contracts serve current state through their view functions, but not history, nor lists they never store, such as every account holding a position on a market. For those (trades and candles, order and position timelines, who holds positions, trigger orders waiting to fire, pending UMA assertions, insurance stakes and termination outcomes) Bazaar publishes a [subgraph](https://github.com/liberta-labs/bazaar/tree/master/subgraph) that indexes the factory, the terminator, the oracle and every pair. The testnet's is served by Subgraph Studio at `https://api.studio.thegraph.com/query/1764016/bazaar-arbitrum-sepolia/version/latest`; send it GraphQL over HTTP POST, starting from the [example queries](https://github.com/liberta-labs/bazaar/tree/master/subgraph#example-queries) in its README. That is Studio's development endpoint: free and keyless, but rate-limited, so a front end or bot with heavy traffic should not depend on it alone. Values the contracts do not emit, such as the mark price and the insurance share price, are not indexed; read them from `BazaarPairLens` over RPC. The mainnet subgraph will be listed in [Deployments](../reference/networks.md) at launch.
