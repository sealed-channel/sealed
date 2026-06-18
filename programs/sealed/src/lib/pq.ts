/**
 * Key-publish helper for Sealed (Phase 3b — universal escrow group).
 *
 * Submits `[escrowSelfPay, publishKeys appCall]` 2-txn group:
 *   Txn 0  Treasury LogicSig self-pay, amount 0, fee = 2 × minFee, flat.
 *   Txn 1  User app-call `publishKeys(byte[32],byte[32],byte[])void`, fee 0.
 *
 * Treasury pays group fee. User wallet pays zero ALGO. Caller must have prior
 * credits (redeemed first); the contract reverts `NO_CREDITS` otherwise. One
 * credit is spent per publish.
 *
 * Constraints on `pqPubkey`: 32 ≤ length ≤ 2048. 32-byte enc + scan pubkeys.
 * Emits ARC28 `KeysPublished` with full pq pubkey + on-chain hash.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import algosdk from "algosdk";
import { loadTreasuryEscrow, type LoadedEscrow } from "./escrow.js";

/**
 * MBR (µALGO) for a fresh `w:` UserState box. Pre-funded by app account at
 * redeem time. Documentation-only here — no longer paid by publishKeys caller.
 */
export const MBR_NEW_USER_BOX = 150_000n;

export const PQ_KEY_MIN = 32;
export const PQ_KEY_MAX = 2048;

const PUBLISH_KEYS_METHOD = new algosdk.ABIMethod({
  name: "publishKeys",
  args: [
    { name: "encryptionPubkey", type: "byte[32]" },
    { name: "scanPubkey", type: "byte[32]" },
    { name: "pqPubkey", type: "byte[]" },
  ],
  returns: { type: "void" },
});

// Pool 3× minFee = 3000µA. Buys 2100 opcode budget — covers spendOneCredit
// + sha256(pq up to 2048B) + box write under all valid pqPubkey sizes.
const GROUP_FEE = 3000;

function userBoxKey(addr: algosdk.Address | string): Uint8Array {
  const pk = algosdk.decodeAddress(
    typeof addr === "string" ? addr : addr.toString(),
  ).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  return key;
}

/** ARC-4 byte[] encoding: 2-byte big-endian length prefix + payload. */
function encodeBytes(bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + bytes.length);
  new DataView(out.buffer).setUint16(0, bytes.length, false);
  out.set(bytes, 2);
  return out;
}

export interface PublishKeysParams {
  algorand: AlgorandClient;
  appId: bigint;
  sender: algosdk.Account;
  encryptionPubkey: Uint8Array; // 32 bytes
  scanPubkey: Uint8Array; // 32 bytes
  pqPubkey: Uint8Array; // 32–2048 bytes
  /** Optional: pre-loaded escrow. Loaded from compiled TEAL if omitted. */
  escrow?: LoadedEscrow;
}

export interface PublishKeysResult {
  /** App-call txId (last in group). */
  txId: string;
  /** All group txIds. Length 2 (escrow self-pay + app-call). */
  txIds: string[];
}

export async function publishKeys(
  p: PublishKeysParams,
): Promise<PublishKeysResult> {
  if (p.encryptionPubkey.length !== 32) throw new Error("ENC_PUBKEY_BAD_LEN");
  if (p.scanPubkey.length !== 32) throw new Error("SCAN_PUBKEY_BAD_LEN");
  if (p.pqPubkey.length < PQ_KEY_MIN) throw new Error("PQ_KEY_TOO_SHORT");
  if (p.pqPubkey.length > PQ_KEY_MAX) throw new Error("PQ_KEY_TOO_LONG");

  const algod = p.algorand.client.algod;
  const escrow = p.escrow ?? (await loadTreasuryEscrow(algod));
  const senderAddr = p.sender.addr.toString();
  const boxRef = userBoxKey(senderAddr);
  const sp = await algod.getTransactionParams().do();

  const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: escrow.address,
    receiver: escrow.address,
    amount: 0,
    suggestedParams: { ...sp, fee: GROUP_FEE, flatFee: true },
  });

  const selector = new Uint8Array(PUBLISH_KEYS_METHOD.getSelector());
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: p.sender.addr,
    appIndex: Number(p.appId),
    appArgs: [
      selector,
      p.encryptionPubkey,
      p.scanPubkey,
      encodeBytes(p.pqPubkey),
    ],
    boxes: [{ appIndex: Number(p.appId), name: boxRef }],
    suggestedParams: { ...sp, fee: 0, flatFee: true },
  });

  algosdk.assignGroupID([feeTxn, appCallTxn]);
  const signedFee = algosdk.signLogicSigTransactionObject(
    feeTxn,
    escrow.account,
  ).blob;
  const signedCall = appCallTxn.signTxn(p.sender.sk);

  const { txid } = await algod.sendRawTransaction([signedFee, signedCall]).do();
  await algosdk.waitForConfirmation(algod, txid, 4);
  // Return appCall txid so callers reading logs/events hit the right txn.
  return { txId: appCallTxn.txID(), txIds: [feeTxn.txID(), appCallTxn.txID()] };
}
