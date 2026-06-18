/**
 * T6 gate: setPrice — admin price-knob with bounds.
 *
 *   non-admin → revert NOT_ADMIN
 *   price < 1 ALGO → revert BAD_PRICE
 *   price > 1M ALGO → revert BAD_PRICE
 *   admin sets valid price → global updated, PriceChanged event
 *   purchase signed at stale price after change → revert BAD_AMOUNT
 *
 * Requires `algokit localnet start`.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import { postCommitment } from "../../scripts/post-commitment.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let appSpec: string;
let localNetUp = false;

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

function commitmentBoxKey(hash: Uint8Array): Uint8Array {
  const k = new Uint8Array(2 + 32);
  k.set(new TextEncoder().encode("c:"), 0);
  k.set(hash, 2);
  return k;
}

function poolBoxKey(idx: bigint): Uint8Array {
  const k = new Uint8Array(2 + 8);
  k.set(new TextEncoder().encode("p:"), 0);
  new DataView(k.buffer).setBigUint64(2, idx, false);
  return k;
}

async function fundAccount(
  funder: algosdk.Account,
  receiver: string,
  amount: bigint,
): Promise<void> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: funder.addr,
    receiver,
    amount: Number(amount),
    suggestedParams: sp,
  });
  const signed = txn.signTxn(funder.sk);
  const { txid } = await algorand.client.algod.sendRawTransaction(signed).do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
}

async function setPrice(
  app: DeployedSealed,
  caller: algosdk.Account,
  price: bigint,
): Promise<string> {
  algorand.setSignerFromAccount(caller);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: caller.addr,
  });
  const result = await client.send.call({
    method: "setPrice(uint64)void",
    args: [price],
    sender: caller.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  return result.txIds[0];
}

async function readPriceGlobal(appId: bigint): Promise<bigint> {
  const info = await algorand.client.algod
    .getApplicationByID(Number(appId))
    .do();
  const entry = info.params.globalState?.find(
    (kv) => Buffer.from(kv.key).toString() === "pr",
  );
  if (!entry) throw new Error("PRICE_GLOBAL_MISSING");
  return BigInt(entry.value.uint);
}

async function seedPool(
  app: DeployedSealed,
  hashes: Uint8Array[],
  tailStart: bigint,
): Promise<void> {
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  const boxes: Uint8Array[] = [];
  for (let i = 0; i < hashes.length; i++) {
    boxes.push(commitmentBoxKey(hashes[i]));
    boxes.push(poolBoxKey(tailStart + BigInt(i)));
  }
  await client.send.call({
    method: "seedSalePool(byte[32][])void",
    args: [hashes],
    boxReferences: boxes,
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(2000n),
  });
}

async function purchaseOneAt(
  app: DeployedSealed,
  buyer: algosdk.Account,
  hash: Uint8Array,
  payAmount: bigint,
  poolHead: bigint,
): Promise<string> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const dpk = new Uint8Array(randomBytes(32));
  const payTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: buyer.addr,
    receiver: app.appAddress,
    amount: Number(payAmount),
    suggestedParams: { ...sp, fee: 1000, flatFee: true },
  });
  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature(
      "purchaseCodes(uint64,byte[32])void",
    ).getSelector(),
  );
  const qtyBytes = new Uint8Array(8);
  new DataView(qtyBytes.buffer).setBigUint64(0, 1n, false);
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: buyer.addr,
    appIndex: Number(app.appId),
    appArgs: [selector, qtyBytes, dpk],
    boxes: [
      { appIndex: Number(app.appId), name: poolBoxKey(poolHead) },
      { appIndex: Number(app.appId), name: commitmentBoxKey(hash) },
    ],
    suggestedParams: { ...sp, fee: 1000, flatFee: true },
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

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping set-price integration tests.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  appSpec = readFileSync(ARC56_PATH, "utf-8");
});

describe("setPrice (T6)", () => {
  it("non-admin reverts NOT_ADMIN", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({ algorand, dispenser });
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 2_000_000n);
    await expect(setPrice(app, imposter, 5_000_000n)).rejects.toThrow(
      /NOT_ADMIN|assert failed/,
    );
  });

  it("below floor reverts BAD_PRICE", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({ algorand, dispenser });
    await expect(setPrice(app, app.admin, 999_999n)).rejects.toThrow(
      /BAD_PRICE|assert failed/,
    );
  });

  it("above ceiling reverts BAD_PRICE", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({ algorand, dispenser });
    await expect(setPrice(app, app.admin, 1_000_000_000_001n)).rejects.toThrow(
      /BAD_PRICE|assert failed/,
    );
  });

  it("admin sets valid price; global updated", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({ algorand, dispenser });
    expect(await readPriceGlobal(app.appId)).toBe(10_000_000n);
    await setPrice(app, app.admin, 25_000_000n);
    expect(await readPriceGlobal(app.appId)).toBe(25_000_000n);
  });

  it("purchase signed at stale price after change reverts BAD_AMOUNT", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({ algorand, dispenser });
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 50_000_000n);

    const preimage = new Uint8Array(randomBytes(16));
    const hash = sha256(preimage);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment: hash,
      denomination: 500n,
    });
    await seedPool(app, [hash], 0n);

    // Bump price 10 ALGO → 25 ALGO.
    await setPrice(app, app.admin, 25_000_000n);

    // Buyer still paying old 10 ALGO → BAD_AMOUNT.
    await expect(
      purchaseOneAt(app, buyer, hash, 10_000_000n, 0n),
    ).rejects.toThrow(/BAD_AMOUNT|assert failed/);
  });
});
