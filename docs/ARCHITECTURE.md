# Architecture — Aevum Agent Pay

## Problem

An autonomous agent that needs to spend money is usually given either nothing
(can't act) or a funded wallet (can drain everything). Neither is acceptable
for real agent economies: API billing, data purchases, agent-to-agent
settlement all need *scoped* spending power — bounded by who, how much, and
until when.

## Design

One contract, `AgentPay` (`src/AgentPay.sol`), holding tUSD8 escrow per
allowance. No proxy, no admin, no upgrade path: the rules are the code.

### Allowance (the core object)

| Field | Meaning |
|---|---|
| `payer` | Who funded it; only they can revoke / top up / manage payees |
| `agent` | The single address allowed to execute payments |
| `payees[]` + `isPayee` mapping | Whitelist; payments to anyone else revert |
| `perPaymentCap` | Max tUSD8 per single payment |
| `totalBudget` | Max tUSD8 over the allowance's whole life |
| `spent` | Running total paid out |
| `expiry` | Unix timestamp; payments after it revert |
| `revoked` | Payer-set kill switch |
| `escrowed` | tUSD8 held in the contract for this allowance |

### Invariants (enforced by construction + tests)

1. `escrowed >= totalBudget - spent` at creation — the contract can never
   promise more than it holds. `createAllowance` requires `deposit >= totalBudget`.
2. `spent <= totalBudget` always — checked before every payment.
3. Every payment moves exactly `amount` to a whitelisted payee and emits a
   `PaymentExecuted` receipt with a monotonically increasing `receiptId`.
4. Revocation is payer-only, irreversible, and refunds `escrowed` in full.
5. No function lets the agent touch funds except `executePayment` under the
   six guards; the agent can never withdraw to itself unless it is whitelisted
   as a payee (and even then only within the caps).
6. Reentrancy: all state-changing functions are `nonReentrant`; token moves
   use `SafeERC20`.

### Flows

**Create** — payer approves tUSD8, calls `createAllowance(agent, payees, cap,
budget, expiry, deposit)`. Escrow is pulled in the same transaction.

**Pay** — agent calls `executePayment(id, payee, amount)`. Six guards run,
escrow decreases, payee receives tUSD8, receipt emitted.

**Manage** — payer can `addPayee` / `removePayee` / `topUp` while the
allowance is active.

**Revoke** — payer calls `revokeAllowance(id)`; unspent escrow returns
immediately; further payments revert with `AlreadyRevoked`.

### Events (audit trail)

- `AllowanceCreated` — full terms at birth
- `PaymentExecuted` — the receipt (id, allowance, payer, agent, payee,
  amount, timestamp)
- `AllowanceRevoked` — with refunded amount
- `PayeeAdded` / `PayeeRemoved` / `AllowanceToppedUp`

Any indexer can reconstruct the complete history of an allowance from events
alone.

## Tech used

- **Solidity 0.8.24**, OpenZeppelin v5.7 (`IERC20`, `SafeERC20`,
  `ReentrancyGuard`) — standard libraries only
- **Foundry** — build, unit + fuzz tests, live-fork test, deploy script
- **Node + ethers v6** — headless demo (`demo/demo.mjs`)
- **Static HTML + ethers v6 (CDN) + MetaMask** — frontend
- **QDay Aevum Testnet** (chain 44005), token **tUSD8** (6 decimals,
  `0x456569838f1d43009A91ebA4263147Afd7233483`)

## Trust model

- The payer trusts the contract code (verified on the explorer after deploy),
  not the agent and not any off-chain service.
- The agent is trusted only within its scope; a compromised agent can at most
  spend up to the remaining budget, only to whitelisted payees, only before
  expiry — and the payer can revoke instantly.
- The payee list is the blast-radius control: keep it to addresses you have
  vetted (e.g. a known API provider's settlement address).

## What is NOT in scope (deliberate)

- Multi-token allowances (trivial extension: token per allowance).
- Streaming / per-second billing.
- Agent identity / reputation — the allowance *is* the credential.
- Privacy — allowances, payees and amounts are public on-chain, as with any
  transparent payment system.

## Verification performed

- `forge test`: 12 unit + fuzz tests, all passing (mock tUSD8).
- `forge test --match-contract AgentPayForkTest`: end-to-end against the real
  tUSD8 on a live fork of Aevum Testnet (funded by impersonating the top
  holder; no gas spent).
- Testnet deployment + headless demo: pending faucet funds (see README §2 and
  `deployments/aevum.json` once deployed).
