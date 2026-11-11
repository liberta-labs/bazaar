#!/usr/bin/env bash
# Prints a signed Pyth Pro update for a local chain: one feed at one price, generated in the
# second given, in the EVM envelope PythLazer verifies. It is signed with the test key that the
# local deployment's MockPythLazer trusts (LazerUpdate.SIGNER_KEY, a key derived from a fixed label
# and therefore public), so it verifies only there.
#
# Usage: script/dev-update.sh <feed-id> <price> <unix-seconds>
#   <feed-id> is the Pyth Pro feed ID as a number or as the bytes32 a pair reports (baseFeedId).
#   <price> is the price mantissa at exponent -8: 200000000000 for $2,000.
#   CAST names the cast binary when it is not on PATH.
#
# The payload carries the four properties BazaarOracle reads: price, exponent, confidence and feed
# update timestamp. The exponent is -8 and the confidence 0.1% of the price, never less than 1:
# BazaarOracle reads a zero confidence as an absent one and refuses the update.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <feed-id> <price at exponent -8> <unix-seconds>" >&2
    exit 1
fi

feed=$(( $1 ))
price=$2
confidence=$(( price / 1000 ))
if [ "$confidence" -lt 1 ]; then confidence=1; fi
micros=$(printf '%016x' $(( $3 * 1000000 )))
cast=${CAST:-cast}
key=$("$cast" keccak "bazaar.test.pyth-lazer-signer")

# magic | timestamp | channel (real time) | one feed | feed ID | four properties
payload="0x93c7d375${micros}0101$(printf '%08x' "$feed")04"
payload+="00$(printf '%016x' "$price")"                 # price
payload+="04fff8"                                        # exponent -8
payload+="05$(printf '%016x' "$confidence")"            # confidence
payload+="0c01${micros}"                                 # feed update timestamp, present

# The signature is over the payload's keccak256 hash; the envelope stores the recovery ID as 0 or 1.
signature=$("$cast" wallet sign --no-hash "$("$cast" keccak "$payload")" --private-key "$key")
recovery=$(printf '%02x' $(( 0x${signature: -2} - 27 )))
length=$(printf '%04x' $(( (${#payload} - 2) / 2 )))

echo "0x2a22999a${signature:2:128}${recovery}${length}${payload:2}"
