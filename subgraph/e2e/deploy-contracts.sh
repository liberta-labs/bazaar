#!/usr/bin/env bash
# Deploys Bazaar to a local Anvil with its mocks, etches MockArbSys at the ArbSys precompile, and
# writes the addresses to $E2E_WORK/addresses.json for deploy-subgraph.sh and the Python scripts.
# Clears the scenario's progress, since a fresh deployment starts a fresh run.
#
#   REPO      Foundry project to deploy from, built (default: this checkout)
#   RPC_URL   Anvil endpoint (default http://127.0.0.1:8545)
#   E2E_WORK  work directory (default /tmp/bazaar-e2e)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
E2E_WORK="${E2E_WORK:-/tmp/bazaar-e2e}"
PATH="$PATH:$HOME/.foundry/bin"
mkdir -p "$E2E_WORK"

KEY="$(cast wallet private-key --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 0)"
LOG="$E2E_WORK/deploy.log"
cd "$REPO"
# --offline keeps forge from looking signatures up over the network, which can hang without one.
forge script script/DeployBazaar.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$KEY" \
    --code-size-limit 100000 --offline > "$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }

get() { grep "$1" "$LOG" | head -1 | awk '{print $NF}'; }
cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 \
    "$(jq -r '.deployedBytecode.object' out/MockArbSys.sol/MockArbSys.json)" --rpc-url "$RPC_URL" > /dev/null

cat > "$E2E_WORK/addresses.json" <<EOF
{"factory":"$(get "BazaarFactory:")","oracle":"$(get "BazaarOracle:")","lens":"$(get "BazaarPairLens:")",
 "terminator":"$(get "BazaarPairTerminator:")","usdc":"$(get "  USDC:")","pythLazer":"$(get "  Pyth Pro verifier:")",
 "oov3":"$(get "OptimisticOracleV3:")"}
EOF
rm -f "$E2E_WORK/state.json"
cat "$E2E_WORK/addresses.json"
