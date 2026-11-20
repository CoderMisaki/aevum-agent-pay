# Aevum Agent Pay — Scoped Autonomous-Agent Payments in tUSD8

**Aevum Builder Challenge #1 (QDay) — free, online hackathon, Nov 16 – Dec 11, 2026.**

Autonomous agents need to pay for things — API calls, data, services — but giving
an agent your wallet is a non-starter. **Aevum Agent Pay** lets a payer create an
on-chain *allowance* for an agent address: whitelisted payee(s), a per-payment cap,
a total budget, and an expiry timestamp. The agent can only pay whitelisted payees,
within the caps, before expiry. The payer funds the allowance up-front (escrow) and
can revoke anytime, reclaiming the unspent balance. Every payment emits a receipt
event — a complete on-chain audit trail.

- **Chain:** QDay Aevum Testnet — chain ID `44005`, RPC `https://rpc-test.qday.info`,
  explorer `https://explorer-test.qday.info`, gas token `tQDAY`
- **Token:** test stablecoin **tUSD8** (ERC-20, 6 decimals) at
  [`0x456569838f1d43009A91ebA4263147Afd7233483`](https://explorer-test.qday.info/address/0x456569838f1d43009A91ebA4263147Afd7233483)
- **Contract:** `AgentPay` — see `src/AgentPay.sol`
- **Deployed address:** [`0xfb4d6F3821518E635a85118902Ef78E77CE7A285`](https://explorer-test.qday.info/address/0xfb4d6F3821518E635a85118902Ef78E77CE7A285) (deploy tx [`0x0ecd8b…`](https://explorer-test.qday.info/tx/0x0ecd8ba0b9a3f70c6a697c896445857a38fe173a7b3f42a6cfc564911a422060))
- **Live demo:** https://codermisaki.github.io/aevum-agent-pay/ (MetaMask + Aevum Testnet)
- **Demo video (79s):** https://github.com/CoderMisaki/aevum-agent-pay/releases/download/demo-video/aevum-agent-pay-demo.mp4

## How it works

```
Payer ── createAllowance(agent, payees, cap, budget, expiry, deposit) ──> AgentPay (escrow)
Agent ── executePayment(allowanceId, payee, amount) ──> payee (tUSD8)
Payer ── revokeAllowance(allowanceId) ──> unspent escrow refunded
```

Guards enforced on-chain, in order, on every payment:

1. Allowance not revoked, not expired
2. Caller is the designated agent (`NotAgent` otherwise)
3. Payee is whitelisted (`PayeeNotWhitelisted` otherwise)
4. Amount ≤ per-payment cap
5. `spent + amount` ≤ total budget
6. Escrow covers the amount

Each payment emits `PaymentExecuted(receiptId, allowanceId, payer, agent, payee,
amount, timestamp)` — the receipt / audit trail.

## Quickstart

### Prerequisites

- [Foundry](https://getfoundry.sh) (`forge`, `cast`)
- Node.js 20+ (for the demo script and frontend tooling)

### 1. Contracts — build & test

```bash
forge build
forge test                 # 12 unit tests (mock tUSD8) + fuzz
forge test --match-contract AgentPayForkTest   # live fork vs the REAL tUSD8
```

### 2. Get testnet funds

**Recommended — Discord faucet:** join the QDay Discord, react ✅ in `#verify`
to get the Verified role, then type `/faucet <your wallet address>`. You get
**1 tQDAY + 5 tUSD8**, once per Discord account and once per address, and it
does **not** check for an Ethereum mainnet balance — a fresh testnet-only wallet
works. (Source: Aevum Starter Kit docs.)

**Web faucet:** <https://faucet.qday.info/en> — 5 tQDAY + 1 tUSD8 per 24h per
address, no signing needed — but the live faucet checks that the recipient
address holds ETH, USDT or USDC on Ethereum mainnet (anti-bot). Our known
wallets hold none of those on mainnet, so the Discord faucet is the way in.

Gas is cheap (~1 gwei): 1 tQDAY covers hundreds of calls; deploying AgentPay
costs well under 0.01 tQDAY.

### 3. Deploy

```bash
# The deployer key lives OUTSIDE the repo (never committed):
export DEPLOYER_KEY=<your testnet private key>
forge script script/Deploy.s.sol --rpc-url https://rpc-test.qday.info --broadcast
# Record the address in deployments/aevum.json and frontend/config.js
```

### 4. Headless demo (end-to-end, no browser)

```bash
cd demo && npm install
npm run demo
```

The demo creates an allowance (cap 2, budget 5, 7-day expiry — sized to the
Discord faucet's 5 tUSD8), has the agent pay the whitelisted payee 1 tUSD8,
proves a non-whitelisted payment reverts, then revokes and reclaims the unspent
4 tUSD8. Amounts are overridable via `DEMO_CAP_TUSD8` / `DEMO_BUDGET_TUSD8` /
`DEMO_PAY_TUSD8`. It reads three test wallets from
`../.keys/{payer,agent,payee}.json` (generated locally, mode 600, never committed)
and the contract address from `AGENT_PAY_ADDRESS` or `deployments/aevum.json`.

### 5. Frontend

Serve `frontend/` statically (any static host, e.g. `npx serve frontend` or
GitHub Pages) and open it with MetaMask on QDay Aevum Testnet (chain 44005).
It supports: connect wallet, create allowance, list allowances, execute a payment
as the agent, revoke, and view payment receipts. Set the deployed address in
`frontend/config.js` first.

## Project structure

```
src/AgentPay.sol            Core contract: allowances, escrow, payments, receipts
test/AgentPay.t.sol         12 unit + fuzz tests (mock tUSD8)
test/AgentPayFork.t.sol     Live-fork test vs the real tUSD8 on Aevum Testnet
test/MockUSD8.sol           6-decimal mock stablecoin (tests only)
script/Deploy.s.sol         Foundry deploy script (Aevum Testnet)
demo/demo.mjs               Headless end-to-end demo (Node + ethers v6)
frontend/                   Static dApp (MetaMask + ethers v6 via CDN)
docs/ARCHITECTURE.md        Design, trust model, invariants, limitations
deployments/aevum.json      Deployed addresses (filled after deploy)
```

## Why this maps to the judging criteria

| Criterion | How Agent Pay addresses it |
|---|---|
| Innovation | Agentic payments — agents paying autonomously, a use case QDay itself highlights for its post-quantum EVM |
| Technical quality | Scoped sessions: payee whitelist, per-payment cap, total budget, expiry — exactly the primitives the criteria name |
| Safety | Least privilege by construction; escrow can never exceed the budget; instant revocation; full receipt audit trail; reentrancy-guarded; `SafeERC20` |
| Real-world utility | The missing primitive for agent economies: subscriptions, per-call API billing, agent-to-agent settlement — all in a stablecoin |

## Limitations (honest)

- Single-token (tUSD8) by design for the demo; multi-token support is a one-line
  generalization (token per allowance).
- Allowances are funded up-front (escrow); no streaming / pull-based billing yet.
- The frontend is intentionally minimal — it is a working demo, not a product UI.

## Team

Solo — **Izka** ([@Izkaizz](https://x.com/Izkaizz), GitHub
[CoderMisaki](https://github.com/CoderMisaki)).

## License

MIT — see `LICENSE`.
