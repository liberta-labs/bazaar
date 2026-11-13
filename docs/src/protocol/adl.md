# Auto-Deleveraging

ADL is the backstop for the backstop: when the vault's inherited liquidation inventory threatens losses the insurance fund cannot absorb, the protocol force-closes the *most profitable, most leveraged counterparties* against that inventory — the standard perp-exchange socialization mechanism, implemented as a permissionless Dutch auction.

The vault holds its inventory in **two buckets**, the liquidated longs and the liquidated shorts (see [Liquidations](liquidations.md)). A window closes both: the long bucket against profitable shorts, the short bucket against profitable longs, each at its own settlement price, so a bucket's shortfall lands on that bucket's own counterparties and never on the other side's.

## Trigger & freeze

After every matching transaction, liquidation, unload, withdrawal, price refresh, and ADL step, the pair computes the vault's **expected loss**. When the expected loss exceeds the fund's **free capital above its reserve**, ADL goes pending.

- **Expected loss.** What closing both buckets at the mark would cost beyond what backs them — the collateral seized with them plus the [ledger's arrears](liquidations.md) to the fund, which settlement collects.
- **Where the two buckets overlap**, a long and a short of equal size, the mark cancels out of that figure: the overlap's loss is the gap between the two sides' entries, fixed whatever the price does, and only the vault's *net* exposure moves with the mark.
- **The reserve** is 10% of the [insurance target](insurance.md) on open interest, kept for the losses no bound can refuse, and sized on the lower of live open interest and its lowest hourly reading over the past day, so positions opened to inflate it cannot bring the trigger forward (see [Insurance Fund](insurance.md)).

### While the window is open

- **All trading and order creation freeze**; position-holders' withdrawals freeze (flat users may still exit — their cash can't affect scores or margin).
- **Insurance deposits are refused too.** The refusal starts at the trigger, not at the latch: a deposit whose own price would open the window is refused as well, so nobody can carry the crossing price in ahead of the health check.
- **Nothing is snapshotted.** Every batch ranks its candidates at the price its own transaction resolves and stores, with the live funding index, and sorts them on-chain (below). `AdlTriggered` reports the price and funding index at the open for indexers; the auction does not read them again.
- **Closing inventory.** Once a window is open, matching is frozen along with everything else, so until it clears `executeAdl` is the only path that closes inventory against counterparties; the one other path that retires inventory is a netting of the two buckets' overlap the fund can afford, which a `liquidate()` that seizes onto the smaller side can still bring about. See [Liquidations](liquidations.md).

<details>
<summary>Why insurance deposits are refused</summary>

A batch that closes winners at a bucket's bankruptcy price moves part of that bucket's loss from the fund onto them, and that recovery belongs to the LPs the window keeps from redeeming. Capital arriving mid-auction would take a share of it, and would shrink the batch as well — a winner could deposit its own haircut away.

</details>

<details>
<summary>How the window's epoch is kept</summary>

The window's **epoch** advances once, at the open: it keys the deposit tags below, and nothing inside the window moves it — not a bucket that appears on the other side mid-window, not a batch, not a netting.

</details>

### How the window ends

- **Hysteresis.** Pending state only clears once the fund's free capital above its reserve could finish the *remaining* inventory at the edge of the unload band — min(5%, MMR) from the oracle on the side the net exposure loses on, with MMR the lower of the current rate and the lowest rate recorded over the past day, the hour in progress included, the same figure each batch closes to. The overlap's fixed loss counts in both tests alike; the band moves only the net side.
- **A hard deadline.** Pending for **24 hours** without resolution → the pair [winds down](termination.md) at the live price (the settlement price is fixed on the spot and the settlement window opens; anyone finalizes once every position is settled). ADL cannot become a limbo.
- **Both the auction and that deadline require a price the oracle currently attests** — the stored-price fallback is refused on either.
- **Runway.** The deadline is not the clock alone: the first fresh price stored past the 24 hours arms it **30 minutes** ahead, and only then may anyone terminate. The window is set once and never extended, and it is cleared when the auction resolves, so a later window on the same pair starts with its own full runway.

<details>
<summary>Why release is judged at the band's edge, why the deadline waits for a fresh price, and why the runway is never extended</summary>

