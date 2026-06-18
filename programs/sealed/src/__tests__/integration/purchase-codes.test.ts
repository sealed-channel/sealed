/**
 * T3 gate: purchaseCodes — buyer 2-txn group, pool consumption, stamping.
 *
 *   happy qty=1: depth shrinks, c: stamped, p: deleted, app account funded
 *   happy qty=8: max batch consumed in one call
 *   qty=0 → EMPTY_BATCH
 *   qty=9 → BATCH_TOO_LARGE or network ref-cap
 *   pool empty / qty > depth → POOL_EMPTY
 *   wrong Pay amount → BAD_AMOUNT
 *   wrong Pay receiver → BAD_RECEIVER
 *   txn 0 signed by other wallet → BAD_PAYER
 *   closeRemainderTo set → BAD_CLOSE
 *   rekeyTo set → BAD_REKEY
 *   all-zero deliveryPubkey → BAD_DELIVERY_PUBKEY
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

async function makeAndSeedFresh(
  n: number,
): Promise<{ app: DeployedSealed; hashes: Uint8Array[] }> {
  const app = await deploySealed({ algorand, dispenser });
  const hashes: Uint8Array[] = [];
  for (let i = 0; i < n; i++) {
    const preimage = new Uint8Array(randomBytes(16));
    const hash = sha256(preimage);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment: hash,
      denomination: 500n,
    });
    hashes.push(hash);
  }
  // Seed in batches of 4 (MAX_POOL_BATCH).
  for (let i = 0; i < hashes.length; i += 4) {
    await seedPool(app, hashes.slice(i, i + 4), BigInt(i));
  }
  return { app, hashes };
}

interface PurchaseOpts {
  app: DeployedSealed;
  buyer: algosdk.Account;
  qty: bigint;
  deliveryPubkey?: Uint8Array;
  /** Amount sent in Txn 0. Defaults to qty × PRICE. */
  payAmount?: bigint;
  /** Receiver of Txn 0. Defaults to app account. */
  payReceiver?: string;
  /** Sender of Txn 0. Defaults to buyer. */
  paySender?: algosdk.Account;
  /** Pre-pool-head index for boxRef construction. Defaults to 0. */
  poolHeadAtCall?: bigint;
  closeRemainderTo?: string;
  rekeyTo?: string;
  /** Subset of pool-head hashes for c: refs. Defaults to first qty hashes. */
  hashes?: Uint8Array[];
}

async function purchaseCodes(opts: PurchaseOpts): Promise<string> {
  const head = opts.poolHeadAtCall ?? 0n;
  const sp = await algorand.client.algod.getTransactionParams().do();
  const dpk = opts.deliveryPubkey ?? new Uint8Array(randomBytes(32));
  const amount = opts.payAmount ?? opts.qty * PRICE_MICROALGOS;
  const paySender = opts.paySender ?? opts.buyer;
  const payReceiver = opts.payReceiver ?? opts.app.appAddress;

  const payTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: paySender.addr,
    receiver: payReceiver,
    amount: Number(amount),
    closeRemainderTo: opts.closeRemainderTo,
    rekeyTo: opts.rekeyTo,
    suggestedParams: { ...sp, fee: 1000, flatFee: true },
  });

  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature(
      "purchaseCodes(uint64,byte[32])void",
    ).getSelector(),
  );
  const qtyBytes = new Uint8Array(8);
  new DataView(qtyBytes.buffer).setBigUint64(0, opts.qty, false);

  const refQty = opts.qty === 0n ? 1n : opts.qty;
  const hashesForRefs = opts.hashes ?? [];
  const appCallBoxes: { appIndex: number; name: Uint8Array }[] = [];
  for (let i = 0n; i < refQty; i++) {
    appCallBoxes.push({
      appIndex: Number(opts.app.appId),
      name: poolBoxKey(head + i),
    });
    if (hashesForRefs[Number(i)]) {
      appCallBoxes.push({
        appIndex: Number(opts.app.appId),
        name: commitmentBoxKey(hashesForRefs[Number(i)]),
      });
    }
  }

  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: opts.buyer.addr,
    appIndex: Number(opts.app.appId),
    appArgs: [selector, qtyBytes, dpk],
    boxes: appCallBoxes,
    suggestedParams: { ...sp, fee: 1000, flatFee: true },
  });

  algosdk.assignGroupID([payTxn, appCallTxn]);
  const signedPay = payTxn.signTxn(paySender.sk);
  const signedCall = appCallTxn.signTxn(opts.buyer.sk);
  const { txid } = await algorand.client.algod
    .sendRawTransaction([signedPay, signedCall])
    .do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
  return txid;
}

async function readCommitmentBox(
  appId: bigint,
  hash: Uint8Array,
): Promise<{ soldAtRound: bigint }> {
  const box = await algorand.client.algod
    .getApplicationBoxByName(Number(appId), commitmentBoxKey(hash))
    .do();
  const v = new Uint8Array(box.value);
  // Commitment struct: denomination(uint64) | postedAtRound(uint64) | soldAtRound(uint64)
  const dv = new DataView(v.buffer, v.byteOffset, v.byteLength);
  return { soldAtRound: dv.getBigUint64(16, false) };
}

