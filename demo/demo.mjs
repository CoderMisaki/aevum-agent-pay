// Aevum Agent Pay — headless end-to-end demo on QDay Aevum Testnet.
//
// Flow:
//   1. Payer approves AgentPay and creates an allowance for the agent
//      (payee whitelisted, per-payment cap 2 tUSD8, total budget 5 tUSD8,
//      expiry +7 days, funded with 5 tUSD8 escrow — sized to the Discord
//      faucet's 5 tUSD8; override via DEMO_*_TUSD8 env vars).
//   2. Agent executes a 1 tUSD8 payment to the whitelisted payee.
//   3. Agent tries to pay a NON-whitelisted address -> must revert.
//   4. Payer revokes the allowance and reclaims the unspent escrow.
//
// Usage:
//   cd demo && npm install
//   # keys live in ../.keys/ (mode 600, never committed)
//   # contract address: set AGENT_PAY_ADDRESS, or write deployments/aevum.json
//   npm run demo
//
// Requires testnet funds: faucet https://faucet.qday.info/en
// (5 tQDAY + 1 tUSD8 per 24h). See README for the faucet notes.

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { ethers } from "ethers";

const RPC = "https://rpc-test.qday.info";
const EXPLORER = "https://explorer-test.qday.info";
const TUSD8 = "0x456569838f1d43009A91ebA4263147Afd7233483";
const ONE = 1_000_000n; // 1 tUSD8 = 1e6 units (6 decimals)

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];

function loadKey(role) {
  const raw = JSON.parse(readFileSync(path.resolve(repoRoot, "..", ".keys", `${role}.json`), "utf8"));
  return raw.data[0].private_key;
}

function loadAgentPayAddress() {
  if (process.env.AGENT_PAY_ADDRESS) return process.env.AGENT_PAY_ADDRESS;
  const depPath = path.resolve(repoRoot, "deployments", "aevum.json");
  if (existsSync(depPath)) return JSON.parse(readFileSync(depPath, "utf8")).agentPay;
  throw new Error("No AgentPay address: set AGENT_PAY_ADDRESS or create deployments/aevum.json (see README).");
}

function loadAbi() {
  const artifact = JSON.parse(
    readFileSync(path.resolve(repoRoot, "out", "AgentPay.sol", "AgentPay.json"), "utf8"),
  );
  return artifact.abi;
}

const fmt = (v) => `${Number(v) / 1e6} tUSD8`;

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const agentPayAddress = loadAgentPayAddress();
  const agentPay = new ethers.Contract(agentPayAddress, loadAbi(), provider);
  const tusd8 = new ethers.Contract(TUSD8, ERC20_ABI, provider);

  const payer = new ethers.Wallet(loadKey("payer"), provider);
  const agent = new ethers.Wallet(loadKey("agent"), provider);
  const payee = new ethers.Wallet(loadKey("payee"), provider);

  console.log("== Aevum Agent Pay demo ==");
  console.log("AgentPay :", agentPayAddress, `${EXPLORER}/address/${agentPayAddress}`);
  console.log("Payer    :", payer.address);
  console.log("Agent    :", agent.address);
  console.log("Payee    :", payee.address);
  console.log("Payer tUSD8 balance:", fmt(await tusd8.balanceOf(payer.address)));
  console.log("Payer tQDAY balance:", ethers.formatEther(await provider.getBalance(payer.address)));

  // 1. Approve + create allowance (cap 2, budget 5, 7-day expiry, 5 escrow).
  //    Defaults fit the Discord faucet's 5 tUSD8; override with env:
  //    DEMO_CAP_TUSD8 / DEMO_BUDGET_TUSD8 / DEMO_PAY_TUSD8.
  const cap = BigInt(Math.round(parseFloat(process.env.DEMO_CAP_TUSD8 ?? "2") * 1e6));
  const budget = BigInt(Math.round(parseFloat(process.env.DEMO_BUDGET_TUSD8 ?? "5") * 1e6));
  const payAmount = BigInt(Math.round(parseFloat(process.env.DEMO_PAY_TUSD8 ?? "1") * 1e6));
  const expiry = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
  console.log("\n[1] Payer creates allowance (cap 10, budget 50, expiry +7d)...");
  const allowance = await tusd8.allowance(payer.address, agentPayAddress);
  if (allowance < budget) {
    const tx = await tusd8.connect(payer).approve(agentPayAddress, budget);
    await tx.wait();
    console.log("    approved, tx:", `${EXPLORER}/tx/${tx.hash}`);
  }
  const createTx = await agentPay
    .connect(payer)
    .createAllowance(agent.address, [payee.address], cap, budget, expiry, budget);
  const createRc = await createTx.wait();
  const created = createRc.logs
    .map((l) => { try { return agentPay.interface.parseLog(l); } catch { return null; } })
    .find((e) => e?.name === "AllowanceCreated");
  const allowanceId = created.args.allowanceId;
  console.log(`    allowance #${allowanceId} created, tx: ${EXPLORER}/tx/${createTx.hash}`);
  // 2. Agent pays the whitelisted payee (default 1 tUSD8).
  console.log(`\n[2] Agent pays payee ${Number(payAmount) / 1e6} tUSD8...`);
  const payTx = await agentPay.connect(agent).executePayment(allowanceId, payee.address, payAmount);
  const payRc = await payTx.wait();
  const receipt = payRc.logs
    .map((l) => { try { return agentPay.interface.parseLog(l); } catch { return null; } })
    .find((e) => e?.name === "PaymentExecuted");
  console.log(`    receipt #${receipt.args.receiptId} emitted, tx: ${EXPLORER}/tx/${payTx.hash}`);
  console.log("    payee balance now:", fmt(await tusd8.balanceOf(payee.address)));

  // 3. Agent tries a non-whitelisted payee — must revert.
  console.log("\n[3] Agent tries non-whitelisted payee (expect revert)...");
  try {
    const badTx = await agentPay.connect(agent).executePayment(allowanceId, agent.address, 1n * ONE);
    await badTx.wait();
    console.log("    !! UNEXPECTED: payment succeeded — guard failed");
    process.exitCode = 1;
  } catch (e) {
    console.log("    reverted as expected:", (e.reason ?? e.shortMessage ?? String(e)).slice(0, 120));
  }

  // 4. Payer revokes and reclaims the unspent escrow (budget - paid).
  console.log("\n[4] Payer revokes allowance...");
  const revokeTx = await agentPay.connect(payer).revokeAllowance(allowanceId);
  await revokeTx.wait();
  console.log(`    revoked, tx: ${EXPLORER}/tx/${revokeTx.hash}`);
  console.log("    payer balance now:", fmt(await tusd8.balanceOf(payer.address)));

  console.log("\nDemo complete. Allowance state:");
  console.log("   ", await agentPay.getAllowance(allowanceId));
}

main().catch((e) => {
  console.error("Demo failed:", e);
  process.exit(1);
});
