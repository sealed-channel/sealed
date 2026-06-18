// Pure-Dart Poseidon hash over BN254 (Fr).
//
// Mirrors circomlibjs/src/poseidon_reference.js byte-for-byte: same prime,
// same round counts, same constants, same MDS matrix. The optimized
// poseidonjs variant produces the same output; we use the reference layout
// because it is far simpler to audit.
//
// Public API:
//   - [poseidonHash1] : t = 2 (one input).
//   - [poseidonHash2] : t = 3 (two inputs).
//
// Both return an Fr in [0, frModulus). Inputs are reduced mod p on entry, so
// callers do not need to pre-reduce.
//
// Constants live in poseidon_constants.dart and are dumped verbatim from
// circomlibjs/src/poseidon_constants.js via
// circuits/scripts/dump-poseidon-consts.mjs. Do not hand-edit constants.

import 'poseidon_constants.dart';

/// BN254 scalar field modulus (Fr).
final BigInt frModulus = BigInt.parse(
  '21888242871839275222246405745257275088548364400416034343698204186575808495617',
);

// Round counts (table 2 / 8 of the Poseidon whitepaper, as fixed in
// circomlibjs). Index = t - 2.
const int _nRoundsF = 8;
const List<int> _nRoundsP = <int>[
  56, 57, 56, 60, 60, 63, 64, 63, 60, 66, 60, 65, 70, 60, 64, 68, //
];

BigInt _mod(BigInt x) {
  final BigInt r = x % frModulus;
  return r.isNegative ? r + frModulus : r;
}

BigInt _pow5(BigInt a) {
  final BigInt a2 = _mod(a * a);
  final BigInt a4 = _mod(a2 * a2);
  return _mod(a4 * a);
}

BigInt _poseidon({
  required List<BigInt> inputs,
  required List<BigInt> c,
  required List<List<BigInt>> m,
}) {
  assert(inputs.isNotEmpty);
  final int t = inputs.length + 1;
  final int nRoundsP = _nRoundsP[t - 2];

  final List<BigInt> state = <BigInt>[BigInt.zero, ...inputs.map(_mod)];

  for (int r = 0; r < _nRoundsF + nRoundsP; r++) {
    // ARK: state[i] += C[r*t + i]
    for (int i = 0; i < t; i++) {
      state[i] = _mod(state[i] + c[r * t + i]);
    }
    // S-box: full rounds at the boundaries, partial in the middle.
    if (r < _nRoundsF ~/ 2 || r >= _nRoundsF ~/ 2 + nRoundsP) {
      for (int i = 0; i < t; i++) {
        state[i] = _pow5(state[i]);
      }
    } else {
      state[0] = _pow5(state[0]);
    }
    // MDS: new_state[i] = sum_j M[i][j] * state[j]
    final List<BigInt> next = List<BigInt>.filled(t, BigInt.zero);
    for (int i = 0; i < t; i++) {
      BigInt acc = BigInt.zero;
      for (int j = 0; j < t; j++) {
        acc = _mod(acc + m[i][j] * state[j]);
      }
      next[i] = acc;
    }
    for (int i = 0; i < t; i++) {
      state[i] = next[i];
    }
  }
  return state[0];
}

/// Poseidon with one input (t = 2). Used for leaf hashing.
BigInt poseidonHash1(BigInt x) =>
    _poseidon(inputs: <BigInt>[x], c: poseidonC_t2, m: poseidonM_t2);

/// Poseidon with two inputs (t = 3). Used for internal Merkle nodes.
BigInt poseidonHash2(BigInt a, BigInt b) =>
    _poseidon(inputs: <BigInt>[a, b], c: poseidonC_t3, m: poseidonM_t3);

/// Domain-separation tag for the redeem nullifier:
///
///   nullifier = poseidonHash2(preimage, nullTag)
///
/// Value mirrors `circuits/scripts/gen-vectors.mjs` (NULL_TAG); the circuit
/// in `circuits/circuits/redeem.circom` hard-codes the same constant. Any
/// change must be made in lockstep across all three.
final BigInt nullTag = BigInt.parse('110815058874449983093867477470989876063');

/// Interpret [bytes] as a big-endian unsigned integer reduced mod [frModulus].
///
/// Matches `bytesToFr` in `circuits/scripts/gen-vectors.mjs` — used to turn
/// the 16-byte preimage (and a 32-byte ed25519 pubkey for recipient binding)
/// into Fr field elements for the redeem circuit.
BigInt bytesToFr(List<int> bytes) {
  BigInt n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b & 0xff);
  }
  return n % frModulus;
}
