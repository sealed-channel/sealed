/**
 * On-chain MiMC Tornado `deposit` (SPEC-onchain-mimc-tornado §3).
 *
 *   (a) canonical leaf in [pay, deposit] group → mN==1, mR advances from zeros[16]
 *   (b) two deposits → mN==2, root advances each time; matches JS-ref tree root
 *   (c) non-canonical leaf (= p) → BAD_LEAF_NONCANON
 *   (d) wrong pay amount (9999 not 10000) → BAD_AMOUNT
 *
 * `deposit` is the buyer-signed 2-txn group [pay price → app, appcall deposit],
 * deposit at groupIndex 1. Box refs: "mfs","mqr". No proofs needed.
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import { mimcBN254, P as FR_MOD } from "../../../../../circuits/test/mimc-bn254-ref.mjs";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");

const PRICE = 10_000n;
const DENOM = 500n;
const HEIGHT = 16;

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let localNetUp = false;

// ---------- MiMC JS reference (matches contract mimcNode / mimcZero) ----------
function bigintTo32BE(x: bigint): Uint8Array {
  if (x < 0n || x >= FR_MOD) throw new Error(`out of range: ${x}`);
  const b = new Uint8Array(32);
  let v = x;
  for (let i = 31; i >= 0; i--) {
    b[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return b;
}
function be32ToBigint(buf: Uint8Array): bigint {
  let v = 0n;
  for (const byte of buf) v = (v << 8n) | BigInt(byte);
  return v;
}
function mimc1(a: bigint): bigint {
  return be32ToBigint(mimcBN254(bigintTo32BE(a)));
}
function mimc2(a: bigint, b: bigint): bigint {
  const c = new Uint8Array(64);
  c.set(bigintTo32BE(a), 0);
  c.set(bigintTo32BE(b), 32);
  return be32ToBigint(mimcBN254(c));
}
const zeros: bigint[] = [0n];
for (let i = 0; i < HEIGHT; i++) zeros.push(mimc2(zeros[i], zeros[i]));

// JS-ref incremental-tree root after inserting `leaves` (in order, from index 0).
function refRoot(leaves: bigint[]): bigint {
  const filled: bigint[] = new Array(HEIGHT).fill(0n);
  let root = zeros[HEIGHT];
  leaves.forEach((leaf, index) => {
    let cur = leaf;
    let idx = index;
    for (let level = 0; level < HEIGHT; level++) {
      if ((idx & 1) === 0) {
        filled[level] = cur;
        cur = mimc2(cur, zeros[level]);
      } else {
        cur = mimc2(filled[level], cur);
      }
      idx = idx >> 1;
    }
    root = cur;
  });
  return root;
}

// ---------- helpers ----------
function boxName(prefix: string): Uint8Array {
  return new TextEncoder().encode(prefix);
}

async function fundAccount(receiver: string, amount: bigint): Promise<void> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: dispenser.addr,
    receiver,
    amount: Number(amount),
    suggestedParams: sp,
  });
  const signed = txn.signTxn(dispenser.sk);
  const { txid } = await algorand.client.algod.sendRawTransaction(signed).do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
}

async function initMimcTree(
  app: DeployedSealed,
  denomination: bigint,
): Promise<void> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  await client.send.call({
    method: "initMimcTree(uint64)void",
    args: [denomination],
    boxReferences: [boxName("mfs"), boxName("mqr")],
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(3000n),
    note: new Uint8Array(randomBytes(8)),
  });
}

// 2-txn group [pay → app, deposit], both signed by `buyer`. deposit at index 1.
async function deposit(
  app: DeployedSealed,
  buyer: algosdk.Account,
  leaf: Uint8Array,
  payAmount: bigint = PRICE,
): Promise<string> {
  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature("deposit(byte[32])void").getSelector(),
  );
  const sp = await algorand.client.algod.getTransactionParams().do();

  const payTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: buyer.addr,
    receiver: app.appAddress,
    amount: Number(payAmount),
    suggestedParams: { ...sp, fee: 1000, flatFee: true },
  });
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: buyer.addr,
    appIndex: Number(app.appId),
    appArgs: [selector, leaf],
    boxes: [
      { appIndex: Number(app.appId), name: boxName("mfs") },
      { appIndex: Number(app.appId), name: boxName("mqr") },
    ],
    suggestedParams: { ...sp, fee: 40_000, flatFee: true },
    note: new Uint8Array(randomBytes(8)),
  });

  algosdk.assignGroupID([payTxn, appCallTxn]);
  const signedPay = payTxn.signTxn(buyer.sk);
  const signedCall = appCallTxn.signTxn(buyer.sk);
  const { txid } = await algorand.client.algod
    .sendRawTransaction([signedPay, signedCall])
    .do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
  return txid;
}

interface Globals {
  mN: bigint;
  mR: Uint8Array;
  mD: bigint;
}
async function readGlobals(appId: bigint): Promise<Globals> {
  const info = await algorand.client.algod.getApplicationByID(Number(appId)).do();
  const kvs = info.params.globalState ?? [];
  const out: Partial<Globals> = {};
  for (const kv of kvs) {
    const key = Buffer.from(kv.key as unknown as Uint8Array).toString("utf-8");
    if (key === "mN") out.mN = BigInt(kv.value.uint as bigint);
    if (key === "mD") out.mD = BigInt(kv.value.uint as bigint);
    if (key === "mR") out.mR = new Uint8Array(kv.value.bytes as Uint8Array);
  }
  return out as Globals;
}

async function freshBuyer(): Promise<algosdk.Account> {
  const acct = algosdk.generateAccount();
  await fundAccount(acct.addr.toString(), 5_000_000n);
  return acct;
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping deposit tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
}, 60_000);

describe("deposit — on-chain MiMC tree insert", () => {
  it("(a) canonical leaf inserts → mN==1, root advances from zeros[16]", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      initialPrice: PRICE,
    });
    await initMimcTree(app, DENOM);

    const before = await readGlobals(app.appId);
    expect(before.mN).toBe(0n);
    expect(before.mD).toBe(DENOM);
    expect(be32ToBigint(before.mR)).toBe(zeros[HEIGHT]); // empty tree root

    const buyer = await freshBuyer();
    const preimage = be32ToBigint(randomBytes(31)) % FR_MOD; // < p
    const leaf = mimc1(preimage);
    await deposit(app, buyer, bigintTo32BE(leaf));

    const after = await readGlobals(app.appId);
    expect(after.mN).toBe(1n);
    expect(be32ToBigint(after.mR)).not.toBe(zeros[HEIGHT]);
    // strong assertion: on-chain root == JS-ref leftmost-leaf root
    expect(be32ToBigint(after.mR)).toBe(refRoot([leaf]));
  }, 90_000);

  it("(b) two deposits → mN==2, root advances and matches JS-ref each time", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      initialPrice: PRICE,
    });
    await initMimcTree(app, DENOM);

    const leaf0 = mimc1((be32ToBigint(randomBytes(31)) % FR_MOD) + 1n);
    const leaf1 = mimc1((be32ToBigint(randomBytes(31)) % FR_MOD) + 7n);

    const b0 = await freshBuyer();
    await deposit(app, b0, bigintTo32BE(leaf0));
    const g1 = await readGlobals(app.appId);
    expect(g1.mN).toBe(1n);
    expect(be32ToBigint(g1.mR)).toBe(refRoot([leaf0]));

    const b1 = await freshBuyer();
    await deposit(app, b1, bigintTo32BE(leaf1));
    const g2 = await readGlobals(app.appId);
    expect(g2.mN).toBe(2n);
    expect(be32ToBigint(g2.mR)).toBe(refRoot([leaf0, leaf1]));
    expect(be32ToBigint(g2.mR)).not.toBe(be32ToBigint(g1.mR));
  }, 120_000);

  it("(c) non-canonical leaf (= p) reverts BAD_LEAF_NONCANON", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      initialPrice: PRICE,
    });
    await initMimcTree(app, DENOM);

    const buyer = await freshBuyer();
    // 32B big-endian encoding of the Fr modulus p — value >= p, rejected.
    const pBytes = new Uint8Array(32);
    let v = FR_MOD;
    for (let i = 31; i >= 0; i--) {
      pBytes[i] = Number(v & 0xffn);
      v >>= 8n;
    }
    await expect(
      deposit(app, buyer, pBytes),
    ).rejects.toThrow(/BAD_LEAF_NONCANON|assert/);
  }, 90_000);

  it("(d) wrong payment amount reverts BAD_AMOUNT", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      initialPrice: PRICE,
    });
    await initMimcTree(app, DENOM);

    const buyer = await freshBuyer();
    const leaf = mimc1(be32ToBigint(randomBytes(31)) % FR_MOD);
    await expect(
      deposit(app, buyer, bigintTo32BE(leaf), PRICE - 1n),
    ).rejects.toThrow(/BAD_AMOUNT|NOT_GROUP|assert/);
  }, 90_000);
});
