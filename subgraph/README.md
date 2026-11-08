# Bazaar subgraph

A [Graph](https://thegraph.com) subgraph over the Bazaar factory, terminator, oracle and every pair
the factory deploys. It serves the history and the lists that the contracts cannot answer on their
own: trades and candles, order and position timelines, who holds a position, which trigger orders
are waiting, which UMA assertions are pending, insurance stakes and termination outcomes.

Live values the contracts deliberately do not emit are not indexed: the mark price, the insurance
share price and the vault's two buckets of liquidated positions (`getPendingLiquidationExposure`).
Read those from `BazaarPairLens` over RPC, as front ends and keepers already do for health checks.

## Layout

| Path | What it holds |
|---|---|
| `schema.graphql` | Entities, with units and semantics in their descriptions |
| `subgraph.yaml` | Data sources: `BazaarFactory`, `BazaarPairTerminator`, `BazaarOracle`, and the `BazaarPair` template each `PairDeployed` starts |
| `networks.json` | Addresses and start blocks per network |
| `src/` | Handlers: `factory.ts`, `terminator.ts`, `oracle.ts`, and `pair.ts`, which re-exports the pair handlers in `src/pair/` |
| `tests/` | Matchstick unit tests |
| `e2e/` | Local end-to-end run: Graph Node in Docker, Anvil, a trading scenario and a checker against chain reads |

## Requirements

Run everything from WSL, where Foundry also lives.

- Node.js 20.18.1 or newer, which the Graph CLI's package requires.
- PostgreSQL client libraries, which Matchstick links against: `sudo apt install postgresql libpq-dev`.
- Optional, for the local end-to-end run: Docker Desktop, to run Graph Node, and `python3`, `jq` and
  `rsync` in WSL.

## ABIs

The manifest reads the ABIs from `../abi`, which `script/export-abis.sh` writes. Most pair events
are emitted by libraries the pair runs by DELEGATECALL, so they are missing from the compiler's
`BazaarPair` ABI; the exported one appends them, and the Graph CLI rejects handlers for events its
data source ABI does not declare. Regenerate the ABIs after any change to an event:

```bash
make abis
```

`make abis` runs a full `forge build`. Where memory is tight, build the sources alone and export:

```bash
forge build --threads 1 --skip 'test/**' && bash script/export-abis.sh
```

## Build and test

```bash
npm install
npm run codegen
npm run build
npm test
```

`codegen` regenerates `generated/` from the schema and ABIs; rerun it after changing either.

## Deploy

1. Deploy the contracts, then put the factory, terminator and oracle addresses and their deployment
   blocks into `networks.json` under the network's name.
2. Create the subgraph in [Subgraph Studio](https://thegraph.com/studio) and copy its deploy key.
   The scripts assume the slugs `bazaar-sepolia` and `bazaar`; edit `package.json` if yours differ.
3. Authenticate once, then build and deploy:

   ```bash
   npx graph auth <deploy key>
   npm run build:sepolia
   npm run deploy:sepolia
   ```

4. Publish from Studio to The Graph Network once Studio shows the subgraph synced. Arbitrum Sepolia
   and Arbitrum One both have full network support, so the same code serves testnet and mainnet;
   only `networks.json` differs.

`graph build --network <name>` writes that network's addresses and start blocks into
`subgraph.yaml`. The manifest is kept in the format the CLI writes, so a build changes nothing but
those values.

## Local end-to-end run

`e2e/` indexes a local Anvil chain with a local Graph Node, drives a trading scenario, and checks
what the subgraph indexed against direct chain reads. Run it after changing a handler or an event.

The scenario lists an ETH/USD pair, then rests, takes, cancels and amends orders, fires a stop-loss
and a stop-limit through a keeper, refreshes the price, liquidates a position and unloads the vault
into the book, withdraws collateral, sweeps an expired order, takes an insurance withdrawal through
request, lock and claim, and claims keeper fees. ADL and termination are not exercised.

The checker compares every order, both sides of the book level by level, every position, open
interest, insurance stakes and requests, and claimable fees with the contracts' getters, and every
record with the event log it came from. It exits 1 on any mismatch.

From the repository root, in WSL, with the contracts built and `npm install` done in `subgraph/`:

```bash
docker compose -f subgraph/e2e/docker-compose.yml -p bazaar-graph up -d
```

```bash
anvil --host 0.0.0.0 --code-size-limit 100000
```

Then, in another shell:

```bash
bash subgraph/e2e/deploy-contracts.sh
bash subgraph/e2e/deploy-subgraph.sh
python3 subgraph/e2e/scenario.py
python3 subgraph/e2e/check.py
```

- Queries go to `http://localhost:8000/subgraphs/name/bazaar/graphql`.
- The scripts share `/tmp/bazaar-e2e` (`E2E_WORK`): the addresses, the scenario's progress, logs, and
  a built copy of the subgraph. The copy holds the Anvil addresses, so the tracked `subgraph.yaml`
  and `networks.json` stay as they are.
- `REPO` points both deploy scripts at another built checkout of the contracts, so you can deploy
  from it without rebuilding here.
- A failed scenario step stops the run with the decoded revert. Rerunning `scenario.py` resumes from
  that step.
- After a handler change, run `deploy-subgraph.sh v0.0.2` (any new label). That reindexes the same
  chain from block 0; then run `check.py` again.
- For a fresh chain, restart Anvil and rerun everything from `deploy-contracts.sh`.
- To stop, run `docker compose -p bazaar-graph down -v` and stop Anvil.

Docker Desktop runs inside the same WSL VM as Foundry. Stop the containers before a large
`forge build`.

Without WSL integration in Docker Desktop, run the `docker compose` command from Windows instead.
Run it from the repository's Windows path; the rest is unchanged.

The containers reach Anvil through `host.docker.internal`. This was tested with WSL's mirrored
networking mode.

## Semantics worth knowing

**Units.** Prices, sizes, notionals, collateral, fees and insurance shares are fixed-point integers
with 18 decimals. Seed refunds are USDC with 6 decimals. Block numbers are Arbitrum L2 block
numbers, the numbers order expiry uses.

**Orders.** `status` moves through `Waiting` (a trigger order not yet fired), `Pending` (a Market or
immediate-or-cancel order inside its creation transaction), `Resting`, `Fired` (a trigger order that
fired and holds size outside the book), `Filled` and `Canceled`. A resting order whose expiry block
has passed stays `Resting` until a transaction removes it; compare `expiryBlock` with the current L2
block. A TakeProfit or StopLoss reports the size its owner set at creation and the size capped at
its position each time it fires.

**The book.** `BookLevel` aggregates resting size per price and side, and includes expired orders
no transaction has removed yet, as the on-chain book does. For quoting and order placement read
`BazaarPairLens.getBookDepth` and `findPredecessor` at the latest block.

**Positions.** Every change to a position emits its full state, and `Position` mirrors it.
`Pair.openInterestLong` and `openInterestShort` sum account positions and exclude inventory the
vault holds after liquidations.

**Insurance.** A dead-pool reset zeroes every provider's shares and requests, as the pair's share
generations do. The share supply is read from the pair, because the orphan shares a deposit into an
empty fund mints are in no event.

**Contract reads.** Four values come from contract reads rather than events. A StopLimit that
fires reads its stored book flag, since its walk can leave it resting or waiting outside the book
with no event telling which. Insurance deposits and redemptions read the share supply. Schedule
events read the pair's cutoff, which the pair can raise to its minimum lead. The first factory event
reads the UMA identifier the factory was deployed with, which no event reports.

**Identifier upgrades.** The factory emits nothing when UMA upholds a dispute against an upgrade.
Such a proposal reads `Disputed` until the next proposal takes the factory's single slot, which
marks it `Rejected`.

## Example queries

Positions open on a pair as of a block, for a keeper starting up. Page with `id_gt`, then follow the
pair's logs from the next block:

```graphql
{
  positions(
    first: 1000
    where: { pair: "0xPAIR", isOpen: true }
    block: { number: 123456789 }
  ) {
    id
    account { id }
    isLong
    size
    collateral
  }
}
```

Trigger orders a keeper can fire, largest bounty first:

```graphql
{
  orders(
    first: 1000
    where: { pair: "0xPAIR", status_in: [Waiting, Fired] }
    orderBy: bountyHeld
    orderDirection: desc
  ) {
    orderId
    owner { id }
    orderType
    isLong
    triggerPrice
    limitPrice
    remaining
    bountyHeld
  }
}
```

Expired orders still in the book, for `sweepExpired`:

```graphql
{
  orders(first: 1000, where: { pair: "0xPAIR", inBook: true, expiryBlock_lt: "123456789" }) {
    orderId
  }
}
```

UMA assertions whose liveness has ended:

```graphql
{
  terminationProposals(where: { status: Pending, livenessEndsAt_lt: "1800000000" }) { id pair { id } }
  listingProposals(where: { status: Pending, livenessEndsAt_lt: "1800000000" }) { id pairId }
  identifierUpgradeProposals(where: { status: Pending, livenessEndsAt_lt: "1800000000" }) { id }
}
```

Five-minute candles and a trader's open orders and positions, for a front end:

```graphql
{
  candles(
    first: 500
    where: { pair: "0xPAIR", interval: 300 }
    orderBy: periodStart
    orderDirection: desc
  ) {
    periodStart
    open
    high
    low
    close
    volumeNotional
  }
  account(id: "0xTRADER") {
    positions(where: { isOpen: true }) { pair { id description } isLong size entryPrice collateral }
    orders(where: { status_in: [Resting, Waiting, Fired] }) { orderId orderType isLong limitPrice remaining }
  }
}
```

Keepers racing for liquidations or trigger fills should decide from logs and a lens read at the live
Pyth price, not from these queries: an indexer trails the chain by a few blocks.
