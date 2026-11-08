"""Compares the local subgraph against direct chain reads once scenario.py has run.

Waits for the subgraph to reach the chain head, then checks pair figures, every order, both sides
of the book level by level, every position, insurance stakes and requests, claimable fees, and one
record per event log (counts and amounts). Exits 1 on any mismatch.
"""
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import ADDRESSES, CAST, E18, RPC, STATE, STATUS, ZERO, addr, arr, call, gql, key, num, run, wait_synced  # noqa: E402

A = json.load(open(ADDRESSES))
S = json.load(open(STATE))
PAIR = S["pair"].lower()
W = [addr(key(i)).lower() for i in range(7)]
ORDERS = ("orders(uint256)(address,uint64,uint8,bool,bool,uint8,address,uint64,bool,uint24,uint128,uint128,uint128,"
          "uint128,uint48,uint64,uint32,uint16,uint48,uint48)")
BUCKET = "positionBuckets(address)(bool,uint128,uint128,uint128,int256,uint64,uint64)"
VAULT = ("pairVault()(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint128,"
         "(uint256,uint256,uint256,uint256,int192,uint64),(uint256,uint256,uint256,uint256,int192,uint64))")
problems, checks = [], 0


def eq(what, subgraph, chain):
    global checks
    checks += 1
    if subgraph != chain:
        problems.append(f"{what}: subgraph={subgraph} chain={chain}")


def logs(sig):
    return json.loads(run([CAST, "logs", "--from-block", "0", "--to-block", "latest", "--address", S["pair"], sig,
                           "--rpc-url", RPC, "--json"]))


