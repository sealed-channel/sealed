/**
 * v2 → v3 lazy-migration tests. Mirrors the production path exactly:
 *
 *   1. deploy the REAL v2 build (fixtures/Sealed.v2.arc56.json — snapshot of
 *      the pre-bio wire layout) and create genuine v2 boxes via redeem +
 *      claimUsername,
 *   2. in-place UpdateApplication to the current v3 build (same appId, boxes
 *      preserved — same mechanism as scripts/update-app.ts),
 *   3. run every op against the untouched v2 boxes and assert nothing bricks:
 *      (a) raw box still reads version 2 after the code update (lazy, no sweep)
 *      (b) getCredits / getUserProfile readonly decode v2 bytes (bio empty)
 *      (c) sendMessage spends a credit and rewrites the box as v3
 *      (d) setBio upgrades a v2 box, preserving username + remaining credits
 *      (e) claimUsername rename works on a v2 box, bio (set pre-rename) survives
 *
 * Requires `algokit localnet start`.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import { setBio } from "../../lib/bio.js";
import { decodeUserState, sumActiveCredits } from "../../lib/codec.js";
import { getCredits } from "../../lib/credits.js";
import { type LoadedEscrow } from "../../lib/escrow.js";
import { claimUsername, resolveUsername } from "../../lib/username.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { redeemAs } from "../../scripts/redeem-as.js";
import { sendAs } from "../../scripts/send-as.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const V2_ARC56_PATH = resolve(HERE, "..", "fixtures", "Sealed.v2.arc56.json");
const V3_ARC56_PATH = resolve(
  HERE,
  "..",
  "..",
  "..",
  "out",
  "Sealed.arc56.json",
);

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
  await postCommitment({
    algorand,
    appId: app.appId,
    admin: app.admin,
    commitment: sha256(preimage),
    denomination: denom,
  });
  return preimage;
}

async function newV2User(
  denom: bigint,
  username?: string,
): Promise<algosdk.Account> {
  const preimage = await postRandomCommitment(denom);
  const user = algosdk.generateAccount();
  await redeemAs({ algorand, appId: app.appId, user, preimage });
  if (username) {
    await claimUsername({ algorand, appId: app.appId, user, username, escrow });
  }
  return user;
}

/** In-place UpdateApplication to the current v3 build (creator-gated). */
async function updateToV3(): Promise<void> {
  const spec = JSON.parse(readFileSync(V3_ARC56_PATH, "utf-8"));
  const approvalProgram = new Uint8Array(
    Buffer.from(spec.byteCode.approval, "base64"),
  );
  const clearProgram = new Uint8Array(
    Buffer.from(spec.byteCode.clear, "base64"),
  );
  const algod = algorand.client.algod;
  const sp = await algod.getTransactionParams().do();
  const txn = algosdk.makeApplicationUpdateTxnFromObject({
    sender: app.creator.addr,
    appIndex: Number(app.appId),
    approvalProgram,
    clearProgram,
    suggestedParams: { ...sp, fee: 2000, flatFee: true },
  });
  const { txid } = await algod
    .sendRawTransaction(txn.signTxn(app.creator.sk))
    .do();
  await algosdk.waitForConfirmation(algod, txid, 4);
}

function uniq(): string {
  return "m" + Buffer.from(randomBytes(4)).toString("hex");
}

// v2 users created BEFORE the code update, exercised after it.
let userBio: algosdk.Account; // (a)(b)(d) — has username
let userSend: algosdk.Account; // (c) — plain credits
let userRename: algosdk.Account; // (e) — has username, renamed post-update
let bioName: string;
let renameOld: string;

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping migration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);

  // 1. Deploy the genuine v2 build and create v2 boxes.
  app = await deploySealed({
    algorand,
    dispenser,
    withEscrow: true,
    appSpecPath: V2_ARC56_PATH,
  });
  escrow = app.escrow!;

  bioName = uniq();
  renameOld = uniq();
  userBio = await newV2User(5n, bioName);
  userSend = await newV2User(5n);
  userRename = await newV2User(5n, renameOld);

  // Sanity: boxes written by v2 code carry version byte 2.
  for (const u of [userBio, userSend, userRename]) {
    const raw = await readCreditBox(u.addr.toString());
    expect(raw[0]).toBe(2);
  }

  // 2. In-place update to v3 — same appId, boxes untouched.
  await updateToV3();
}, 180_000);

describe("v2 → v3 lazy migration", () => {
  it("(a) code update does not touch boxes — version byte still 2", async () => {
    if (!localNetUp) return;
    const raw = await readCreditBox(userBio.addr.toString());
    expect(raw[0]).toBe(2);
  });

  it("(b) readonly v3 methods decode a v2 box: getCredits + empty bio", async () => {
    if (!localNetUp) return;
    // claimUsername spent 1 of 5 credits under v2.
    const credits = await getCredits({
      algorand,
      appId: app.appId,
      caller: dispenser,
      wallet: userBio.addr.toString(),
    });
    expect(credits).toBe(4n);
    // Off-chain decoder mirrors the lazy upgrade: v2 bytes → empty bio.
    const state = decodeUserState(await readCreditBox(userBio.addr.toString()));
    expect(state.version).toBe(2);
    expect(state.username).toEqual(utf8(bioName));
    expect(state.bio).toHaveLength(0);
  });

  it("(c) sendMessage on a v2 box spends a credit and persists v3", async () => {
    if (!localNetUp) return;
    await sendAs({
      algorand,
      appId: app.appId,
      user: userSend,
      recipientTag: new Uint8Array(randomBytes(32)),
      ciphertext: utf8("post-update message"),
      escrow,
    });
    const state = decodeUserState(
      await readCreditBox(userSend.addr.toString()),
    );
    expect(state.version).toBe(3);
    expect(state.bio).toHaveLength(0);
    const status = await algorand.client.algod.status().do();
    expect(sumActiveCredits(state, BigInt(status.lastRound))).toBe(4n);
  });

  it("(d) setBio upgrades a v2 box, preserving username + credits", async () => {
    if (!localNetUp) return;
    const bio = utf8("migrated and thriving");
    await setBio({ algorand, appId: app.appId, user: userBio, bio, escrow });

    const state = decodeUserState(await readCreditBox(userBio.addr.toString()));
    expect(state.version).toBe(3);
    expect(state.bio).toEqual(bio);
    expect(state.username).toEqual(utf8(bioName)); // survived the upgrade
    const status = await algorand.client.algod.status().do();
    // 5 redeemed − 1 claim (v2) − 1 setBio = 3.
    expect(sumActiveCredits(state, BigInt(status.lastRound))).toBe(3n);
    // Reverse index untouched.
    const owner = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: bioName,
    });
    expect(owner).toBe(userBio.addr.toString());
  });

  it("(e) claimUsername rename on a v2 box; pre-set bio survives the rename", async () => {
    if (!localNetUp) return;
    // First give the v2 user a bio (upgrades box to v3), then rename.
    const bio = utf8("bio before rename");
    await setBio({ algorand, appId: app.appId, user: userRename, bio, escrow });

    const renameNew = uniq();
    await claimUsername({
      algorand,
      appId: app.appId,
      user: userRename,
      username: renameNew,
      previousUsername: renameOld,
      escrow,
    });

    const state = decodeUserState(
      await readCreditBox(userRename.addr.toString()),
    );
    expect(state.version).toBe(3);
    expect(state.username).toEqual(utf8(renameNew));
    expect(state.bio).toEqual(bio);
    const owner = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: renameNew,
    });
    expect(owner).toBe(userRename.addr.toString());
  });
});
