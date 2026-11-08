"""Drives a trading scenario on the local Anvil deployment written by deploy-contracts.sh.

Lists an ETH/USD pair, then exercises every pair path the subgraph indexes short of ADL and
termination: resting and market orders, a cancel and an amend, a stop-loss and a stop-limit with
keeper bounties, price refreshes, a liquidation and the vault's unload into the book, a collateral
withdrawal, an expired order's sweep, an insurance deposit, request, lock and claim, and a fee
claim. Each step runs once; progress is kept in $E2E_WORK/state.json, so after a failure the step
can be fixed and the script rerun to continue from it.

Accounts are Anvil's defaults: 0 lists the pair and is the keeper, 1 and 2 make the book, 3 and 4
take, 5 provides insurance, 6 is the position that gets liquidated.
"""
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import (ADDRESSES, E18, FEED, STATE, ZERO, Prices, Reverted, addr, call, key, latest,  # noqa: E402
                 next_ts, num, rpc, run, send, warp, CAST)

A = json.load(open(ADDRESSES))
S = json.load(open(STATE)) if os.path.exists(STATE) else {"done": [], "orders": {}, "price": 2000.0}
K = [key(i) for i in range(7)]
W = [addr(k) for k in K]
PX = Prices(A["pyth"])
CREATE = ("createOrder((uint8,bool,bool,uint8,uint256,uint256,uint256,uint256,uint64,address),"
          "(uint64,uint64,uint64,uint64,uint32),bytes[],uint256,uint256,uint256,bytes,bytes)")
EXECUTE = "executeTriggeredOrders((uint64,(uint64,uint64,uint64,uint64,uint32))[],bytes[])"
BUCKET = "positionBuckets(address)(bool,uint128,uint128,uint128,int256,uint64,uint64)"
MARKET, LIMIT, STOP_LIMIT, STOP_LOSS = 0, 1, 2, 4


def pu(price=None):
    """A price update stamped with the next block's timestamp, at the scenario's current price."""
    return PX.update(S["price"] if price is None else price, next_ts())


def expiry(blocks=200_000):
    n, _ = latest()
    return n + blocks


def hints(is_long, limit):
    """Placement hint for a resting order: the order it should rest directly behind."""
    pred = num(call(A["lens"], "findPredecessor(address,bool,uint256,uint64,uint256)(uint64,bool)", S["pair"],
                    "true" if is_long else "false", limit, 0, 64)[0])
    return f"({pred},0,0,0,0)"


def create(i, otype, is_long, size, label, trigger=0, limit=0, slip=0, exp=None):
    """Creates an order for account i and records its id under label. Trigger orders carry their
    keeper bounty in the high 128 bits of `trigger`."""
    h = hints(is_long, limit) if otype == LIMIT else "(0,0,0,0,0)"
    spec = f"({otype},{'true' if is_long else 'false'},false,0,{size},{trigger},{limit},{slip},{exp or expiry()},{ZERO})"
    send(K[i], S["pair"], CREATE, spec, h, pu(), 0, 0, 0, "0x", "0x", label=label)
    oid = num(call(A["lens"], "nextOrderId(address)(uint256)", S["pair"])[0]) - 1
    S["orders"][label] = oid
    return oid


def mint_usdc():
    for w in W:
        send(K[0], A["usdc"], "mint(address,uint256)", w, 2_000_000 * 10**6)


def seed_price():
    # The factory lists a feed only once Pyth holds a price for it.
    send(K[0], A["pyth"], "updatePriceFeeds(bytes[])", pu())


def list_pair():
    send(K[0], A["usdc"], "approve(address,uint256)", A["factory"], 5000 * 10**6)
    r = send(K[0], A["factory"], "proposePairDeployment(bytes32,bool,uint256,string)", FEED, "true", 5000 * E18, "ETH/USD")
    topic = run([CAST, "keccak", "PairDeploymentProposed(bytes32,bytes32,address,bytes32,string,uint256)"])
    log = next(lg for lg in r["logs"] if lg["topics"][0] == topic)
    S["pairId"], S["assertionId"] = log["topics"][1], log["topics"][2]
    warp(48 * 3600 + 1)  # the listing's UMA liveness
    send(K[0], A["factory"], "settleDeploymentProposal(bytes32)", S["assertionId"])
    S["pair"] = call(A["factory"], "getPairAddress(bytes32)(address)", S["pairId"])[0]
    assert S["pair"] != ZERO, "pair not deployed"
    print("   pair", S["pair"])


