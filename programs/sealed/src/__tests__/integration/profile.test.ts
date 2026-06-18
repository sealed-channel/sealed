/**
 * Profile readonly ABI + lib/profile.ts integration (T10).
 *
 * Covers:
 *   (a) after redeem + publishKeys: getUserProfile returns full UserState;
 *       getUserKeys returns key subset.
 *   (b) readUserProfile (raw box GET) matches ABI simulate output.
 *   (c) unknown wallet: ABI methods revert NOT_FOUND; readUserProfile → null.
 *   (d) fetchFullProfile happy path with mock indexer.
 *   (e) fetchFullProfile hash mismatch → throws PQ_HASH_MISMATCH.
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { readFileSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import { decodeUserState } from "../../lib/codec.js";
import { fetchFullProfile, readUserProfile } from "../../lib/profile.js";
import { publishKeys } from "../../lib/pq.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { redeemAs } from "../../scripts/redeem-as.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");

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

function appClient(sender: algosdk.Account) {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  algorand.setSignerFromAccount(sender);
  return algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: sender.addr,
  });
}

async function callGetUserProfile(
  caller: algosdk.Account,
  wallet: string,
): Promise<unknown> {
  const client = appClient(caller);
  const result = await client.send.call({
    method:
      "getUserProfile(address)(uint8,byte[],uint8,(uint64,uint64)[],byte[32],byte[32],byte[32],byte[])",
    args: [wallet],
    boxReferences: [userBoxKey(wallet)],
    sender: caller.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  return result.return;
}

async function callGetUserKeys(
  caller: algosdk.Account,
  wallet: string,
): Promise<unknown> {
  const client = appClient(caller);
  const result = await client.send.call({
    method: "getUserKeys(address)(byte[32],byte[32],byte[32])",
    args: [wallet],
    boxReferences: [userBoxKey(wallet)],
    sender: caller.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  return result.return;
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping profile integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

async function setupUserWithKeys(
  denom: bigint,
  pq: Uint8Array,
): Promise<{
  user: algosdk.Account;
  enc: Uint8Array;
  scan: Uint8Array;
}> {
  const preimage = await postRandomCommitment(denom);
  const user = algosdk.generateAccount();
  await redeemAs({ algorand, appId: app.appId, user, preimage });
  await fundAccount(dispenser, user.addr.toString(), 200_000n);
  const enc = new Uint8Array(randomBytes(32));
  const scan = new Uint8Array(randomBytes(32));
  await publishKeys({
    algorand,
    appId: app.appId,
    sender: user,
    encryptionPubkey: enc,
    scanPubkey: scan,
    pqPubkey: pq,
  });
  return { user, enc, scan };
}

describe("profile — readonly ABI + lib/profile (T10)", () => {
  it("(a) getUserProfile + getUserKeys return on-chain state after publishKeys", async () => {
    if (!localNetUp) return;
    const pq = new Uint8Array(randomBytes(96));
    const { user, enc, scan } = await setupUserWithKeys(5n, pq);

    const toU8 = (v: Uint8Array | ArrayLike<number>): Uint8Array =>
      v instanceof Uint8Array ? v : Uint8Array.from(v);
    const asTuple = (ret: unknown): unknown[] => {
      if (Array.isArray(ret)) return ret;
      if (ret && typeof ret === "object")
        return Object.values(ret as Record<string, unknown>);
      throw new Error("UNEXPECTED_RETURN_SHAPE");
    };

    const prof = asTuple(
      await callGetUserProfile(user, user.addr.toString()),
    ) as [
      number | bigint,
      Uint8Array | ArrayLike<number>,
      number | bigint,
      [bigint, bigint][],
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
    ];
    expect(Number(prof[0])).toBe(3); // version
    expect(toU8(prof[1]).length).toBe(0); // username empty
    expect(Number(prof[2])).toBe(1); // batchCount
    expect(prof[3][0][0]).toBe(4n); // batch amount: redeemed 5, publishKeys spent 1
    expect(toU8(prof[4])).toEqual(enc);
    expect(toU8(prof[5])).toEqual(scan);
    expect(toU8(prof[6])).toEqual(sha256(pq));
    expect(toU8(prof[7]).length).toBe(0); // bio empty

    const keys = asTuple(await callGetUserKeys(user, user.addr.toString())) as [
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
    ];
    expect(toU8(keys[0])).toEqual(enc);
    expect(toU8(keys[1])).toEqual(scan);
    expect(toU8(keys[2])).toEqual(sha256(pq));
  });

  it("(b) readUserProfile matches raw box decode + ABI return", async () => {
    if (!localNetUp) return;
    const pq = new Uint8Array(randomBytes(128));
    const { user, enc, scan } = await setupUserWithKeys(2n, pq);

    const prof = await readUserProfile(
      algorand.client.algod,
      app.appId,
      user.addr.toString(),
    );
    expect(prof).not.toBeNull();
    expect(prof!.encryptionPubkey).toEqual(enc);
    expect(prof!.scanPubkey).toEqual(scan);
    expect(prof!.pqPubkeyHash).toEqual(sha256(pq));

    // Cross-check raw box decode matches publishKeys-written state.
    const res = await algorand.client.algod
      .getApplicationBoxByName(
        Number(app.appId),
        userBoxKey(user.addr.toString()),
      )
      .do();
    const rawBox = new Uint8Array(res.value);
    expect(decodeUserState(rawBox)).toMatchObject({
      encryptionPubkey: enc,
      scanPubkey: scan,
      pqPubkeyHash: sha256(pq),
    });

    // ABI return decodes to the same key triple (shape may differ struct↔tuple).
    const asTuple = (ret: unknown): unknown[] => {
      if (Array.isArray(ret)) return ret;
      if (ret && typeof ret === "object")
        return Object.values(ret as Record<string, unknown>);
      throw new Error("UNEXPECTED_RETURN_SHAPE");
    };
    const abiArr = asTuple(
      await callGetUserProfile(user, user.addr.toString()),
    );
    const toU8 = (v: unknown): Uint8Array =>
      v instanceof Uint8Array ? v : Uint8Array.from(v as ArrayLike<number>);
    expect(toU8(abiArr[4])).toEqual(enc);
    expect(toU8(abiArr[5])).toEqual(scan);
    expect(toU8(abiArr[6])).toEqual(sha256(pq));
  });

  it("(c) unknown wallet: ABI reverts NOT_FOUND, readUserProfile returns null", async () => {
    if (!localNetUp) return;
    const ghost = algosdk.generateAccount();
    await expect(
      callGetUserProfile(dispenser, ghost.addr.toString()),
    ).rejects.toThrow(/NOT_FOUND|assert failed/);
    await expect(
      callGetUserKeys(dispenser, ghost.addr.toString()),
    ).rejects.toThrow(/NOT_FOUND|assert failed/);
    const prof = await readUserProfile(
      algorand.client.algod,
      app.appId,
      ghost.addr.toString(),
    );
    expect(prof).toBeNull();
  });

  it("(d) fetchFullProfile happy path with mock indexer serves matching pq pubkey", async () => {
    if (!localNetUp) return;
    const pq = new Uint8Array(randomBytes(256));
    const { user } = await setupUserWithKeys(1n, pq);

    const fakeFetch: typeof fetch = async () =>
      new Response(pq, {
        status: 200,
        headers: { "content-type": "application/octet-stream" },
      });
    const full = await fetchFullProfile({
      algod: algorand.client.algod,
      indexerBaseUrl: "http://mock.local",
      appId: app.appId,
      wallet: user.addr.toString(),
      fetchImpl: fakeFetch,
    });
    expect(full.pqPubkey).toEqual(pq);
    expect(full.pqPubkeyHash).toEqual(sha256(pq));
  });

  it("(e) fetchFullProfile hash mismatch reverts PQ_HASH_MISMATCH", async () => {
    if (!localNetUp) return;
    const pq = new Uint8Array(randomBytes(64));
    const { user } = await setupUserWithKeys(1n, pq);

    const tampered = new Uint8Array(pq);
    tampered[0] ^= 0xff;
    const fakeFetch: typeof fetch = async () =>
      new Response(tampered, { status: 200 });
    await expect(
      fetchFullProfile({
        algod: algorand.client.algod,
        indexerBaseUrl: "http://mock.local",
        appId: app.appId,
        wallet: user.addr.toString(),
        fetchImpl: fakeFetch,
      }),
    ).rejects.toThrow(/PQ_HASH_MISMATCH/);
  });
});
