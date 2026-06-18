/**
 * Username helpers for Sealed (Phase 3b — universal escrow group).
 *
 * Wraps `claimUsername(byte[])void`, `releaseUsername()void`, and
 * `resolveUsername(byte[]):address` ABI calls. All MUTATING ops
 * (`claim` / `release`) ride the treasury escrow fee-pool group; treasury
 * pays the network fee, user wallet pays zero ALGO, contract spends 1
 * credit on the caller's UserState box. `resolve` is readonly (single
 * sender-paid app call — caller can be any wallet with min balance).
 *
 * Charset (mirrors contract `validateNameFormat`): a-z, 0-9, '_'.
 * Length 3..20. No leading digit/underscore, no trailing underscore.
 * Caller-side validation gives early errors before round-tripping the chain.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadTreasuryEscrow, type LoadedEscrow } from "./escrow.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(__dirname, "../../out/Sealed.arc56.json");

const NAME_MIN = 3;
const NAME_MAX = 20;
const NAME_RE = /^[a-z0-9][a-z0-9_]*[a-z0-9]$/;
// Treasury self-pay funds the entire group: 1 minFee (escrow pay) + 1 minFee
// (app call at fee=0) + 3 minFee opup inner-appl txns issued via
// ensureBudget(2400, GroupCredit) inside the contract = 5 × minFee = 5000µA.
// Pooled across the group; user wallet pays zero ALGO.
const GROUP_FEE = 5000;

export function validateUsername(name: string): void {
  if (name.length < NAME_MIN || name.length > NAME_MAX)
    throw new Error("BAD_LEN");
  if (!NAME_RE.test(name)) throw new Error("BAD_CHAR");
}

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

function nameBoxKey(name: string): Uint8Array {
  const hash = sha256(new TextEncoder().encode(name));
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("n:"), 0);
  key.set(hash, 2);
  return key;
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

const CLAIM_SELECTOR = new Uint8Array(
  algosdk.ABIMethod.fromSignature("claimUsername(byte[])void").getSelector(),
);
const RELEASE_SELECTOR = new Uint8Array(
  algosdk.ABIMethod.fromSignature("releaseUsername()void").getSelector(),
);

export interface ClaimUsernameParams {
  algorand: AlgorandClient;
  appId: bigint;
  user: algosdk.Account;
  username: string;
  /** Optional: previous username, if known, so its 'n:' box can be referenced. */
  previousUsername?: string;
  /** Optional: pre-loaded escrow. Loaded from compiled TEAL if omitted. */
  escrow?: LoadedEscrow;
}

export async function claimUsername(p: ClaimUsernameParams): Promise<string> {
  validateUsername(p.username);
  const algod = p.algorand.client.algod;
  const escrow = p.escrow ?? (await loadTreasuryEscrow(algod));

  const boxes: { appIndex: number; name: Uint8Array }[] = [
    { appIndex: Number(p.appId), name: creditBoxKey(p.user.addr.toString()) },
    { appIndex: Number(p.appId), name: nameBoxKey(p.username) },
  ];
  if (p.previousUsername) {
    boxes.push({
      appIndex: Number(p.appId),
      name: nameBoxKey(p.previousUsername),
    });
  }

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
    appArgs: [
      CLAIM_SELECTOR,
      encodeBytes(new TextEncoder().encode(p.username)),
    ],
    boxes,
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

export interface ReleaseUsernameParams {
  algorand: AlgorandClient;
  appId: bigint;
  user: algosdk.Account;
  /** Previous username — required to compute the 'n:' box reference. */
  username: string;
  /** Optional: pre-loaded escrow. */
  escrow?: LoadedEscrow;
}

export async function releaseUsername(
  p: ReleaseUsernameParams,
): Promise<string> {
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
    appArgs: [RELEASE_SELECTOR],
    boxes: [
      { appIndex: Number(p.appId), name: creditBoxKey(p.user.addr.toString()) },
      { appIndex: Number(p.appId), name: nameBoxKey(p.username) },
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

export interface ResolveUsernameParams {
  algorand: AlgorandClient;
  appId: bigint;
  sender: algosdk.Account;
  username: string;
}

export async function resolveUsername(
  p: ResolveUsernameParams,
): Promise<string> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  p.algorand.setSignerFromAccount(p.sender);
  const client = p.algorand.client.getAppClientById({
    appSpec,
    appId: p.appId,
    defaultSender: p.sender.addr,
  });

  const result = await client.send.call({
    method: "resolveUsername(byte[])address",
    args: [new TextEncoder().encode(p.username)],
    boxReferences: [nameBoxKey(p.username)],
    sender: p.sender.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  const ret = result.return as unknown;
  if (typeof ret === "string") return ret;
  if (ret instanceof Uint8Array) return algosdk.encodeAddress(ret);
  throw new Error("UNEXPECTED_RETURN");
}
