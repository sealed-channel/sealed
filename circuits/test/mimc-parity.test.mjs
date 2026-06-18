// Leg B of the MiMC parity gate: prove the circom MiMCHash matches the JS
// reference oracle (which is already verified == on-chain AVM mimc BN254Mp110)
// byte-for-byte, for six input vectors. If circom == ref, then circom == AVM
// transitively.
//
// Run: node test/mimc-parity.test.mjs   (from circuits/)
import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const require = createRequire(import.meta.url);
const wasm_tester = require('circom_tester').wasm;
const { mimcBN254, P } = await import(new URL('./mimc-bn254-ref.mjs', import.meta.url));

const __dirname = dirname(fileURLToPath(import.meta.url));
const CIRCUITS = resolve(__dirname, '..');

// --- helpers -----------------------------------------------------------------
function biToBE32(x) {
  const out = new Uint8Array(32);
  for (let i = 31; i >= 0; i--) { out[i] = Number(x & 0xffn); x >>= 8n; }
  return out;
}
function be32ToBi(bytes) {
  let x = 0n;
  for (const b of bytes) x = (x << 8n) | BigInt(b);
  return x;
}
function concatBlocks(bigints) {
  const out = new Uint8Array(32 * bigints.length);
  bigints.forEach((b, i) => out.set(biToBE32(b), i * 32));
  return out;
}

// Build a tiny top-level circuit wrapping MiMCHash(n) for a given block count.
function makeMainCircom(nBlocks) {
  const dir = mkdtempSync(join(tmpdir(), `mimc-parity-${nBlocks}-`));
  const src = `pragma circom 2.0.0;
include "${join(CIRCUITS, 'mimc_bn254.circom')}";
template Main(n) {
  signal input blocks[n];
  signal output out;
  component h = MiMCHash(n);
  for (var i = 0; i < n; i++) { h.blocks[i] <== blocks[i]; }
  out <== h.out;
}
component main = Main(${nBlocks});
`;
  const file = join(dir, `main_${nBlocks}.circom`);
  writeFileSync(file, src);
  return file;
}

// arbitrary in-range values
const ARB = 1234567890123456789012345678901234567890n % P;
const ARB2 = 98765432109876543210987654321098765432109n % P;
const PM1 = P - 1n;

const VECTORS = [
  { name: 'single block 0',                 blocks: [0n] },
  { name: 'single block 1',                 blocks: [1n] },
  { name: 'single block arbitrary',         blocks: [ARB] },
  { name: 'single block p-1',               blocks: [PM1] },
  { name: 'two blocks: 1, 2',               blocks: [1n, 2n] },
  { name: 'two blocks: arbitrary, p-1',     blocks: [ARB2, PM1] },
];

// cache compiled circuits per block count
const circuits = new Map();
async function getCircuit(nBlocks) {
  if (!circuits.has(nBlocks)) {
    const file = makeMainCircom(nBlocks);
    const c = await wasm_tester(file, { include: [join(CIRCUITS, 'node_modules')] });
    circuits.set(nBlocks, c);
  }
  return circuits.get(nBlocks);
}

let allPass = true;
const rows = [];

for (const v of VECTORS) {
  const nBlocks = v.blocks.length;
  const circuit = await getCircuit(nBlocks);

  // ref output
  const refBytes = mimcBN254(concatBlocks(v.blocks));
  const refBi = be32ToBi(refBytes);

  // circuit witness output
  const input = { blocks: v.blocks.map((b) => b.toString()) };
  const witness = await circuit.calculateWitness(input, true);
  await circuit.checkConstraints(witness); // ensure witness satisfies R1CS
  // out is the single output signal: read it via getDecoratedOutput symbol map.
  await circuit.loadSymbols();
  const outIdx = circuit.symbols['main.out'].varIdx;
  const circBi = BigInt(witness[outIdx].toString());

  const match = circBi === refBi;
  if (!match) allPass = false;
  rows.push({ name: v.name, ref: refBi, circ: circBi, match });
}

// --- parity table ------------------------------------------------------------
console.log('\n=== MiMC BN254Mp110 parity: circom vs JS ref oracle ===\n');
for (const r of rows) {
  console.log(`[${r.match ? 'MATCH' : 'FAIL '}] ${r.name}`);
  console.log(`   ref : ${r.ref}`);
  console.log(`   circ: ${r.circ}`);
  if (!r.match) console.log(`   >>> MISMATCH <<<`);
}
console.log(`\n${allPass ? 'ALL 6 VECTORS MATCH' : 'SOME VECTORS FAILED'}\n`);

if (!allPass) process.exit(1);
