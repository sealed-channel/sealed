// Parity/sanity gate for the rewritten Sealed redeem circuit (Redeem(16), MiMC).
//
// Proves the circuit's internal MiMC Merkle tree + nullifier agree with a tree
// built entirely from the AVM-mimc reference oracle (./mimc-bn254-ref.mjs,
// already verified byte-for-byte == on-chain `mimc BN254Mp110`).
//
// Strategy: build an incremental height-16 tree with the leaf at index 0 using
// the ref oracle for EVERY hash, then feed (root, nullifier, ...) to the circuit.
// The circuit constrains cur[16] === root and nullifier === MiMCHash(preimage,
// NULL_TAG). If calculateWitness succeeds AND checkConstraints passes, the
// circuit's internally-recomputed root/nullifier equal the ref-oracle ones —
// that IS the parity proof (transitively == AVM).
//
// Negative check: root+1 must make calculateWitness throw, proving the
// cur[16]===root constraint is actually exercised (not vacuously passing).
//
// Run: node test/redeem-parity.test.mjs   (from circuits/)

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const wasm_tester = require('circom_tester').wasm;
const { mimcBN254, P } = await import(new URL('./mimc-bn254-ref.mjs', import.meta.url));

const __dirname = dirname(fileURLToPath(import.meta.url));
const CIRCUITS = resolve(__dirname, '..');

const HEIGHT = 16;
const NULL_TAG = 110815058874449983093867477470989876063n; // "SEALED_NULL_V1__"

// --- field-element <-> 32-byte big-endian helpers ----------------------------
function bigintTo32BE(x) {
  assert(x >= 0n && x < P, `value out of field range (>= p): ${x}`);
  const out = new Uint8Array(32);
  for (let i = 31; i >= 0; i--) { out[i] = Number(x & 0xffn); x >>= 8n; }
  return out;
}
function be32ToBigint(bytes) {
  let x = 0n;
  for (const b of bytes) x = (x << 8n) | BigInt(b);
  return x;
}
function concat(...buffers) {
  const total = buffers.reduce((n, b) => n + b.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const b of buffers) { out.set(b, off); off += b.length; }
  return out;
}
// Hash one or more field elements via the ref oracle (each as a 32-byte BE block).
function refHash(...fields) {
  const input = concat(...fields.map(bigintTo32BE));
  const out = be32ToBigint(mimcBN254(input));
  assert(out >= 0n && out < P, `ref oracle output out of range: ${out}`);
  return out;
}

// --- 1. concrete secret ------------------------------------------------------
// 16-byte value 0x0123456789abcdef0123456789abcdef, clearly < p.
const preimage = 0x0123456789abcdef0123456789abcdefn;
assert(preimage < P);

// --- 2. incremental height-16 tree, leaf at index 0 (leftmost) ---------------
// Empty-subtree (zeros) ladder: zeros[0] = 0 (empty leaf value),
// zeros[k+1] = mimc(zeros[k] || zeros[k]).
const zeros = new Array(HEIGHT);
zeros[0] = 0n;
for (let k = 0; k + 1 < HEIGHT; k++) {
  zeros[k + 1] = refHash(zeros[k], zeros[k]);
}

// leaf := mimc(preimage)  (single 32-byte block, == on-chain deposit leaf)
const leaf = refHash(preimage);

// Walk up: leaf is leftmost, every sibling is the empty subtree zeros[i].
// pathElements[i] = zeros[i], pathIndices[i] = 0 (cur is left child).
let cur = leaf;
for (let i = 0; i < HEIGHT; i++) {
  cur = refHash(cur, zeros[i]); // mimc(cur || zeros[i])
}
const root = cur;

// nullifier := mimc(preimage || NULL_TAG)
const nullifier = refHash(preimage, NULL_TAG);

const pathElements = zeros.slice(0, HEIGHT); // zeros[0..15]
const pathIndices = new Array(HEIGHT).fill(0);

console.log('\n=== Sealed redeem MiMC parity (circuit vs AVM-mimc ref oracle) ===\n');
console.log(`preimage  : ${preimage}`);
console.log(`leaf      : ${leaf}`);
console.log(`root      : ${root}`);
console.log(`nullifier : ${nullifier}\n`);

// --- 3. compile circuit (source unchanged; no .r1cs regeneration here) --------
const circuit = await wasm_tester(join(CIRCUITS, 'redeem.circom'), {
  include: [join(CIRCUITS, 'node_modules')],
});

const baseInput = {
  root,
  nullifier,
  recipient: 12345n,
  denomination: 500n,
  preimage,
  pathElements,
  pathIndices,
};
// circom_tester accepts BigInt; stringify to be explicit.
function asStrings(obj) {
  const o = {};
  for (const [k, v] of Object.entries(obj)) {
    o[k] = Array.isArray(v) ? v.map((x) => x.toString()) : v.toString();
  }
  return o;
}

// --- POSITIVE case -----------------------------------------------------------
let positivePass = false;
try {
  const witness = await circuit.calculateWitness(asStrings(baseInput), true);
  await circuit.checkConstraints(witness);
  positivePass = true;
} catch (err) {
  console.error('POSITIVE case error:', err.message || err);
}
console.log(`[${positivePass ? 'PASS' : 'FAIL'}] positive: circuit root/nullifier == ref-oracle tree`);
if (!positivePass) {
  console.log('   >>> circuit MiMC tree does NOT match the ref oracle.');
  console.log('   >>> Check: zero convention (zeros[0]=0, mimc(z||z)),');
  console.log('   >>> block concat (left||right 64 bytes), endianness (BE),');
  console.log('   >>> leaf single-block mimc(preimage).');
}

// --- NEGATIVE case: flip root, expect calculateWitness to throw ---------------
let negativePass = false;
try {
  const badInput = { ...baseInput, root: (root + 1n) % P };
  await circuit.calculateWitness(asStrings(badInput), true);
  // If it did NOT throw, the constraint isn't being exercised.
  console.error('NEGATIVE case: calculateWitness did NOT throw on root+1 (constraint not enforced!)');
} catch (err) {
  negativePass = true; // expected: cur[16] === root assertion fails
}
console.log(`[${negativePass ? 'PASS' : 'FAIL'}] negative: root+1 correctly rejected (cur[16]===root enforced)`);

console.log(`\n${positivePass && negativePass ? 'ALL CHECKS PASS' : 'SOME CHECKS FAILED'}\n`);

if (!(positivePass && negativePass)) process.exit(1);
