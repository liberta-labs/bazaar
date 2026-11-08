# ABIs

The JSON ABIs of the five Bazaar contracts, as `make abis` exports them from a build. Use them from any language without building the repository.

`BazaarPair.json` also carries the events and errors of the external libraries the pair links. Those libraries run by DELEGATECALL in the pair's context, so their logs carry the pair's address and their reverts surface from its calls, but the compiler leaves them out of the pair's own ABI.

Each file declares exactly what the matching interface in [`src/interfaces/`](../src/interfaces) declares. `script/check-interfaces.sh` checks this, and CI fails if a file here differs from what the contracts compile to.

These files are licensed under the MIT License, like those interfaces; see [`LICENSE-MIT`](../LICENSE-MIT).