def approvals():
    for k in K:
        send(k, A["usdc"], "approve(address,uint256)", S["pair"], str(2**256 - 1))


def deposits():
    for i, amount in [(1, 40000), (2, 40000), (3, 10000), (4, 10000)]:
        send(K[i], S["pair"], "depositCollateral(uint256,uint256,uint256,uint256,bytes,bytes)", amount * E18, 0, 0, 0, "0x", "0x")


def insurance_deposit():
    send(K[5], S["pair"], "depositToInsurance(uint256,bytes[],uint256,uint256,uint256,bytes,bytes)",
         20000 * E18, pu(), 0, 0, 0, "0x", "0x")


def makers():
    for price, size in [(1990, 1), (1980, 2), (1970, 1)]:
        create(1, LIMIT, True, int(size * E18), f"bid{price}", limit=price * E18)
    for price, size in [(2010, 1.5), (2020, 1), (2030, 2)]:
        create(2, LIMIT, False, int(size * E18), f"ask{price}", limit=price * E18)


def taker_buy():
    create(3, MARKET, True, 2 * E18, "market-buy", slip=300)


def taker_sell():
    create(4, MARKET, False, int(1.5 * E18), "market-sell", slip=300)


def cancel():
    send(K[1], S["pair"], "cancelOrders(uint256[],uint256,uint256,uint256,bytes,bytes)",
         f"[{S['orders']['bid1970']}]", 0, 0, 0, "0x", "0x")


def amend():
    # Each amendment is a triple: the id word (order id plus placement hints), new price, new size.
    word = num(call(A["lens"], "amendIdWord(uint64,uint64,uint64)(uint256)", S["orders"]["ask2030"], 0, 0)[0])
    send(K[2], S["pair"], "amendOrders(uint256[],bytes[],uint256,uint256,uint256,bytes,bytes)",
         f"[{word},{2040 * E18},{int(2.5 * E18)}]", pu(), 0, 0, 0, "0x", "0x")


def stop_loss():
    create(3, STOP_LOSS, False, 2 * E18, "stop-loss", trigger=(E18 << 128) | (1950 * E18), slip=500)


