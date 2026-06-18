/**
 * G8 gate tests: pruneExpired + getCredits.
 *
 *   (a) getCredits on missing box returns 0
 *   (b) getCredits after redeem returns batch amount
 *   (c) pruneExpired on missing box reverts NO_CREDITS
 *   (d) expired batches dropped, getCredits returns 0, next sendMessage reverts
 *
 * Deploys w/ `roundsPerYear = 5` so a handful of dummy txns expire batches.
 * Requires `algokit localnet start`.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { getCredits, pruneExpired } from "../../lib/credits.js";
import { postCommitment } from "../../scripts/post-commitment.js";
import { redeemAs } from "../../scripts/redeem-as.js";
import { sendAs } from "../../scripts/send-as.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let localNetUp = false;
const ROUNDS_PER_YEAR = 5n;

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

async function advanceRounds(n: number): Promise<void> {
  // Each payment from dispenser to self advances one round on LocalNet.
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

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping credits integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({
    algorand,
    dispenser,
    withEscrow: true,
    roundsPerYear: ROUNDS_PER_YEAR,
  });
});

describe("credits — pruneExpired + getCredits (G8)", () => {
  it("(a) getCredits on missing wallet returns 0", async () => {
    if (!localNetUp) return;
    const stranger = algosdk.generateAccount();
    const c = await getCredits({
      algorand,
      appId: app.appId,
      caller: dispenser,
      wallet: stranger.addr.toString(),
    });
    expect(c).toBe(0n);
  });

  it("(b) getCredits returns sum of live batches", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(7n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    const c = await getCredits({
      algorand,
      appId: app.appId,
      caller: dispenser,
      wallet: user.addr.toString(),
    });
    expect(c).toBe(7n);
  });

  it("(c) pruneExpired on missing wallet reverts NO_CREDITS", async () => {
    if (!localNetUp) return;
    const stranger = algosdk.generateAccount();
    await expect(
      pruneExpired({
        algorand,
        appId: app.appId,
        caller: dispenser,
        wallet: stranger.addr.toString(),
      }),
    ).rejects.toThrow(/NO_CREDITS|assert failed/);
  });

  it("(d) expired batches dropped, sendMessage reverts NO_CREDITS", async () => {
    if (!localNetUp) return;
    const preimage = await postRandomCommitment(3n);
    const user = algosdk.generateAccount();
    await redeemAs({ algorand, appId: app.appId, user, preimage });

    // Advance > roundsPerYear so the batch's expiry passes.
    await advanceRounds(Number(ROUNDS_PER_YEAR) + 2);

    await pruneExpired({
      algorand,
      appId: app.appId,
      caller: dispenser,
      wallet: user.addr.toString(),
    });

    const c = await getCredits({
      algorand,
      appId: app.appId,
      caller: dispenser,
      wallet: user.addr.toString(),
    });
    expect(c).toBe(0n);

    await expect(
      sendAs({
        algorand,
        appId: app.appId,
        user,
        recipientTag: new Uint8Array(32),
        ciphertext: new Uint8Array([1, 2, 3]),
      }),
    ).rejects.toThrow(/NO_CREDITS|assert failed/);
  });
});
