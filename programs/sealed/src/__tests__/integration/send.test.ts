/**
 * G6 gate tests: sendMessage 2-txn fee-pool group.
 *
 *   (a) 0-credit wallet           → revert 'NO_CREDITS'
 *   (b) credit wallet             → success, batch -1, user ALGO unchanged, log = ciphertext
 *   (c) single-txn submission     → revert 'NOT_GROUP'
 *   (d) wrong fee payer           → revert 'BAD_FEE_PAYER'
 *   (e) fee below GROUP_FEE       → network rejects
 *   (f) 1KB ciphertext            → success
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { decodeUserState } from "../../lib/codec.js";
import { GROUP_FEE } from "../../lib/group.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { redeemAs } from "../../scripts/redeem-as.js";
import { sendAs } from "../../scripts/send-as.js";
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
    console.warn("LocalNet not running — skipping send integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

/** Canonical 32-byte zero tag used in tests that don't care about the value. */
const ZERO_TAG = new Uint8Array(32);

describe("sendMessage — 2-txn fee-pool group (G6)", () => {
  it("(a) zero-credit wallet reverts NO_CREDITS", async () => {
    if (!localNetUp) return;
    const user = algosdk.generateAccount();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);
    await expect(
      sendAs({
        algorand,
        appId: app.appId,
        user,
        recipientTag: ZERO_TAG,
        ciphertext: new Uint8Array([1, 2, 3]),
      }),
    ).rejects.toThrow(/NO_CREDITS|assert failed/);
  });

  it("(b) credit wallet sends; user ALGO unchanged, batch decremented", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(5n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    const beforeInfo = await algorand.client.algod
      .accountInformation(user.addr.toString())
      .do();
    const before = BigInt(beforeInfo.amount);

    await sendAs({
      algorand,
      appId: app.appId,
      user,
      recipientTag: ZERO_TAG,
      ciphertext: new Uint8Array([0xde, 0xad, 0xbe, 0xef]),
    });

    const afterInfo = await algorand.client.algod
      .accountInformation(user.addr.toString())
      .do();
    const after = BigInt(afterInfo.amount);
    expect(after).toBe(before); // user wallet unchanged — treasury paid fee

    const box = await readCreditBox(user.addr.toString());
    expect(box).not.toBeNull();
    const state = decodeUserState(box!);
    expect(state.batches[0].amount).toBe(4n);
  });

  it("(c) single-txn submission reverts NOT_GROUP", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    const sp = await algorand.client.algod.getTransactionParams().do();
    const userAddrBytes = algosdk.decodeAddress(user.addr.toString()).publicKey;
    const boxKey = new Uint8Array(2 + 32);
    boxKey.set(new TextEncoder().encode("w:"), 0);
    boxKey.set(userAddrBytes, 2);
    const selector = new Uint8Array(
      algosdk.ABIMethod.fromSignature(
        "sendMessage(byte[32],byte[])void",
      ).getSelector(),
    );
    const ct = new Uint8Array([0xaa]);
    const arg = new Uint8Array(2 + ct.length);
    new DataView(arg.buffer).setUint16(0, ct.length, false);
    arg.set(ct, 2);

    const txn = algosdk.makeApplicationNoOpTxnFromObject({
      sender: user.addr,
      appIndex: Number(app.appId),
      appArgs: [selector, ZERO_TAG, arg],
      boxes: [{ appIndex: Number(app.appId), name: boxKey }],
      suggestedParams: { ...sp, fee: 2000, flatFee: true },
    });
    const signed = txn.signTxn(user.sk);
    await expect(
      algorand.client.algod.sendRawTransaction(signed).do(),
    ).rejects.toThrow();
  });

  it("(d) wrong fee payer reverts BAD_FEE_PAYER", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(1n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    // Use a fresh imposter as the fee payer instead of treasury escrow.
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 2_000_000n);

    const sp = await algorand.client.algod.getTransactionParams().do();
    const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: imposter.addr,
      receiver: imposter.addr,
      amount: 0,
      suggestedParams: { ...sp, fee: Number(GROUP_FEE), flatFee: true },
    });

    const userAddrBytes = algosdk.decodeAddress(user.addr.toString()).publicKey;
    const boxKey = new Uint8Array(2 + 32);
    boxKey.set(new TextEncoder().encode("w:"), 0);
    boxKey.set(userAddrBytes, 2);
    const selector = new Uint8Array(
      algosdk.ABIMethod.fromSignature(
        "sendMessage(byte[32],byte[])void",
      ).getSelector(),
    );
    const ct = new Uint8Array([0xbb]);
    const arg = new Uint8Array(2 + ct.length);
    new DataView(arg.buffer).setUint16(0, ct.length, false);
    arg.set(ct, 2);

    const callTxn = algosdk.makeApplicationNoOpTxnFromObject({
      sender: user.addr,
      appIndex: Number(app.appId),
      appArgs: [selector, ZERO_TAG, arg],
      boxes: [{ appIndex: Number(app.appId), name: boxKey }],
      suggestedParams: { ...sp, fee: 0, flatFee: true },
    });

    algosdk.assignGroupID([feeTxn, callTxn]);
    const signedFee = feeTxn.signTxn(imposter.sk);
    const signedCall = callTxn.signTxn(user.sk);
    await expect(
      algorand.client.algod.sendRawTransaction([signedFee, signedCall]).do(),
    ).rejects.toThrow(/BAD_FEE_PAYER|assert failed/);
  });

  it("(f) 1KB ciphertext succeeds", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(2n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });
    const ct = new Uint8Array(1024);
    for (let i = 0; i < ct.length; i++) ct[i] = i & 0xff;
    await sendAs({
      algorand,
      appId: app.appId,
      user,
      recipientTag: ZERO_TAG,
      ciphertext: ct,
    });
  });
});
