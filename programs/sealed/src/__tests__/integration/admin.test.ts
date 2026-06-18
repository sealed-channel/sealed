/**
 * G9 gate tests: admin surface — withdrawTreasury, setTreasury, update.
 *
 *   (a) non-admin withdrawTreasury → revert NOT_ADMIN
 *   (b) admin withdrawTreasury drains amount to receiver
 *   (c) non-creator setTreasury → revert NOT_CREATOR
 *   (d) creator setTreasury rotates global
 *   (e) non-creator update → revert NOT_CREATOR
 *   (f) creator update succeeds (program bytes unchanged is fine)
 *
 * Requires `algokit localnet start`.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { setTreasury, withdrawTreasury } from "../../lib/admin.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let localNetUp = false;

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

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping admin integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser, withEscrow: true });
});

describe("admin — withdrawTreasury / setTreasury / update (G9)", () => {
  it("(a) non-admin withdrawTreasury reverts NOT_ADMIN", async () => {
    if (!localNetUp) return;
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 2_000_000n);

    await expect(
      withdrawTreasury({
        algorand,
        appId: app.appId,
        admin: imposter,
        amount: 1_000n,
        receiver: imposter.addr.toString(),
      }),
    ).rejects.toThrow(/NOT_ADMIN|assert failed/);
  });

  it("(b) admin withdrawTreasury drains to receiver", async () => {
    if (!localNetUp) return;
    const receiver = algosdk.generateAccount();
    await fundAccount(dispenser, receiver.addr.toString(), 100_000n);

    const beforeInfo = await algorand.client.algod
      .accountInformation(receiver.addr.toString())
      .do();
    const before = BigInt(beforeInfo.amount);

    const withdrawAmount = 250_000n;
    await withdrawTreasury({
      algorand,
      appId: app.appId,
      admin: app.admin,
      amount: withdrawAmount,
      receiver: receiver.addr.toString(),
    });

    const afterInfo = await algorand.client.algod
      .accountInformation(receiver.addr.toString())
      .do();
    const after = BigInt(afterInfo.amount);
    expect(after).toBe(before + withdrawAmount);
  });

  it("(c) non-creator setTreasury reverts NOT_CREATOR", async () => {
    if (!localNetUp) return;
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 2_000_000n);
    const newAddr = algosdk.generateAccount().addr.toString();

    await expect(
      setTreasury({
        algorand,
        appId: app.appId,
        creator: imposter,
        newEscrow: newAddr,
      }),
    ).rejects.toThrow(/NOT_CREATOR|assert failed/);
  });

  it("(d) creator setTreasury rotates global", async () => {
    if (!localNetUp) return;
    const newAddr = algosdk.generateAccount().addr.toString();
    await setTreasury({
      algorand,
      appId: app.appId,
      creator: app.creator,
      newEscrow: newAddr,
    });

    const info = await algorand.client.algod
      .getApplicationByID(Number(app.appId))
      .do();
    const tEntry = info.params.globalState?.find(
      (kv) => Buffer.from(kv.key).toString() === "t",
    );
    expect(tEntry).toBeDefined();
    const stored = algosdk.encodeAddress(new Uint8Array(tEntry!.value.bytes));
    expect(stored).toBe(newAddr);
  });

  it("(e) non-creator update reverts NOT_CREATOR", async () => {
    if (!localNetUp) return;
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 3_000_000n);

    const appInfo = await algorand.client.algod
      .getApplicationByID(Number(app.appId))
      .do();
    const approval = new Uint8Array(appInfo.params.approvalProgram);
    const clear = new Uint8Array(appInfo.params.clearStateProgram);

    const sp = await algorand.client.algod.getTransactionParams().do();
    const txn = algosdk.makeApplicationUpdateTxnFromObject({
      sender: imposter.addr,
      appIndex: Number(app.appId),
      approvalProgram: approval,
      clearProgram: clear,
      suggestedParams: { ...sp, fee: 1000, flatFee: true },
      note: new Uint8Array(randomBytes(4)),
    });
    const signed = txn.signTxn(imposter.sk);
    await expect(
      algorand.client.algod.sendRawTransaction(signed).do(),
    ).rejects.toThrow(/NOT_CREATOR|assert failed|rejected/);
  });

  it("(f) creator update succeeds", async () => {
    if (!localNetUp) return;
    // Recompile current contract bytes — update with same TEAL is a no-op success.
    const appInfo = await algorand.client.algod
      .getApplicationByID(Number(app.appId))
      .do();
    const approval = new Uint8Array(appInfo.params.approvalProgram);
    const clear = new Uint8Array(appInfo.params.clearStateProgram);

    const sp = await algorand.client.algod.getTransactionParams().do();
    const txn = algosdk.makeApplicationUpdateTxnFromObject({
      sender: app.creator.addr,
      appIndex: Number(app.appId),
      approvalProgram: approval,
      clearProgram: clear,
      suggestedParams: { ...sp, fee: 1000, flatFee: true },
      note: new Uint8Array(randomBytes(4)),
    });
    const signed = txn.signTxn(app.creator.sk);
    const { txid } = await algorand.client.algod
      .sendRawTransaction(signed)
      .do();
    const confirmed = await algosdk.waitForConfirmation(
      algorand.client.algod,
      txid,
      4,
    );
    expect(confirmed).toBeDefined();
  });
});
