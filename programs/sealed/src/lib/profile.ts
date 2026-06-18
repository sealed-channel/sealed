/**
 * Off-chain user profile helpers.
 *
 * Two layers:
 *   - `readUserProfile`  → algod box GET + ARC4 decode → UserProfile | null
 *   - `fetchFullProfile` → parallel algod box + indexer pq-pubkey fetch,
 *      sha256-verifies indexer-served pq pubkey against on-chain hash anchor.
 *
 * Mirrors `UserState` ARC4 layout in contract.algo.ts. The on-chain box only
 * anchors `sha256(pqPubkey)`; the full pq pubkey is served by indexer (cached
 * from `KeysPublished` ARC28 event log). Hash check guards against tamper.
 */

import algosdk from "algosdk";
import { createHash } from "node:crypto";
import { decodeUserState, type UserState, ZERO_KEY } from "./codec.js";

export interface UserProfile {
  wallet: string;
  version: number;
  username: Uint8Array;
  batchCount: number;
  batches: UserState["batches"];
  encryptionPubkey: Uint8Array;
  scanPubkey: Uint8Array;
  pqPubkeyHash: Uint8Array;
}

export interface FullUserProfile extends UserProfile {
  /** Full pq pubkey bytes fetched from indexer, hash-verified. */
  pqPubkey: Uint8Array;
}

function userBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  return key;
}

/**
 * Constant-time byte comparison. Returns true iff a and b are equal length and
 * have identical contents. Never short-circuits on first mismatch.
 */
export function ctEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

/**
 * Read `w:<wallet>` box via algod, decode UserState. Returns null if box
 * missing (404 / "box not found"). Throws on any other error.
 */
export async function readUserProfile(
  algod: algosdk.Algodv2,
  appId: bigint,
  wallet: string,
): Promise<UserProfile | null> {
  let raw: Uint8Array;
  try {
    const res = await algod
      .getApplicationBoxByName(Number(appId), userBoxKey(wallet))
      .do();
    raw = new Uint8Array(res.value);
  } catch (err) {
    const msg = (err as Error).message ?? "";
    if (/box not found|no application box|404/i.test(msg)) return null;
    throw err;
  }
  const state = decodeUserState(raw);
  return {
    wallet,
    version: state.version,
    username: state.username,
    batchCount: state.batchCount,
    batches: state.batches,
    encryptionPubkey: state.encryptionPubkey,
    scanPubkey: state.scanPubkey,
    pqPubkeyHash: state.pqPubkeyHash,
  };
}

export interface FetchFullProfileParams {
  algod: algosdk.Algodv2;
  /** Base URL of indexer exposing `/user/:wallet/pq-pubkey` returning raw bytes. */
  indexerBaseUrl: string;
  appId: bigint;
  wallet: string;
  /** Override for tests. Defaults to global `fetch`. */
  fetchImpl?: typeof fetch;
}

/**
 * Parallel-fetch on-chain UserState + indexer-served pq pubkey, verify hash.
 *
 * Throws:
 *   - `NOT_FOUND`         — algod has no `w:` box for wallet
 *   - `KEYS_UNSET`        — box exists but pqPubkeyHash is all-zero
 *   - `INDEXER_<status>`  — indexer returned non-2xx
 *   - `PQ_HASH_MISMATCH`  — sha256(indexerBytes) ≠ on-chain anchor
 */
export async function fetchFullProfile(
  p: FetchFullProfileParams,
): Promise<FullUserProfile> {
  const f = p.fetchImpl ?? fetch;
  const url = `${p.indexerBaseUrl.replace(/\/$/, "")}/user/${encodeURIComponent(p.wallet)}/pq-pubkey`;

  const [profile, pqResp] = await Promise.all([
    readUserProfile(p.algod, p.appId, p.wallet),
    f(url),
  ]);

  if (profile === null) throw new Error("NOT_FOUND");
  if (ctEqual(profile.pqPubkeyHash, ZERO_KEY)) throw new Error("KEYS_UNSET");
  if (!pqResp.ok) throw new Error(`INDEXER_${pqResp.status}`);

  const pqPubkey = new Uint8Array(await pqResp.arrayBuffer());
  const computed = sha256(pqPubkey);
  if (!ctEqual(computed, profile.pqPubkeyHash))
    throw new Error("PQ_HASH_MISMATCH");

  return { ...profile, pqPubkey };
}
