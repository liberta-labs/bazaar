#!/usr/bin/env bash
# Builds the subgraph against the addresses deploy-contracts.sh wrote and deploys it to a local
# Graph Node as `bazaar`. It builds a copy under $E2E_WORK, so the tracked subgraph.yaml and
# networks.json keep the addresses they hold. The ABIs are exported from the same build the
# contracts were deployed from, so the handlers decode exactly what the chain emits.
#
#   REPO      Foundry project the contracts were deployed from (default: this checkout)
#   E2E_WORK  work directory (default /tmp/bazaar-e2e)
#   $1        version label (default v0.0.1); redeploying with a new label reindexes from block 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBGRAPH="$(cd "$HERE/.." && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
E2E_WORK="${E2E_WORK:-/tmp/bazaar-e2e}"
LABEL="${1:-v0.0.1}"
[ -f "$E2E_WORK/addresses.json" ] || { echo "run deploy-contracts.sh first"; exit 1; }
[ -d "$SUBGRAPH/node_modules" ] || { echo "run npm install in $SUBGRAPH first"; exit 1; }

OUT_DIR="$REPO/out" ABI_DIR="$E2E_WORK/abi" bash "$REPO/script/export-abis.sh"
rm -f "$E2E_WORK/errors.json"

W="$E2E_WORK/subgraph"
mkdir -p "$W"
rsync -a --delete --exclude node_modules --exclude build --exclude generated --exclude tests/.bin \
    --exclude e2e "$SUBGRAPH/" "$W/"
ln -sfn "$SUBGRAPH/node_modules" "$W/node_modules"

python3 - "$E2E_WORK" <<'EOF'
import json, sys
work = sys.argv[1]
a = json.load(open(f"{work}/addresses.json"))
n = json.load(open(f"{work}/subgraph/networks.json"))
n["anvil"] = {name: {"address": a[k], "startBlock": 0}
              for name, k in (("BazaarFactory", "factory"), ("BazaarPairTerminator", "terminator"), ("BazaarOracle", "oracle"))}
json.dump(n, open(f"{work}/subgraph/networks.json", "w"), indent=2)
EOF

cd "$W"
G="node node_modules/@graphprotocol/graph-cli/bin/run.js"
$G codegen > "$E2E_WORK/codegen.log" 2>&1 || { tail -20 "$E2E_WORK/codegen.log"; exit 1; }
$G build --network anvil > "$E2E_WORK/build.log" 2>&1 || { tail -30 "$E2E_WORK/build.log"; exit 1; }
$G create --node http://localhost:8020/ bazaar > /dev/null 2>&1 || true  # already exists on a redeploy
$G deploy --node http://localhost:8020/ --ipfs http://localhost:5001 --network anvil --version-label "$LABEL" bazaar \
    > "$E2E_WORK/deploy-subgraph.log" 2>&1 || { tail -20 "$E2E_WORK/deploy-subgraph.log"; exit 1; }
echo "deployed bazaar $LABEL: http://localhost:8000/subgraphs/name/bazaar/graphql"