- **Why the band's edge.** So the walk that resumes can sell the rest inside the band without reopening the window, and the boundary can't flap on a tick.
- **Why not the clock alone.** On a pair whose venue is shut, the auction and the deadline are blocked together and would otherwise unblock in the same block at reopen, racing over a pair the auction might still save.
- **Why set once.** A per-price refresh would be a snooze button, since the [refresh bounty](fees.md) pays keepers to store a price every ~5 minutes while the vault holds inventory worth $1,250 or more, as it typically does through a window, and the fund more than $5,000 of free capital.

</details>

<details>
<summary>Edge case: an estate seized onto the other side mid-window</summary>

An estate seized onto the other side while a window is open — a `liquidate()` the fund could not afford to net — is inventory like any other: it seeds or joins that side's bucket, its loss beyond its seizure counts in the expected loss, and the next batch closes it against its own counterparties. Nothing is re-pointed, re-snapshotted or restarted, and the 24-hour clock runs on.

</details>

### Unloads and insurance redemptions

- **The unload walk** spends only the fund's headroom above the reserve, so an unload can never open a window on its own — and a walk that starts past the trigger takes only fills at or better than the estates' fund-neutral price, which cost the fund nothing, leaving the rest to the auction.
- **Insurance redemptions are held tighter.** A paying call pays at most the fund's free capital less the reserve and the cost of finishing the inventory, valued together at whichever edge of the band makes their sum larger, with the band at the current maintenance rate, never narrower than the one a window's release is judged on, and a larger claim only that far. An LP exit can then neither open a window nor spend the reserve, and no move of the mark inside the band opens one after it unless the move also raises the fund target (see [Insurance Fund](insurance.md)).

### A fund at or below its reserve

The capital above the reserve is zero and the gate collapses to its strictest form:

- **Trigger.** Any paper loss on inherited inventory opens a window on the next fresh verdict.
- **Each batch is sized** to close whatever its legs can until the reserve their closes release can carry the rest.
- **The window clears** only once the inventory is gone or sits above water by more than the band.
- **Unloads.** The vault meanwhile sells only at its neutral price or better, so nothing is realized at the fund's expense.
- **Winners carry every loss beyond the seizures** while the taker insurance fee runs near the top of its deficit curve (about 40× its base rate at a tenth of target coverage, capped at 50 bp) and LP withdrawals stay blocked.
- **Recovery.** Every dollar of fees or deposits above the reserve restores a dollar of headroom and moves the trigger off zero — there is no memory and no separate threshold at the reserve line.
- **[Share pricing](insurance.md)** reads the same figure: a deposit or redemption deducts the inventory's unrealized loss only as far as the capital above the reserve covers it. No share changes hands past that point: a redemption's own health check refuses there, and so does a deposit.
- **LP flows wait** in this regime: a redemption while the vault holds any inherited inventory, and a deposit while that inventory sits under water.

<details>
<summary>Why share pricing stops at the reserve, and why LP flows wait</summary>

- **The deduction stops at the capital above the reserve** because beyond that the auction charges the remainder to winners rather than to the fund.
- **A deposit past that point**: its capital would shrink or cancel the auction that charge rests on.
- **A redemption while the vault holds any inherited inventory**: it pays only from capital above the reserve and the finish, valued together at the band's edge, and there is none.

</details>

## The auction

Anyone may call `executeAdl(longBucketWinners[], shortBucketWinners[], priceUpdate)`.

- **The first list** is shorts to close the long bucket against, the second longs to close the short bucket against; either may be empty, not both, and neither may hold more than 25 entries.
- **Order does not matter and repeats are harmless**: the batch scores every entry itself, at the price the call resolves, sorts each list by descending **ADL score** with ties by ascending address, drops a repeated account, and closes in that order. There is nothing a keeper's off-chain sort can get wrong, and a newer tick stored ahead of the call moves the ranking without reverting the batch.

### The ADL score

```
adlScore = positionPnL(at the price the call resolves) / collateral
```

The score is profit-to-collateral, so a 10× levered winner outranks a 2× one at equal profit.

