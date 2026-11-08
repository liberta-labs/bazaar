"""Shared helpers for the local end-to-end run: cast wrappers, Pyth updates, GraphQL and sync waits.

Paths come from the environment so the scripts run from any checkout:
  E2E_WORK  work directory shared with the shell scripts (default /tmp/bazaar-e2e)
  CAST      cast binary (default: cast on PATH, else ~/.foundry/bin/cast)
  RPC_URL   Anvil endpoint (default http://127.0.0.1:8545)
  GRAPH_URL Graph Node host (default http://127.0.0.1), queried on ports 8000 and 8030
"""
import json
import os
import shutil
import subprocess
import time
import urllib.request

WORK = os.environ.get("E2E_WORK", "/tmp/bazaar-e2e")
CAST = os.environ.get("CAST") or shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")
RPC = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
_GRAPH = os.environ.get("GRAPH_URL", "http://127.0.0.1")
GQL = f"{_GRAPH}:8000/subgraphs/name/bazaar"
STATUS = f"{_GRAPH}:8030/graphql"
ADDRESSES = os.path.join(WORK, "addresses.json")
STATE = os.path.join(WORK, "state.json")
ABI_DIR = os.path.join(WORK, "abi")

# Anvil's default accounts; test keys only.
MNEMONIC = "test test test test test test test test test test test junk"
FEED = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"  # Pyth ETH/USD
USDC_FEED = "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a"  # Pyth USDC/USD
ZERO = "0x0000000000000000000000000000000000000000"
E18 = 10**18


def run(args, check=True):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, args))[:300]}\n{p.stderr.strip()[:2000]}")
    return p.stdout.strip()


def rpc(method, *params):
    args = [p if isinstance(p, str) else json.dumps(p) for p in params]
    return json.loads(run([CAST, "rpc", method, *args, "--rpc-url", RPC]))


def call(to, sig, *args):
    """Calls a view and returns its decoded outputs as strings."""
    v = json.loads(run([CAST, "call", to, sig, *args, "--rpc-url", RPC, "--json"]))
    return v if isinstance(v, list) else [v]


def num(s):
    """Parses one decoded value: an integer (cast may append a ` [1e18]` hint) or a bool."""
    s = str(s).strip()
    if s in ("true", "false"):
        return s == "true"
    return int(s.split(" ")[0], 0)


def arr(s):
    s = str(s).strip().strip("[]")
    return [num(x) for x in s.split(",") if x.strip()]


def latest():
    b = rpc("eth_getBlockByNumber", "latest", False)
    return int(b["number"], 16), int(b["timestamp"], 16)


def key(i):
    return run([CAST, "wallet", "private-key", "--mnemonic", MNEMONIC, "--mnemonic-index", i])


def addr(k):
    return run([CAST, "wallet", "address", "--private-key", k])


_ERRORS = None


def error_map():
    """Maps 4-byte selectors to the custom errors declared in the exported ABIs."""
    global _ERRORS
    if _ERRORS is not None:
        return _ERRORS
    cache = os.path.join(WORK, "errors.json")
    if os.path.exists(cache):
        _ERRORS = json.load(open(cache))
        return _ERRORS

    def canon(i):
        if i["type"].startswith("tuple"):
            return "(" + ",".join(canon(c) for c in i["components"]) + ")" + i["type"][5:]
        return i["type"]

    sigs = {"Error(string)", "Panic(uint256)"}
    for f in os.listdir(ABI_DIR):
        for e in json.load(open(os.path.join(ABI_DIR, f))):
            if e.get("type") == "error":
                sigs.add(e["name"] + "(" + ",".join(canon(i) for i in e["inputs"]) + ")")
    _ERRORS = {run([CAST, "sig", s]): s for s in sorted(sigs)}
    json.dump(_ERRORS, open(cache, "w"))
    return _ERRORS


def decode_revert(txhash):
    """Names the custom error of a reverted transaction, from the innermost reverting call."""
    try:
        t = rpc("debug_traceTransaction", txhash, {"tracer": "callTracer"})
    except Exception as e:  # noqa: BLE001
        return f"(trace failed: {e})"

    def deepest(c):
        for sub in c.get("calls") or []:
            if sub.get("error"):
                d = deepest(sub)
                if d:
                    return d
        return c.get("output") if c.get("error") else None

    out = deepest(t) or t.get("output") or ""
    return f"{error_map().get(out[:10], 'unknown selector')} data={out[:400]}"


class Reverted(Exception):
    pass


def send(k, to, sig, *args, gas=20_000_000, label=""):
    """Sends a transaction with a fixed gas limit, so it is mined even when it reverts and the
    revert can be decoded from its trace. Gas estimation would run before the timestamp that
    evm_setNextBlockTimestamp pins, against which a fresh price update is judged."""
    cmd = [CAST, "send", to, sig, *args, "--private-key", k, "--rpc-url", RPC, "--gas-limit", gas, "--json"]
    p = subprocess.run([str(a) for a in cmd], capture_output=True, text=True)
    if p.returncode != 0:
        raise Reverted(f"{label or sig}: cast send failed: {p.stderr.strip()[:1500]}")
    r = json.loads(p.stdout)
    if r.get("status") not in ("0x1", 1, "1"):
        raise Reverted(f"{label or sig}: reverted in {r['transactionHash']}: {decode_revert(r['transactionHash'])}")
    return r


class Prices:
    """Builds MockPyth update data for the base feed and USDC/USD."""

    def __init__(self, pyth):
        self.pyth = pyth

    def update(self, price_usd, ts):
        sig = "createPriceFeedUpdateData(bytes32,int64,uint64,int32,int64,uint64,uint64,uint64)(bytes)"
        p = int(round(price_usd * 10**8))
        base = call(self.pyth, sig, FEED, p, 0, "-8", p, 0, ts, ts - 1)[0]
        usdc = call(self.pyth, sig, USDC_FEED, 10**8, 0, "-8", 10**8, 0, ts, ts - 1)[0]
        return f"[{base},{usdc}]"


def next_ts(step=4):
    """Pins the next block's timestamp. The step is above Pyth's 3-second window, inside which a
    newer update is ignored in favour of the cached one."""
    _, ts = latest()
    t = ts + step
    rpc("evm_setNextBlockTimestamp", hex(t))
    return t


def warp(seconds):
    rpc("evm_increaseTime", hex(seconds))
    rpc("evm_mine")


def gql(query, url=GQL):
    req = urllib.request.Request(url, data=json.dumps({"query": query}).encode(),
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read())
    if "errors" in out:
        raise RuntimeError(json.dumps(out["errors"])[:2000])
    return out["data"]


def wait_synced(timeout=180):
    """Waits until the subgraph has indexed the chain head; raises on a fatal indexing error."""
    head, _ = latest()
    q = ('{ indexingStatusForCurrentVersion(subgraphName: "bazaar") { health fatalError { message block { number } } '
         'nonFatalErrors { message } chains { latestBlock { number } } } }')
    t0, st = time.time(), None
    while time.time() - t0 < timeout:
        st = gql(q, STATUS)["indexingStatusForCurrentVersion"]
        if st["fatalError"]:
            raise RuntimeError(f"subgraph failed: {st['fatalError']}")
        if int(st["chains"][0]["latestBlock"]["number"]) >= head:
            return st
        time.sleep(1)
    raise RuntimeError(f"subgraph not synced to block {head} after {timeout}s: {st}")
