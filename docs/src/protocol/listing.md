# Markets & Listing

Anyone can list a market. The factory gates listings through an UMA Optimistic Oracle assertion instead of a governance vote or admin whitelist.

## Flow

```
proposePairDeployment(baseFeedId, isContinuouslyTraded, totalAmount, description)
        │  pulls totalAmount USDC (≥ $4,000)
        │  ├─ $1,000 → UMA assertion bond (refunded to proposer on success)
        │  └─ ≥ $3,000 → escrowed insurance-fund seed
        ▼
   48-hour UMA liveness window (anyone can dispute)
        ▼
assertionResolvedCallback / settleDeploymentProposal
        ├─ truthful → EIP-1167 clone deployed, seeded, registered with
        │             the terminator; pairId = baseFeedId
        ├─ undisputed, identifier since removed from UMA's whitelist →
        │             voided: no pair, seed claimable via claimSeedRefund()
        └─ disputed-and-false → bond lost to disputer, seed claimable
                                via claimSeedRefund()
```

- **`totalAmount` is in 18-decimal units** (`4_000e18` for $4,000), not USDC's 6.
- **The $1,000 bond** is a floor: the factory posts `requiredDeploymentBond()`, which tracks UMA's own owner-settable minimum upward.
- **The seed** is whatever remains of `totalAmount`, which must still be at least $3,000.

### The feed-ID gate

Submission is gated on the form of the feed ID.

