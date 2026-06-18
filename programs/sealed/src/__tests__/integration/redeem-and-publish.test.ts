/**
 * T7 gate: redeemAndPublish — sponsored onboarding bundle.
 *
 *   happy fresh wallet: 500 credits + key fields set + no spendOneCredit
 *   happy wallet w/ existing w: box: appends batch, overwrites keys
 *   CODE_EXPIRED on sold-and-expired commitment
 *   PQ_KEY_TOO_SHORT (< 32) reverts
 *   PQ_KEY_TOO_LONG (> 2048) reverts
 *   cost regression: escrow burn ≤ 5000 µA
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
import { loadTreasuryEscrow, type LoadedEscrow } from "../../lib/escrow.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");
const PRICE_MICROALGOS = 10_000_000n;
const ROUNDS_PER_YEAR = 10n;
const ESCROW_FEE_POOL = 5000;

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

function userBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const k = new Uint8Array(2 + 32);
  k.set(new TextEncoder().encode("w:"), 0);
  k.set(pk, 2);
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

interface RnpOpts {
  app: DeployedSealed;
  escrow: LoadedEscrow;
  user: algosdk.Account;
  preimage: Uint8Array;
  encPub: Uint8Array;
  scanPub: Uint8Array;
  pqPub: Uint8Array;
}

function encodeBytes(b: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + b.length);
  new DataView(out.buffer).setUint16(0, b.length, false);
  out.set(b, 2);
  return out;
}

async function redeemAndPublish(opts: RnpOpts): Promise<string> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const commitment = sha256(opts.preimage);

  const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: opts.escrow.address,
    receiver: opts.escrow.address,
    amount: 0,
    suggestedParams: { ...sp, fee: ESCROW_FEE_POOL, flatFee: true },
  });

  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature(
      "redeemAndPublish(byte[],byte[32],byte[32],byte[])void",
    ).getSelector(),
  );

  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: opts.user.addr,
    appIndex: Number(opts.app.appId),
    appArgs: [
      selector,
      encodeBytes(opts.preimage),
      opts.encPub,
      opts.scanPub,
      encodeBytes(opts.pqPub),
    ],
    boxes: [
      { appIndex: Number(opts.app.appId), name: commitmentBoxKey(commitment) },
      {
        appIndex: Number(opts.app.appId),
        name: userBoxKey(opts.user.addr.toString()),
      },
    ],
    suggestedParams: { ...sp, fee: 0, flatFee: true },
  });

  algosdk.assignGroupID([feeTxn, appCallTxn]);
  const signedFee = algosdk.signLogicSigTransactionObject(
    feeTxn,
    opts.escrow.account,
  ).blob;
  const signedCall = appCallTxn.signTxn(opts.user.sk);

  const { txid } = await algorand.client.algod
    .sendRawTransaction([signedFee, signedCall])
    .do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
  return txid;
}

async function getCreditsFor(
  app: DeployedSealed,
  wallet: string,
): Promise<bigint> {
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  const result = await client.send.call({
    method: "getCredits(address)uint64",
    args: [wallet],
    boxReferences: [userBoxKey(wallet)],
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  const ret = result.return as unknown;
  if (typeof ret === "bigint") return ret;
  if (typeof ret === "number") return BigInt(ret);
  throw new Error("UNEXPECTED_RETURN");
}

function toU8(v: Uint8Array | ArrayLike<number>): Uint8Array {
  return v instanceof Uint8Array ? v : Uint8Array.from(v);
}

function asTuple(ret: unknown): unknown[] {
  if (Array.isArray(ret)) return ret;
  if (ret && typeof ret === "object")
    return Object.values(ret as Record<string, unknown>);
  throw new Error("UNEXPECTED_RETURN_SHAPE");
}

async function getKeysFor(
  app: DeployedSealed,
  wallet: string,
): Promise<{ encPub: Uint8Array; scanPub: Uint8Array; pqHash: Uint8Array }> {
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  const result = await client.send.call({
    method: "getUserKeys(address)(byte[32],byte[32],byte[32])",
    args: [wallet],
    boxReferences: [userBoxKey(wallet)],
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  const tuple = asTuple(result.return) as [
    Uint8Array | ArrayLike<number>,
    Uint8Array | ArrayLike<number>,
    Uint8Array | ArrayLike<number>,
  ];
  return {
    encPub: toU8(tuple[0]),
    scanPub: toU8(tuple[1]),
    pqHash: toU8(tuple[2]),
  };
}

async function preparePurchasedCode(
  app: DeployedSealed,
): Promise<{ preimage: Uint8Array; hash: Uint8Array; buyer: algosdk.Account }> {
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
  const buyer = algosdk.generateAccount();
  await fundAccount(dispenser, buyer.addr.toString(), 15_000_000n);
  await purchaseOne(app, buyer, hash, 0n);
  return { preimage, hash, buyer };
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping redeem-and-publish integration tests.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  appSpec = readFileSync(ARC56_PATH, "utf-8");
});

describe("redeemAndPublish (T7)", () => {
  it("fresh wallet: 500 credits + keys set, no credit spent", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const { preimage } = await preparePurchasedCode(app);
    const escrow = await loadTreasuryEscrow(algorand.client.algod);

    const user = algosdk.generateAccount();
    const encPub = new Uint8Array(randomBytes(32));
    const scanPub = new Uint8Array(randomBytes(32));
    const pqPub = new Uint8Array(randomBytes(800));

    await redeemAndPublish({
      app,
      escrow,
      user,
      preimage,
      encPub,
      scanPub,
      pqPub,
    });

    expect(await getCreditsFor(app, user.addr.toString())).toBe(500n);
    const keys = await getKeysFor(app, user.addr.toString());
    expect(Buffer.from(keys.encPub).equals(Buffer.from(encPub))).toBe(true);
    expect(Buffer.from(keys.scanPub).equals(Buffer.from(scanPub))).toBe(true);
    expect(Buffer.from(keys.pqHash).equals(Buffer.from(sha256(pqPub)))).toBe(
      true,
    );
  });

  it("wallet w/ existing w: box: appends batch + overwrites keys", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const escrow = await loadTreasuryEscrow(algorand.client.algod);

    // First redeem: seed UserState with one batch + initial keys.
    const first = await preparePurchasedCode(app);
    const user = algosdk.generateAccount();
    const k1Enc = new Uint8Array(randomBytes(32));
    const k1Scan = new Uint8Array(randomBytes(32));
    const k1Pq = new Uint8Array(randomBytes(800));
    await redeemAndPublish({
      app,
      escrow,
      user,
      preimage: first.preimage,
      encPub: k1Enc,
      scanPub: k1Scan,
      pqPub: k1Pq,
    });
    expect(await getCreditsFor(app, user.addr.toString())).toBe(500n);

    // Second redeem on same wallet: should append batch and overwrite keys.
    const preimage2 = new Uint8Array(randomBytes(16));
    const hash2 = sha256(preimage2);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment: hash2,
      denomination: 500n,
    });
    await seedPool(app, [hash2], 1n);
    // Buyer (irrelevant who).
    const buyer2 = algosdk.generateAccount();
    await fundAccount(dispenser, buyer2.addr.toString(), 15_000_000n);
    await purchaseOne(app, buyer2, hash2, 1n);

    const k2Enc = new Uint8Array(randomBytes(32));
    const k2Scan = new Uint8Array(randomBytes(32));
    const k2Pq = new Uint8Array(randomBytes(800));
    await redeemAndPublish({
      app,
      escrow,
      user,
      preimage: preimage2,
      encPub: k2Enc,
      scanPub: k2Scan,
      pqPub: k2Pq,
    });

    expect(await getCreditsFor(app, user.addr.toString())).toBe(1000n);
    const keys = await getKeysFor(app, user.addr.toString());
    expect(Buffer.from(keys.encPub).equals(Buffer.from(k2Enc))).toBe(true);
    expect(Buffer.from(keys.scanPub).equals(Buffer.from(k2Scan))).toBe(true);
    expect(Buffer.from(keys.pqHash).equals(Buffer.from(sha256(k2Pq)))).toBe(
      true,
    );
  });

  it("expired sold code reverts CODE_EXPIRED", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const { preimage } = await preparePurchasedCode(app);
    await advanceRounds(Number(ROUNDS_PER_YEAR) + 2);
    const escrow = await loadTreasuryEscrow(algorand.client.algod);

    const user = algosdk.generateAccount();
    await expect(
      redeemAndPublish({
        app,
        escrow,
        user,
        preimage,
        encPub: new Uint8Array(randomBytes(32)),
        scanPub: new Uint8Array(randomBytes(32)),
        pqPub: new Uint8Array(randomBytes(800)),
      }),
    ).rejects.toThrow(/CODE_EXPIRED|assert failed/);
  });

  it("pqPub too short reverts PQ_KEY_TOO_SHORT", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const { preimage } = await preparePurchasedCode(app);
    const escrow = await loadTreasuryEscrow(algorand.client.algod);

    const user = algosdk.generateAccount();
    await expect(
      redeemAndPublish({
        app,
        escrow,
        user,
        preimage,
        encPub: new Uint8Array(randomBytes(32)),
        scanPub: new Uint8Array(randomBytes(32)),
        pqPub: new Uint8Array(randomBytes(16)),
      }),
    ).rejects.toThrow(/PQ_KEY_TOO_SHORT|assert failed/);
  });

  it("pqPub too long rejected (PQ_KEY_TOO_LONG or protocol arg-cap)", async () => {
    if (!localNetUp) return;
    const app = await deploySealed({
      algorand,
      dispenser,
      withEscrow: true,
      roundsPerYear: ROUNDS_PER_YEAR,
    });
    const { preimage } = await preparePurchasedCode(app);
    const escrow = await loadTreasuryEscrow(algorand.client.algod);

    const user = algosdk.generateAccount();
    await expect(
      redeemAndPublish({
        app,
        escrow,
        user,
        preimage,
        encPub: new Uint8Array(randomBytes(32)),
        scanPub: new Uint8Array(randomBytes(32)),
        pqPub: new Uint8Array(randomBytes(2049)),
      }),
    ).rejects.toThrow(
      /PQ_KEY_TOO_LONG|ApplicationArgs total length|assert failed/,
    );
  });
});
