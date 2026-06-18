# SNARK golden vectors

Cross-stack test fixtures for Spec B redeem circuit.

**Source of truth:** `circuits/redeem.circom` @ git commit recorded in each vector's `note`.

**Generator:** `circuits/scripts/gen-vectors.mjs`. Deterministic — same git state regenerates identical vectors.

**Verifier (this codebase):**
```bash
cd circuits
node scripts/verify-vector.mjs ../programs/sealed/test/snark-vectors/vector-07-edge0.json keys/vk_dev.json
```

## Status

DEV-ONLY. Vectors signed against `keys/vk_dev.json` (single-contributor ceremony, see `circuits/keys/ceremony-dev-log.md`). After production ceremony, regenerate all vectors:

```bash
cd circuits
node scripts/gen-vectors.mjs   # uses keys/redeem_dev.zkey by default; edit to point at redeem_prod_FINAL.zkey
```

## Schema

```jsonc
{
  "name": "vector-07-edge0",
  "note": "...",
  "publicInputs": {
    "root":         "Fr-as-decimal-string",
    "nullifier":    "Fr",
    "recipient":    "Fr",
    "denomination": "Fr"
  },
  "privateInputs": {
    "preimage":      "Fr",
    "pathElements":  ["Fr", ...16],
    "pathIndices":   ["0"|"1", ...16]
  },
  "proof":         { /* snarkjs Groth16 proof */ },
  "publicSignals": ["root", "nullifier", "recipient", "denomination"],
  "meta": {
    "leafIndex":     <int>,
    "realLeafCount": <int>,
    "treeHeight":    16,
    "proveTimeMs":   <int>
  }
}
```

## Coverage

| Vector | Real leaves | Target idx | Note |
|---|---|---|---|
| 01-basic | 1 | 0 | Single-leaf tree, simplest case |
| 02-deep | 8 | 7 | Last real leaf, full at level 3 |
| 03-mid | 128 | 100 | Mid-tree, non-power-of-2 index |
| 04-pow2 | 512 | 256 | Power-of-2 boundary |
| 05-odd | 100 | 13 | Non-aligned count + idx |
| 06-far | 1024 | 1023 | Last real leaf, dense tree |
| 07-edge0 | 65536 | 0 | Full tree, first leaf |
| 08-edgeN | 65536 | 65535 | Full tree, last leaf |
| 09-mid2 | 100 | 42 | Mid-range cross-check |
| 10-spread | 1000 | 999 | Last leaf in mid-density tree |

## Consumer test plan

Code consuming these vectors must:

1. Round-trip via on-chain verifier (T4): submit `publicInputs` + `proof` → contract accepts.
2. Round-trip via Dart prover (T8): regenerate proof from `privateInputs` → matches `publicSignals` exactly.
3. Negative cases: tamper any one byte of `publicSignals` or `proof` → contract rejects with `BAD_PROOF`.