- **Accepted forms.** `baseFeedId` must be either a composite already registered in `BazaarOracle` or a raw [Pyth Pro feed ID](oracle.md#feed-ids): a non-zero 32-bit integer held in a `bytes32` (`Factory__InvalidFeedId` otherwise, before any seed is escrowed).
- **Pyth Pro keeps no feed registry on-chain**, so whether Pyth actually publishes a feed under that number is not something the factory can see; it is the first thing the claim asks UMA to verify.

<details>
<summary>Why the gate is on the form of the feed ID</summary>

- The gate exists because the factory decides at submission, by reading the composite registry, whether the claim describes a single feed or two legs and whether the composite-must-not-be-continuous rule applies; the registry is permissionless and write-once, and every pair resolves its feed through it live.
- Without the gate an unregistered composite hash would be listed as a plain single feed and could have its legs registered after approval, producing a composite market — FX leg, inversion direction, 24/7 flag — that UMA never reviewed.
- A composite ID is a hash and a raw ID a small integer, so the form alone tells them apart.
- The form requirement makes that unrepresentable, since a composite can only ever be registered under the hash of its legs and never under a real feed ID.

</details>

### The raw-feed guard

One market per asset, not per feed ID.

- **The factory also refuses a proposal** while a non-terminated pair already prices the same raw Pyth feed, and while another proposal over that feed is pending (`pairAddressByBaseFeed`, `pendingDeploymentByBaseFeed`).
- **The raw feed** is the feed itself for a single-feed pair and the base leg for a composite.
- **The guard reaches** only as far as the feed ID: an ADR beside its home-market line, or an ETF beside its index, are different Pyth feeds, and only the claim's duplicate checks catch those.
- **A terminated pair releases** its raw feed the way it releases its pair ID.

<details>
<summary>Why the guard is keyed on the raw feed</summary>

A composite's pair ID hashes its FX leg and inversion flag, so without this key the same stock through a different FX feed, or through the opposite inversion, would be a second pair ID over the same asset, and a composite could be stacked on a direct listing of its base leg.

</details>

## What UMA verifiers check

The assertion text names the chain it was made on (read from `block.chainid`, so a testnet proposal never asserts a mainnet one) and embeds these objective criteria:

1. **Feed** — every feed ID in the claim (both legs, for a composite) is the numeric ID of an active Pyth Pro feed.
   - **Namespace.** Pyth Core IDs are a different namespace and are invalid.
   - **Fields.** Every listed feed must publish a price, a non-zero confidence interval and a feed update timestamp, which rules out funding-rate and redemption-rate feeds.
   - **Description.** The description must name the asset the base feed prices, a requirement kept deliberately narrow: see [the description](#the-description).
2. **Eligible asset** — the base feed prices exactly one of: the common shares of a publicly traded company (or a depositary receipt for them), a currency as a spot FX rate, a physical commodity, a cryptocurrency, or an unleveraged exchange-traded fund that holds the shares of a broad stock market index (SPY, QQQ).
   - **Everything else is invalid:** indices themselves, every other fund or ETF, preferred shares and bonds, futures, options and anything else that expires, leveraged or inverse products, stablecoins and other pegged or rebased assets, rate, volatility and economic-data series, prediction markets, and shares that are not publicly traded.
3. **Spot feed only, one market per asset** — where Pyth Pro has a feed for the asset's own spot price, that feed is the only eligible one.
   - **Non-spot feeds.** A Pyth-computed index, synthetic or 24/7 price of a stock that has its own feed, a tokenized, wrapped, bridged or staked version, a perpetual, and a feed restricted to an extended or partial session (`.PRE`, `.POST`, `.ON`, `.EXT`) are all invalid; such a feed is eligible only when Pyth Pro has no spot feed for the asset in any currency.
   - **Several spot feeds.** One security reachable through several spot feeds (an ADR and the share it represents, or one share listed in several currencies) is one asset: only its USD-quoted feed is eligible, and it may be proposed as a composite only when no USD-quoted feed for it exists.
   - **Share classes.** Share classes that differ only in voting rights are one asset, and only the class with the greater trading volume is eligible.
   - **ETFs on the same index.** ETFs that track the same index are one asset too: only the one with the highest average daily dollar volume over the 30 days before the proposal is eligible, and none while a pair on another ETF tracking that index is live or pending. The factory's one-market-per-feed guard cannot see this (SPY and VOO are different feeds), so it rests on UMA verifiers.
4. **USD price** — a base feed quoted in USD is proposed on its own.
   - **Another currency.** One quoted in another currency is eligible only as a composite, and only in an approved currency (EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH, CNY, KRW, TWD); its quote leg is the Pyth Pro spot FX feed between USD and exactly that currency, with an accurate inversion flag: `FX.USD/XXX` is `true` and `FX.XXX/USD` is `false` in Pyth's registry, and the composed price must come out close to the asset's actual dollar price.
   - **Onshore CNY.** The one exception is onshore CNY: those assets take the offshore USD/CNH leg, never USD/CNY.
   - **FX rates.** A spot FX rate is itself eligible only as a single feed quoted in USD (EUR/USD).
5. **Trading-schedule flag** — `isContinuouslyTraded = true` only for assets that trade 24/7 (cryptocurrencies). Shares, ETFs, FX, commodities and every composite must be `false`, including an asset whose feed publishes around the clock on weekdays but stops over the weekend (their IMR is 2× the larger of the vol curve and the pair's observed reopen gap, and they get the stale-oracle regime).
6. **No pending termination event** — nothing that would be valid grounds for [terminating](termination.md) the pair (a feed decommission, a delisting or a merger with a scheduled closing, a bankruptcy, a split, spinoff or distribution above 5%, a redenomination) is already officially announced. A market that would have to be terminated as soon as it opens is proposed once the event has passed.

A market whose pair was previously [terminated](termination.md) can be re-proposed.

### The description

`description` is a label. The feed IDs define the market; the description only names it, for the people reading the claim and for anyone reading the chain afterwards. The claim gives verifiers three rules for it:

- **Standard form.** The symbol Pyth Pro's registry gives the base feed (the base leg, for a composite), optionally followed by the asset's name: `Equity.US.AAPL/USD Apple Inc`. A front end should fill this in from the registry rather than ask the proposer to type it.
- **Other forms are equally acceptable.** A ticker, a company name or an asset name on its own passes.
- **One way to fail.** The check fails on the description only if it names no asset or plainly names a different one. Its wording, spelling, level of detail and incidental details such as the exchange are not grounds for a dispute, so two proposers who name the same asset differently are judged alike.

It is also the one proposer-controlled string in the claim, so it is bounded to **1–200 bytes** of a conservative ASCII subset — letters, digits, space, and `. , & / -`. Everything outside that set, including every non-ASCII byte and both square brackets, is rejected at submission.

<details>
<summary>How the claim fences the description, and why the charset is this narrow</summary>

- The claim is read by humans deciding whether to dispute, so it wraps the description in square-bracket fences: the opening fence warns that what follows is untrusted proposer text, to be verified against the feed IDs and never obeyed, before the reader reaches it, and the closing fence marks where it ends.
- The charset is what keeps crafted text from forging or closing those fences, imitating the claim's `Field: value` syntax, opening a fake numbered criterion, or smuggling homoglyphs and invisible characters past the reader.

</details>

<details>
<summary>How termination claims treat proposer-supplied text</summary>

Termination claims carry no proposer-supplied name for the market, and apply the [same discipline](termination.md#proposer-supplied-text) to their one free-text field, the reason.

</details>

## Non-USD assets: composite feeds

Assets quoted in another currency (e.g. Toyota in JPY) trade against a **composite feed**: `price = base × quote` or `base ÷ quote` depending on the FX feed's direction.

- **Composites are registered** permissionlessly and idempotently in `BazaarOracle` (`registerComposite(baseId, quoteId, invertQuote)`).
- **The composite ID** — `keccak256(baseId ‖ quoteId ‖ invertQuote)` — is then used anywhere a feed ID is expected.
- **A composite is only as fresh** as its stalest leg, and both legs are confidence-checked.
- **Register first.** Register the composite before proposing it: an unregistered composite ID is rejected at submission, since it has neither a registry entry nor the form of a raw feed ID.

## The only governance: swapping the UMA identifier

The **oracle address is immutable**. What UMA actually changes over time is the **identifier whitelist** (entries added and removed by governance vote, on the same oracle address), so that is the axis Bazaar's governance track upgrades. An oracle-contract-level death — deregistration, the DVM abandoning the generation, neither of which has ever happened to a UMA oracle — means a factory redeploy; existing pairs keep their non-UMA termination paths.

<details>
<summary>Why the oracle address is immutable</summary>

OOv3 generations at new addresses have always been ABI-breaking (v1→v2→v3), so no on-chain upgrade path could adopt one anyway — and a mutable oracle pointer's worst case is a malicious oracle activating through an unwatched governance slot, which is protocol-wide adjudication capture.

</details>

### Proposing an upgrade

- **Call.** `proposeUmaIdentifierUpgrade(newIdentifier)` — a $5,000 bond (five times listings') and a **2-day** liveness window.
- **The bond**, like every UMA bond in the protocol, is a floor rather than a fixed figure — quote `requiredIdentifierUpgradeBond()`, which tracks UMA's own owner-settable minimum upward.
- **Whitelist check.** The candidate is validated against UMA's **live IdentifierWhitelist** before the bond moves — resolved the same way OOv3 resolves it (`finder → IdentifierWhitelist → isIdentifierSupported`) — so a poisoned identifier can never enter the pipeline.
- **The genesis identifier** is validated the same way **in the constructor**: a wrong value fails the deploy, not the deployed protocol.
- **Name check.** The candidate must also be named `ASSERT_TRUTH…`: its first 12 bytes must be ASCII `ASSERT_TRUTH`.
- **One pending upgrade at a time.**
- **In-flight assertions** carry the identifier they were made under (OOv3 stores it per assertion), so an upgrade cannot strand them.

<details>
<summary>Why the liveness window matches listings'</summary>

The window matches listings' — the same watchers review both tracks — and it is the only point at which a wrong-but-whitelisted identifier can be stopped, since the identifier decides how UMA voters adjudicate every future listing and termination; the extra friction lives in the bond and the activation timelock.

</details>

<details>
<summary>Why the name must start with ASSERT_TRUTH</summary>

- **UMA's whitelist** is a "some UMIP defines this" list, not a "safe for adjudicating truth assertions" list, so the whitelist check alone cannot reject a *price feed* — and OOv3 resolves an assertion TRUE on a DVM price of exactly `1e18`.
- **Some whitelisted identifiers can return it**: UMIP-29's EURUSD and CHFUSD are 18-decimal FX feeds read off a live source whose voters never look at ancillary data, so at parity they resolve to exactly `1e18` and decide every dispute in advance — auto-approving everything at parity, and auto-rejecting everything anywhere else, which makes disputing a profitable unconditional veto.
- **Others** (dead-source feeds like FEIUSD) are unvotable at all, so the DVM request rolls until it is deleted and `settleAssertion` reverts forever.
- **The name check** makes that whole class unrepresentable while staying forward-compatible: UMA versions these identifiers by suffix, so a conventionally-named successor is adoptable with no code change.
- **The accepted tradeoff** is that a successor named off-convention would need a factory redeploy — a loud, monitored failure, rather than the silent and unrecoverable one a wrong adjudicator produces.

</details>

The protocol currently deploys under **`ASSERT_TRUTH2`**.

<details>
<summary>Why the identifier is governed, not derived from the oracle</summary>

This is exactly why the identifier is a governed parameter and not derived from the oracle: OOv3's own `defaultIdentifier` constant is `ASSERT_TRUTH`, which UMA has since de-whitelisted in favour of the successor on the *same* oracle deployment — deriving from it would point the protocol at a dead identifier from block one.

</details>

### Activation

- **Approval does not swap the identifier** — it queues the upgrade behind a further **7-day** activation timelock (`IDENTIFIER_UPGRADE_TIMELOCK`).
- **Until anyone calls `activateIdentifierUpgrade()`**, the incoming identifier governs nothing, so traders who distrust it have a guaranteed exit window.
- **Once the incumbent is off UMA's live whitelist**, activation opens **4 days** after approval instead (`IDENTIFIER_UPGRADE_MIN_NOTICE`).
- **The whitelist check runs again** at activation; an identifier de-whitelisted between proposal and activation *cancels* the upgrade and keeps the incumbent, so a dud can never brick governance.
- **Insurance LPs** who react to the approval are not released by it: the 13-day withdrawal cooldown outlasts the timelock, so a request filed at or after approval ripens only after activation.

<details>
<summary>Why activation opens after 4 days once the incumbent is removed, and what that floor covers</summary>

- In that state new listings and UMA termination proposals are refused until activation, so the full timelock would only keep them closed longer.
- The floor is calendar time: it outlasts a single holiday next to a weekend, so even a session pair approved as its venue shuts trades before activation, though a longer closure, such as Easter on a venue that shuts both Good Friday and Easter Monday or a week-long holiday, can cover all of it.

</details>

<details>
<summary>Edge case: an insurance request that ripens inside the notice period</summary>

Only a request filed more than six days before approval (the cooldown less the timelock) can ripen inside the notice period: a standing request, or one filed during liveness when approval comes days after it ends.

</details>

<details>
<summary>Edge case: OOv3's identifier cache is not a liveness guarantee</summary>

The factory also calls `syncUmaParams` at construction and activation to warm OOv3's identifier cache — a first-assertion gas nicety only. The cache is **not** a liveness guarantee: `syncUmaParams` is public and overwrites with the live value, so anyone can flip a de-whitelisted identifier's cache to false. Nothing in Bazaar relies on it — submissions under a dead identifier are prevented upstream by the gates and the routing below.

</details>

### Degraded mode

De-whitelisting creates a **degraded mode**: no dispute on an assertion under the dead identifier can be **resolved**.

- **An undisputed assertion** still settles TRUE when its liveness ends, so a proposal in that state passes unless someone disputes it, and that dispute costs a bond that never comes back.
- **The protocol fails closed** instead of failing open: while `umaIdentifierIsLive()` is false, new pair listings and UMA termination proposals revert at submission, so nothing enters a pipeline nobody can adjudicate (non-UMA termination — insurer vote, stale price, insolvency — is unaffected, and `umaIdentifierIsLive()` doubles as the one-call monitoring endpoint).
- **The identifier-upgrade path** is the deliberate exception — it is the repair path — and in degraded mode it **routes its assertion under the proposed (validated-live) identifier** rather than the dead incumbent, so a dispute on the recovery proposal itself can still be resolved.

<details>
<summary>How a dispute under a dead identifier fails</summary>

- UMA's DVM checks the live whitelist when a dispute's price request reaches it and refuses a dead identifier.
- On Arbitrum, OOv3's oracle is UMA's OracleSpoke, which accepts the dispute and relays the request to the mainnet DVM without that check, so the dispute goes through but is never voted on: the assertion never settles, and both bonds stay locked in OOv3.
- A dispute that reached the DVM before the removal is voted on normally, since the check runs only when a request arrives.
- Making a new assertion under the dead identifier also reverts outright once anyone re-syncs OOv3's public cache.

</details>

<details>
<summary>Which whitelist the fail-closed check reads</summary>

That check reads Arbitrum's copy of the whitelist, which UMA updates by relay from its mainnet governance, so it can trail the mainnet list the DVM checks.

</details>

<details>
<summary>Edge case: an upgrade proposed shortly before the incumbent's removal</summary>

The routing is decided when the proposal is made: one asserted under the incumbent shortly before its removal keeps that identifier, so a dispute filed after the removal would hold it, and anyone may discard such a proposal at once ([below](#stuck-proposals)).

</details>

#### A listing in flight

A listing in flight when its identifier is removed is handled when it resolves.

- **If nobody disputed it**, it is **voided** rather than deployed (`PairDeploymentProposalVoided`). Its pair-ID and feed slots are freed, the escrowed seed is credited to `seedRefundOwed`, UMA returns the bond, and the asset can be proposed again under a live identifier.
- **A disputed listing the DVM ruled TRUE** deploys as usual.

<details>
<summary>Why an undisputed listing is voided</summary>

Its only check was the chance to dispute, no dispute under a removed identifier can be ruled on, and the factory cannot tell whether the removal came before its liveness ended.

</details>

<details>
<summary>Edge case: a whitelist lookup that fails</summary>

A whitelist lookup that fails is never read as a removal, here or in the early activation and immediate discard described on this page, so a caller cannot unlock any of them by starving the lookup of gas.

</details>

### No rollback

**There is no rollback lever, deliberately.** The identifier-upgrade track is the sole recovery route, and the fail-closed gates hold listings and terminations meanwhile — so a slow recovery costs liveness, never funds.

<details>
<summary>Why there is no rollback lever</summary>

- Reverting to a predecessor identifier would require that predecessor to still be whitelisted, but a full upgrade cycle (2-day liveness + 7-day timelock = 9 days) outlasts the ~7.7-day coexistence window UMA left between whitelisting a successor and retiring its predecessor in its only observed migration, and a cycle ends sooner only once the predecessor is already off the whitelist — so a rollback target is already gone by the time it could be used.
- Nor would a rollback address the case that would most want one: an identifier that is semantically wrong but still *whitelisted*, where the incumbent is exactly what you would be rolling back to.
- A permissionless writer of `umaIdentifier` guarding a state that cannot be reached is a liability, not insurance.

</details>

### Stuck proposals

#### Identifier upgrades

With `expireStuckIdentifierUpgradeProposal()`, anyone may have the factory resolve a proposal whose assertion cannot settle. It attempts settlement first, so a still-resolvable proposal simply settles, and the assertion is left live on the oracle either way so the winning party can still collect their bond later.

- For an **undisputed** proposal no waiting is needed beyond liveness, and the proposal is **approved rather than discarded**. The factory queues the upgrade itself, behind the usual timelock, and only the bond waits on the oracle.
- A **disputed** proposal is the one case that needs a timer. It waits out a further `DVM_DISPUTE_GRACE` of **14 days**. Past the grace it is discarded, because its outcome is the DVM's and the factory cannot read it.
- **The exception** is a proposal disputed after its assertion identifier had already left UMA's live whitelist: its price request reaches the DVM after the removal and is refused, so no ruling can come, and anyone may discard it at once while the identifier stays removed. That frees the slot for a new proposal that, with the incumbent removed, is asserted under the proposed identifier.
- **A dispute filed while the identifier was still live keeps the grace** even if the identifier is removed afterwards, because its request may have reached the DVM in time.

<details>
<summary>Why a proposal can get stuck</summary>

Only one upgrade proposal exists at a time, and UMA returns the bond to the proposer *before* firing its resolve callback — so a proposer who becomes unable to receive USDC after proposing makes settlement revert, leaving the slot occupied with nothing able to clear it. `expireStuckIdentifierUpgradeProposal()` bounds that.

</details>

<details>
<summary>Why an undisputed proposal is approved, and why a failed settlement is not proof it is stuck</summary>

- The factory reads the assertion back from the oracle, and one that is undisputed and past its `expirationTime` can only ever resolve as approved: OOv3 takes no dispute from that instant on, and its undisputed branch always resolves truthful.
- A failed settlement is deliberately not read as proof that the proposal is stuck — a caller can make the attempt fail on a healthy proposal by calling from inside one of the oracle's own callbacks, where its reentrancy lock rejects the nested settlement, and discarding on that evidence would give anyone a veto over every upgrade for the price of gas.

</details>

<details>
<summary>Why a disputed proposal waits, and why the grace is 14 days</summary>

- Being unsettleable is expected while the DVM votes, and that state is not readable from the factory (`hasPrice`/`getPrice` are `onlyRegisteredContract`).
- The grace stops a dispute from becoming a cheap veto: without it, any disputer could discard the proposal the moment liveness ended regardless of how the vote later went.
- The 14 days are derived from mainnet VotingV2's own limits: a commit+reveal round is 48 h (`phaseLength` = 24 h) and a request is deleted once it rolls past `maxRolls` = 4, giving it five rounds — 10 days — plus up to one round of enqueue lead, so 12 days is the longest a dispute can legitimately take.
- That bound is a property of the DVM rather than of what is being proposed, which is why the deployment track shares the same constant.

</details>

<details>
<summary>Edge case: this chain's whitelist drops an identifier before mainnet's</summary>

If this chain's whitelist ever dropped an identifier before mainnet's did, a dispute filed in between could still be voted on, and would be discarded at once all the same.

</details>

#### Deployment proposals

Deployment proposals get the identical escape hatch for the identical reason: `expireStuckDeploymentProposal(pairId)` releases a `pairId` whose assertion cannot settle.

- **An undisputed proposal past liveness** is approved on the same reasoning: the pair is deployed with the escrowed seed, and the deployer collects the bond by settling on the oracle whenever that becomes possible — unless its identifier has been removed, in which case it is voided as described above.
- **A disputed one** past the grace, or at once if it was disputed after its identifier's removal, is discarded and its escrowed seed credited to `seedRefundOwed`, which its owner collects with `claimSeedRefund()`.

<details>
<summary>Why deployment proposals need the hatch, and why the seed refund is pulled</summary>

- Without the hatch, a blacklisted deployer or an undeliverable disputer payout would occupy that asset's listing slot forever.
- The credit is pulled rather than pushed because a rejected proposal is credited inside UMA's settlement callback, where a failing transfer would take settlement down with it.

</details>