- **Collateral for scoring excludes deposits made during the current ADL window** (epoch-tagged at deposit time), on either side: topping up mid-auction protects your margin but cannot re-rank you out of the queue.
- **A withdrawn-to-zero winner** scores effectively infinite — pure-profit claims stand first in line.
- **An account is a candidate** only while the bucket opposite it holds inventory, only while it is in profit at that price, and only while its score clears the threshold below.
- **`BazaarPairLens.getAdlScore`** applies the same rule to either side at the pair's last stored price, which is the on-chain key whenever the transaction stores nothing newer.
- **The price the pair ranks at** is the keeper's update when it was generated in a later second than the pair's stored price, and the stored price otherwise, so a keeper can bring a newer price but cannot pin the ranking to one from an earlier second than the pair already holds.

### The eligibility threshold

Eligibility decays like a Dutch auction: the score threshold starts at **25×** and decays quadratically to ~0 over **10 minutes**. The worst offenders are executable immediately; by minute ten, any profitable counterparty is.

- **A stored price that ends a gap of at least 1 hour** restarts the decay at 25×.
- **The 24-hour termination clock** is separate and never rewinds, so a pair that keeps failing to deleverage still resolves.

<details>
<summary>Why a gap of an hour restarts the decay</summary>

The decay measures time the auction could actually run.

