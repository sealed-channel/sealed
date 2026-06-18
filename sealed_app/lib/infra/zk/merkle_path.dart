// Sparse Merkle tree utilities for the redeem circuit (height = 16).
//
// Layout matches circuits/circuits/redeem.circom and
// circuits/scripts/gen-vectors.mjs:
//   - leaf      = poseidonHash1(preimage)
//   - internal  = poseidonHash2(left, right)
//   - padding   = poseidonHash1(0)         // for missing leaves
//   - pathIndex = 0 → sibling is on the right (current is left child)
//                 1 → sibling is on the left  (current is right child)
//
// Tree height is fixed by the circuit and not configurable.

import 'poseidon.dart';

/// Fixed tree height of the redeem circuit.
const int treeHeight = 16;

/// Number of leaves in a fully-padded tree (2^treeHeight).
const int treeSize = 1 << treeHeight;

/// Authentication path for a single leaf.
///
/// [elements] holds the sibling node value at each level, leaf → root.
/// [indices] holds 0 (current is left) or 1 (current is right) at each level.
class MerklePath {
  MerklePath({required this.elements, required this.indices})
    : assert(elements.length == treeHeight),
      assert(indices.length == treeHeight);

  final List<BigInt> elements;
  final List<int> indices;
}

/// Cached padding leaf = poseidonHash1(0). Computed lazily.
BigInt? _paddingLeafCache;
BigInt _paddingLeaf() => _paddingLeafCache ??= poseidonHash1(BigInt.zero);

/// Cached zero-subtree roots: zeroRoot[k] is the root of a k-level subtree
/// whose every leaf is the padding leaf. Precomputed once per process.
List<BigInt>? _zeroRootCache;
List<BigInt> _zeroRoots() {
  final List<BigInt>? c = _zeroRootCache;
  if (c != null) return c;
  final List<BigInt> z = List<BigInt>.filled(treeHeight + 1, BigInt.zero);
  z[0] = _paddingLeaf();
  for (int k = 1; k <= treeHeight; k++) {
    z[k] = poseidonHash2(z[k - 1], z[k - 1]);
  }
  return _zeroRootCache = z;
}

/// Build the authentication path for leaf [targetIdx] given the leaf array.
/// Leaves shorter than 2^treeHeight are implicitly padded with poseidonHash1(0).
///
/// Implementation note: we only hash within the prefix of real leaves; every
/// node outside the prefix is read from the precomputed zero-subtree table.
/// This keeps the work O(realCount + treeHeight) Poseidon hashes instead of
/// the naïve O(2^treeHeight).
MerklePath build({required List<BigInt> leaves, required int targetIdx}) {
  if (targetIdx < 0 || targetIdx >= treeSize) {
    throw ArgumentError.value(
      targetIdx,
      'targetIdx',
      'must be in [0, $treeSize)',
    );
  }
  if (leaves.length > treeSize) {
    throw ArgumentError('leaves.length (${leaves.length}) exceeds $treeSize');
  }

  final List<BigInt> zero = _zeroRoots();
  final List<BigInt> elements = <BigInt>[];
  final List<int> indices = <int>[];

  List<BigInt> cur = List<BigInt>.from(leaves);
  int idx = targetIdx;

  for (int level = 0; level < treeHeight; level++) {
    final int siblingIdx = idx ^ 1;
    final int isRight = idx & 1;
    final BigInt sibling = siblingIdx < cur.length
        ? cur[siblingIdx]
        : zero[level];
    elements.add(sibling);
    indices.add(isRight);

    final int nextLen = (cur.length + 1) >> 1;
    final List<BigInt> next = List<BigInt>.filled(nextLen, BigInt.zero);
    for (int i = 0; i < nextLen; i++) {
      final BigInt l = (2 * i) < cur.length ? cur[2 * i] : zero[level];
      final BigInt r = (2 * i + 1) < cur.length ? cur[2 * i + 1] : zero[level];
      next[i] = poseidonHash2(l, r);
    }
    cur = next;
    idx >>= 1;
  }
  return MerklePath(elements: elements, indices: indices);
}

/// Recompute the Merkle root from a leaf and its authentication path.
/// Useful for client-side parity checks against the on-chain root.
BigInt computeRoot({required BigInt leaf, required MerklePath path}) {
  BigInt cur = leaf;
  for (int level = 0; level < treeHeight; level++) {
    final BigInt sibling = path.elements[level];
    final int isRight = path.indices[level];
    if (isRight == 0) {
      cur = poseidonHash2(cur, sibling);
    } else {
      cur = poseidonHash2(sibling, cur);
    }
  }
  return cur;
}

/// Find the leaf index whose hash matches [preimage].
/// Returns null if not present.
int? findLeaf({required BigInt preimage, required List<BigInt> leaves}) {
  final BigInt target = poseidonHash1(preimage);
  for (int i = 0; i < leaves.length; i++) {
    if (leaves[i] == target) return i;
  }
  return null;
}
