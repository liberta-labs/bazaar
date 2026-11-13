# Liquidations

`liquidate(usersToLiquidate[], priceUpdate)` is permissionless: any keeper can liquidate any positions whose equity is below maintenance margin, judged by the same [lagged-MMR solvency math](margin.md) as the rest of the protocol, at plain oracle spot. The call recalculates the margin curve from that price before judging anyone, without storing it, and judges at that rate — capped by the stored rate inside the one-minute cooldown, the only time open interest opened earlier in the same transaction can have reached it.

<details>
<summary>Edge cases: a requirement that has fallen, and the rate the call stores</summary>

- **A requirement that has fallen** since the last recompute — the fund topped up, open interest closed — protects a position at once, even inside the cooldown, rather than when someone else refreshes.
- **The rate the call stores.** After the walk the call stores the curve through the normal cooldown, so the recorded rate reflects the seizures in the same transaction unless something stored it within the last minute, in which case it waits for the next refresh. Open interest opened earlier in the same transaction cannot reach the stored rate this way: the call that opened it refreshed first.

</details>

**Which price may confiscate collateral.** A liquidation is judged at a fresh price, or on a pair that is not continuously traded at Pyth's latest price, and at a stored price older than 3 s only when that is newer still. Seizure takes a position's *entire* bucket rather than its shortfall, so the price has to be the one the market is showing:

- **No `priceUpdate`.** The call uses the pair's stored price only while it is fresh (`MAX_PRICE_STALENESS`, 3 s), and reverts once it has aged out (`BazaarPair__LiquidationPriceTooOld`).
- **Pyth's latest update.** On a pair that is not continuously traded the call can bring Pyth's latest update instead: an update issued within 3 s of the block proves nothing newer existed. While the feed is live that price is fresh; while it is quiet, after a close, it is the last price, usable for **1 minute** after it was generated (`MAX_LIQUIDATION_PRICE_AGE`, `BazaarOracle.verifyAndFetchLatestPrice`). After that, positions wait for the next price, which the reopen leg of the margin curve is sized for.
- **Confidence.** A latest price wider than the 2% confidence cap is refused, not passed over for an older one: while Pyth's publishers disagree that much, liquidations wait, as they do on a 24/7 pair.
- **What is stored.** The price the call is judged at is stored when it is newer than the stored one, like any priced call's, so the pair's mark and the lagged maintenance margin describe the instant of the seizure.
- **A newer stored price** than the one the update brings is judged instead.

<details>
<summary>Why a stale stored price reverts, and how an update proves the latest price</summary>

- **A stale stored price reverts** because otherwise a liquidator could pick, whenever the stored price was older than the live one, whichever of the two condemned an account.
- **How an update proves the latest price.** Pyth issues an update on every tick of a channel whether or not a price changed, each carrying the most recent price with the time it was generated, so an update issued within 3 s of the block proves nothing newer existed.
- **Why a newer stored price is judged instead.** An update carries each feed's latest price as of its issue, so a stored price newer than the one the update brings came from an update issued after the call's: for a single feed it is fresh, and a composite's, dated by its older leg, may be older than 3 s but is still newer than Pyth's latest as the call proves it.

</details>

**No restart grace on 24/7 pairs.** A continuously traded pair has no stale fallback, so a liquidation there always runs on a fresh price, and nothing holds it back after an outage.

- **After a gap.** When the Arbitrum sequencer halts, or nobody brings the pair a Pyth update for a while, the first transaction that brings a fresh price judges every account it names at the post-gap price. The protocol reads no sequencer-uptime signal and opens no grace window.
- **What is at stake.** Because seizure takes the whole bucket, an account that sits just under maintenance margin at the restart price loses all of its remaining equity, up to about MMR × notional, even when a small top-up would have cured it.
- **The holder's defences race the keepers** in the same block: `depositCollateral` needs no price and stays open, but nothing orders it ahead of a liquidation.
- **A StopLoss** set above the restart price gives no protection either.
- **The only protection** across an outage on a 24/7 pair is margin held above maintenance.
- **Session pairs differ**: their gap risk is priced into margin, and their liquidations follow the rules above.

<details>
<summary>Why there is no grace window, and why a StopLoss does not help</summary>

- **No grace.** The trade-off is deliberate: a grace would also delay the seizure of positions that are genuinely failing, and the fund would carry the gap through it.
- **The StopLoss** is cancelled with the bucket if the account is seized first, and if that batch opens an [ADL](adl.md) window, trigger execution halts while liquidation carries on.

</details>

