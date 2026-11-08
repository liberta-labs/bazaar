#!/usr/bin/env bash
# Fails unless each MIT interface in src/interfaces/ declares exactly the external surface of the
# contract it describes, as script/export-abis.sh writes it to $ABI_DIR: the same functions, events
# and errors, with the same names, parameter names, types, indexed flags and state mutability. The
# exported BazaarPair.json carries the events and errors of the libraries the pair links, so
# IBazaarPair has to declare those too. `internalType` is not compared: an interface names its own
# structs (InitParams, not BazaarPair.InitParams) and declares contract-typed values as address,
# neither of which changes the encoding.
set -euo pipefail

OUT_DIR="${OUT_DIR:-out}"
ABI_DIR="${ABI_DIR:-abi}"

# Entries are sorted by kind, name and parameter types, so declaration order does not matter and a
# failure diffs only the entries that differ.
normalize='
  def strip:
    if type == "object" then del(.internalType) | map_values(strip)
    elif type == "array" then map(strip)
    else . end;
  [.[] | select(.type == "function" or .type == "event" or .type == "error") | strip]
  | sort_by(.type, .name, (.inputs | map(.type) | join(",")))
'

status=0
for contract in BazaarPair BazaarFactory BazaarPairTerminator BazaarPairLens BazaarOracle; do
    iface="I$contract"
    if ! diff -u --label "$ABI_DIR/$contract.json" --label "src/interfaces/$iface.sol" \
        <(jq -S "$normalize" "$ABI_DIR/$contract.json") \
        <(jq -S ".abi | $normalize" "$OUT_DIR/$iface.sol/$iface.json"); then
        echo "error: $iface does not declare what $contract exposes" >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "src/interfaces/ matches the ABIs in $ABI_DIR"
fi
exit "$status"
