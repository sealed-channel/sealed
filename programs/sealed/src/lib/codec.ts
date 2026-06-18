/**
 * Codec helpers — client-side ARC4 (de)serialisation that mirrors the on-chain
 * Struct shapes declared in `contract.algo.ts`.
 *
 * Source-of-truth layouts (see SPEC §5.1):
 *   Batch       = (uint64 amount, uint64 expiryRound)
 *   UserState   = (uint8 version, bytes username, uint8 batchCount,
 *                  Batch[] batches, byte[32] encryptionPubkey,
 *                  byte[32] scanPubkey, byte[32] pqPubkeyHash, bytes bio)
 *   Commitment  = (uint64 denomination, uint64 postedAtRound)
 *
 * Wire versions: v2 has no `bio` field (102B head); v3 appends it (104B head).
 * `decodeUserState` accepts both — the contract upgrades v2 boxes lazily, so
 * off-chain readers can still encounter v2 bytes until a wallet's next write.
 * `encodeUserState` always emits v3.
 *
 * Uses algosdk's ABIType to encode/decode. The contract reads/writes the same
 * tuple bytes; this module is the off-chain mirror.
 */

import algosdk from "algosdk";

export const BATCH_TYPE = algosdk.ABIType.from("(uint64,uint64)");
/** v2 wire layout — pre-bio boxes still on chain until their next write. */
export const USER_STATE_TYPE_V2 = algosdk.ABIType.from(
  "(uint8,byte[],uint8,(uint64,uint64)[],byte[32],byte[32],byte[32])",
);
/** v3 wire layout — current. `bio` appended. */
export const USER_STATE_TYPE = algosdk.ABIType.from(
  "(uint8,byte[],uint8,(uint64,uint64)[],byte[32],byte[32],byte[32],byte[])",
);
export const COMMITMENT_TYPE = algosdk.ABIType.from("(uint64,uint64)");

export const USER_STATE_VERSION = 3;

export interface Batch {
  amount: bigint;
  expiryRound: bigint;
}

export interface UserState {
  version: number;
  username: Uint8Array;
  batchCount: number;
  batches: Batch[];
  encryptionPubkey: Uint8Array; // 32 bytes
  scanPubkey: Uint8Array; // 32 bytes
  pqPubkeyHash: Uint8Array; // 32 bytes
  /** UTF-8 bytes, ≤ BIO_MAX_BYTES. Empty = unset (v2 boxes decode as empty). */
  bio: Uint8Array;
}

export interface Commitment {
  denomination: bigint;
  postedAtRound: bigint;
}

export const MAX_BATCHES = 12;
export const MAX_USERNAME_LEN = 32;
/** Mirrors contract `BIO_MAX` — bytes of UTF-8, not characters. */
export const BIO_MAX_BYTES = 160;
export const KEY_LEN = 32;
export const ZERO_KEY = new Uint8Array(KEY_LEN);

export function encodeBatch(b: Batch): Uint8Array {
  return BATCH_TYPE.encode([b.amount, b.expiryRound]);
}

export function decodeBatch(bytes: Uint8Array): Batch {
  const tuple = BATCH_TYPE.decode(bytes) as [bigint, bigint];
  return { amount: tuple[0], expiryRound: tuple[1] };
}

function assertKeyLen(name: string, b: Uint8Array): void {
  if (b.length !== KEY_LEN) throw new Error(`${name}_BAD_LEN`);
}

export function encodeUserState(s: UserState): Uint8Array {
  // Encoder only emits the v3 layout; decode branches on the version byte,
  // so stamping any other version into v3-shaped bytes would poison decode.
  if (s.version !== USER_STATE_VERSION) throw new Error("BAD_VERSION");
  if (s.username.length > MAX_USERNAME_LEN)
    throw new Error("USERNAME_TOO_LONG");
  if (s.batches.length > MAX_BATCHES) throw new Error("TOO_MANY_BATCHES");
  if (s.batchCount !== s.batches.length)
    throw new Error("BATCH_COUNT_MISMATCH");
  if (s.bio.length > BIO_MAX_BYTES) throw new Error("BIO_TOO_LONG");
  assertKeyLen("ENC_PUBKEY", s.encryptionPubkey);
  assertKeyLen("SCAN_PUBKEY", s.scanPubkey);
  assertKeyLen("PQ_PUBKEY_HASH", s.pqPubkeyHash);
  const batches = s.batches.map((b) => [b.amount, b.expiryRound]);
  return USER_STATE_TYPE.encode([
    s.version,
    s.username,
    s.batchCount,
    batches,
    s.encryptionPubkey,
    s.scanPubkey,
    s.pqPubkeyHash,
    s.bio,
  ]);
}

export function decodeUserState(bytes: Uint8Array): UserState {
  const toU8 = (v: Uint8Array | ArrayLike<number>): Uint8Array =>
    v instanceof Uint8Array ? v : Uint8Array.from(v);

  const version = bytes[0];
  if (version === 2) {
    const tuple = USER_STATE_TYPE_V2.decode(bytes) as [
      number | bigint,
      Uint8Array | ArrayLike<number>,
      number | bigint,
      [bigint, bigint][],
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
      Uint8Array | ArrayLike<number>,
    ];
    const [v, username, batchCount, batches, enc, scan, pqHash] = tuple;
    return {
      version: Number(v),
      username: toU8(username),
      batchCount: Number(batchCount),
      batches: batches.map(([amount, expiryRound]) => ({
        amount,
        expiryRound,
      })),
      encryptionPubkey: toU8(enc),
      scanPubkey: toU8(scan),
      pqPubkeyHash: toU8(pqHash),
      bio: new Uint8Array(0),
    };
  }

  const tuple = USER_STATE_TYPE.decode(bytes) as [
    number | bigint,
    Uint8Array | ArrayLike<number>,
    number | bigint,
    [bigint, bigint][],
    Uint8Array | ArrayLike<number>,
    Uint8Array | ArrayLike<number>,
    Uint8Array | ArrayLike<number>,
    Uint8Array | ArrayLike<number>,
  ];
  const [v, username, batchCount, batches, enc, scan, pqHash, bio] = tuple;
  return {
    version: Number(v),
    username: toU8(username),
    batchCount: Number(batchCount),
    batches: batches.map(([amount, expiryRound]) => ({ amount, expiryRound })),
    encryptionPubkey: toU8(enc),
    scanPubkey: toU8(scan),
    pqPubkeyHash: toU8(pqHash),
    bio: toU8(bio),
  };
}

export function encodeCommitment(c: Commitment): Uint8Array {
  return COMMITMENT_TYPE.encode([c.denomination, c.postedAtRound]);
}

export function decodeCommitment(bytes: Uint8Array): Commitment {
  const tuple = COMMITMENT_TYPE.decode(bytes) as [bigint, bigint];
  return { denomination: tuple[0], postedAtRound: tuple[1] };
}

/** Sums non-expired batch amounts for the given current round. */
export function sumActiveCredits(s: UserState, currentRound: bigint): bigint {
  let total = 0n;
  for (const b of s.batches) {
    if (b.expiryRound > currentRound) total += b.amount;
  }
  return total;
}
