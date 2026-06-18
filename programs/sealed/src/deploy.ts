/**
 * Deploy Sealed + TreasuryEscrow.
 *
 * Usage:
 *   ALGORAND_NETWORK=localnet|testnet|mainnet \
 *   pnpm --filter @sealed/contract deploy [-- --new-wallet | --mnemonic "<25 words>"]
 *
 * Modes:
 *   --new-wallet  Generate a fresh 25-word mnemonic, write to .env as
 *                 SEALED_TREASURY_MNEMONIC. On LocalNet, auto-funds via
 *                 dispenser. On TestNet/MainNet, prints address + dispenser
 *                 URL and exits — user must fund and rerun without flag.
 *   --mnemonic    Use the supplied mnemonic for this deploy. Does NOT write
 *                 .env.
 *   (no flag)     Read SEALED_TREASURY_MNEMONIC from .env / process env.
 *
 * Writes to `deploy.log`:
 *   timestamp  network  appId  appAddress  escrowAddress  deployer  commit
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { execSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { fundEscrow, loadTreasuryEscrow } from "./lib/escrow.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(__dirname, "..");
const ARC56_PATH = resolve(PKG_ROOT, "out", "Sealed.arc56.json");
const ENV_PATH = resolve(PKG_ROOT, ".env");
const DEPLOY_LOG = resolve(PKG_ROOT, "deploy.log");

const APP_BASE_MBR = 200_000n;
/**
 * Per-user UserState box MBR. App account pre-funds this for every redeem
 * (which creates the `w:` box at full v2 size — keys included). publishKeys
 * is a same-size overwrite, no MBR delta.
 */
const MBR_NEW_USER_BOX = 150_000n;
/**
 * Per-username `n:<sha256(name)>` reverse-index box MBR. App account
 * pre-funds this for every first-claim of a username. `releaseUsername`
 * refunds it back. Rename = net-zero (delete old + create new).
 * MBR = 2500 + 400 * (34 key + 32 value) ≈ 28_900. Round up generously.
 */
const MBR_NAME_BOX = 30_000n;
/**
 * Per-code `c:<sha256(preimage)>` commitment box MBR (v2 layout w/
 * `soldAtRound` field). Key 34B, value 24B (3 × uint64). MBR = 2500 + 400 ×
 * (34 + 24) = 25_700 µA. App account pre-funds for every `registerCommitment`.
 */
const MBR_COMMITMENT_BOX = 25_700n;
/**
 * Per-pool-slot `p:<be_uint64>` queue-entry box MBR. Key 10B, value 32B.
 * MBR = 2500 + 400 × (10 + 32) = 19_300 µA. App account pre-funds for every
 * `seedSalePool` entry; refunded on `purchaseCodes` or `unseedSalePool`.
 */
const MBR_POOL_BOX = 19_300n;
/**
 * Number of expected user redeems the app account is pre-funded for. Bump
 * via `--users <N>` CLI flag for high-volume deploys.
 *
 * NOTE: temporarily reduced 25 → 3 + slack 1M → 200k + escrow 1M → 300k for
 * low-balance TestNet smoke redeploy (deployer ~1.66 ALGO). Top up via
 * payment to app account before high-volume use.
 */
/**
 * Default redeem headroom when `--users <N>` is not passed (smoke-test scale).
 * Override at deploy time: `pnpm deploy -- --users 100`. The flag IS wired in
 * main() — earlier versions documented it but ignored it.
 */
const DEFAULT_HEADROOM_USERS = 3n;
/**
 * Pre-fund formula (Phase 3b): base + N × (UserState MBR + name MBR) + slack.
 * Slack covers admin-paid commitment boxes, escrow round-trip inner-pay seed
 * deltas, and ~1 ALGO buffer for fee absorption. Documented per T25.
 *
 * Monetization v1: if `--pool-depth N` is passed, app account also pre-funds
 * `N × (MBR_COMMITMENT_BOX + MBR_POOL_BOX)` so admin can `registerCommitment`
 * + `seedSalePool` for N codes without further top-up. v2 default is 0 (no
 * pre-funded pool — admin tops up app account separately before seeding).
 */
const SLACK = 200_000n;
/** Per-code headroom required to register + seed one sale-pool entry. */
const MBR_PER_SOLD_CODE = MBR_COMMITMENT_BOX + MBR_POOL_BOX;
const ESCROW_FUNDING_LOCALNET = 5_000_000n;
const ESCROW_FUNDING_TESTNET = 300_000n;
/**
 * MainNet escrow (fee-burn LogicSig) seed. Worst-case SNARK redeem pools up to
 * ~220_000 µA of group fee from the escrow; the LogicSig hard-caps any single
 * fee at 250_000 µA. 25 ALGO ≈ 100 worst-case redeems of buffer. Toppable post
 * launch via a plain payment to the escrow address, or override with
 * `--escrow <ALGO>` at deploy time. Monitor escrow balance — when it drains,
 * redeems start failing.
 */