- **What the restart prevents.** ADL needs a price the oracle currently attests, so across a closure the curve would otherwise descend against attempts nobody was able to make — and the first keeper at the reopen would find the gate wide open, free to deleverage any profitable account instead of the worst-ranked ones the curve exists to reach first.
- **Why an hour.** It is the same discontinuity threshold the [reopen-gap leg](margin.md#the-stress-move) of the pair's stress move learns from, set so the refresh bounty's cadence separates a shut venue from ordinary call sparsity.
- **What it costs.** Restarting forfeits whatever the auction had already spent, which is at most the ten minutes; the trade is a clock that is a single instant rather than an accumulated one.

</details>

### Batches that close nothing

- **A batch that admits nobody on either leg** and finds no netting to make reverts `AdlLib__NoEligibleWinners`.
- **A batch that admits winners but closes nothing** — they are all skipped at their leg's settlement price (below), or no size of its legs moves the fund toward release — returns quietly and emits `AdlExecuted` with what it closed, which may be nothing; keepers read the event, not the call's success.

### Two buckets, one batch

- **A batch runs one leg per non-empty bucket**, each against its own cohort.
- **Each leg settles at its bucket's price** — the bucket's average bankruptcy price, or the mark when the mark sits on the fund's favorable side of it (see [Settlement](#settlement)) — so the leg whose bucket is under water closes its winners at the bankruptcy price and costs the fund nothing, and the leg whose bucket is above water closes at the mark and hands the fund the gain.
- **The losing leg runs first**, and the other leg is then sized on what the first leaves and closes only what is still needed. Where both buckets are under water, or neither, the larger runs first.

<details>
<summary>Why the losing leg runs first</summary>

It is sized on the vault as the batch finds it, so its counterparties pay what restoring health takes before any gain on the other bucket is realized.

</details>

Each leg closes **only as much as restores the fund** (the sizing below). The two legs meet only through the fund, with two exceptions: pairs and fallback netting.

#### Pairs

- **Only a bucket's excess over the other bucket is directional**; the rest of it is hedged unit for unit by the other bucket.
- **A leg closes its excess first**, and where that does not restore the fund, closes its hedged units in **pairs**, one of each bucket against its own cohort: a pair retires an overlap unit whole.

<details>
<summary>Why hedged units close in pairs, and what a pair gains</summary>

- **Closing a hedged unit alone** leaves the other bucket's unit directional, finished at the band edge adverse to that bucket, so it lowers what finishing the inventory would cost only where its own settlement price lies beyond that edge — where the bucket is under water by more than the band — and otherwise *raises* it, a close that could never release the window.
- **A pair's gain** is the gap between the two legs' settlement prices less both rewards, with reserve released on both sides.

</details>

<details>
<summary>Edge cases: which leg pairs, the cap on pairs, and hedged units left unpaired</summary>

- **The other leg is held to at least as many units as the pairs**, so only the leg that runs first can pair: a pair sized against a leg that has already run would close its own half alone.
- **The pairs are capped** at what the other cohort covers, and units the first leg could not close against its own cohort do not hold the other leg.
- **Hedged units with no leg left to pair with** close alone where that still gains, and otherwise not at all.

</details>

#### Fallback netting

- **When it applies.** A losing bucket with **no eligible winner at all** holds the window open however the rest reads, and only the fund absorbing it ends that: netting the two buckets' overlap, which the fund may do once it can afford the overlap's loss above its reserve (the [netting gate](liquidations.md)).
- **The winning leg** is what moves the fund's means, so it is sized to the point where the netting fits.
- **The fund pays** what the netting costs, as the `liquidate()` that seized the estate would have had it held the cash then; the loss stays with the fund, not with the other bucket's winners.

<details>
<summary>How the winning leg is sized for the netting, and where its close is capped</summary>

- **How it moves the fund's means.** Each unit the winning leg closes at the mark hands the fund the slice's earmark plus its realization there, and frees the unit's share of the reserve once live open interest is down to the reading the reserve is sized on.
- **The point where the netting fits.** The overlap's cost beyond the two netted slices' own backing, the rate the netting pays its executor, the reward already accrued, and what the bucket the netting leaves has to keep (the larger of its finish cost at the band edge and the cost beyond its earmark of closing it at its bankruptcy price).
- **The close never eats into the overlap itself**: it is capped at the winning bucket's excess over the losing one when the winning bucket is the larger, and at the whole winning bucket when it is the smaller or the two are equal, where closing it all retires the overlap and leaves nothing to net.
- **Where no size within the cap affords the netting**, the cap is closed and the netting waits for a later batch or walk to move the fund's means further.

</details>

#### The closing netting

**Every batch ends by netting** the buckets' overlap if the fund can then afford it, whichever route got it there: the legs' closes hand the fund earmarks and realizations and release reserve, so a netting that was unaffordable as the batch began can fit at its end. The same re-test runs after every `liquidate()` and every unload walk.

Two buckets therefore coexist only while netting them would cost the fund more than it may spend; at the first liquidation, walk or batch after that stops being true, they collapse to one.

## Settlement

Winners close at the **average bankruptcy price of their bucket's dead estates** — the price at which that bucket realizes exactly the collateral it seized, so the close is neutral to the fund whatever the winner's own entry was — or at the **mark**, whenever the mark sits on the fund's favorable side of that price.

<details>
<summary>How a bucket's bankruptcy price is computed</summary>

The bankruptcy price is the bucket's summed bankruptcy notional over its size, rounded toward the fund: up for the long bucket, which the vault sells, down for the short bucket, which it buys back.

</details>

<details>
<summary>Why a leg takes the mark when it is the better price for the fund</summary>

A window can outlive a recovery past the bankruptcy price (it releases only once the fund could finish the remainder at the band edge), and `executeAdl` is permissionless with a caller-chosen winner list, so settling there at the bankruptcy price would let a winner deleverage themselves better than market at the fund's expense. Taking the mark keeps the close never better than market for the winner and hands the recovery to the fund.

</details>

### What a winner receives

At the leg's settlement price:

- **Winners whose PnL at that price** would be *negative* are skipped (never worse than break-even). A winner profitable at the mark can be under water at a bankruptcy-priced settlement; the leg's scan admits it at the mark and its close skips it there, and the next admitted winner takes its place.
- **Oversized winners** are partially closed pro-rata.
- **The winner realizes their full PnL at that price** into their bucket, exactly as a maker filled by a vault unload does.

<details>
<summary>How a winner's full PnL is backed</summary>

The part of that PnL between the winner's entry and the estate's entry was already settled by the winner's earlier counterparties, so it is backed by the deposits ledger, not by the fund.

</details>

### How the inventory slice settles

- **The inventory slice settles** through insurance against the liquidatees' entry, **price and funding legs together**, as on an unload fill.
- **The fund can only fall short by the holding-window carry**, the funding accrued while the vault held the inventory: what it cannot pay is **withheld from the winner's funding income** — never from their price PnL — and reported in the `UserAdld` event.
- **A shortfall beyond that** is recorded as `deficit` and [winds the pair down](termination.md).
- **Rounding is the one exception.** Up to **one millionth of a USDC** per close (the smallest amount the pair can pay out) comes off the winner's credit even where they earned no funding, and a remainder that small which the credit cannot absorb is not recorded as `deficit`.
- **Each slice is funded** from its own seizure earmark, the arrears and the fund's free capital, never from the earmark of inventory still open — the other bucket's included — so within a batch the highest-scored winners are paid in full and any withholding lands on the later ones.
- **It spends them in this order**: its own earmark first, then the arrears, then free capital.

<details>
<summary>Why the fund can only fall short by the carry, why rounding is an exception, and why a partly paid seizure is not a shortfall</summary>

- **The carry.** At the bankruptcy price the two legs net to the seizure (already in the fund) plus the funding accrued while the vault held the inventory, because the bankruptcy price already embeds the estate's pre-liquidation funding; at a better mark the loss is smaller by the distance and the fund keeps the rest of the earmark.
- **Rounding.** A slice's shares of the entry basis and the earmark are each rounded on their own, so a close can land a few wei past its earmark with no carry at all. A remainder that small is not recorded as `deficit` because a deficit of any size ends the pair.
- **A seizure the deposits ledger could only partly pay** is not a shortfall: the unpaid part is the ledger's arrears to the fund, and a slice's settlement nets its share of them.

</details>

<details>
<summary>Why a slice spends its own earmark before the arrears</summary>

A slice whose earmark and share of the arrears cover its loss therefore leaves the inventory it does not close at least as backed per unit as before. Netting the arrears first would leave the inventory reading worse to the netting gate and to the window test, which both count the arrears in full, while the released earmark sat in free capital below the reserve, where neither counts it.

</details>

### How much a leg closes

A leg closes **only as much of its bucket as restores the fund**, never the whole bucket because one winner happened to be large enough to cover it.

- **The target** is the gate's release condition: the fund's budget — free capital above the reserve, negative by any shortfall below it, plus the ledger's arrears — must be able to finish the inventory that remains at the unload band's edge.
- **Whatever the batch does not need** stays with the winner.

<details>
<summary>How the size is derived</summary>

- **Each unit a leg closes moves that comparison** by what the close hands the fund less what it takes off the finish cost — on the bucket's excess over the other bucket, the distance from the leg's settlement price to the band edge, always a gain; on its hedged units, as described under Pairs above — less what the unit pays the executor (below), debited from the same capital before the health re-evaluation that ends the auction.
- **Reserve released.** A closed unit also takes its share of the reserve off, since the reserve follows open interest — but only once the close has brought live open interest down to the trailing reading the reserve is sized on; while live open interest sits above that reading, closing units releases nothing and the leg is sized without it.
- **One figure per segment.** Every term is linear in the size closed within each of a leg's two segments, its excess and its hedged units, and none depends on which winner takes the other side, so one figure holds per segment, the second sized on what the first leaves of the distance, rounded up by one millionth of a USDC so the pro-rata shares each slice rounds on its own cannot land the release a few wei short and leave a second call to close dust.

</details>

<details>
<summary>Edge case: a zero band</summary>

Only with a zero band, where the settlement price can be the band edge itself and a close takes at least as much off the capital as off the finish cost, does no size restore health; the auction then runs to its eligible size and the timeout or a recorded `deficit` resolves it. No pair's band is zero, since the maintenance rate it derives from never falls below 2%.

</details>

### The executor's reward

- **For every unit a leg closes**, the executor earns **2 bp of its notional, valued at the mark**, or **0.1% of the bad debt the close averts** where that is larger, which it is only once the mark lies more than a fifth of itself past the bucket's bankruptcy price.
- **A fallback close** at the mark averts nothing and earns the rate alone.
- **For the overlap the batch's closing netting retires**, the executor earns the same 2 bp at the mark that a `liquidate()` whose seizure nets earns ([Liquidations](liquidations.md)).
- **All of it is debited together from the insurance fund's free capital** (the earmark left against unclosed inventory never pays it) and accrued to its claimable balance (`claimFees()`) — so the reward is bounded by what the exposure actually required.
- **Each leg is sized with the reward counted**, so paying it never leaves the fund short of releasing the window.

<details>
<summary>Why the rate is an unload's rate</summary>

The units a leg closes take the bucket's exposure off the fund, as an unload's sale does, while the window halts unloads, so they are paid the rate an unload is paid, at the mark as at the bankruptcy price.

</details>
