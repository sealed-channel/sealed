// MiMC over BN254 scalar field (alt_bn128 Fr), Miyaguchi-Preneel mode.
// Reference implementation matching go-algorand's `mimc BN254Mp110` opcode,
// which wraps gnark-crypto's ecc/bn254/fr/mimc.
//
// Spec (confirmed from gnark-crypto ecc/bn254/fr/mimc/mimc.go):
//   p      = BN254 Fr modulus
//   rounds = 110
//   sbox   = x^5
//   seed   = ASCII "seed"
//   Round constants (legacy keccak256, NOT sha3-256):
//     rnd = keccak256("seed")            // primed into the hash, discarded as a constant
//     for i in 0..110:
//       rnd = keccak256(rnd)             // i.e. c[0] = keccak256(keccak256("seed"))
//       c[i] = rnd mod p                 //      c[i] = keccak256(c[i-1] bytes) mod p
//   encrypt(m; key=h):
//     for i in 0..110: t = m + h + c[i]; m = t^5
//     return m + h
//   Miyaguchi-Preneel feed-forward over 32-byte big-endian blocks:
//     h = 0
//     for each block m_i: h = encrypt(m_i; key=h) + h + m_i
//     output = h as 32 big-endian bytes
//
// NOTE on input validation: the AVM opcode requires the input length be a
// multiple of 32, and requires each 32-byte block to be a CANONICAL fr.Element
// (big-endian value strictly < p). Non-canonical blocks (value >= p, e.g. a raw
// 32-byte value with the high bits set, or the encoding of p itself) are
// REJECTED on-chain with "invalid mimc input invalid fr.Element encoding" — the
// opcode does NOT reduce mod p. This reference mirrors that and throws on >= p,
// so the circom circuit / callers must guarantee leaves are < p. (Verified
// against localnet algod 4.7.0, mimc BN254Mp110.)

import { keccak_256 } from '@noble/hashes/sha3.js';
const keccak256 = { array: (bytes) => keccak_256(bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes)) };

export const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const ROUNDS = 110;

// --- round constants ---------------------------------------------------------
function bytesToBigInt(bytes) {
  let x = 0n;
  for (const b of bytes) x = (x << 8n) | BigInt(b);
  return x;
}

function buildConstants() {
  const cs = [];
  // prime the hash with keccak256("seed")
  let rnd = keccak256.array(new TextEncoder().encode('seed')); // Uint8Array length 32
  for (let i = 0; i < ROUNDS; i++) {
    rnd = keccak256.array(rnd);
    cs.push(bytesToBigInt(rnd) % P);
  }
  return cs;
}

const CONSTANTS = buildConstants();

// --- field ops ---------------------------------------------------------------
function fadd(a, b) { const r = (a + b) % P; return r < 0n ? r + P : r; }
function fmul(a, b) { return (a * b) % P; }
function fpow5(x) {
  const x2 = fmul(x, x);
  const x4 = fmul(x2, x2);
  return fmul(x4, x);
}

// --- MiMC permutation (gnark encrypt), key = h -------------------------------
function encrypt(m, h) {
  for (let i = 0; i < ROUNDS; i++) {
    const t = fadd(fadd(m, h), CONSTANTS[i]);
    m = fpow5(t);
  }
  return fadd(m, h);
}

// --- Miyaguchi-Preneel hash --------------------------------------------------
export function mimcBN254(bytes) {
  if (!(bytes instanceof Uint8Array)) bytes = Uint8Array.from(bytes);
  if (bytes.length % 32 !== 0) {
    throw new Error(`input length must be a multiple of 32, got ${bytes.length}`);
  }
  let h = 0n;
  for (let off = 0; off < bytes.length; off += 32) {
    const block = bytes.subarray(off, off + 32);
    const raw = bytesToBigInt(block);
    // The AVM opcode requires each 32-byte block to be a CANONICAL fr.Element
    // (value < p). It rejects non-canonical encodings with
    // "invalid fr.Element encoding" rather than reducing mod p. We mirror that.
    if (raw >= P) {
      throw new Error(
        `invalid fr.Element encoding at block offset ${off}: value >= field modulus p (AVM rejects this)`
      );
    }
    const m = raw; // already < p
    const r = encrypt(m, h);
    h = fadd(fadd(r, h), m);
  }
  // output as 32 big-endian bytes
  const out = new Uint8Array(32);
  let x = h;
  for (let i = 31; i >= 0; i--) { out[i] = Number(x & 0xffn); x >>= 8n; }
  return out;
}

export function toHex(u8) {
  return Array.from(u8).map((b) => b.toString(16).padStart(2, '0')).join('');
}
