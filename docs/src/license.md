# License

Bazaar's protocol is licensed under the **GNU Affero General Public License v3.0 only** ([AGPL-3.0-only](https://www.gnu.org/licenses/agpl-3.0.en.html)). The code an integration compiles against is licensed under the **MIT License**, and the text of this documentation under **CC BY 4.0**. Every Solidity source file names its license in its `SPDX-License-Identifier` header, and the repository carries the full texts in `LICENSE` (AGPL) and `LICENSE-MIT`.

## Integrating

Using the deployed contracts puts no license conditions on you. A wallet, frontend, trading bot, keeper, relayer, aggregator, vault or indexer that sends the contracts transactions or reads their state does not modify or distribute the protocol's code, and modifying and distributing it are what the AGPL's conditions attach to. That holds whatever you charge for your product, and whether or not its own source is published.

The files you would copy or compile into your product are MIT-licensed, so building on them brings no AGPL obligations with it:

| Path | What it is |
|---|---|
| `src/interfaces/IBazaarPair.sol`, `IBazaarFactory.sol`, `IBazaarPairLens.sol`, `IBazaarPairTerminator.sol`, `IBazaarOracle.sol` | One interface per contract, declaring every function, event and error in its ABI. `IBazaarPair` includes the events and errors of the libraries the pair links |
| `src/libraries/BazaarTypes.sol` | The structs, enums, events and constants those interfaces use |
| `abi/` | The same five contracts' JSON ABIs |
| `examples/` | Example contracts to adapt and deploy yourself, such as the account in [Batching Orders](guide/batching.md) |
| `subgraph/` | The Graph subgraph that indexes the protocol |
| Code samples in this documentation | Snippets such as the `createOrder` call in [Integrators](guide/integrators.md) |

The MIT License's one condition is that its copyright and permission notice (`LICENSE-MIT`) stays with copies of those files.

## Forking the protocol

The rest of Bazaar's own code — the protocol's contracts and libraries, the deployment scripts and the tests — is AGPL-3.0-only:

- You may use, study, modify, and redistribute the code freely.
- If you distribute a modified version, you must release your modifications under AGPL-3.0.
- **§13 — the network clause**: if you run a modified version as a network service (which is what deploying a fork of a DeFi protocol *is*), you must offer its complete corresponding source to the users of that service. There is no SaaS loophole.
- You may not relicense forks under more restrictive terms, add usage restrictions that conflict with the license's freedoms, or take the code proprietary.

Forking and competing is legal and expected — the license only guarantees that every fork stays as open as the original.

## This documentation

The text of these pages is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/): reuse and adapt it with attribution. Its code samples are MIT-licensed, as above, and the images are covered by neither license.