const ESCROW_FUNDING_MAINNET = 25_000_000n;
/**
 * Per-code sale price in µAlgos seeded into `priceMicroAlgos` global at
 * createApplication. v1 monetization: buyer's TOTAL wallet debit must land on
 * a round 10 ALGO. The 2-txn purchase group carries a 0.002 ALGO network fee
 * the buyer pays on top of the transfer, so the transfer itself is priced at
 * 9.998 ALGO (9_998_000 µA) — 9.998 transfer + 0.002 fee = exactly 10.00 ALGO.
 * Mutable post-create via `setPrice`. T8 (deploy MBR headroom for sale pool)
 * lands later.
 */
const INITIAL_PRICE_MICROALGOS = 9_998_000n;

function parseArgs(argv: string[]): Record<string, string | true> {
  const out: Record<string, string | true> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const k = a.slice(2);
    const v = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
    out[k] = v;
  }
  return out;
}

function loadEnv(): Record<string, string> {
  if (!existsSync(ENV_PATH)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(ENV_PATH, "utf-8").split("\n")) {
    const m = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2].replace(/^"(.*)"$/, "$1");
  }
  return out;
}

function writeEnv(updates: Record<string, string>): void {
  const lines = existsSync(ENV_PATH)
    ? readFileSync(ENV_PATH, "utf-8").split("\n")
    : [];
  const keysWritten = new Set<string>();
  const next = lines.map((line) => {
    const m = /^([A-Z_][A-Z0-9_]*)=/.exec(line);
    if (m && updates[m[1]] !== undefined) {
      keysWritten.add(m[1]);
      return `${m[1]}=${updates[m[1]]}`;
    }
    return line;
  });
  for (const [k, v] of Object.entries(updates)) {
    if (!keysWritten.has(k)) next.push(`${k}=${v}`);
  }
  writeFileSync(ENV_PATH, next.join("\n").replace(/\n+$/, "") + "\n");
}

function pickNetwork(): { name: string; client: AlgorandClient } {
  const network = (process.env.ALGORAND_NETWORK ?? "localnet").toLowerCase();
  switch (network) {
    case "localnet":
      return { name: "localnet", client: AlgorandClient.defaultLocalNet() };
    case "testnet":
      return { name: "testnet", client: AlgorandClient.testNet() };
    case "mainnet":
      return { name: "mainnet", client: AlgorandClient.mainNet() };
    default:
      throw new Error(`Unknown ALGORAND_NETWORK=${network}`);
  }
}

function currentCommit(): string {
  try {
    return execSync("git rev-parse --short HEAD", { cwd: PKG_ROOT })
      .toString()
      .trim();
  } catch {
    return "unknown";
  }
}