async function boxExists(appId: bigint, name: Uint8Array): Promise<boolean> {
  const boxes = await algorand.client.algod
    .getApplicationBoxes(Number(appId))
    .do();
  return boxes.boxes.some((b) => Buffer.from(b.name).equals(Buffer.from(name)));
}

async function accountBalance(addr: string): Promise<bigint> {
  const info = await algorand.client.algod.accountInformation(addr).do();
  return BigInt(info.amount);
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping purchase-codes integration tests.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  appSpec = readFileSync(ARC56_PATH, "utf-8");
});

describe("purchaseCodes (T3)", () => {
  it("happy qty=1: pool shrinks, c: stamped, p: deleted, revenue lands", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(2);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);

    const appBalBefore = await accountBalance(app.appAddress);

    await purchaseCodes({
      app,
      buyer,
      qty: 1n,
      hashes: [hashes[0]],
    });

    const stamped = await readCommitmentBox(app.appId, hashes[0]);
    expect(stamped.soldAtRound).toBeGreaterThan(0n);
    expect(await boxExists(app.appId, poolBoxKey(0n))).toBe(false);
    // Second pool entry untouched.
    expect(await boxExists(app.appId, poolBoxKey(1n))).toBe(true);

    const appBalAfter = await accountBalance(app.appAddress);
    // Net delta = +PRICE (revenue) + p: MBR refund (~19_300) − OpUp fees
    // (~4× minFee from ensureBudget). Empirically lands at ~9_997_000 for
    // qty=1. Assert ≥ 99.5% of revenue captured (tolerance for OpUp tax).
    const delta = appBalAfter - appBalBefore;
    expect(delta).toBeGreaterThanOrEqual((PRICE_MICROALGOS * 995n) / 1000n);
  });

  it("happy qty=4 (max batch): all 4 popped in one call", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(4);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 50_000_000n);

    await purchaseCodes({
      app,
      buyer,
      qty: 4n,
      hashes,
    });

    for (let i = 0; i < 4; i++) {
      const stamped = await readCommitmentBox(app.appId, hashes[i]);
      expect(stamped.soldAtRound).toBeGreaterThan(0n);
      expect(await boxExists(app.appId, poolBoxKey(BigInt(i)))).toBe(false);
    }
  });

  it("qty=0 reverts EMPTY_BATCH", async () => {
    if (!localNetUp) return;
    const { app } = await makeAndSeedFresh(1);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 2_000_000n);

    await expect(
      purchaseCodes({ app, buyer, qty: 0n, payAmount: 0n }),
    ).rejects.toThrow(/EMPTY_BATCH|assert failed/);
  });

  it("qty=5 rejected (BATCH_TOO_LARGE or network ref-cap)", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(5);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 60_000_000n);

    await expect(
      purchaseCodes({ app, buyer, qty: 5n, hashes }),
    ).rejects.toThrow(/BATCH_TOO_LARGE|box references is 8|assert failed/);
  });

  it("POOL_EMPTY when qty > available depth", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(2);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 50_000_000n);

    await expect(
      purchaseCodes({ app, buyer, qty: 4n, hashes }),
    ).rejects.toThrow(/POOL_EMPTY|assert failed/);
  });

  it("BAD_AMOUNT on wrong Pay amount", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(1);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);

    await expect(
      purchaseCodes({
        app,
        buyer,
        qty: 1n,
        payAmount: 5_000_000n,
        hashes: [hashes[0]],
      }),
    ).rejects.toThrow(/BAD_AMOUNT|assert failed/);
  });

  it("BAD_RECEIVER on wrong Pay receiver", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(1);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
    const other = algosdk.generateAccount();
    await fundAccount(dispenser, other.addr.toString(), 200_000n);

    await expect(
      purchaseCodes({
        app,
        buyer,
        qty: 1n,
        payReceiver: other.addr.toString(),
        hashes: [hashes[0]],
      }),
    ).rejects.toThrow(/BAD_RECEIVER|assert failed/);
  });

  it("BAD_PAYER when txn 0 signed by other wallet", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(1);
    const buyer = algosdk.generateAccount();
    const sponsor = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 2_000_000n);
    await fundAccount(dispenser, sponsor.addr.toString(), 15_000_000n);

    await expect(
      purchaseCodes({
        app,
        buyer,
        qty: 1n,
        paySender: sponsor,
        hashes: [hashes[0]],
      }),
    ).rejects.toThrow(/BAD_PAYER|assert failed/);
  });

  it("BAD_DELIVERY_PUBKEY on all-zero pubkey", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(1);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);

    await expect(
      purchaseCodes({
        app,
        buyer,
        qty: 1n,
        deliveryPubkey: new Uint8Array(32),
        hashes: [hashes[0]],
      }),
    ).rejects.toThrow(/BAD_DELIVERY_PUBKEY|assert failed/);
  });

  it("BAD_REKEY when Pay txn has rekeyTo set", async () => {
    if (!localNetUp) return;
    const { app, hashes } = await makeAndSeedFresh(1);
    const buyer = algosdk.generateAccount();
    await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
    const someone = algosdk.generateAccount();

    await expect(
      purchaseCodes({
        app,
        buyer,
        qty: 1n,
        rekeyTo: someone.addr.toString(),
        hashes: [hashes[0]],
      }),
    ).rejects.toThrow(
      /BAD_REKEY|assert failed|rekey|should have been authorized/i,
    );
  });
});