def stop_limit():
    create(4, STOP_LIMIT, True, E18 // 2, "stop-limit", trigger=((E18 // 2) << 128) | (2050 * E18), limit=2060 * E18)


def refreshes():
    for price in (2005, 2010):
        warp(600)
        S["price"] = price
        send(K[0], S["pair"], "refreshPrice(bytes[])", pu())


def fire_stop_limit():
    S["price"] = 2055
    send(K[0], S["pair"], EXECUTE, f"[({S['orders']['stop-limit']},(0,0,0,0,0))]", pu())


def victim_opens():
    imr, mmr = (num(x) for x in call(S["pair"], "marginRequirements()(uint256,uint256,uint256,uint256)")[:2])
    collateral = 1000
    size = round(min(0.85 * collateral * 10000 / imr / S["price"], 5.0), 3)
    S["victim"] = {"imr": imr, "mmr": mmr}
    print(f"   imrBp={imr} mmrBp={mmr}: opening {size} at about {S['price']}")
    create(2, LIMIT, False, int((size + 1) * E18), "ask2045", limit=2045 * E18)
    send(K[6], S["pair"], "depositCollateral(uint256,uint256,uint256,uint256,bytes,bytes)", collateral * E18, 0, 0, 0, "0x", "0x")
    create(6, MARKET, True, int(size * E18), "victim-buy", slip=500)


def liquidate():
    b = call(S["pair"], BUCKET, W[6])
    size, entry_value, collateral = num(b[1]) / E18, num(b[2]) / E18, num(b[3]) / E18
    entry = entry_value / size
    mmr = S["victim"]["mmr"] / 10000
    # The price at which equity meets maintenance, less 2% of the entry so the position is under.
    price = round((size * entry - collateral) / (size * (1 - mmr)) - 0.02 * entry, 2)
    print(f"   size {size} entry {entry:.2f} collateral {collateral:.2f}: liquidating at {price}")
    create(1, LIMIT, True, int((size + 2) * E18), "bid-unload", limit=int(round(price - 5)) * E18)
    S["price"] = price
    send(K[0], S["pair"], "liquidate(address[],bytes[])", f"[{W[6]}]", pu())


def fire_stop_loss():
    send(K[0], S["pair"], EXECUTE, f"[({S['orders']['stop-loss']},(0,0,0,0,0))]", pu())


def unload_vault():
    inv = call(A["lens"], "getPendingLiquidationExposure(address)((uint256,uint256,uint256,uint256,int192,uint64),"
               "(uint256,uint256,uint256,uint256,int192,uint64))", S["pair"])
    if any(num(x.strip("()").split(",")[0]) for x in inv):
        create(1, LIMIT, True, 3 * E18, "bid-unload2", limit=int(round(S["price"] - 2)) * E18)
        send(K[0], S["pair"], "unloadVault(uint256,bytes[])", 16, pu())
    else:
        print("   the liquidation's inline unload already emptied both buckets")


def withdraw_collateral():
    send(K[3], S["pair"], "withdrawCollateral(uint256,bytes[],uint256,uint256,uint256,bytes)", 1000 * E18, pu(), 0, 0, 0, "0x")


def expire_and_sweep():
    min_life = num(call(A["lens"], "getOrderLifetimeConstants()(uint64,uint64)")[0])
    # The lifetime counts from the block the order lands in, one past the latest.
    oid = create(2, LIMIT, False, E18 // 2, "ask-expiring", limit=int(round(S["price"] * 1.05)) * E18, exp=expiry(min_life + 5))
    rpc("anvil_mine", hex(min_life + 10))
    send(K[0], S["pair"], "sweepExpired(uint256[])", f"[{oid}]")


def insurance_withdrawal():
    # Claims are capped per period by a budget proportional to open interest, which is thin here,
    # so the request is a quarter of what the budget would pay.
    remaining = num(call(A["lens"], "getInsuranceWithdrawalBudget(address,uint256)(uint256,uint256,uint256,uint256,uint256)",
                         S["pair"], int(S["price"] * E18))[0])
    share_price = num(call(A["lens"], "getInsuranceSharePrice(address)(uint256)", S["pair"])[0])
    shares = remaining * E18 // share_price // 4
    print(f"   budget {remaining / E18:.2f}, share price {share_price / E18:.4f}: requesting {shares / E18:.4f} shares")
    send(K[5], S["pair"], "requestInsuranceWithdrawal(uint256,uint256,uint256,uint256,bytes,bytes)", shares, 0, 0, 0, "0x", "0x")
    cooldown = num(call(A["lens"], "getInsuranceWithdrawalConstants()(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)")[0])
    warp(cooldown + 60)
    execute = "executeInsuranceWithdrawal(bytes[],uint256,uint256,uint256,bytes,bytes)"
    send(K[5], S["pair"], execute, pu(), 0, 0, 0, "0x", "0x")  # the first call locks the amount
    lock = call(A["lens"], "getInsuranceWithdrawalLock(address,address)(bool,uint256,uint256,uint256,uint256)", S["pair"], W[5])
    if num(lock[0]):
        _, now = latest()
        if num(lock[3]) > now:
            warp(num(lock[3]) - now + 5)
        send(K[5], S["pair"], execute, pu(), 0, 0, 0, "0x", "0x")  # the second pays it


def claim_fees():
    owed = num(call(A["lens"], "claimableFees(address,address)(uint256,uint256)", S["pair"], W[0])[0])
    print(f"   keeper fees owed {owed / E18:.6f}")
    if owed:
        send(K[0], S["pair"], "claimFees()")


def close_short():
    create(2, LIMIT, False, 2 * E18, "ask-final", limit=int(round(S["price"] * 1.002)) * E18)
    create(4, MARKET, True, E18, "market-close", slip=500)


STEPS = [mint_usdc, seed_price, list_pair, approvals, deposits, insurance_deposit, makers, taker_buy, taker_sell,
         cancel, amend, stop_loss, stop_limit, refreshes, fire_stop_limit, victim_opens, liquidate, fire_stop_loss,
         unload_vault, withdraw_collateral, expire_and_sweep, insurance_withdrawal, claim_fees, close_short]

for fn in STEPS:
    if fn.__name__ in S["done"]:
        continue
    print(f"-- {fn.__name__}", flush=True)
    try:
        fn()
    except Reverted as e:
        sys.exit(f"step {fn.__name__} failed: {e}")
    S["done"].append(fn.__name__)
    json.dump(S, open(STATE, "w"), indent=1)

print("scenario complete at block", latest()[0])
