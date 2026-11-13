# Gasless Transactions

The trading and funding actions on a pair — deposits, withdrawals, order creation, amendment and cancellation, insurance deposits/withdrawals — can be executed by a **relayer** carrying the user's EIP-712 signature. Combined with ERC-2612 permit for USDC approvals, a trader needs no ETH for any of them. `claimFees` has no relayed form, so collecting a claimable balance (a refunded trigger bounty, say) is a self-submitted call.

## How it works

Each function takes a `(nonce, deadline, relayerFee, signature)` tuple, and every one but `withdrawCollateral` — the deposits, `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal`, `createOrder`, `cancelOrders` and `amendOrders` — takes a trailing `permitData` after it (`withdrawCollateral` nets its fee from the payout, and a terminal withdrawal worth zero pulls the fee against the allowance already in place):

- Empty signature → normal transaction, `msg.sender` is the actor, fee ignored.
- Non-empty → the contract recovers the signer over the typed payload and acts as *them*; whoever submitted the transaction is credited `relayerFee` in USDC on their claimable balance, withdrawn with `claimFees()`.

| Rule | Value |
|---|---|
| Domain | name `"BazaarPair"`, version `"1"`, chainId, verifying contract (re-derived if chainId changes — fork protection) |
| Nonces | strictly sequential per user, kept separately on each pair (`metaTxNonces(user)`) |
| Deadline | must not be passed, and at most **10 s** in the future (`MAX_DEADLINE_WINDOW`) — a signature cannot be warehoused |
| Relayer fee | ≤ **$1** per action, charged at its USDC floor; the rules follow the table |
| Price staleness | the same 3 s bound as every other path — but `priceUpdate` sits outside the signed payload, so the relayer attaches a fresh price at submission and an earlier signature still lands on it |

<details>
<summary>Edge case: a relayer leaving a trigger order on the stale fallback</summary>

On a session pair a relayer can instead leave a trigger order on the stale fallback, which keeps a trigger the live price already meets from arming on arrival; firing it itself in the same block earns nothing, since an execution in that block on an order the stale fallback left unarmed pays the bounty to the owner.

</details>

The relayer fee:

- **Cap and rounding.** ≤ **$1** per action, charged at its USDC floor: the signed fee is rounded down to USDC's 6-decimal precision before it is pulled or netted, so the relayer's credit is exactly the USDC the pair received, and a fee below one micro-USDC charges nothing.
- **Where it is taken.** Netted from the payout on withdrawals, pulled from the user's wallet alongside deposits, and pulled from the wallet on its own for order create/cancel/amend, insurance-withdrawal requests, and a withdrawal that pays nothing out — the first, locking `executeInsuranceWithdrawal` call, or a redemption or terminal withdrawal worth zero (a withdrawal paying more than zero but no more than the fee reverts).
- **Who is paid.** Each relayed call pays whoever submits it, so a lock and its paying call can go through different relayers. In every case the fee stays in the pair as the relayer's claimable balance, accrued per call and withdrawn with `claimFees()` in any pair state.
- **Never bucket collateral.** Never charged to bucket collateral: margin backing a position leaves only through `withdrawCollateral` and its gates.

Building the signature:

- **Typed structs** exist for `depositCollateral`, `withdrawCollateral`, `createOrder`, `cancelOrders`, `amendOrders` (one `uint256[]` of word triples — an id word carrying the order id and its optional insertion hints, the new price and the new size per amendment — hashed as EIP-712 hashes an array; the hints are signed too, so a relayer cannot refresh them), `depositToInsurance`, `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal`.
- **`createOrder`** signs the order spec but not its `MatchHints`: like `priceUpdate`, the relayer attaches insertion hints at submission (each verified on-chain against the real neighbours), and a relayed order always walks the protocol-default step budget, since only the signer may bound how much of their order executes.
- **Constants.** `BazaarPairLens.getEip712Constants()` and `getTypehashes()` expose everything an integrator needs to build signatures.

## Type strings

Every pair is its own EIP-712 domain: `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with name `"BazaarPair"`, version `"1"`, the chain's id, and the pair's address as `verifyingContract`. The primary types, whose hashes `getTypehashes()` returns:

```text
DepositCollateral(uint256 amount,uint256 nonce,uint256 deadline,uint256 relayerFee)
WithdrawCollateral(uint256 amount,uint256 nonce,uint256 deadline,uint256 relayerFee)
DepositToInsurance(uint256 amount,uint256 nonce,uint256 deadline,uint256 relayerFee)
RequestInsuranceWithdrawal(uint256 shareAmount,uint256 nonce,uint256 deadline,uint256 relayerFee)
ExecuteInsuranceWithdrawal(uint256 nonce,uint256 deadline,uint256 relayerFee)
CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint8 tif,uint256 expirationBlock,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)
CancelOrders(uint256[] orderIds,uint256 nonce,uint256 deadline,uint256 relayerFee)
AmendOrders(uint256[] amends,uint256 nonce,uint256 deadline,uint256 relayerFee)
```

Each field is the call's argument of the same name — for `CreateOrder`, the field of the call's `OrderSpec` — and `nonce` is the signer's current `metaTxNonces` on that pair. `CreateOrder` lists its fields in its own order rather than the struct's, signs `orderType` and `tif` as the enums' `uint8` values, and signs `expirationBlock` as a `uint256` although the struct holds a `uint64`.

## Permit

The functions that take a `permitData` execute it best-effort before the pull — approval and action in one signature.

- **Deposits.** For the deposits the permit covers the deposit plus fee.
- **`createOrder`.** For `createOrder` it covers the relayer fee plus the trigger bounty the order carries (the fee is pulled first, so one permit serves both).
- **Fee-only calls.** For `cancelOrders`, `amendOrders`, `requestInsuranceWithdrawal` and the locking `executeInsuranceWithdrawal` call it covers the relayer fee alone, so a trader who onboarded through a permit and holds no ETH can still trade, amend and cancel gaslessly, and an LP can request and lock an exit the same way.
- **No permit needed.** The paying `executeInsuranceWithdrawal` call needs no permit, since its fee comes out of the payout.
- **A failed permit** emits `PermitExecutionFailed` and falls through to the normal allowance path (so a griefed permit can't block a call that would succeed anyway).
