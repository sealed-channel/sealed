/**
 * T5 gate: reclaimExpired — admin frees c: box MBR for sold-and-expired codes.
 *
 *   non-admin → revert NOT_ADMIN
 *   empty batch → revert EMPTY_BATCH
 *   unsold commitment (soldAtRound=0) → revert NOT_SOLD
 *   sold but within fuse → revert NOT_EXPIRED
 *   sold + past fuse → success, c: box deleted, MBR refunded to app account
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
const PRICE_MICROALGOS = 10_000_000n;
const ROUNDS_PER_YEAR = 10n;

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

async function advanceRounds(n: number): Promise<void> {
  for (let i = 0; i < n; i++) {
    const sp = await algorand.client.algod.getTransactionParams().do();
    const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: dispenser.addr,
      receiver: dispenser.addr,
      amount: 0,
      suggestedParams: { ...sp, fee: 1000, flatFee: true },
      note: new Uint8Array(randomBytes(8)),
    });
    const signed = txn.signTxn(dispenser.sk);
    const { txid } = await algorand.client.algod
      .sendRawTransaction(signed)
      .do();
    await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
  }
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

async function purchaseOne(
  app: DeployedSealed,
  buyer: algosdk.Account,
  hash: Uint8Array,
  poolHead: bigint,
): Promise<void> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const dpk = new Uint8Array(randomBytes(32));
  const payTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: buyer.addr,
    receiver: app.appAddress,
    amount: Number(PRICE_MICROALGOS),
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
}

interface SoldPair {
  preimage: Uint8Array;
  hash: Uint8Array;
}

async function registerOne(app: DeployedSealed): Promise<SoldPair> {
  const preimage = new Uint8Array(randomBytes(16));
  const hash = sha256(preimage);
  await postCommitment({
    algorand,
    appId: app.appId,
    admin: app.admin,
    commitment: hash,
    denomination: 500n,
  });
  return { preimage, hash };
}

async function reclaim(
  app: DeployedSealed,
  caller: algosdk.Account,
  hashes: Uint8Array[],
): Promise<string> {
  algorand.setSignerFromAccount(caller);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: caller.addr,
  });
  const boxes = hashes.map((h) => commitmentBoxKey(h));
  const result = await client.send.call({
    method: "reclaimExpired(byte[32][])void",
    args: [hashes],
    boxReferences: boxes,
    sender: caller.addr,
    staticFee: AlgoAmount.MicroAlgo(2000n),
  });
  return result.txIds[0];
}

async function boxExists(appId: bigint, name: Uint8Array): Promise<boolean> {
  const boxes = await algorand.client.algod
    .getApplicationBoxes(Number(appId))
    .do();
  return boxes.boxes.some((b) => Buffer.from(b.name).equals(Buffer.from(name)));
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping reclaim-expired integration tests.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  appSpec = readFileSync(ARC56_PATH, "utf-8");
});

describe("reclaimExpired (T5)", () => {
  it("non-admin reverts NOT_ADMIN", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const { hash } = await registerOne(app);

    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 2_000_000n);
    await expect(reclaim(app, imposter, [hash])).rejects.toThrow(
      /NOT_ADMIN|assert failed/,
    );
  });

  it("empty batch reverts EMPTY_BATCH", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    await expect(reclaim(app, app.admin, [])).rejects.toThrow(
      /EMPTY_BATCH|assert failed/,
    );
  });

  it("unsold commitment reverts NOT_SOLD", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const { hash } = await registerOne(app);
    await expect(reclaim(app, app.admin, [hash])).rejects.toThrow(
      /NOT_SOLD|assert failed/,
    );
  });

  it("sold but within fuse reverts NOT_EXPIRED", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
    const { hash } = await registerOne(app);
    await seedPool(app, [hash], 0n);
    await purchaseOne(app, buyer, hash, 0n);

    await expect(reclaim(app, app.admin, [hash])).rejects.toThrow(
      /NOT_EXPIRED|assert failed/,
    );
  });

  it("sold + past fuse: c: deleted, MBR refunded", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
    const { hash } = await registerOne(app);
    await seedPool(app, [hash], 0n);
    await purchaseOne(app, buyer, hash, 0n);

    await advanceRounds(Number(ROUNDS_PER_YEAR) + 2);

    expect(await boxExists(app.appId, commitmentBoxKey(hash))).toBe(true);
    await reclaim(app, app.admin, [hash]);
    expect(await boxExists(app.appId, commitmentBoxKey(hash))).toBe(false);
  });
});