## What happens to a liquidated position

Liquidation is **full** — there are no partials:

1. The entire remaining collateral is seized into the pair's **insurance fund**.
2. The position itself transfers to the pair's **vault** at its *bankruptcy price* — the price at which its equity would have been exactly zero:

   ```
   long:  bankruptcy = (entryValue − collateral − fundingPnl) / size
   short: bankruptcy = (entryValue + collateral + fundingPnl) / size
   ```

3. The keeper earns [a reward](#the-keepers-reward) from the insurance fund.
4. The user's TP/SL orders are canceled and the bucket fully reset. Resting limit and stop-limit orders are not canceled by the liquidation.

### The keeper's reward

The keeper earns, from the insurance fund and with no profit-contingent component:

- **Per seizure:** **$0.05** for each position the call seizes — except that a seizure whose arrival [nets](#the-vault-two-buckets-one-netting-rule) the two buckets' overlap earns the larger of $0.05 and **2 bp** of the notional the netting retires, valued at the liquidation price.
- **Inline unload:** on top of those, whatever 2 bp of what the call's inline unload sells into the book exceeds the part of those rewards beyond the nettings' 2 bp.

How the rewards are paid:

- **Paid at seizure.** The per-account rewards are paid as soon as the call seizes the accounts, so they are due even when nothing can be sold, as while an ADL window is open.
- **Nothing seized, no flat reward.** A call that seizes nothing earns no flat reward (it still runs the inline unload and earns 2 bp of whatever it sells), and an account named twice in one call is paid for once, so naming solvent or repeated accounts cannot farm the $0.05.
- **Positions under $5.** An account whose position is worth less than **$5** (the order minimum) at the liquidation price counts for at most its own equity rather than the full $0.05. A position of $5 or more is paid the full $0.05 even past bankruptcy.
- **Credited, not transferred.** The fund is debited and the keeper's claimable balance credited in the same step — no transfer runs inside the liquidation, so nothing about the keeper's address can block it.
- **Exposure that joins a bucket.** The rate is paid on exposure the call actually took off the fund, not on exposure it moved onto the fund: a netting retires the overlap at once, while a seizure that joins a bucket, or the part of a netted estate larger than the opposite bucket, is paid for when it is retired — at 2 bp by the call's own unload, a later `unloadVault` or a later netting, or by an [ADL](adl.md) batch's close, at 2 bp or its share of the bad debt the close averts where that is larger.
- **Capped at the fund's *free capital*.** The collateral just seized is earmarked against the bucket it arrived with and never pays the keeper, so a fund holding nothing else pays nothing, and the liquidations themselves still commit.

<details>
<summary>Why the reward is per account</summary>

Batching is never penalized: one call naming ten accounts earns what ten single-account calls would, and costs the keeper less gas.

</details>

<details>
<summary>Why $5 is the line for the full $0.05</summary>

- **Below $5.** The order minimum bounds orders, not positions: a reduce sized just under the position, or a small partial fill, can leave a position that small sitting at or near zero equity without any price move, so an unconditional $0.05 would pay the fund out once per such account.
- **$5 or more.** A position of $5 or more holds at least $0.10 of equity at the maintenance line and only a real price move carries it further, and until it is seized its further losses are the fund's.

</details>

## The vault: two buckets, one netting rule

Inherited inventory is held in two aggregates, a **long bucket** and a **short bucket**, each a single-direction holding — sums of size, entry notional, bankruptcy notional and the collateral seized with it, a size-weighted entry funding index and a size-weighted seizure time. A seized estate joins its own side's bucket, seeding one when that side is empty. There is no per-estate FIFO: unwinding is O(1) regardless of how many accounts were liquidated, and a bucket never changes side.

### Netting the overlap

Where both buckets hold inventory they **overlap** by the smaller one's size: a long and a short of equal size, whose price legs cancel at any price and whose funding legs cancel at the live index.

- **Netting the overlap realizes** the gap between the two sides' entries, price and funding legs together, which does not depend on the market price.
- **It runs as soon as it is a gain or a loss the fund can afford**: after every seizure, at the end of every unload walk and at the end of every [ADL](adl.md) batch.
- **The loss is paid** from the collateral seized with the two netted slices first, and only then net of the arrears and from the fund's free capital — never from the earmark of inventory that survives the netting.
- **Backstop.** The cap on what the netting may spend is kept as the backstop, and anything it cannot cover is realized as `deficit` in the same transaction.

<details>
<summary>How the gate measures a loss the fund can afford, and why the seizure pays first</summary>

- **When the loss fits.** The loss fits when it is within the two netted slices' seizure plus whatever of the fund's free capital **above the reserve** and the ledger's arrears exceeds what the bucket that survives the netting — the larger one's remainder — needs to close at its own bankruptcy price beyond its earmark: the collateral the ledger never paid at seizure plus the funding accrued while the vault held it.
- **What the survivor needs.** The arrears are one pair-wide balance, and spent on a netting they would be missing when the survivor settles, where the shortfall would surface as `deficit` with no insolvency verdict in between.
- **Seizure first.** Netting the arrears first would spend the survivor's share on a loss the slices' own seizure covers and leave that seizure in free capital, which, while the fund sits below its reserve, neither this gate nor the ADL gate counts: the survivor would read short although the fund held the same value, the next netting could be refused, and its loss at the mark could open a window. Paid from the seizure first, a netting reaches the arrears only by what its loss exceeds it, within what the gate found spendable.

</details>

### When the netting would breach the reserve

**Both buckets stand.**

- **The estate has still been seized** — its owner is out, its collateral is in the fund, earmarked against its bucket — and the two buckets hold a hedged pair whose loss is fixed whatever the price does.
- **That loss beyond the two seizures counts in the [ADL](adl.md) gate** like any other inventory loss, and almost always exceeds the fund's capital above the reserve, since that is why the netting was refused.
- **The window that opens** closes each bucket against its own counterparties at its own bankruptcy price, so the loss lands on the winners it belongs to rather than on the fund.
- **The netting is re-tested** as every batch and every walk moves the fund's means.
- **Nothing is left open on a trader**, there is no list and no cap, and a liquidator earns the same flat reward for a seizure that joins a bucket as for any other.

## Exiting the inventory

The vault is not a market maker — it exits as fast as the book allows.

- **Inline, inside `liquidate()` itself**: the freshly seized side is crossed into the resting book before the transaction re-evaluates vault health, within a fixed node budget (`LIQ_INLINE_UNLOAD_STEPS` = 16) that keeps the liquidator's gas predictable. At that instant only bids inside the band fill; bids beyond it wait for the floor described below.
- **Permissionless `unloadVault(maxSteps, priceUpdate)`**: any keeper finishes deeper inventory for **2 bp of the notional it unloads**, from the insurance fund. The rate is paid on any amount, so a keeper that drains a thin book is never left with nothing; a **$0.25** floor (`UNLOAD_BOUNTY_MIN`) applies only when at least **$1,250** unloads (where the rate overtakes it) or the call clears the bucket it works, which is what stops a keeper earning a premium by slicing one unload into many. Capped at the fund's free capital — never paid from the seizure earmarked against inventory still held.
- **Netting the two buckets' overlap** (above), re-tested at the end of every walk.
- **[Auto-deleveraging](adl.md)** when the book can't absorb it and the fund is threatened.

Each unload walk works **one bucket**: the one above water at the oracle, where a sale or a cover at the oracle is at or better than the bucket's bankruptcy price, and otherwise the larger, long on a tie; the next call works the other.

<details>
<summary>Edge case: both buckets above water</summary>

Two buckets both above water seldom coexist: their overlap's loss then sits within what the estates' collateral covers, give or take the funding accrued between the two seizures, and the netting gate usually passes it at the next liquidation, walk or batch; where it does not, the order above decides.

</details>

Both unload paths fill only inside the **unload bound** and within the fund's **headroom**.

### The unload bound

The bound is built from two anchors:

- **The estates' fund-neutral price**: the price at which closing the inventory pays back exactly what backs it in the fund's hands, net of the funding accrued since the estates entered (their entry basis less that backing, carried forward by that funding).
- **The band edge, min(5%, MMR) from oracle** (`LIQ_MAX_SLIPPAGE_BP`), where the MMR is the lower of the current rate and its lowest hourly sample over the past day.

The backing is the collateral seized with the bucket *plus its share, by size, of the ledger's arrears* ([below](#how-an-exit-is-booked)), which settlement nets off the fund's payment, so with both counted the neutral price is the estates' own bankruptcy price however much of their collateral the ledger could actually hand over. The neutral price is held from crossing the estates' bankruptcy price: the vault never sells inventory below (or buys it back above) the price at which the estates' own collateral ran out, whatever else the ledger owes the fund.

<details>
<summary>Why the band uses the day's lowest MMR, and why the neutral price counts the arrears but stops at bankruptcy</summary>

- **The day's lowest MMR.** The current rate follows live open interest, which a matched pair of accounts can inflate for a minute, and a wider band would move its edge toward bankruptcy, where fills are immediate.
- **Counting the arrears.** Counting the seizure alone would read an estate as bankrupt by the amount its winners had already withdrawn and refuse fills the fund loses nothing on.
- **Stopping at bankruptcy.** The arrears are one pair-wide balance, though, and an inventory that closes without a loss large enough to consume the arrears it created leaves them behind; hence the hold at the estates' bankruptcy price.
- **What the hold forgoes.** The hold also forgoes funding the inventory has received since seizure, which the frozen bankruptcy figure does not carry.

</details>

How a bid is treated:

- **Inside the band.** A bid inside the band fills at once, including one under bankruptcy.
- **Beyond the band.** A bid beyond the band that still beats bankruptcy fills only once the vault's **floor** has opened to it. The floor starts at the band edge when the inventory is seized and slides linearly to the neutral price over **3 minutes** (`UNLOAD_FLOOR_DECAY`), measured from the bucket's size-weighted seizure time (a large estate joining later restarts most of the countdown, a dust one barely moves it, and inventory leaving does not touch it).
- **Under both anchors.** A bid under both anchors is refused.

<details>
<summary>Why a bid beyond the band waits for the floor</summary>

The region between the band edge and bankruptcy is the estates' residual equity; offering it to the whole market for a few minutes means its price is set by competing bids rather than by whoever bids in the seizing transaction — the liquidator included, who could otherwise rest a bid a hair above bankruptcy and sell the vault its own seizure in the same call.

</details>

### The headroom

The headroom is what the fund may spend on fills inside that bound: its free capital above a **reserve** of 10% of the [insurance target](insurance.md) on open interest (`ADL_RESERVE_BP`; the lower of live open interest and its lowest hourly reading over the past day), less the loss the inventory already carries at the mark, less the caller's reward.

A fill is measured against a reference price:

- **Beyond it** a fill lowers the loss the remainder carries by at least what it costs and is always taken.
- **Inside it** a fill costs the difference per unit, and the walk takes only what the headroom covers, trimming the last maker and stopping.

<details>
<summary>Which price is the reference, and why</summary>

- **On the healthy side of the ADL gate** — while the fund's capital above the reserve covers the inventory's loss at the mark — the reference is the nearer of the neutral price and the oracle, because the headroom has already set that loss aside: spending it to zero leaves the fund above its reserve by exactly the remaining inventory's loss at the mark, so the pair ends the walk healthy.
- **A walk that starts past the trigger** has nothing set aside, so its reference is the neutral price itself: it takes only fills that cost the fund nothing, spends neither the base nor the reserve, cannot book a deficit, and leaves the rest to the auction.

</details>

An unload's fills can never take the fund below its reserve, and never push a pair over the ADL trigger — which is why health is judged *after* the walk, letting stale bids absorb inventory before any auction opens.

The caller's reward, paid after the walk, is held to the same line:

- **A loss left at the mark.** Fills at or beyond the reference are taken whatever the headroom, so where the inventory left carries a loss at the mark the reward takes no more than what the fund's capital above the reserve covers that loss by, and cannot open the auction either.
- **Where the inventory carries no loss at the mark** the reserve may pay it.
- **A walk that started past the trigger** pays its reward from free capital, the reserve included, since the auction opens regardless.

### No fills against a stale oracle

A liquidation judged at Pyth's latest price older than 3 s still seizes, within its 1-minute age limit (see above), but its inline unload waits, and `unloadVault` fills nothing and pays nothing until the first fresh print.

<details>
<summary>Why the vault does not exit at a frozen mark</summary>

Off-chain venues print the reopen before the oracle can, so a maker who can see it would take the inventory at the frozen mark only when the reopen favours the fund, which would then exit exactly when holding pays and hold exactly when it loses.

</details>

### How an exit is booked

- **Vault PnL** from these exits is booked as an insurance↔deposits transfer (profits refill the fund; losses drain it, never past the headroom).
- **Winners' withdrawals.** Until an exit books it, the loss has not reached the deposits ledger: the ledger sits below the claims on it by the inventory's loss at the mark, and a realized winner's withdrawal beyond what the ledger holds reverts with `CollateralLib__LedgerShortfall(amount, available)`.
- **How the cash comes back.** The cash is in the fund, earmarked against the inventory, and any exit — an unload, an opposing netting, an ADL close — pays it back; a winner still holding the position can rest an order inside the bound and call `unloadVault` to be that exit, and `available` is withdrawable meanwhile.

<details>
<summary>Why the ledger sits below its claims, and how large the stuck tail can be</summary>

- **Why the ledger is short.** The seizure moved the estate's whole collateral into the fund, including the part that covers the counterparties' gains.
- **The stuck tail** is bounded by the inventory's loss less the margin the winning side's new holders posted, which is nothing after a prompt liquidation at the maintenance line and something only after a gap or a late seizure.

</details>

- **`deficit`** — realized bad debt that [winds the pair down](termination.md) — is reserved for genuine insolvency: a loss the fund cannot cover once the estate settles.
- **Arrears.** A seizure the deposits ledger could not pay in full (winners had already realized against the position and withdrawn) is carried as the ledger's **arrears** to the fund, netted off the fund's payment when the estate settles and subtracted from what traders are owed at finalize, so the fund's outlay on an estate is never more than the loss beyond its bankruptcy price. Arrears no open inventory relies on stay a receivable until a later loss nets them or finalize collects them.
- **Payment order.** Every exit — a netting, an unload fill, an [ADL](adl.md) close — pays its loss first out of the collateral seized with the units it settles, then net of the arrears, and only then from free capital.

<details>
<summary>Why every exit pays from its own seized collateral first</summary>

An exit that loses no more than that collateral and the units' share of the arrears therefore leaves the inventory behind it at least as backed per unit as before, and one that loses more draws on the arrears and free capital by exactly the excess. Netted from the arrears first, a fill the walk takes as free would leave the inventory reading worse per unit while the released collateral sat in free capital below the reserve, where the ADL gate does not count it, and the walk could open the auction it is there to avoid.

</details>

Once a pair's settlement price is fixed, this live liquidation path is off: positions are marked to the frozen price by permissionless settlement instead.

### Slippage and drift

Every liquidation fill also feeds two EMAs, split at the oracle, and they go to different places.

- **Slippage** is the fill against the oracle — the execution cost of closing the inventory — and adds straight into the pair's [stress move](margin.md#the-stress-move) at full size, because maintenance margin has to pay for getting out.
- **Drift** is the oracle against the estates' average bankruptcy price — how far the market ran past the level margin was set to survive while the vault held the position — and feeds the [insurance target](insurance.md), because that overrun is precisely the loss the fund exists to absorb.

<details>
<summary>How the readings are kept: fade, clock, floor, caps and weight</summary>

- **Fade.** A reading from one episode halves three days after it and keeps falling harmonically, so a market that stops liquidating badly recedes to its volatility curve on its own.
- **Clock.** The clock advances only as prices are stored and, on a session pair, skips any stretch of 12 h or more without one (see [Margin](margin.md#the-stress-move)).
- **Floor.** Each fill is recorded floored at zero before it is weighted.
- **Caps.** Slippage is also capped at `LIQ_MAX_SLIPPAGE_BP`, the unload bound's own band. Drift is never capped.
- **Weight.** Each batch is weighed against the evidence already accumulated or 1% of per-side open interest (`LIQ_GAP_PRIOR_FLOOR_BP`), whichever is larger, so it moves both readings by its share of the book (see [Margin](margin.md#the-stress-move)).

</details>

<details>
<summary>Why two readings, and why each is floored, capped and aged this way</summary>

- **Two readings, not one.** Measuring both against the bankruptcy price alone fuses them into one number that reads as neither: blind to a thin book whenever slippage stays inside MMR, and unbounded above it, since a short bought back in a squeeze can print arbitrarily far past bankruptcy.
- **Anchors.** Each reading keeps its own anchor, which a later batch moves toward the present only by its share of that reading (evidence merged into an older reading takes on part of its age), and each is stored to a fraction of a basis point, so a stream of dust unloads can neither restart the fade nor round a reading away.
- **Why the clock skips a closure.** A shut venue teaches nothing, and a reading taken during the silence must not fade through a closure that has not ended yet.
- **Fresh oracle only.** Unloads fill only against a fresh oracle, so neither leg ever records oracle error as book depth.
- **Floored at zero.** A fill better than the oracle, or an oracle still short of bankruptcy, is value the unload has already paid into the fund, so it counts as a zero-cost sample at full weight rather than as credit against the next real cost.
- **The slippage cap.** Past the unload bound's own band a fill only lands when the market sits that far past bankruptcy in the fund's favor, where the walk takes any maker that still beats it.
- **No drift cap.** A large reading is a genuine overrun.
- **A batch's share of the book.** A dust unload moves the readings by a fraction of a basis point, and no single estate — including one its own liquidator buys back from the vault — can replace the pair's history.

</details>
