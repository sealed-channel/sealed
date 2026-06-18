/**
 * 2-txn fee-pool group builder for `sendMessage`.
 *
 * Stub for slice S2 — types + unsigned shape only. LogicSig signing wired
 * in slice S6 once `treasury_escrow.algo.ts` exists.
 *
 * Group layout (SPEC §5.4):
 *   Txn 0  Treasury self-pay, amount 0, fee = MIN_FEE * 2, signed by LogicSig.
 *   Txn 1  User app-call to Sealed.sendMessage(ciphertext), fee 0.
 */

import algosdk from "algosdk";

export const MIN_FEE = 1000n;
// 2-txn group: fee txn (1) + app-call (1) = 2000µA. No ensureBudget in sendMessage.
export const GROUP_FEE = MIN_FEE * 2n;

export interface BuildSendGroupParams {
  algod: algosdk.Algodv2;
  appId: bigint;
  treasuryAddress: string;
  userAddress: string;
  ciphertext: Uint8Array;
  /** ABI selector bytes for `sendMessage(byte[])void` — derived at call time. */
  methodSelector: Uint8Array;
}

export interface UnsignedSendGroup {
  feeTxn: algosdk.Transaction;
  appCallTxn: algosdk.Transaction;
}

/** Builds the unsigned group. Signing happens in S6. */
export async function buildUnsignedSendGroup(
  p: BuildSendGroupParams,
): Promise<UnsignedSendGroup> {
  const sp = await p.algod.getTransactionParams().do();

  const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: p.treasuryAddress,
    receiver: p.treasuryAddress,
    amount: 0,
    suggestedParams: { ...sp, fee: Number(GROUP_FEE), flatFee: true },
  });

  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: p.userAddress,
    appIndex: Number(p.appId),
    appArgs: [p.methodSelector, p.ciphertext],
    suggestedParams: { ...sp, fee: 0, flatFee: true },
  });

  algosdk.assignGroupID([feeTxn, appCallTxn]);
  return { feeTxn, appCallTxn };
}
