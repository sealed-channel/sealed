/**
 * G3 gate test: deploy LogicSig, fund it, submit a 2-txn dummy group with the
 * escrow as fee payer, group succeeds, escrow balance decreases by exactly the
 * group fee.
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  fundEscrow,
  loadTreasuryEscrow,
  type LoadedEscrow,
} from "../../lib/escrow.js";
import { GROUP_FEE } from "../../lib/group.js";

let algorand: AlgorandClient;
let algod: algosdk.Algodv2;
let dispenser: algosdk.Account;
let escrow: LoadedEscrow;
let localNetUp = false;

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    algod = algorand.client.algod;
    await algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping integration tests. Run `algokit localnet start`.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser = {
    addr: dispenserAccount,
    sk: dispenserAccount.account.sk,
  } as unknown as algosdk.Account;
  // algokit-utils dispenser is a TransactionSignerAccount; pull the underlying signing key via the algosdk Account it wraps.
  dispenser = dispenserAccount.account ?? dispenserAccount;
  escrow = await loadTreasuryEscrow(algod);
});

afterAll(() => {
  /* nothing to clean — fresh LocalNet recommended */
});

describe("escrow — LogicSig fee payer (G3)", () => {
  it("compiles and yields a stable address", () => {
    if (!localNetUp) return;
    expect(escrow.address).toMatch(/^[A-Z2-7]{58}$/);
  });

  it("funds and uses the escrow as group fee payer; balance drops by group fee", async () => {
    if (!localNetUp) return;

    const fundAmount = 1_000_000n; // 1 ALGO
    await fundEscrow({
      algod,
      funder: dispenser,
      escrowAddress: escrow.address,
      amount: fundAmount,
    });

    // Escrow address is deterministic — LocalNet may persist balance across
    // runs. Snapshot the post-funding balance directly and assert the delta.
    const before = await algod.accountInformation(escrow.address).do();
    const beforeBalance = BigInt(before.amount);
    expect(beforeBalance).toBeGreaterThanOrEqual(fundAmount);

    // Build a 2-txn group: escrow self-pay 0 (fee = 2× min, signs the group);
    // user self-pay 0 with fee 0 (covered by fee pool).
    const user = algosdk.generateAccount();
    // Seed user with min account MBR so the second txn can settle.
    await fundEscrow({
      algod,
      funder: dispenser,
      escrowAddress: user.addr.toString(),
      amount: 200_000n,
    });

    const sp = await algod.getTransactionParams().do();
    const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: escrow.address,
      receiver: escrow.address,
      amount: 0,
      suggestedParams: { ...sp, fee: Number(GROUP_FEE), flatFee: true },
    });
    const userTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: user.addr,
      receiver: user.addr,
      amount: 0,
      suggestedParams: { ...sp, fee: 0, flatFee: true },
    });
    algosdk.assignGroupID([feeTxn, userTxn]);

    const signedFee = algosdk.signLogicSigTransactionObject(
      feeTxn,
      escrow.account,
    ).blob;
    const signedUser = userTxn.signTxn(user.sk);
    const { txid } = await algod
      .sendRawTransaction([signedFee, signedUser])
      .do();
    await algosdk.waitForConfirmation(algod, txid, 4);

    const after = await algod.accountInformation(escrow.address).do();
    const afterBalance = BigInt(after.amount);
    expect(beforeBalance - afterBalance).toBe(GROUP_FEE);
  });

  it("rejects a single-txn submission (groupSize != 2)", async () => {
    if (!localNetUp) return;
    const sp = await algod.getTransactionParams().do();
    const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: escrow.address,
      receiver: escrow.address,
      amount: 0,
      suggestedParams: { ...sp, fee: Number(GROUP_FEE), flatFee: true },
    });
    const signed = algosdk.signLogicSigTransactionObject(
      txn,
      escrow.account,
    ).blob;
    await expect(algod.sendRawTransaction(signed).do()).rejects.toThrow();
  });

  it("rejects non-zero amount (escrow tries to send funds out)", async () => {
    if (!localNetUp) return;
    const recipient = algosdk.generateAccount();
    const sp = await algod.getTransactionParams().do();
    const evilTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: escrow.address,
      receiver: recipient.addr,
      amount: 1,
      suggestedParams: { ...sp, fee: Number(GROUP_FEE), flatFee: true },
    });
    const filler = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
      sender: recipient.addr,
      receiver: recipient.addr,
      amount: 0,
      suggestedParams: { ...sp, fee: 0, flatFee: true },
    });
    algosdk.assignGroupID([evilTxn, filler]);
    const signed = algosdk.signLogicSigTransactionObject(
      evilTxn,
      escrow.account,
    ).blob;
    const signedFiller = filler.signTxn(recipient.sk);
    await expect(
      algod.sendRawTransaction([signed, signedFiller]).do(),
    ).rejects.toThrow();
  });
});
