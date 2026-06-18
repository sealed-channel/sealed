/**
 * Short-code ↔ preimage utilities.
 *
 * Format (SPEC §11.2):
 *   - 12-char base32, RFC 4648 alphabet `A-Z2-7`, no padding.
 *   - 12 chars × 5 bits = 60 bits → 2^60 keyspace (lookup-only).
 *   - The on-chain commitment hashes a separate full 16-byte preimage stored
 *     server-side; the short code is only an indexer-DB lookup key.
 *
 * On-chain commitment = sha256(preimage), where preimage = 16 random bytes.
 */

import { createHash, randomBytes } from "node:crypto";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const SHORT_CODE_BITS = 60;
const SHORT_CODE_LEN = SHORT_CODE_BITS / 5; // 12
const SHORT_CODE_BYTES = Math.ceil(SHORT_CODE_BITS / 8); // 8 (top 60 bits used)
const PREIMAGE_LEN = 16;

const ALPHABET_INDEX = new Map<string, number>(
  Array.from(ALPHABET).map((ch, i) => [ch, i] as const),
);

export interface ShortCodeBundle {
  /** 12-char human-shareable lookup key. */
  shortCode: string;
  /** Raw 60-bit value, packed into 8 bytes (top 60 bits). */
  shortCodeBytes: Uint8Array;
  /** Random 16-byte preimage stored server-side. */
  preimage: Uint8Array;
  /** sha256(preimage), 32 bytes — posted on-chain as the commitment key. */
  commitmentHash: Uint8Array;
}

/** Generates a fresh code/preimage pair. CSPRNG-backed. */
export function generateShortCode(): ShortCodeBundle {
  const raw = new Uint8Array(randomBytes(SHORT_CODE_BYTES));
  // Mask off the bottom 4 bits of byte 7 — only top 60 bits are meaningful.
  raw[7] = raw[7] & 0xf0;
  const shortCode = encodeShortCode(raw);
  const preimage = new Uint8Array(randomBytes(PREIMAGE_LEN));
  const commitmentHash = sha256(preimage);
  return { shortCode, shortCodeBytes: raw, preimage, commitmentHash };
}

/** Encodes 8-byte raw (top 60 bits) → 12-char base32. */
export function encodeShortCode(raw: Uint8Array): string {
  if (raw.length !== SHORT_CODE_BYTES) throw new Error("BAD_RAW_LEN");
  let bits = 0n;
  for (let i = 0; i < SHORT_CODE_BYTES; i++)
    bits = (bits << 8n) | BigInt(raw[i]);
  // Drop the bottom 4 bits, leaving 60 meaningful bits.
  bits = bits >> 4n;
  let out = "";
  for (let i = SHORT_CODE_LEN - 1; i >= 0; i--) {
    const idx = Number((bits >> BigInt(i * 5)) & 0x1fn);
    out += ALPHABET[idx];
  }
  return out;
}

/** Decodes 12-char base32 → 8-byte raw (top 60 bits, bottom 4 bits zero). */
export function decodeShortCode(code: string): Uint8Array {
  if (code.length !== SHORT_CODE_LEN) throw new Error("BAD_CODE_LEN");
  let bits = 0n;
  for (const ch of code) {
    const idx = ALPHABET_INDEX.get(ch);
    if (idx === undefined) throw new Error("BAD_CODE_CHAR");
    bits = (bits << 5n) | BigInt(idx);
  }
  // Re-pad bottom 4 bits to align with 8-byte buffer.
  bits = bits << 4n;
  const out = new Uint8Array(SHORT_CODE_BYTES);
  for (let i = SHORT_CODE_BYTES - 1; i >= 0; i--) {
    out[i] = Number(bits & 0xffn);
    bits = bits >> 8n;
  }
  return out;
}

/** Validates a short code is exactly 12 chars from the RFC 4648 alphabet. */
export function isValidShortCode(code: string): boolean {
  if (code.length !== SHORT_CODE_LEN) return false;
  for (const ch of code) if (!ALPHABET_INDEX.has(ch)) return false;
  return true;
}

export function commitmentFromPreimage(preimage: Uint8Array): Uint8Array {
  return sha256(preimage);
}

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

export const constants = {
  SHORT_CODE_LEN,
  SHORT_CODE_BITS,
  PREIMAGE_LEN,
  ALPHABET,
} as const;
