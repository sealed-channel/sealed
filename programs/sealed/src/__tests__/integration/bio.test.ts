/**
 * Bio gate tests: setBio on the v3 UserState layout.
 *
 *   (a) set bio after redeem → box v3, bio bytes match, 1 credit spent
 *   (b) 160-byte bio (boundary) → accepted
 *   (c) 161-byte bio → reverts BIO_TOO_LONG (raw call, bypassing client validation)
 *   (d) empty bio → clears a previously-set bio
 *   (e) multibyte UTF-8 (emoji) round-trips byte-exact
 *   (f) setBio without a credit box → reverts NO_CREDITS
 *   (g) solo app-call (no escrow group) → reverts NOT_GROUP
 *
 * Requires `algokit localnet start`.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { setBio, validateBio } from "../../lib/bio.js";
import { decodeUserState, sumActiveCredits } from "../../lib/codec.js";
import { type LoadedEscrow } from "../../lib/escrow.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { redeemAs } from "../../scripts/redeem-as.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let escrow: LoadedEscrow;
let localNetUp = false;

const utf8 = (s: string) => new TextEncoder().encode(s);

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

function creditBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(utf8("w:"), 0);
  key.set(pk, 2);
  return key;
}

async function readCreditBox(wallet: string): Promise<Uint8Array> {
  const res = await algorand.client.algod
    .getApplicationBoxByName(Number(app.appId), creditBoxKey(wallet))
    .do();
  return new Uint8Array(res.value);
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

async function newUserWithCredits(
  denom: bigint = 5n,
): Promise<algosdk.Account> {
  const preimage = await postRandomCommitment(denom);
  const user = algosdk.generateAccount();
  await redeemAs({ algorand, appId: app.appId, user, preimage });
  return user;
}

/**
 * Raw setBio group WITHOUT client-side length validation — used to prove the
 * on-chain BIO_TOO_LONG revert independent of the lib's early throw.
 */
async function setBioRaw(
  user: algosdk.Account,
  bio: Uint8Array,
): Promise<string> {
  const algod = algorand.client.algod;
  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature("setBio(byte[])void").getSelector(),
  );
  const encoded = new Uint8Array(2 + bio.length);
  new DataView(encoded.buffer).setUint16(0, bio.length, false);
  encoded.set(bio, 2);

  const sp = await algod.getTransactionParams().do();
  const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: escrow.address,
    receiver: escrow.address,
    amount: 0,
    suggestedParams: { ...sp, fee: 5000, flatFee: true },
  });
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: user.addr,
    appIndex: Number(app.appId),
    appArgs: [selector, encoded],
    boxes: [
      { appIndex: Number(app.appId), name: creditBoxKey(user.addr.toString()) },
    ],
    suggestedParams: { ...sp, fee: 0, flatFee: true },
  });
  algosdk.assignGroupID([feeTxn, appCallTxn]);
  const signedFee = algosdk.signLogicSigTransactionObject(
    feeTxn,
    escrow.account,
  ).blob;
  const signedCall = appCallTxn.signTxn(user.sk);
  const { txid } = await algod.sendRawTransaction([signedFee, signedCall]).do();
  await algosdk.waitForConfirmation(algod, txid, 4);
  return appCallTxn.txID();
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping bio integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
  escrow = app.escrow!;
}, 120_000);

