/**
 * Deterministic redeem code ↔ preimage.
 *
 * Code format: 16-char Crockford base32 (no I, L, O, U). 80 bits entropy.
 * Preimage   : first 16 bytes of sha256(utf8(normalized code)).
 * Commitment : sha256(preimage). Posted on-chain by admin.
 *
 * Normalization: uppercase, strip dashes/spaces, map I→1, L→1, O→0.
 * Display form may include dashes for readability: `XXXX-XXXX-XXXX-XXXX`.
 */

import { createHash, randomBytes } from "node:crypto";

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const CODE_LEN = 16;

export function generateCode(): string {
  const buf = randomBytes(CODE_LEN);
  let s = "";
  for (let i = 0; i < CODE_LEN; i++) s += ALPHABET[buf[i] & 0x1f];
  return s;
}

export function formatCode(code: string): string {
  const n = normalizeCode(code);
  return `${n.slice(0, 4)}-${n.slice(4, 8)}-${n.slice(8, 12)}-${n.slice(12, 16)}`;
}

export function normalizeCode(code: string): string {
  const s = code
    .toUpperCase()
    .replace(/[-\s]/g, "")
    .replace(/I/g, "1")
    .replace(/L/g, "1")
    .replace(/O/g, "0");
  if (s.length !== CODE_LEN)
    throw new Error(`BAD_CODE_LEN (got ${s.length}, want ${CODE_LEN})`);
  for (const c of s)
    if (!ALPHABET.includes(c)) throw new Error(`BAD_CODE_CHAR ${c}`);
  return s;
}

export function preimageFromCode(code: string): Uint8Array {
  const n = normalizeCode(code);
  const h = createHash("sha256").update(n, "utf8").digest();
  return new Uint8Array(h.subarray(0, 16));
}

export function commitmentFromCode(code: string): Uint8Array {
  const pre = preimageFromCode(code);
  return new Uint8Array(createHash("sha256").update(pre).digest());
}
