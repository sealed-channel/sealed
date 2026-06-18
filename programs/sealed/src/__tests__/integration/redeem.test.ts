/**
 * G5 gate tests: redeem from zero-ALGO wallet.
 *
 *   (a) fresh 0-ALGO wallet → credits granted, account MBR seeded
 *   (b) replay same code    → revert 'BAD_CODE'
 *   (c) wallet ≥ 0.1 ALGO   → no inner-pay seed fires
 *   (d) wrong preimage      → revert 'BAD_CODE'
 *   (e) username arg passed → revert 'USERNAME_NOT_IMPL'
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { decodeUserState } from "../../lib/codec.js";
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

async function postRandomCommitment(
  denom: bigint,
): Promise<{ preimage: Uint8Array; commitment: Uint8Array }> {
  const preimage = new Uint8Array(randomBytes(16));
  const commitment = sha256(preimage);
  await postCommitment({
    algorand,
    appId: app.appId,
    admin: app.admin,
    commitment,
    denomination: denom,
  });
  return { preimage, commitment };
}

async function readCreditBox(wallet: string): Promise<Uint8Array | null> {
  const addrBytes = algosdk.decodeAddress(wallet).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(addrBytes, 2);
  try {
    const res = await algorand.client.algod
      .getApplicationBoxByName(Number(app.appId), key)
      .do();
    return new Uint8Array(res.value);
  } catch {
    return null;
  }
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping redeem integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

describe("redeem — credit grant + account MBR seed (G5)", () => {
  it("(a) fresh 0-ALGO wallet receives credits + MBR seed", async () => {
    if (!localNetUp) return;
    const { preimage } = await postRandomCommitment(50n);
    const user = algosdk.generateAccount();
    // intentionally do not fund

    await redeemAs({
      algorand,
      appId: app.appId,
      user,
      preimage,
    });

    const info = await algorand.client.algod
      .accountInformation(user.addr.toString())
      .do();
    expect(BigInt(info.amount)).toBeGreaterThanOrEqual(100_000n);

    const box = await readCreditBox(user.addr.toString());
    expect(box).not.toBeNull();
    const state = decodeUserState(box!);
    expect(state.batchCount).toBe(1);
    expect(state.batches[0].amount).toBe(50n);
  });

  it("(b) replay same code → BAD_CODE", async () => {
    if (!localNetUp) return;
    const { preimage } = await postRandomCommitment(25n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    await expect(
      redeemAs({ algorand, appId: app.appId, user, preimage }),
    ).rejects.toThrow(/BAD_CODE|assert failed/);
  });

  it("(c) wallet already funded → no seed fires (balance unchanged minus fee)", async () => {
    if (!localNetUp) return;
    const { preimage } = await postRandomCommitment(10n);
    const user = algosdk.generateAccount();
    await fundAccount(dispenser, user.addr.toString(), 500_000n);
    const beforeInfo = await algorand.client.algod
      .accountInformation(user.addr.toString())
      .do();
    const before = BigInt(beforeInfo.amount);

    await redeemAs({ algorand, appId: app.appId, user, preimage });

    const afterInfo = await algorand.client.algod
      .accountInformation(user.addr.toString())
      .do();
    const after = BigInt(afterInfo.amount);
    // Treasury fee-pools the group; pre-funded user pays no fee and gets no seed.
    expect(after).toBe(before);
  });

  it("(d) wrong preimage → BAD_CODE", async () => {
    if (!localNetUp) return;
    const user = algosdk.generateAccount();
    const bogus = new Uint8Array(randomBytes(16));
    await expect(
      redeemAs({ algorand, appId: app.appId, user, preimage: bogus }),
    ).rejects.toThrow(/BAD_CODE|assert failed/);
  });

  it("(e) redeem with username claims it atomically", async () => {
    if (!localNetUp) return;
    const { preimage } = await postRandomCommitment(5n);
    const user = algosdk.generateAccount();
    await redeemAs({
      algorand,
      appId: app.appId,
      user,
      preimage,
      username: "alice",
    });

    const box = await readCreditBox(user.addr.toString());
    expect(box).not.toBeNull();
    const state = decodeUserState(box!);
    expect(new TextDecoder().decode(state.username)).toBe("alice");
  });

  it("(f) solo redeem (no escrow group) reverts NOT_GROUP", async () => {
    if (!localNetUp) return;
    const { preimage } = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await fundAccount(dispenser, user.addr.toString(), 500_000n);

    const sp = await algorand.client.algod.getTransactionParams().do();
    const commitment = sha256(preimage);
    const commitmentBoxKey = new Uint8Array(2 + 32);
    commitmentBoxKey.set(new TextEncoder().encode("c:"), 0);
    commitmentBoxKey.set(commitment, 2);
    const pk = algosdk.decodeAddress(user.addr.toString()).publicKey;
    const userBox = new Uint8Array(2 + 32);
    userBox.set(new TextEncoder().encode("w:"), 0);
    userBox.set(pk, 2);

    const selector = new Uint8Array(
      algosdk.ABIMethod.fromSignature(
        "redeem(byte[],byte[])void",
      ).getSelector(),
    );
    const encodeBytes = (b: Uint8Array): Uint8Array => {
      const out = new Uint8Array(2 + b.length);
      new DataView(out.buffer).setUint16(0, b.length, false);
      out.set(b, 2);
      return out;
    };
    const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
      sender: user.addr,
      appIndex: Number(app.appId),
      appArgs: [selector, encodeBytes(preimage), encodeBytes(new Uint8Array())],
      boxes: [
        { appIndex: Number(app.appId), name: commitmentBoxKey },
        { appIndex: Number(app.appId), name: userBox },
      ],
      suggestedParams: { ...sp, fee: 1000, flatFee: true },
    });
    const signed = appCallTxn.signTxn(user.sk);
    await expect(
      algorand.client.algod.sendRawTransaction(signed).do(),
    ).rejects.toThrow(/NOT_GROUP|assert failed/);
  });
});
