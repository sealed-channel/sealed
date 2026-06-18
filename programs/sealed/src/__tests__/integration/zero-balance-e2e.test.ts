/**
 * T26 — zero-balance E2E.
 *
 * Proves the universal-escrow group lets a freshly-generated wallet that
 * holds ZERO ALGO complete the full identity lifecycle without ever paying
 * a network fee:
 *
 *   redeem(denom=5)
 *     → balance grows from 0 to ACCOUNT_MBR_MIN (contract MBR seed inner-pay)
 *     → credits: 5
 *   publishKeys                    → credits: 4
 *   claimUsername("alice42")       → credits: 3
 *   sendMessage(tag, ciphertext)   → credits: 2
 *   releaseUsername                → credits: 1
 *
 * After each step we re-read the wallet balance and assert it is unchanged
 * (still equal to the post-redeem seed). Treasury escrow pays all fees;
 * contract account pays new-box MBR for w:/n: boxes.
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { decodeUserState } from "../../lib/codec.js";
import { claimUsername, releaseUsername } from "../../lib/username.js";
import { publishKeys } from "../../lib/pq.js";
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

function userBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  return key;
}

async function readBalance(addr: string): Promise<bigint> {
  const info = await algorand.client.algod.accountInformation(addr).do();
  return BigInt(info.amount);
}

async function readCredits(wallet: string): Promise<bigint> {
  const res = await algorand.client.algod
    .getApplicationBoxByName(Number(app.appId), userBoxKey(wallet))
    .do();
  const state = decodeUserState(new Uint8Array(res.value));
  return state.batches.reduce<bigint>((acc, b) => acc + b.amount, 0n);
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping zero-balance E2E.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

describe("T26 — zero-balance E2E (full identity lifecycle, 0 ALGO user)", () => {
  it("zero-ALGO wallet completes redeem → publishKeys → claim → send → release", async () => {
    if (!localNetUp) return;

    // Fresh wallet, never funded. Balance == 0.
    const user = algosdk.generateAccount();
    const userAddr = user.addr.toString();
    expect(await readBalance(userAddr)).toBe(0n);

    // Post a commitment, denom 5 — enough for publish(1) + claim(1) + send(1) + release(1) + 1 left.
    const preimage = new Uint8Array(randomBytes(16));
    const commitment = sha256(preimage);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment,
      denomination: 5n,
    });

    // Step 1: redeem.
    await redeemAs({ algorand, appId: app.appId, user, preimage });
    const seedBal = await readBalance(userAddr);
    expect(seedBal).toBe(100_000n); // contract MBR-seed inner-pay = ACCOUNT_MBR_MIN
    expect(await readCredits(userAddr)).toBe(5n);

    // Step 2: publishKeys. Spends 1 credit. Balance unchanged.
    const enc = new Uint8Array(randomBytes(32));
    const scan = new Uint8Array(randomBytes(32));
    const pq = new Uint8Array(randomBytes(96));
    await publishKeys({
      algorand,
      appId: app.appId,
      sender: user,
      encryptionPubkey: enc,
      scanPubkey: scan,
      pqPubkey: pq,
    });
    expect(await readBalance(userAddr)).toBe(seedBal);
    expect(await readCredits(userAddr)).toBe(4n);

    // Step 3: claimUsername. Spends 1 credit. Balance unchanged.
    await claimUsername({
      algorand,
      appId: app.appId,
      user,
      username: "alice42",
    });
    expect(await readBalance(userAddr)).toBe(seedBal);
    expect(await readCredits(userAddr)).toBe(3n);

    // Step 4: sendMessage. Spends 1 credit. Balance unchanged.
    await sendAs({
      algorand,
      appId: app.appId,
      user,
      recipientTag: new Uint8Array(randomBytes(32)),
      ciphertext: new Uint8Array(randomBytes(64)),
    });
    expect(await readBalance(userAddr)).toBe(seedBal);
    expect(await readCredits(userAddr)).toBe(2n);

    // Step 5: releaseUsername. Spends 1 credit. Balance unchanged.
    await releaseUsername({
      algorand,
      appId: app.appId,
      user,
      username: "alice42",
    });
    expect(await readBalance(userAddr)).toBe(seedBal);
    expect(await readCredits(userAddr)).toBe(1n);
  });
});