describe("setBio — v3 UserState bio field", () => {
  it("(a) sets bio, persists v3 box, spends 1 credit", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits(5n);
    const bio = utf8("I am a friendly and hardworking person.");

    await setBio({ algorand, appId: app.appId, user, bio, escrow });

    const state = decodeUserState(await readCreditBox(user.addr.toString()));
    expect(state.version).toBe(3);
    expect(state.bio).toEqual(bio);
    const status = await algorand.client.algod.status().do();
    expect(sumActiveCredits(state, BigInt(status.lastRound))).toBe(4n);
  });

  it("(b) accepts a 160-byte bio (boundary)", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits(5n);
    const bio = new Uint8Array(160).fill(0x61);
    await setBio({ algorand, appId: app.appId, user, bio, escrow });
    const state = decodeUserState(await readCreditBox(user.addr.toString()));
    expect(state.bio).toHaveLength(160);
  });

  it("(c) rejects a 161-byte bio on-chain: BIO_TOO_LONG", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits(5n);
    const bio = new Uint8Array(161).fill(0x61);
    expect(() => validateBio(bio)).toThrow(/BIO_TOO_LONG/); // client mirror
    await expect(setBioRaw(user, bio)).rejects.toThrow(
      /BIO_TOO_LONG|assert failed|logic eval error/,
    );
  });

  it("(d) empty bio clears a previously-set bio", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits(5n);
    await setBio({
      algorand,
      appId: app.appId,
      user,
      bio: utf8("temporary"),
      escrow,
    });
    await setBio({
      algorand,
      appId: app.appId,
      user,
      bio: new Uint8Array(0),
      escrow,
    });
    const state = decodeUserState(await readCreditBox(user.addr.toString()));
    expect(state.bio).toHaveLength(0);
    const status = await algorand.client.algod.status().do();
    expect(sumActiveCredits(state, BigInt(status.lastRound))).toBe(3n); // 2 setBio calls
  });

  it("(e) multibyte UTF-8 round-trips byte-exact", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits(5n);
    const bio = utf8("héllo 👋 multiline\nbio");
    await setBio({ algorand, appId: app.appId, user, bio, escrow });
    const state = decodeUserState(await readCreditBox(user.addr.toString()));
    expect(state.bio).toEqual(bio);
    expect(new TextDecoder().decode(state.bio)).toBe("héllo 👋 multiline\nbio");
  });

  it("(f) reverts NO_CREDITS without a credit box", async () => {
    if (!localNetUp) return;
    const ghost = algosdk.generateAccount();
    await expect(
      setBio({
        algorand,
        appId: app.appId,
        user: ghost,
        bio: utf8("hi"),
        escrow,
      }),
    ).rejects.toThrow(/NO_CREDITS|assert failed|logic eval error/);
  });

  it("(g) solo app-call (no escrow group) reverts NOT_GROUP", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits(2n);
    const algod = algorand.client.algod;
    const selector = new Uint8Array(
      algosdk.ABIMethod.fromSignature("setBio(byte[])void").getSelector(),
    );
    const bio = utf8("solo");
    const encoded = new Uint8Array(2 + bio.length);
    new DataView(encoded.buffer).setUint16(0, bio.length, false);
    encoded.set(bio, 2);
    const sp = await algod.getTransactionParams().do();
    const txn = algosdk.makeApplicationNoOpTxnFromObject({
      sender: user.addr,
      appIndex: Number(app.appId),
      appArgs: [selector, encoded],
      boxes: [
        {
          appIndex: Number(app.appId),
          name: creditBoxKey(user.addr.toString()),
        },
      ],
      suggestedParams: { ...sp, fee: 2000, flatFee: true },
    });
    // Solo call needs the user to hold ALGO for the fee.
    const fundSp = await algod.getTransactionParams().do();
    const fund = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: dispenser.addr,
      receiver: user.addr.toString(),
      amount: 200_000,
      suggestedParams: fundSp,
    });
    const { txid: fundId } = await algod
      .sendRawTransaction(fund.signTxn(dispenser.sk))
      .do();
    await algosdk.waitForConfirmation(algod, fundId, 4);

    const signed = txn.signTxn(user.sk);
    await expect(
      (async () => {
        const { txid } = await algod.sendRawTransaction(signed).do();
        await algosdk.waitForConfirmation(algod, txid, 4);
      })(),
    ).rejects.toThrow(/NOT_GROUP|assert failed|logic eval error/);
  });
});
