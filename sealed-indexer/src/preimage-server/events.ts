/**
 * ARC28 event decoder for `CommitmentsSold`.
 *
 * Event signature (matches `class CommitmentsSold` in
 * programs/sealed/src/contract.algo.ts):
 *
 *   CommitmentsSold(address, byte[32], byte[32][], uint64)
 *     buyer            : address           (32B)
 *     deliveryPubkey   : byte[32]          (32B)
 *     commitments      : byte[32][]        (dyn array of 32B)
 *     purchasedAtRound : uint64            (8B)
 *
 * On-chain log layout is `tag(4B) || arc4_encode(struct)` where `tag` is
 * the first 4 bytes of sha512/256(signature). We compute the tag once at
 * module load and use it to filter logs in the watcher.
 */

import { createHash } from 'node:crypto';
import algosdk from 'algosdk';

export const COMMITMENTS_SOLD_SIGNATURE =
  'CommitmentsSold(address,byte[32],byte[32][],uint64)';

export const COMMITMENTS_SOLD_TAG: Buffer = (() => {
  const digest = createHash('sha512-256').update(COMMITMENTS_SOLD_SIGNATURE, 'utf-8').digest();
  return Buffer.from(digest.subarray(0, 4));
})();

const COMMITMENTS_SOLD_TYPE = algosdk.ABIType.from(
  '(address,byte[32],byte[32][],uint64)',
);

const COMMITMENT_LEN = 32;
const DELIVERY_PUBKEY_LEN = 32;
const MAX_COMMITMENTS_PER_PURCHASE = 8;

export interface CommitmentsSoldEvent {
  buyer: string; // Algorand address (base32, 58 chars)
  deliveryPubkey: Uint8Array; // 32 bytes
  commitments: Uint8Array[]; // each entry is 32 bytes
  purchasedAtRound: bigint;
}

/**
 * Coerce algosdk's ARC4 decode output (which returns plain `number[]` for
 * `byte[N]` types, not `Uint8Array`) into a Uint8Array of the expected
 * length. Returns null on any shape mismatch so the parser falls back to
 * "not a CommitmentsSold event" instead of throwing.
 */
function toFixedBytes(v: unknown, expectedLen: number): Uint8Array | null {
  if (v instanceof Uint8Array) {
    return v.length === expectedLen ? new Uint8Array(v) : null;
  }
  if (Array.isArray(v) && v.length === expectedLen) {
    const out = new Uint8Array(expectedLen);
    for (let i = 0; i < expectedLen; i++) {
      const b = v[i];
      if (typeof b !== 'number' || !Number.isInteger(b) || b < 0 || b > 0xff) return null;
      out[i] = b;
    }
    return out;
  }
  return null;
}

/**
 * Decode the bytes of a single app-call log entry as a CommitmentsSold
 * event. Returns null for anything that does not match — wrong tag,
 * malformed ARC4 body, illegal field sizes — so the watcher can skip
 * non-event logs without throwing.
 */
export function parseCommitmentsSoldEvent(
  log: Uint8Array,
): CommitmentsSoldEvent | null {
  if (log.length < COMMITMENTS_SOLD_TAG.length) return null;
  for (let i = 0; i < COMMITMENTS_SOLD_TAG.length; i++) {
    if (log[i] !== COMMITMENTS_SOLD_TAG[i]) return null;
  }
  // algosdk's ABI decoder reads from the backing ArrayBuffer at offset 0
  // and does not honour the Uint8Array's byteOffset — feeding it a
  // subarray view throws "dynamic segment should display a [l, r] space".
  // Force a fresh, offset-0 copy.
  const body = new Uint8Array(log.length - COMMITMENTS_SOLD_TAG.length);
  body.set(log.subarray(COMMITMENTS_SOLD_TAG.length));

  let decoded: unknown;
  try {
    decoded = COMMITMENTS_SOLD_TYPE.decode(body);
  } catch {
    return null;
  }
  if (!Array.isArray(decoded) || decoded.length !== 4) return null;
  const [buyerRaw, deliveryPubkeyRaw, commitmentsRaw, purchasedAtRoundRaw] = decoded;

  if (typeof buyerRaw !== 'string') return null;
  const deliveryPubkey = toFixedBytes(deliveryPubkeyRaw, DELIVERY_PUBKEY_LEN);
  if (!deliveryPubkey) return null;
  if (!Array.isArray(commitmentsRaw)) return null;
  if (commitmentsRaw.length === 0 || commitmentsRaw.length > MAX_COMMITMENTS_PER_PURCHASE) {
    return null;
  }
  const commitments: Uint8Array[] = [];
  for (const c of commitmentsRaw) {
    const bytes = toFixedBytes(c, COMMITMENT_LEN);
    if (!bytes) return null;
    commitments.push(bytes);
  }
  if (typeof purchasedAtRoundRaw !== 'bigint' || purchasedAtRoundRaw < 0n) return null;

  return {
    buyer: buyerRaw,
    deliveryPubkey,
    commitments,
    purchasedAtRound: purchasedAtRoundRaw,
  };
}

/**
 * Encode a CommitmentsSold event back into its on-chain log bytes
 * (`tag || arc4_encode(struct)`). Used by tests; the sidecar itself never
 * emits events — that's the contract's job.
 */
export function encodeCommitmentsSoldEvent(ev: CommitmentsSoldEvent): Uint8Array {
  if (ev.deliveryPubkey.length !== DELIVERY_PUBKEY_LEN) {
    throw new Error('deliveryPubkey must be 32 bytes');
  }
  if (ev.commitments.length === 0) throw new Error('commitments must be non-empty');
  for (const c of ev.commitments) {
    if (c.length !== COMMITMENT_LEN) throw new Error('every commitment must be 32 bytes');
  }
  const body = COMMITMENTS_SOLD_TYPE.encode([
    ev.buyer,
    ev.deliveryPubkey,
    ev.commitments,
    ev.purchasedAtRound,
  ]);
  const out = new Uint8Array(COMMITMENTS_SOLD_TAG.length + body.length);
  out.set(COMMITMENTS_SOLD_TAG, 0);
  out.set(body, COMMITMENTS_SOLD_TAG.length);
  return out;
}
