/**
 * G4 gate test: commitment lifecycle.
 *
 *   admin posts commitment → box exists
 *   non-admin posts        → revert 'NOT_ADMIN'
 *   admin re-posts same    → revert 'TAKEN'
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { postCommitment } from "../../scripts/post-commitment.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let localNetUp = false;

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping register integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser });
});

describe("registerCommitment — admin gate + box lifecycle (G4)", () => {
  it("admin posts a fresh commitment; box exists", async () => {
    if (!localNetUp) return;
    const preimage = new Uint8Array(randomBytes(16));
    const commitment = sha256(preimage);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment,
      denomination: 50n,
    });
    const boxKey = new Uint8Array(2 + 32);
    boxKey.set(new TextEncoder().encode("c:"));
    boxKey.set(commitment, 2);
    const boxes = await algorand.client.algod
      .getApplicationBoxes(Number(app.appId))
      .do();
    const found = boxes.boxes.some((b) =>
      Buffer.from(b.name).equals(Buffer.from(boxKey)),
    );
    expect(found).toBe(true);
  });

  it("non-admin attempt reverts NOT_ADMIN", async () => {
    if (!localNetUp) return;
    const intruder = algosdk.generateAccount();
    const sp = await algorand.client.algod.getTransactionParams().do();
    // Fund intruder so it can sign.
    const fund = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: dispenser.addr,
      receiver: intruder.addr,
      amount: 1_000_000,
      suggestedParams: sp,
    });
    const sFund = fund.signTxn(dispenser.sk);
    const { txid } = await algorand.client.algod.sendRawTransaction(sFund).do();
    await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);

    const preimage = new Uint8Array(randomBytes(16));
    const commitment = sha256(preimage);
    await expect(
      postCommitment({
        algorand,
        appId: app.appId,
        admin: intruder,
        commitment,
        denomination: 50n,
      }),
    ).rejects.toThrow(/NOT_ADMIN/);
  });

  it("admin re-posting same commitment reverts TAKEN", async () => {
    if (!localNetUp) return;
    const preimage = new Uint8Array(randomBytes(16));
    const commitment = sha256(preimage);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment,
      denomination: 50n,
    });
    await expect(
      postCommitment({
        algorand,
        appId: app.appId,
        admin: app.admin,
        commitment,
        denomination: 50n,
      }),
    ).rejects.toThrow(/TAKEN/);
  });
});
