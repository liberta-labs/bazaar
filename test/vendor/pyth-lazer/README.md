# Pyth Pro (Lazer) reference parser

`PythLazerLib.sol` and `PythLazerStructs.sol` are unmodified copies of Pyth's EVM payload parser,
from `lazer/contracts/evm/src` in [pyth-network/pyth-crosschain](https://github.com/pyth-network/pyth-crosschain),
under the Apache-2.0 license their headers carry.

Nothing in `src/` imports them. They exist so `test/unit/LazerPayloadLibTest.t.sol` can check that
`src/libraries/LazerPayloadLib.sol`, the parser BazaarOracle uses, reads every payload the way
Pyth's own parser does. Replace both files together when Pyth changes the payload format, and
re-run that test.
