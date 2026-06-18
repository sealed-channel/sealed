/**
 * G7 gate tests: username claim / rename / release / resolve.
 *
 *   (a) fresh wallet redeems with username arg → claimed atomically
 *   (b) claim after redeem (empty slot) → success
 *   (c) rename: claim 'alice' then claim 'alice2' → resolve('alice') reverts, resolve('alice2') == user
 *   (d) release → resolve reverts, slot empty
 *   (e) double claim same name → TAKEN
 *   (f) invalid format (bad char, length) → revert; digit-first names are valid
 *   (g) claim without credit box → NO_CREDITS
 *
 * Requires `algokit localnet start`.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { decodeUserState } from "../../lib/codec.js";
import {
  claimUsername,
  releaseUsername,
  resolveUsername,
} from "../../lib/username.js";
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
  const pk = algosdk.decodeAddress(wallet).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  try {
    const res = await algorand.client.algod
      .getApplicationBoxByName(Number(app.appId), key)
      .do();
    return new Uint8Array(res.value);
  } catch {
    return null;
  }
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

async function newUserWithCredits(
  denom: bigint = 5n,
): Promise<algosdk.Account> {
  const preimage = await postRandomCommitment(denom);
  const user = algosdk.generateAccount();
  await redeemAs({ algorand, appId: app.appId, user, preimage });
  return user;
}

function uniq(): string {
  return "u" + Buffer.from(randomBytes(4)).toString("hex");
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping username integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

describe("username — claim / rename / release / resolve (G7)", () => {
  it("(a) redeem with username claims atomically", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(5n);
    const user = algosdk.generateAccount();
    const name = uniq();
    await redeemAs({
      algorand,
      appId: app.appId,
      user,
      preimage,
      username: name,
    });

    const box = await readCreditBox(user.addr.toString());
    const state = decodeUserState(box!);
    expect(new TextDecoder().decode(state.username)).toBe(name);

    const resolved = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: name,
    });
    expect(resolved).toBe(user.addr.toString());
  });

  it("(b) claim on empty slot after redeem", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);
    const name = uniq();
    await claimUsername({ algorand, appId: app.appId, user, username: name });

    const resolved = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: name,
    });
    expect(resolved).toBe(user.addr.toString());

    // T19: claim spends 1 credit — newUserWithCredits gave 5; expect 4 remain.
    const box = await readCreditBox(user.addr.toString());
    const state = decodeUserState(box!);
    expect(state.batches[0].amount).toBe(4n);
  });

  it("(c) rename clears old reverse-index", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);
    const a = uniq();
    const b = uniq();
    await claimUsername({ algorand, appId: app.appId, user, username: a });
    await claimUsername({
      algorand,
      appId: app.appId,
      user,
      username: b,
      previousUsername: a,
    });

    const resolvedB = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: b,
    });
    expect(resolvedB).toBe(user.addr.toString());

    await expect(
      resolveUsername({
        algorand,
        appId: app.appId,
        sender: dispenser,
        username: a,
      }),
    ).rejects.toThrow(/NOT_FOUND|assert failed/);
  });

  it("(d) release clears slot", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);
    const name = uniq();
    await claimUsername({ algorand, appId: app.appId, user, username: name });
    await releaseUsername({ algorand, appId: app.appId, user, username: name });

    await expect(
      resolveUsername({
        algorand,
        appId: app.appId,
        sender: dispenser,
        username: name,
      }),
    ).rejects.toThrow(/NOT_FOUND|assert failed/);

    const box = await readCreditBox(user.addr.toString());
    const state = decodeUserState(box!);
    expect(state.username.length).toBe(0);
  });

  it("(e) double claim same name reverts TAKEN", async () => {
    if (!localNetUp) return;
    const userA = await newUserWithCredits();
    const userB = await newUserWithCredits();
    await fundAccount(dispenser, userA.addr.toString(), 200_000n);
    await fundAccount(dispenser, userB.addr.toString(), 200_000n);
    const name = uniq();
    await claimUsername({
      algorand,
      appId: app.appId,
      user: userA,
      username: name,
    });

    await expect(
      claimUsername({
        algorand,
        appId: app.appId,
        user: userB,
        username: name,
      }),
    ).rejects.toThrow(/TAKEN|assert failed/);
  });

  it("(f) invalid format reverts", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);

    // Client-side rejects bad format before chain call.
    await expect(
      claimUsername({ algorand, appId: app.appId, user, username: "bad-char" }),
    ).rejects.toThrow(/BAD_CHAR|BAD_LEN/);

    await expect(
      claimUsername({ algorand, appId: app.appId, user, username: "ab" }),
    ).rejects.toThrow(/BAD_LEN/);
  });

  it("(f2) digit-first and all-digit names claim successfully", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);

    // Digit-first: '1' + hex suffix. Claims end-to-end (lib regex + on-chain format).
    const digitFirst = "1" + uniq();
    await claimUsername({
      algorand,
      appId: app.appId,
      user,
      username: digitFirst,
    });
    const owner = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: digitFirst,
    });
    expect(owner).toBe(user.addr.toString());

    // All digits (rename path — same slot, old name released).
    const allDigits = Array.from(randomBytes(8), (b) => String(b % 10)).join(
      "",
    );
    await claimUsername({
      algorand,
      appId: app.appId,
      user,
      username: allDigits,
      previousUsername: digitFirst,
    });
    const owner2 = await resolveUsername({
      algorand,
      appId: app.appId,
      sender: dispenser,
      username: allDigits,
    });
    expect(owner2).toBe(user.addr.toString());
  });

  it("(g) claim without credit box reverts NO_CREDITS", async () => {
    if (!localNetUp) return;
    const user = algosdk.generateAccount();
    await fundAccount(dispenser, user.addr.toString(), 300_000n);
    await expect(
      claimUsername({ algorand, appId: app.appId, user, username: uniq() }),
    ).rejects.toThrow(/NO_CREDITS|assert failed/);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// T11 — ARC28 event assertions on claim/release
// ─────────────────────────────────────────────────────────────────────────────

function arc28Selector(sig: string): Uint8Array {
  const hash = createHash("sha512-256").update(sig).digest();
  return new Uint8Array(hash.subarray(0, 4));
}

function findEventLog(
  logs: Uint8Array[],
  prefix: Uint8Array,
): Uint8Array | null {
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

async function txnLogs(txid: string): Promise<Uint8Array[]> {
  const conf = await algorand.client.algod
    .pendingTransactionInformation(txid)
    .do();
  return (conf.logs ?? []).map((l: Uint8Array | string) =>
    typeof l === "string"
      ? new Uint8Array(Buffer.from(l, "base64"))
      : new Uint8Array(l),
  );
}

const USERNAME_CLAIMED_TYPE = algosdk.ABIType.from("(address,byte[],byte[])");
const USERNAME_RELEASED_TYPE = algosdk.ABIType.from("(address,byte[])");
const USERNAME_CLAIMED_SEL = arc28Selector(
  "UsernameClaimed(address,byte[],byte[])",
);
const USERNAME_RELEASED_SEL = arc28Selector("UsernameReleased(address,byte[])");

function toU8(v: Uint8Array | ArrayLike<number>): Uint8Array {
  return v instanceof Uint8Array ? v : Uint8Array.from(v);
}

describe("username — ARC28 events (T11)", () => {
  it("(a) first claim emits UsernameClaimed with oldName empty", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);
    const name = uniq();
    const txid = await claimUsername({
      algorand,
      appId: app.appId,
      user,
      username: name,
    });

    const body = findEventLog(await txnLogs(txid), USERNAME_CLAIMED_SEL);
    expect(body).not.toBeNull();
    const tuple = USERNAME_CLAIMED_TYPE.decode(body!) as [
      string,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
    ];
    expect(tuple[0]).toBe(user.addr.toString());
    expect(toU8(tuple[1]).length).toBe(0);
    expect(new TextDecoder().decode(toU8(tuple[2]))).toBe(name);
  });

  it("(b) rename emits UsernameClaimed with oldName == previous", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 300_000n);
    const a = uniq();
    const b = uniq();
    await claimUsername({ algorand, appId: app.appId, user, username: a });
    const txid = await claimUsername({
      algorand,
      appId: app.appId,
      user,
      username: b,
      previousUsername: a,
    });

    const body = findEventLog(await txnLogs(txid), USERNAME_CLAIMED_SEL);
    expect(body).not.toBeNull();
    const tuple = USERNAME_CLAIMED_TYPE.decode(body!) as [
      string,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
    ];
    expect(tuple[0]).toBe(user.addr.toString());
    expect(new TextDecoder().decode(toU8(tuple[1]))).toBe(a);
    expect(new TextDecoder().decode(toU8(tuple[2]))).toBe(b);
  });

  it("(c) release emits UsernameReleased with released name", async () => {
    if (!localNetUp) return;
    const user = await newUserWithCredits();
    await fundAccount(dispenser, user.addr.toString(), 200_000n);
    const name = uniq();
    await claimUsername({ algorand, appId: app.appId, user, username: name });
    const txid = await releaseUsername({
      algorand,
      appId: app.appId,
      user,
      username: name,
    });

    const body = findEventLog(await txnLogs(txid), USERNAME_RELEASED_SEL);
    expect(body).not.toBeNull();
    const tuple = USERNAME_RELEASED_TYPE.decode(body!) as [
      string,
      Uint8Array | ArrayLike<number>,
    ];
    expect(tuple[0]).toBe(user.addr.toString());
    expect(new TextDecoder().decode(toU8(tuple[1]))).toBe(name);
  });
});