def words(lg):
    h = lg["data"][2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def topic_addr(lg, i):
    return "0x" + lg["topics"][i][-40:]


st = wait_synced()
status = gql('{ indexingStatusForCurrentVersion(subgraphName: "bazaar") { health nonFatalErrors { message } } }', STATUS)
eq("health", status["indexingStatusForCurrentVersion"]["health"], "healthy")
eq("non-fatal errors", status["indexingStatusForCurrentVersion"]["nonFatalErrors"], [])
print(f"subgraph synced to block {st['chains'][0]['latestBlock']['number']}")

d = gql(f'''{{
  protocols {{ accountCount }}
  accounts(first: 1000) {{ id }}
  pair(id: "{PAIR}") {{ lastPrice fundingIndex openInterestLong openInterestShort openPositionCount restingBidCount
    restingAskCount totalInsuranceShares tradeCount volumeSize vaultFillCount }}
  orders(first: 1000) {{ orderId orderType size filledSize remaining status inBook limitPrice prioritySeq expiryBlock
    bountyEscrowed bountyHeld owner {{ id }} }}
  bookLevels(first: 1000) {{ isBid price size orderCount }}
  positions(first: 1000) {{ account {{ id }} isLong size entryValue collateral entryFundingIndex isOpen
    takeProfitOrder {{ orderId }} stopLossOrder {{ orderId }} }}
  insuranceProviders(first: 1000) {{ account {{ id }} shares requestedShares }}
  feeBalances(first: 1000) {{ recipient {{ id }} claimable }}
  trades(first: 1000) {{ size isVaultFill }}
  candles(first: 1000, where: {{interval: 60}}) {{ volumeSize tradeCount }}
  liquidations(first: 100) {{ id }}
  priceUpdates(first: 1000) {{ id }}
}}''')
p = d["pair"]

# ---- pair figures
eq("pair.lastPrice", int(p["lastPrice"]), num(call(S["pair"], "lastPairPrice()(uint256,uint256,uint256,uint256,uint256)")[0]))
eq("pair.fundingIndex", int(p["fundingIndex"]), num(call(S["pair"], "currentFundingIndex()(int256)")[0]))
vault = call(S["pair"], VAULT)
eq("pair.openInterestLong", int(p["openInterestLong"]), num(vault[0]))
eq("pair.openInterestShort", int(p["openInterestShort"]), num(vault[1]))
book = [num(x) for x in call(S["pair"], "book()(uint64,uint64,uint64,uint64)")]
eq("pair.restingBidCount", p["restingBidCount"], book[2])
eq("pair.restingAskCount", p["restingAskCount"], book[3])
eq("pair.totalInsuranceShares", int(p["totalInsuranceShares"]), num(call(S["pair"], "totalInsuranceShares()(uint256)")[0]))

# ---- one record per log
trade_logs = logs("Trade(bytes32,address,address,uint256,uint256,bool,uint256,uint256,uint256,uint256,uint256,uint256)")
eq("trades (records vs logs)", len(d["trades"]), len(trade_logs))
eq("pair.tradeCount", int(p["tradeCount"]), len(trade_logs))
eq("price updates (records vs logs)", len(d["priceUpdates"]), len(logs("NewPriceUpdateAdded(bytes32,uint256,uint256,int32,int256)")))
eq("liquidations (records vs logs)", len(d["liquidations"]),
   len(logs("PositionLiquidated(bytes32,address,address,uint256,bool,uint256,uint256,uint256,uint256)")))
eq("pair.volumeSize == sum of trade sizes", int(p["volumeSize"]), sum(int(t["size"]) for t in d["trades"]))
eq("pair.vaultFillCount == vault trades", int(p["vaultFillCount"]), sum(1 for t in d["trades"] if t["isVaultFill"]))
eq("1-minute candle volume == pair volume", sum(int(c["volumeSize"]) for c in d["candles"]), int(p["volumeSize"]))
eq("1-minute candle trade count", sum(c["tradeCount"] for c in d["candles"]), len(trade_logs))
eq("protocol.accountCount == accounts", d["protocols"][0]["accountCount"], len(d["accounts"]))

# ---- orders: every order on chain is indexed and agrees
next_id = num(call(A["lens"], "nextOrderId(address)(uint256)", S["pair"])[0])
sub_orders = {int(o["orderId"]): o for o in d["orders"]}
chain_ids = []
for oid in range(1, next_id):  # ids have gaps: queue positions draw from the same counter
    o = call(S["pair"], ORDERS, oid)
    if o[0].lower() == ZERO:
        continue
    chain_ids.append(oid)
    so = sub_orders.get(oid)
    if so is None:
        problems.append(f"order {oid}: on chain, missing from the subgraph")
        continue
    size, filled, canceled_block, in_book = num(o[12]), num(o[13]), num(o[1]), num(o[8])
    eq(f"order {oid} owner", so["owner"]["id"], o[0].lower())
    eq(f"order {oid} size", int(so["size"]), size)
    eq(f"order {oid} filledSize", int(so["filledSize"]), filled)
    eq(f"order {oid} inBook", so["inBook"], in_book)
    eq(f"order {oid} limitPrice", int(so["limitPrice"]), num(o[11]))
    eq(f"order {oid} prioritySeq", int(so["prioritySeq"]), num(o[14]))
    eq(f"order {oid} expiryBlock", int(so["expiryBlock"]), num(o[7]))
    if canceled_block:
        eq(f"order {oid} status", so["status"], "Canceled")
    elif filled >= size and so["orderType"] not in ("TakeProfit", "StopLoss"):  # TP/SL sizes cap at the position
        eq(f"order {oid} status", so["status"], "Filled")
    elif in_book:
        eq(f"order {oid} status", so["status"], "Resting")
        eq(f"order {oid} remaining", int(so["remaining"]), size - filled)
eq("order ids", sorted(sub_orders), chain_ids)

# ---- book: walk each side on chain and total the remaining size per price
for side, is_long in (("bid", True), ("ask", False)):
    ids, prices, _ = call(A["lens"], "getBookDepth(address,bool,uint64,uint256)(uint256[],uint256[],uint64)",
                          S["pair"], "true" if is_long else "false", 0, 200)
    levels = {}
    for oid, price in zip(arr(ids), arr(prices)):
        o = call(S["pair"], ORDERS, oid)
        size, count = levels.get(price, (0, 0))
        levels[price] = (size + num(o[12]) - num(o[13]), count + 1)
    sub = {int(b["price"]): (int(b["size"]), b["orderCount"]) for b in d["bookLevels"]
           if b["isBid"] == is_long and (int(b["size"]) > 0 or b["orderCount"] > 0)}
    eq(f"{side} book levels", sub, levels)
    print(f"{side}s: " + (", ".join(f"{pr / E18:g} x {sz / E18:g}" for pr, (sz, _c) in sorted(levels.items())) or "none"))

# ---- positions
sub_pos = {x["account"]["id"]: x for x in d["positions"]}
open_count = 0
for w in W:
    b = call(S["pair"], BUCKET, w)
    size = num(b[1])
    open_count += size > 0
    sp = sub_pos.get(w)
    if sp is None:
        if size or num(b[3]):
            problems.append(f"position {w}: on chain, missing from the subgraph")
        continue
    eq(f"position {w[:8]} size", int(sp["size"]), size)
    if size:
        eq(f"position {w[:8]} isLong", sp["isLong"], num(b[0]))
    eq(f"position {w[:8]} entryValue", int(sp["entryValue"]), num(b[2]))
    eq(f"position {w[:8]} collateral", int(sp["collateral"]), num(b[3]))
    eq(f"position {w[:8]} entryFundingIndex", int(sp["entryFundingIndex"]), num(b[4]))
    eq(f"position {w[:8]} isOpen", sp["isOpen"], size > 0)
    eq(f"position {w[:8]} takeProfit", int(sp["takeProfitOrder"]["orderId"]) if sp["takeProfitOrder"] else 0, num(b[5]))
    eq(f"position {w[:8]} stopLoss", int(sp["stopLossOrder"]["orderId"]) if sp["stopLossOrder"] else 0, num(b[6]))
eq("pair.openPositionCount", p["openPositionCount"], open_count)

# ---- insurance stakes and fee balances
sub_ins = {x["account"]["id"]: x for x in d["insuranceProviders"]}
for w in set(W) | set(sub_ins):
    shares = num(call(S["pair"], "insuranceShares(address)(uint256)", w)[0])
    requested = num(call(S["pair"], "insuranceWithdrawalRequestShareAmount(address)(uint256)", w)[0])
    sp = sub_ins.get(w)
    if sp is None:
        if shares:
            problems.append(f"insurance {w}: {shares} shares on chain, missing from the subgraph")
        continue
    eq(f"insurance {w[:8]} shares", int(sp["shares"]), shares)
    eq(f"insurance {w[:8]} requestedShares", int(sp["requestedShares"]), requested)
sub_fee = {x["recipient"]["id"]: x for x in d["feeBalances"]}
for w in set(W) | set(sub_fee):
    owed = num(call(A["lens"], "claimableFees(address,address)(uint256,uint256)", S["pair"], w)[0])
    sf = sub_fee.get(w)
    if sf is None:
        if owed:
            problems.append(f"fees {w}: {owed} claimable on chain, missing from the subgraph")
        continue
    eq(f"fees {w[:8]} claimable", int(sf["claimable"]), owed)

# ---- event records: amounts per kind, and keeper bounties
e = gql(f'''{{
  collateralTransfers(first: 1000) {{ isDeposit amount }}
  feeAccruals(first: 1000) {{ amount }}
  feeClaims(first: 1000) {{ amount }}
  insuranceEvents(first: 1000) {{ id }}
  triggerBountyReleases(first: 1000) {{ amount }}
  orderEvents(first: 1000) {{ id }}
  positionChanges(first: 1000) {{ id }}
  positionSnapshots(first: 1000) {{ id }}
  listingProposals {{ status pair {{ id }} }}
  account(id: "{W[0]}") {{ triggerBountiesEarned feesClaimed }}
}}''')
amounts = lambda sig: sorted(words(lg)[0] for lg in logs(sig))  # noqa: E731
transfers = e["collateralTransfers"]
eq("collateral deposits", sorted(int(x["amount"]) for x in transfers if x["isDeposit"]), amounts("CollateralDeposited(bytes32,address,uint256)"))
eq("collateral withdrawals", sorted(int(x["amount"]) for x in transfers if not x["isDeposit"]), amounts("CollateralWithdrawn(bytes32,address,uint256)"))
eq("fee accruals", sorted(int(x["amount"]) for x in e["feeAccruals"]), amounts("FeeAccrued(bytes32,address,uint256)"))
eq("fee claims", sorted(int(x["amount"]) for x in e["feeClaims"]), amounts("FeesClaimed(bytes32,address,uint256)"))
releases = logs("TriggerBountyReleased(bytes32,uint256,address,uint256)")
eq("bounty releases", sorted(int(x["amount"]) for x in e["triggerBountyReleases"]), sorted(words(lg)[0] for lg in releases))
order_logs = sum(len(logs(s)) for s in (
    "OrderUpdated(bytes32,uint256,address,(uint8,uint8,bool,bool,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint64,uint64,uint8,address,uint8))",
    "OrderAmended(bytes32,uint256,address,uint256,uint256,uint256)",
    "OrderAmendSkipped(bytes32,uint256,address,uint8)"))
eq("order events (records vs logs)", len(e["orderEvents"]), order_logs)
eq("position changes (records vs PositionModified)", len(e["positionChanges"]),
   len(logs("PositionModified(bytes32,address,bool,int256,uint256,uint256,uint256,uint256,uint256,int256)")))
eq("position snapshots (records vs PositionBucketUpdated)", len(e["positionSnapshots"]),
   len(logs("PositionBucketUpdated(bytes32,address,bool,uint256,uint256,uint256,int256,int256,uint256,uint256)")))
insurance_logs = sum(len(logs(s)) for s in (
    "InsuranceDeposited(bytes32,address,uint256,uint256)", "InsuranceWithdrawalRequested(bytes32,address,uint256)",
    "InsuranceWithdrawalLocked(bytes32,address,uint256,uint256,uint256)", "InsuranceWithdrawalExecuted(bytes32,address,uint256,uint256)"))
# The listing's seed deposit is recorded from the factory's PairDeployed, not from a pair log.
eq("insurance events (records vs pair logs + the seed deposit)", len(e["insuranceEvents"]), insurance_logs + 1)
eq("listing proposal", [(x["status"], (x["pair"] or {}).get("id")) for x in e["listingProposals"]], [("Deployed", PAIR)])
for lg in logs("TriggerBountyEscrowed(bytes32,uint256,uint256)"):
    oid = int(lg["topics"][2], 16)
    eq(f"order {oid} bountyEscrowed", int(sub_orders[oid]["bountyEscrowed"]), words(lg)[0])
    eq(f"order {oid} bountyHeld", int(sub_orders[oid]["bountyHeld"]),
       num(call(A["lens"], "triggerBounty(address,uint256)(uint256)", S["pair"], oid)[0]))
eq("keeper triggerBountiesEarned", int(e["account"]["triggerBountiesEarned"]),
   sum(words(lg)[0] for lg in releases if topic_addr(lg, 3) == W[0]))
eq("keeper feesClaimed", int(e["account"]["feesClaimed"]),
   sum(words(lg)[0] for lg in logs("FeesClaimed(bytes32,address,uint256)") if topic_addr(lg, 2) == W[0]))

print("orders: " + ", ".join(f"{o['orderId']} {o['orderType']} {o['status']}" for o in sorted(d["orders"], key=lambda o: int(o["orderId"]))))
print(f"\n{checks} checks, {len(problems)} mismatches")
for x in problems:
    print("  MISMATCH", x)
sys.exit(1 if problems else 0)
