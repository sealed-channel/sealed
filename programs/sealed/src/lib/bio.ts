/**
 * Bio helpers for Sealed (universal escrow group).
 *
 * Wraps the `setBio(byte[])void` ABI call. Mutating — rides the treasury
 * escrow fee-pool group like `claimUsername`; treasury pays the network fee,
 * user wallet pays zero ALGO, contract spends 1 credit on the caller's
 * UserState box. Empty bio clears the field.
 *
 * Validation (mirrors contract): length-only, ≤ BIO_MAX_BYTES UTF-8 bytes.
 * Content policy (control chars) is a client-app concern, not enforced here.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { loadTreasuryEscrow, type LoadedEscrow } from "./escrow.js";
import { BIO_MAX_BYTES } from "./codec.js";

// Same fee-pool shape as claimUsername: 1 minFee escrow pay + 1 minFee app
// call (fee=0) + 3 minFee opup headroom for ensureBudget(2400, GroupCredit).
const GROUP_FEE = 5000;

export function validateBio(bio: Uint8Array): void {
  if (bio.length > BIO_MAX_BYTES) throw new Error("BIO_TOO_LONG");
}

function creditBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  return key;
}

/** ARC-4 byte[] encoding: 2-byte big-endian length prefix + payload. */
function encodeBytes(b: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + b.length);
  new DataView(out.buffer).setUint16(0, b.length, false);
  out.set(b, 2);
  return out;
}

const SET_BIO_SELECTOR = new Uint8Array(
  algosdk.ABIMethod.fromSignature("setBio(byte[])void").getSelector(),
);

export interface SetBioParams {
  algorand: AlgorandClient;
  appId: bigint;
  user: algosdk.Account;
  /** UTF-8 bytes, ≤ BIO_MAX_BYTES. Empty clears the bio. */
  bio: Uint8Array;
  /** Optional: pre-loaded escrow. Loaded from compiled TEAL if omitted. */
  escrow?: LoadedEscrow;
}

export async function setBio(p: SetBioParams): Promise<string> {
  validateBio(p.bio);
  const algod = p.algorand.client.algod;
  const escrow = p.escrow ?? (await loadTreasuryEscrow(algod));

  const sp = await algod.getTransactionParams().do();
  const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: escrow.address,
    receiver: escrow.address,
    amount: 0,
    suggestedParams: { ...sp, fee: GROUP_FEE, flatFee: true },
  });
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: p.user.addr,
    appIndex: Number(p.appId),
    appArgs: [SET_BIO_SELECTOR, encodeBytes(p.bio)],
    boxes: [
      { appIndex: Number(p.appId), name: creditBoxKey(p.user.addr.toString()) },
    ],
    suggestedParams: { ...sp, fee: 0, flatFee: true },
  });

  algosdk.assignGroupID([feeTxn, appCallTxn]);
  const signedFee = algosdk.signLogicSigTransactionObject(
    feeTxn,
    escrow.account,
  ).blob;
  const signedCall = appCallTxn.signTxn(p.user.sk);
  const { txid } = await algod.sendRawTransaction([signedFee, signedCall]).do();
  await algosdk.waitForConfirmation(algod, txid, 4);
  return appCallTxn.txID();
}
