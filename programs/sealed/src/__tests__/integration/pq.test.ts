/**
 * publishKeys universal-escrow tests (Phase 3b — T18).
 *
 *   (a) redeemed user publishKeys via escrow group → keys written, 1 credit spent
 *   (b) re-publish overwrites keys; another credit spent
 *   (c) no-redeem user publishKeys → reverts NO_CREDITS
 *   (d) solo app call (no escrow group) → reverts NOT_GROUP
 *   (e) pq pubkey 31B → PQ_KEY_TOO_SHORT
 *   (f) pq pubkey 2049B → PQ_KEY_TOO_LONG
 *   (g) KeysPublished event log present + parses + sha256(pq) == anchor
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { decodeUserState, ZERO_KEY } from "../../lib/codec.js";
import { publishKeys } from "../../lib/pq.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { redeemAs } from "../../scripts/redeem-as.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let localNetUp = false;

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

function userBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  return key;
}

async function readUserBox(wallet: string): Promise<Uint8Array | null> {
  try {
    const res = await algorand.client.algod
      .getApplicationBoxByName(Number(app.appId), userBoxKey(wallet))
      .do();
    return new Uint8Array(res.value);
  } catch {
    return null;
  }
}

async function postRandomCommitment(denom: bigint): Promise<Uint8Array> {
  const preimage = new Uint8Array(randomBytes(16));
  const commitment = sha256(preimage);
  await postCommitment({
    algorand,
    appId: app.appId,
    admin: app.admin,
    commitment,
    denomination: denom,
  });
  return preimage;
}

function keysPublishedSelector(): Uint8Array {
  const sig = "KeysPublished(address,byte[32],byte[32],byte[],byte[32])";
  const hash = createHash("sha512-256").update(sig).digest();
  return new Uint8Array(hash.subarray(0, 4));
}

function findEventLog(
  logs: Uint8Array[] | undefined,
  prefix: Uint8Array,
): Uint8Array | null {
  if (!logs) return null;
  for (const log of logs) {
    if (log.length < 4) continue;
    let match = true;
    for (let i = 0; i < 4; i++)
      if (log[i] !== prefix[i]) {
        match = false;
        break;
      }
    if (match) return log.slice(4);
  }
  return null;
}

const KEYS_PUBLISHED_TYPE = algosdk.ABIType.from(
  "(address,byte[32],byte[32],byte[],byte[32])",
);

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping pq integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

describe("publishKeys — escrow group + credit-gate (T18)", () => {
  it("(a) redeemed user publishKeys writes keys + spends 1 credit", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(5n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    const enc = new Uint8Array(randomBytes(32));
    const scan = new Uint8Array(randomBytes(32));
    const pq = new Uint8Array(randomBytes(800));
    const result = await publishKeys({
      algorand,
      appId: app.appId,
      sender: user,
      encryptionPubkey: enc,
      scanPubkey: scan,
      pqPubkey: pq,
    });
    expect(result.txIds.length).toBe(2);

    const box = await readUserBox(user.addr.toString());
    expect(box).not.toBeNull();
    const state = decodeUserState(box!);
    expect(state.encryptionPubkey).toEqual(enc);
    expect(state.scanPubkey).toEqual(scan);
    expect(state.pqPubkeyHash).toEqual(sha256(pq));
    // 5 credits → 1 spent → 4 remain.
    expect(state.batches[0].amount).toBe(4n);
  });

  it("(b) re-publish overwrites keys + spends another credit", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(3n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    const enc1 = new Uint8Array(randomBytes(32));
    const scan1 = new Uint8Array(randomBytes(32));
    const pq1 = new Uint8Array(randomBytes(64));
    await publishKeys({
      algorand,
      appId: app.appId,
      sender: user,
      encryptionPubkey: enc1,
      scanPubkey: scan1,
      pqPubkey: pq1,
    });

    const enc2 = new Uint8Array(randomBytes(32));
    const scan2 = new Uint8Array(randomBytes(32));
    const pq2 = new Uint8Array(randomBytes(64));
    await publishKeys({
      algorand,
      appId: app.appId,
      sender: user,
      encryptionPubkey: enc2,
      scanPubkey: scan2,
      pqPubkey: pq2,
    });

    const state = decodeUserState((await readUserBox(user.addr.toString()))!);
    expect(state.encryptionPubkey).toEqual(enc2);
    expect(state.scanPubkey).toEqual(scan2);
    expect(state.pqPubkeyHash).toEqual(sha256(pq2));
    // 3 credits → 2 spent → 1 remains.
    expect(state.batches[0].amount).toBe(1n);
  });

  it("(c) user with no credits publishKeys reverts NO_CREDITS", async () => {
    if (!localNetUp) return;
    const user = algosdk.generateAccount();
    await expect(
      publishKeys({
        algorand,
        appId: app.appId,
        sender: user,
        encryptionPubkey: new Uint8Array(randomBytes(32)),
        scanPubkey: new Uint8Array(randomBytes(32)),
        pqPubkey: new Uint8Array(randomBytes(64)),
      }),
    ).rejects.toThrow(/NO_CREDITS|assert failed/);
  });

  it("(d) solo app call (no escrow group) reverts NOT_GROUP", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });
    // Top up so user can pay solo fee.
    const sp0 = await algorand.client.algod.getTransactionParams().do();
    const topup = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: dispenser.addr,
      receiver: user.addr,
      amount: 500_000,
      suggestedParams: sp0,
    });
    const signedT = topup.signTxn(dispenser.sk);
    const { txid: tid } = await algorand.client.algod
      .sendRawTransaction(signedT)
      .do();
    await algosdk.waitForConfirmation(algorand.client.algod, tid, 4);

    const sp = await algorand.client.algod.getTransactionParams().do();
    const method = new algosdk.ABIMethod({
      name: "publishKeys",
      args: [
        { name: "encryptionPubkey", type: "byte[32]" },
        { name: "scanPubkey", type: "byte[32]" },
        { name: "pqPubkey", type: "byte[]" },
      ],
      returns: { type: "void" },
    });
    const enc = new Uint8Array(32);
    const scan = new Uint8Array(32);
    const pq = new Uint8Array(64);
    const pqBytes = new Uint8Array(2 + pq.length);
    new DataView(pqBytes.buffer).setUint16(0, pq.length, false);
    pqBytes.set(pq, 2);
    const solo = algosdk.makeApplicationNoOpTxnFromObject({
      sender: user.addr,
      appIndex: Number(app.appId),
      appArgs: [new Uint8Array(method.getSelector()), enc, scan, pqBytes],
      boxes: [
        { appIndex: Number(app.appId), name: userBoxKey(user.addr.toString()) },
      ],
      suggestedParams: { ...sp, fee: 1000, flatFee: true },
    });
    const signed = solo.signTxn(user.sk);
    await expect(
      algorand.client.algod.sendRawTransaction(signed).do(),
    ).rejects.toThrow(/NOT_GROUP|assert failed/);
  });

  it("(e) pq pubkey 31B reverts PQ_KEY_TOO_SHORT", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });
    await expect(
      publishKeys({
        algorand,
        appId: app.appId,
        sender: user,
        encryptionPubkey: new Uint8Array(randomBytes(32)),
        scanPubkey: new Uint8Array(randomBytes(32)),
        pqPubkey: new Uint8Array(randomBytes(31)),
      }),
    ).rejects.toThrow(/PQ_KEY_TOO_SHORT/);
  });

  it("(f) pq pubkey 2049B reverts PQ_KEY_TOO_LONG", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });
    await expect(
      publishKeys({
        algorand,
        appId: app.appId,
        sender: user,
        encryptionPubkey: new Uint8Array(randomBytes(32)),
        scanPubkey: new Uint8Array(randomBytes(32)),
        pqPubkey: new Uint8Array(randomBytes(2049)),
      }),
    ).rejects.toThrow(/PQ_KEY_TOO_LONG/);
  });

  it("(g) KeysPublished event log present; sha256(pq) matches on-chain anchor", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });
    const enc = new Uint8Array(randomBytes(32));
    const scan = new Uint8Array(randomBytes(32));
    const pq = new Uint8Array(randomBytes(128));
    const result = await publishKeys({
      algorand,
      appId: app.appId,
      sender: user,
      encryptionPubkey: enc,
      scanPubkey: scan,
      pqPubkey: pq,
    });

    const conf = await algorand.client.algod
      .pendingTransactionInformation(result.txId)
      .do();
    const logs = (conf.logs ?? []).map((l: Uint8Array | string) =>
      typeof l === "string"
        ? new Uint8Array(Buffer.from(l, "base64"))
        : new Uint8Array(l),
    );
    const body = findEventLog(logs, keysPublishedSelector());
    expect(body).not.toBeNull();

    const tuple = KEYS_PUBLISHED_TYPE.decode(body!) as [
      string,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
    ];
    const toU8 = (v: Uint8Array | ArrayLike<number>): Uint8Array =>
      v instanceof Uint8Array ? v : Uint8Array.from(v);
    const [walletAddr, encOut, scanOut, pqOut, hashOut] = tuple;
    expect(walletAddr).toBe(user.addr.toString());
    expect(toU8(encOut)).toEqual(enc);
    expect(toU8(scanOut)).toEqual(scan);
    expect(toU8(pqOut)).toEqual(pq);
    expect(toU8(hashOut)).toEqual(sha256(pq));

    const state = decodeUserState((await readUserBox(user.addr.toString()))!);
    expect(state.pqPubkeyHash).toEqual(sha256(pq));
    expect(state.pqPubkeyHash).not.toEqual(ZERO_KEY);
  });
});
