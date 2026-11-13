# Insurance Fund

Each pair has its own insurance fund, held inside the pair contract and owned by **share-based LPs** — anyone can capitalize any market and earn its fee flow. There is no protocol-wide fund: a meme-coin market's blowup cannot touch the ETH market's backstop.

## Flows

**In:** maker + taker insurance [fees](fees.md) · seized liquidatee collateral · vault unwind profits · forfeited termination bonds · the listing seed (≥ $3,000)

**Out:** vault unwind losses (unload fills, opposing nettings and ADL settlement alike) · keeper rewards (liquidation, vault unloading, price refresh, ADL execution, and the part of a terminal-settlement tip the settled position's collateral does not cover) · UMA termination-proposer rewards

- **Seized collateral arrives earmarked.** While the vault still holds the inventory it came in with, it is not capital the fund can spend and not value a share can redeem — it leaves again when that inventory closes, and only what the close did not need stays with LPs. Everything below that reads "free capital" means the balance net of that earmark.
- **Losses beyond the fund become `deficit`** — realized bad debt — which [winds the pair down](termination.md) (the health check fixes the settlement price and opens the settlement window).
- **The fund is the last cushion** before winners get haircut: at finalize it becomes whatever remains after every trader entitlement is reserved, so bad debt, the deficit and the inventory's loss come out of it first, and only the shortfall beyond it reduces the winners' payout ratio.

## Target sizing

The fund's target is the **worse of a forecast and a measurement**, clamped to **2%–10% of open interest**. The fund pays what a liquidation loses *beyond* maintenance margin, and it estimates that two ways.

- **The forecast leg** is the pair's [stress move](margin.md#the-stress-move) — the same number maintenance margin is set to. At the current 1× setting the fund is sized to absorb one further stress move beyond what traders already hold, on every pair alike.
- **The realized leg** is that same loss measured directly: how far the mark ran past the estates' bankruptcy price before the vault could clear inherited inventory (see [Liquidations](liquidations.md)). A negative drift reading contributes nothing; it is evidence the forecast is sufficient.
- **The two compete by `max`** rather than summing.
- **Effect on leverage.** Realized drift still reaches traders, but only through the fund-health multiplier below, and only while the fund is actually short of the target it raised — capped at 3×. A fund that meets the raised target leaves leverage untouched.

<details>
<summary>Worked example: the forecast leg on a calm market, a 100%-vol market and a session pair</summary>

A calm market's 2% maintenance level asks for 2% coverage, a 100%-vol market's 4.5% asks for 4.5%, and a session pair's demonstrated 10% reopen asks for the full 10%.

</details>

<details>
<summary>Why the target follows the stress move, takes the larger leg, stops at the clamps, and may exceed maintenance margin</summary>

- **Proportional to the stress move.** For a fat-tailed return the shortfall scales with the quantile it is measured past, so the target is proportional to the level rather than reasoned about on a curve of its own.
- **`max`, not a sum.** Realized drift is a draw from the very distribution the stress move estimates, so adding them would size the fund for one tail twice.
- **The clamps** are the only place the target stops tracking its inputs — past the 10% ceiling a pair too risky to back is left to give on leverage instead, and the margin curve keeps climbing after the fund stops. Below that ceiling the target may exceed the maintenance margin it backstops.
- **A target above the maintenance margin it backstops.** Once liquidations have demonstrated losses past that level, a fund sized beyond it is the fund doing its job.

</details>

<details>
<summary>Why realized drift feeds the fund target rather than margin</summary>

Routing realized drift here rather than into margin is what bounds its effect, instead of one violent close adding itself to the maintenance level without limit.

</details>

### Steering toward target

- **The taker insurance fee** steers the fund toward target: sharply higher when underfunded, and floored at its base rate — an overfull fund gets no discount. Excess is returned to LPs through the wider above-target withdrawal budget instead.
- **Risk-*reducing* fills** pay that base rate rather than the multiplied one — deleveraging is never punished.
- **A depleted fund also tightens leverage**, through the insurance multiplier on IMR, but it never moves the target.

<details>
<summary>Why an overfull fund gets no discount, and why a shortfall never moves the target</summary>

- **No discount**, because new flow still consumes coverage and grows the very open interest the target is measured against.
- **The target never follows the fund:** that would let a shortfall deepen its own measure.

</details>

### The reserve

A tenth of the target is a **reserve** (`ADL_RESERVE_BP`):

- the vault's [unloads](liquidations.md) never spend below it;
- the [ADL](adl.md) gate measures expected loss against the capital above it;
- an opposing liquidation is netted only when its loss fits inside that capital and is left to the auction otherwise (see [Liquidations](liquidations.md));
- share pricing deducts an inventory loss only as far as the same capital covers it.

The reserve itself stays for the realizations no bound can refuse: the holding-window funding a deleveraged slice carries, and the keeper rewards the fund pays.

The open interest the reserve is sized on is the **lower of live open interest and its lowest hourly reading over the past 24 hours**.

<details>
<summary>Why the reserve is not sized on live open interest alone</summary>

Live open interest counts every position, including a long and a short held by one owner, so it can be raised within a single transaction; a reserve sized on it alone would rise with it, the capital above the reserve would fall to zero, and a loss the fund could carry would open an ADL window that charges it to winners instead.

</details>

<details>
<summary>How the trailing rule behaves, how it is sampled, and the edge cases that follow</summary>

Under the trailing rule open interest adds to the reserve only after it has been held for a full day — every hourly sample in the window has to carry it — while a fall takes effect at once.

The samples ride the same hourly ring as the [lagged maintenance margin](margin.md): each is the lowest open interest any margin refresh saw during its hour, so a spike inside an hour is never sampled.

Two edges follow from the ring. Until a pair has an hourly interval a full day old there is no trailing reading and live open interest sizes the reserve alone; and after a stretch with no open interest at all the reserve is zero until positions have been held for a day.

</details>

## LP mechanics

| Rule | Value |
|---|---|
| [Minimum deposit](#deposits) | $5 |
| [Share pricing](#share-pricing) | off the fund's **value at the mark**, not its balance; first deposit 1:1 |
| [Fresh-price requirement](#fresh-price-requirement) | a **redemption** on a live pair always needs a fresh mark; a **deposit** needs one only while the vault holds inventory |
| [Withdrawal](#withdrawal) | request → **13-day cooldown** → **execution window**: **2 days** on a pair that trades around the clock, **4 days** on a pair with trading hours |
| [Rate limit (below target)](#rate-limits) | min(0.5% of OI notional, 5% of the fund) per 6-hour period |
| [Rate limit (above target)](#rate-limits) | max(1% of OI, 10% of fund) against the same 6-hour budget |
| [Headroom while inventory is held](#headroom-while-inventory-is-held) | a paying call pays no more than the fund's **headroom** |
| [Reading the budget](#reading-the-budget) | `BazaarPairLens.getInsuranceWithdrawalBudget` |
| [Voting maturity](#governance) | shares must be 4 days old when a vote's window opens to count in it, the listing seed included |
| [Deposits](#deposits) | ≤ 100 per user across the current and previous three UTC days |

### Deposits

- **Minimum.** $5.
- **Maximum.** A single deposit is also capped at 2¹²⁸ − 1 in 18-decimal units, a sanity bound far above any real amount that refuses an absurd figure before the share arithmetic sees it.
- **Count.** ≤ 100 per user across the current and previous three UTC days (`MAX_DEPOSITS_PER_WINDOW`; four days, the length of the maturity period).
- **Refused while an [ADL](adl.md) window is pending**, and whenever, at the price the deposit carries, the inventory's loss would open one.

<details>
<summary>Why a deposit is refused when an ADL window is pending or would open</summary>

A batch closed at the estates' bankruptcy price moves part of the inventory's loss onto the winners, and that recovery belongs to the LPs the window keeps from redeeming. Capital added then would also shrink the batch, or keep the window shut and leave the LPs the loss the winners would have paid.

</details>

### Share pricing

- **Basis.** Both bases start from *free capital* — the fund less the collateral seized alongside inventory the vault still holds, which leaves again when that inventory unloads — and add the inventory's net result at the mark: its PnL from the estates' entry plus the seizure and the ledger's arrears that back it.
- **A deposit** counts both legs.
- **A redemption** counts the loss the fund will bear and never an unrealized gain.
- **Loss cap.** A loss is deducted only as far as the fund's capital above the reserve covers it, and no share is priced past that point: a redemption's own health check refuses there, and a deposit is refused.
- **With no inventory held** the basis is free capital (plus, for a deposit, any arrears the deposits ledger still owes the fund — an uncollected gain the newcomer pays for like any other) and a deposit reads no price.
- **First deposit** 1:1.
- **Quotes.** `BazaarPairLens.quoteInsuranceDeposit` / `quoteInsuranceWithdrawal` run the same arithmetic at a caller-supplied mark.

<details>
<summary>Why a deposit counts both legs, a redemption only the loss, and the loss only up to the reserve</summary>

- **A deposit counts both legs**, so a newcomer neither pays for a loss the incumbents underwrote nor buys a pending recovery at a discount.
- **A redemption never counts an unrealized gain:** it is not cash yet, and paying it would hand the leaver a price-timing option inside the execution window.
- **Loss cap.** Beyond the fund's capital above the reserve the ADL closes the inventory at the estates' bankruptcy price and the winners take the rest, so the deduction stops where the fund's own exposure stops. A deposit is refused past that point because its capital could shrink or cancel that auction.

</details>

<details>
<summary>Edge cases: a fund wiped out by bad debt, and fund value left with no live LPs</summary>

- **Share epoch.** A fund whose cash and arrears together are wiped below $1 by bad debt starts a new **share epoch** on the next deposit (arrears count because they are the fund's to collect: a settlement pays its loss out of its own seizure ahead of them, so the cash alone can sit under $1 while the stake has value): pre-drain balances lazily read as zero (that stake truly went to zero) and the rescuer is minted 1:1 against only their own contribution.
- **Fund value left with no live LPs** is priced into permanently locked shares at `address(0)`, so a new depositor can't buy the pre-existing buffer for the price of their deposit.

</details>

### Fresh-price requirement

- **A redemption** on a live pair always needs a fresh mark — it prices the shares, judges vault health and sizes the rate limit — so the frozen closing mark of a non-continuously traded pair is refused outright; once the pair is finalized it needs no price at all, its inventory having been retired.
- **A deposit** needs one only while the vault holds inventory, the single case where it has to value something the frozen mark cannot see. With the vault flat a deposit reads no price, so recapitalizing a drained fund is never blocked by market hours.

<details>
<summary>Why a frozen mark is refused, and why nothing is lost by waiting</summary>

- **The reason is the same on both sides:** off-chain venues print the reopen hours before the oracle can, so shares priced against a frozen mark hand the difference to whoever can already see it — a redemption escaping a loss, or a deposit buying the inventory's recovery cheap — and there is no conservative figure to charge a depositor instead, because a reopen can print anywhere.
- **Nothing is lost by waiting:** a shut venue also freezes the machinery that capital would fund (ADL refuses a stale mark, liquidation any price more than a minute old), and the loss realizes at the reopen, where a fresh mark prices the flow correctly.

</details>

### Withdrawal

request → **13-day cooldown** → **execution window**: **2 days** on a pair that trades around the clock, **4 days** on a pair with trading hours.

- **Usable hours.** Both execute calls need a fresh price, so on a pair with trading hours only the hours its venue trades are usable. Four days hold a holiday next to a weekend; a longer closure can leave a request without a trading hour, and the LP files again.
- **Two calls.** On a live pair the exit then takes at least two `executeInsuranceWithdrawal` calls inside the window. A finalized pair pays in one call.
  1. The first **locks**: it records what the requested shares are worth and moves nothing.
  2. The second **pays**: it burns the shares and pays the lower of the locked amount and what they are worth then, or, while the vault holds inventory, as much of it as the fund's headroom allows, leaving the rest requested for a later paying call (see [Headroom while inventory is held](#headroom-while-inventory-is-held)).
- **When the second call may pay.** From 5 minutes after the lock, never sooner than 5 minutes after the last stored price that **jumped** 2% or more from the pair's last price sample (taken at most once a minute), and never sooner than 30 minutes after the last stored price that ended a pause of an hour or more. The paying call can never itself be the store that carries such a jump or ends such a pause, since that store counts before the call is judged.
- **Unclaimed locks.** A lock draws nothing on the rate-limit budget: one never claimed lapses with the window, the shares stay in the pool, and a new request starts unlocked.
- **A lock whose claim could only open after the window closes** is refused.
- **Reading a lock.** `BazaarPairLens.getInsuranceWithdrawalLock` reports a lock, its amount and when its claim opens.

<details>
<summary>Why the window is 2 days on a 24/7 pair and 4 days on a pair with trading hours</summary>

- **4 days.** Four days hold a holiday next to a weekend (89.5 hours from a Thursday close to a Monday open on a US venue), with the reopen and the 30-minute reopen delay after it still inside a window that opened as the venue shut. The longer closures that can leave a request without a trading hour: Easter on a venue that shuts both Good Friday and Easter Monday (about 112 hours in London or Frankfurt), or a week-long holiday such as Lunar New Year.
- **2 days.** On a 24/7 pair two days outlast an [ADL](adl.md) window that resolves only at the end of its 24-hour timeout and 30-minute runway, throughout which redemptions are refused, and still leave most of a day for the lock, its claim and several turns of the 6-hour rate-limit period; every hour beyond that would be time to pick the moment to lock.

</details>

<details>
<summary>Why the exit is a lock and then a payment, and why the jump threshold is 2%</summary>

- **The lower of two moments.** The share price learns of a loss only when a keeper seizes the position behind it, so an exit priced at one moment the LP picks could land between a price move and that seizure and leave at the pre-loss value; the lower of two moments puts a loss booked in between on the leaver, and a gain in between stays with the LPs who remain.
- **The 2% jump.** 2% is the smallest maintenance rate, so a smaller move cannot carry a position from its maintenance line past bankruptcy.

</details>

<details>
<summary>Edge case: a fund recapitalized while a request is pending</summary>

Requests are stamped with the share epoch: a fund recap voids pending requests, so a post-recap re-depositor starts a fresh cooldown.

</details>

### Rate limits

- **Below target:** min(0.5% of OI notional, 5% of the fund) per 6-hour period.
- **Above target:** max(1% of OI, 10% of fund) against the same 6-hour budget.
- **One cumulative budget** shared by all LPs, so Sybil-splitting doesn't help.
- **Which open interest.** Above target, the OI is the lower of the period's opening reading and the open interest the pair has **held for the whole trailing day** — the same figure the reserve is sized on ([above](#the-reserve)) — read at the paying call. Below target the opening reading stands alone.
- **The coverage ratio that picks the regime** still reads live open interest: inflating it can only push the fund below target, into the stricter budget.

<details>
<summary>Why the budget has a fund term, and why it reads held open interest above target</summary>

- **The fund term** keeps each period's outflow a bounded fraction of what is left, since an OI-only budget would exceed a depleted fund outright.
- **Held open interest.** Open interest counts a long and a short held by one owner, so a budget on an instant's reading could be set by positions opened for the withdrawal that rolls the period and closed before the paying call that spends it; on the held figure, positions widen the budget only once carried for a day, and a fall in open interest narrows it at once.
- **Below target** the opening reading stands alone, since 5% of the fund already caps that budget whatever open interest reads.

</details>

### Reading the budget

`BazaarPairLens.getInsuranceWithdrawalBudget` returns what the current period still admits, the cap, when it refills, and the coverage and **live** target that decide the regime — computed with the same arithmetic execution runs, so the figure shown is the figure enforced.

- **A reading, not a reservation:** every LP draws on the one budget, and the check happens at the paying call, a cooldown after the request.
- **A lapsed period** is reported as the fresh one the next withdrawal would open, since the pair only rolls it when a withdrawal lands.

### Headroom while inventory is held

- **Cap.** While the vault holds inventory, a paying call pays no more than the fund's **headroom**: its free capital less the [ADL](adl.md) reserve and the cost of finishing the inventory, valued together at whichever edge of the unload band makes their sum larger.
- **The band** is min(5%, MMR) either side of the mark at the pair's current maintenance rate, never narrower than the band the ADL gate releases a window on.
- **A larger claim is paid up to the headroom** at its own amount per share: the shares that payment redeems are burned, and the rest stay requested under the same lock, scaled to them, for a later paying call inside the window, once the inventory has unloaded or the mark has moved back far enough to leave room.
- **A claim the headroom cannot pay any of** is refused (`InsuranceVaultLib__AdlBlocking`).
- **The rate limit** is charged with what is paid.
- **A lock** pays nothing and is never held back.

<details>
<summary>Why the cap is taken at the edge of the unload band</summary>

- **Where the sum peaks.** The reserve is open interest valued at the mark, so it rises with the price, while the loss rises toward the edge against the vault; their sum peaks at one edge of the band, and the cap holds back that peak.
- **What the health check cannot see.** The health check that precedes the payout judges the fund before it, so it cannot see what the payout does.
- **Paid into the reserve**, a payout would leave a fund short of it, which opens a window on the first adverse tick, sizes the auction to rebuild the reserve, and caps keeper rewards at the free capital left.
- **Paid down to the line where the gate opens**, it would leave the next refresh bounty, the inventory's funding or a small move of the mark to open one; held to the reserve at the mark alone, a rise short of the band's edge would still open one on an inventory of shorts, whose loss climbs with the reserve.

</details>

<details>
<summary>What the headroom guarantees, and what can still open an ADL window</summary>

- **Held to the headroom**, the fund opens no window on a move of the mark inside the band that leaves open interest and the fund target where they were, and sits at or inside the line the gate releases a window on.
- On long inventory about the size of the reserve the two cancel across the band, so the slack left at today's price is small and the next bounty or the inventory's funding can still open one.
- A move that also raises the target, through the volatility it adds or a reopen gap, raises the reserve with it and can still open one.

</details>

<details>
<summary>How the unload walk's bound differs</summary>

The [unload walk](liquidations.md) holds back less, the reserve and the inventory's loss at the mark, and can end with the fund exactly on the line where the gate opens: each of its fills shrinks the inventory the fund is exposed to, while a redemption leaves that exposure in place. Neither can carry a pair over the trigger or spend its reserve.

</details>

### When withdrawals are blocked

- **Withdrawals are blocked while the vault's liquidation exposure exceeds the ADL trigger** — LPs cannot front-run the exact events they are paid to backstop.
- **A paying call** must also leave the fund clear of that trigger across the unload band at the current fund target, with its reserve whole (see [Headroom while inventory is held](#headroom-while-inventory-is-held)).

Both the lock and the paying call run every gate below, and each judges vault health itself, against the price it fetches, rather than trusting a flag that only trading activity refreshes.

- **The price it fetches must be fresh:** on non-24/7 markets the frozen closing mark is refused — so LP exits happen during trading hours, and a market whose feed has died releases its LPs once the [stale-oracle termination](termination.md) settles it.
- **Withdrawals are also blocked** from 6 s before a scheduled cutoff, and while the [settlement window](termination.md) is open, until finalize. A scheduled termination does not lock withdrawals before that point: an exit ahead of it passes every gate here like any other.
- **Shares committed to an insurer-vote proposal** are likewise locked until its cutoff while it is pending or has scheduled the pair; once it resolves without scheduling (it failed at the latch deadline, or a cutoff at or before its own preempted it) they stay locked only while the pair carries a cutoff of its own, until the earlier of the two, and are released at once otherwise.
- **After the fix of a pair a vote scheduled**, the yes-voters stay locked for the 13-day cooldown unless UMA upheld the claim behind the vote, and at redemption the vote's levy credits part of their voted shares to the bug bounty address (see [Termination](termination.md)); every other holder redeems at once.
- **Once a pair *is* finalized**, the live gates open: LPs always have an exit after settlement, for whatever remains of the fund after bad debt, paid in one call that needs no price update — a pair whose feed has died is exactly the case it must work in.
- **One gate remains if finalize ran through the [escape hatch](termination.md) with positions still open:** exits wait until those are settled — anyone, the LP included, can settle them for gas — or 14 days beyond the hatch at most.

<details>
<summary>Why each gate is there</summary>

- **Headroom.** A paying call pays at most free capital less the reserve and the cost of finishing the inventory, valued together at whichever edge of the band makes their sum larger, a larger claim is paid that far with the rest left for later in its window, so an exit can never be what opens an ADL window on the traders who remain, nor spend the reserve that cushions them.
- **Each call judges vault health itself**, rather than trusting a flag that only trading activity refreshes: on a quiet book that flag would sit stale while inherited inventory drifts into a loss the fund is about to absorb.
- **Fresh price.** The frozen closing mark is refused because off-chain venues print the reopen hours before the oracle can and the fund is sized to absorb exactly that gap.
- **Settlement window.** Withdrawals are blocked until finalize because the fund's residual is only known at finalize; letting LPs exit first would push those losses onto traders.
- **Escape-hatch finalize.** Exits wait so a bankrupt straggler's shortfall is charged to the residual before any redemption is priced against it.

</details>

<details>
<summary>Why a scheduled termination does not lock withdrawals any earlier</summary>

- The book settles at the cutoff's own print, the price live trading would have marked it at too, so a cutoff exposes the fund to no loss that the same hours of trading would not.
- A lock from scheduling would also hold only the LPs who were not watching: the events a UMA termination is filed for are public before anyone proposes, and its cutoff has no upper bound.

</details>

### Governance

Insurance LPs also hold a governance right: proposing and voting on [insurer-vote termination](termination.md) of their pair — the people with capital at risk can shut the market down, and they answer for it: a shutdown UMA does not uphold costs the voters a lock and a levy.

- **Voting maturity.** Shares must be 4 days old when a vote's window opens to count in it, the listing seed included.
- **A bare proposal's window opens** at filing, a UMA claim's 14 days before its cutoff.
- **A bare proposal** also needs a mature stake to file.
- **Deposit lots** are tracked 18 days as snipe-vote defense.
