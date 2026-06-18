/**
 * T4 gate: code-expiry fuse in `redeem`.
 *
 *   sold + within 1yr → redeem succeeds, credits minted
 *   sold + past 1yr   → redeem reverts CODE_EXPIRED
 *   unsold (admin-direct, soldAtRound==0) → covered by existing redeem tests
 *
 * Deploys w/ `roundsPerYear = 10` so a handful of dummy txns trip the fuse.
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
import { redeemAs } from "../../scripts/redeem-as.js";
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

async function registerAndSeedOne(
  app: DeployedSealed,
  tailStart: bigint,
): Promise<SoldPair> {
  const preimage = new Uint8Array(randomBytes(16));
  const hash = sha256(preimage);
  await postCommitment({
    algorand,
    appId: app.appId,
    admin: app.admin,
    commitment: hash,
    denomination: 500n,
  });
  await seedPool(app, [hash], tailStart);
  return { preimage, hash };
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping code-expiry integration tests.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  appSpec = readFileSync(ARC56_PATH, "utf-8");
});

describe("redeem CODE_EXPIRED fuse (T4)", () => {
  it("sold + within 1yr redeems successfully", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
    const { preimage, hash } = await registerAndSeedOne(app, 0n);
    await purchaseOne(app, buyer, hash, 0n);

    // Stay within the fuse window. Don't advance.
    const redeemer = algosdk.generateAccount();
    await fundAccount(dispenser, redeemer.addr.toString(), 500_000n);
    const { txid } = await redeemAs({
      algorand,
      appId: app.appId,
      user: redeemer,
      preimage,
    });
    expect(txid).toBeDefined();
  });

  it("sold + past 1yr reverts CODE_EXPIRED", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
    const { preimage, hash } = await registerAndSeedOne(app, 0n);
    await purchaseOne(app, buyer, hash, 0n);

    // Burn through the fuse window.
    await advanceRounds(Number(ROUNDS_PER_YEAR) + 2);

    const redeemer = algosdk.generateAccount();
    await fundAccount(dispenser, redeemer.addr.toString(), 500_000n);

    await expect(
      redeemAs({
        algorand,
        appId: app.appId,
        user: redeemer,
        preimage,
      }),
    ).rejects.toThrow(/CODE_EXPIRED|assert failed/);
  });
});