async function resolveDeployer(
  args: Record<string, string | true>,
  networkName: string,
  algorand: AlgorandClient,
): Promise<algosdk.Account> {
  if (typeof args.mnemonic === "string") {
    return algosdk.mnemonicToSecretKey(args.mnemonic.trim());
  }

  if (args["new-wallet"]) {
    const acct = algosdk.generateAccount();
    const mnemonic = algosdk.secretKeyToMnemonic(acct.sk);
    writeEnv({ SEALED_TREASURY_MNEMONIC: `"${mnemonic}"` });
    console.log(
      `Generated wallet ${acct.addr.toString()} — mnemonic saved to .env`,
    );

    if (networkName === "localnet") {
      const dispenserAccount = await algorand.account.localNetDispenser();
      const dispenser =
        dispenserAccount.account ??
        (dispenserAccount as unknown as algosdk.Account);
      const sp = await algorand.client.algod.getTransactionParams().do();
      const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
        sender: dispenser.addr,
        receiver: acct.addr.toString(),
        amount: 100_000_000,
        suggestedParams: sp,
      });
      const signed = txn.signTxn(dispenser.sk);
      const { txid } = await algorand.client.algod
        .sendRawTransaction(signed)
        .do();
      await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
      console.log(`Funded with 100 ALGO from LocalNet dispenser`);
      return acct;
    } else {
      console.log(
        `Fund ${acct.addr.toString()} at https://bank.testnet.algorand.network/ (TestNet) then rerun without --new-wallet.`,
      );
      process.exit(0);
    }
  }

  const env = loadEnv();
  const mnemonic =
    process.env.SEALED_TREASURY_MNEMONIC ?? env.SEALED_TREASURY_MNEMONIC;
  if (!mnemonic) {
    throw new Error(
      "SEALED_TREASURY_MNEMONIC not set; pass --new-wallet or --mnemonic, or populate .env",
    );
  }
  return algosdk.mnemonicToSecretKey(mnemonic.trim());
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const { name: networkName, client: algorand } = pickNetwork();
  const deployer = await resolveDeployer(args, networkName, algorand);

  const headroomUsers: bigint =
    typeof args.users === "string" ? BigInt(args.users) : DEFAULT_HEADROOM_USERS;
  const boxHeadroom: bigint =
    SLACK + headroomUsers * (MBR_NEW_USER_BOX + MBR_NAME_BOX);
  console.log(`User redeem headroom: ${headroomUsers}`);

  const poolDepth: bigint =
    typeof args["pool-depth"] === "string" ? BigInt(args["pool-depth"]) : 0n;
  const poolMbrHeadroom: bigint = poolDepth * MBR_PER_SOLD_CODE;
  if (poolDepth > 0n) {
    console.log(
      `Pool pre-fund: ${poolDepth} codes × ${MBR_PER_SOLD_CODE} µA = ${poolMbrHeadroom} µA`,
    );
  }

  const info = await algorand.client.algod
    .accountInformation(deployer.addr.toString())
    .do();
  const bal = BigInt(info.amount);
  console.log(
    `Deployer ${deployer.addr.toString()} balance=${bal}µA on ${networkName}`,
  );
  // if (bal < 3_500_000n) {
  //   throw new Error(`Deployer balance ${bal}µA insufficient (need ≥3.5 ALGO)`);
  // }

  algorand.setSignerFromAccount(deployer);
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  const factory = algorand.client.getAppFactory({
    appSpec,
    defaultSender: deployer.addr,
  });

  const zeroAddr = algosdk.encodeAddress(new Uint8Array(32));
  const { appClient } = await factory.send.create({
    method: "createApplication(address,address,uint64,uint64)void",
    args: [
      zeroAddr,
      deployer.addr.toString(),
      9_500_000n,
      INITIAL_PRICE_MICROALGOS,
    ],
    onComplete: algosdk.OnApplicationComplete.NoOpOC,
    staticFee: AlgoAmount.MicroAlgo(2000n),
    // extraProgramPages immutable post-create. 3 = 4 pages * 2048 = 8192 byte
    // limit. Approval is ~4.3 KB after SNARK redeem (Groth16 verify, OpUps);
    // headroom for future ABI additions.
    extraProgramPages: 3,
  });
  const appId = appClient.appId;
  const appAddress = appClient.appAddress.toString();
  console.log(`App created appId=${appId} appAddress=${appAddress}`);

  // Top up app account for box MBR (UserState + name + optional sale pool).
  await algorand.send.payment({
    sender: deployer.addr,
    receiver: appAddress,
    amount: AlgoAmount.MicroAlgo(APP_BASE_MBR + boxHeadroom + poolMbrHeadroom),
  });

  // Verify app account holds at least base + N × (UserState + name MBR).
  const appInfo = await algorand.client.algod
    .accountInformation(appAddress)
    .do();
  const appBal = BigInt(appInfo.amount);
  const required =
    APP_BASE_MBR + headroomUsers * (MBR_NEW_USER_BOX + MBR_NAME_BOX);
  if (appBal < required) {
    throw new Error(
      `App account ${appAddress} balance ${appBal}µA < required ${required}µA`,
    );
  }
  console.log(
    `App account balance=${appBal}µA (headroom for ${headroomUsers} redeem+claimUsername sequences)`,
  );

  // Load + fund escrow, rotate treasuryAddress.
  const escrow = await loadTreasuryEscrow(algorand.client.algod);
  console.log(`Escrow address=${escrow.address}`);

  const escrowFunding =
    typeof args.escrow === "string"
      ? BigInt(Math.round(Number(args.escrow) * 1_000_000))
      : networkName === "localnet"
        ? ESCROW_FUNDING_LOCALNET
        : networkName === "mainnet"
          ? ESCROW_FUNDING_MAINNET
          : ESCROW_FUNDING_TESTNET;
  await fundEscrow({
    algod: algorand.client.algod,
    funder: deployer,
    escrowAddress: escrow.address,
    amount: escrowFunding,
  });
  console.log(`Escrow funded with ${escrowFunding}µA`);

  const client = algorand.client.getAppClientById({
    appSpec,
    appId,
    defaultSender: deployer.addr,
  });
  await client.send.call({
    method: "setTreasury(address)void",
    args: [escrow.address],
    sender: deployer.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  console.log(`Treasury rotated to escrow`);

  writeEnv({ TOPUP_APP_ID: String(appId) });

  const commit = currentCommit();
  const ts = new Date().toISOString();
  const logLine = `${ts}\t${networkName}\tappId=${appId}\tappAddress=${appAddress}\tescrow=${escrow.address}\tdeployer=${deployer.addr.toString()}\tcommit=${commit}\n`;
  appendFileSync(DEPLOY_LOG, logLine);

  console.log("\nDeploy complete:");
  console.log(`  network        ${networkName}`);
  console.log(`  appId          ${appId}`);
  console.log(`  appAddress     ${appAddress}`);
  console.log(`  escrowAddress  ${escrow.address}`);
  console.log(`  deployer       ${deployer.addr.toString()}`);
  console.log(`  commit         ${commit}`);
  console.log(`\nTOPUP_APP_ID=${appId} written to .env`);
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
