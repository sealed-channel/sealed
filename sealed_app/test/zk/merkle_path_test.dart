// Reconstructs the full leaf array used by gen-vectors.mjs from its
// documented deterministic seed and asserts that MerklePath.build produces
// the exact pathElements / pathIndices stored in each golden vector.
//
// The seed scheme (mirrored from circuits/scripts/gen-vectors.mjs):
//   raw_i = sha256(`sealed-vec-<name>-pre-<i>` || [0])[0..16]
//   preimage_i = bytesToBigIntBE(raw_i)
//   leaf_i     = poseidonHash1(preimage_i)
// Padding (i >= realCount) is poseidonHash1(0), supplied implicitly by build.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/zk/merkle_path.dart';
import 'package:sealed_app/infra/zk/poseidon.dart';

const List<String> _vectorFiles = <String>[
  'vector-01-basic.json',
  'vector-02-deep.json',
  'vector-03-mid.json',
  'vector-04-pow2.json',
  'vector-05-odd.json',
  'vector-06-far.json',
  // Skip 07/08: realCount=65536 (~262k Poseidon hashes) — covered indirectly
  // by poseidon_test.dart's path-walk parity test for those vectors.
  'vector-09-mid2.json',
  'vector-10-spread.json',
];

Map<String, dynamic> _loadVector(String name) =>
    jsonDecode(
          File(
            '../programs/sealed/test/snark-vectors/$name',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

BigInt _bytesToFrBE(Uint8List bytes) {
  BigInt n = BigInt.zero;
  for (final int b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  return n;
}

/// Mirrors gen-vectors.mjs `seededBytes(seed, 16)`.
Uint8List _seededBytes16(String seed) {
  final List<int> input = <int>[...utf8.encode(seed), 0];
  final List<int> digest = crypto.sha256.convert(input).bytes;
  return Uint8List.fromList(digest.sublist(0, 16));
}

List<BigInt> _reconstructLeaves(String vectorName, int realCount) {
  // vectorName here is the bare name like "vector-01-basic".
  final String seedPrefix = 'sealed-vec-$vectorName';
  final List<BigInt> leaves = <BigInt>[];
  for (int i = 0; i < realCount; i++) {
    final BigInt pre = _bytesToFrBE(_seededBytes16('$seedPrefix-pre-$i'));
    leaves.add(poseidonHash1(pre));
  }
  return leaves;
}

void main() {
  for (final String vf in _vectorFiles) {
    test('MerklePath.build matches stored path for $vf', () {
      final Map<String, dynamic> v = _loadVector(vf);
      final Map<String, dynamic> priv =
          v['privateInputs'] as Map<String, dynamic>;
      final Map<String, dynamic> meta = v['meta'] as Map<String, dynamic>;
      final int leafIndex = meta['leafIndex'] as int;
      final int realCount = meta['realLeafCount'] as int;

      final String bareName = vf.replaceAll('.json', '');
      final List<BigInt> leaves = _reconstructLeaves(bareName, realCount);

      final MerklePath got = build(leaves: leaves, targetIdx: leafIndex);

      final List<BigInt> wantElements = (priv['pathElements'] as List<dynamic>)
          .map((dynamic e) => BigInt.parse(e as String))
          .toList(growable: false);
      final List<int> wantIndices = (priv['pathIndices'] as List<dynamic>)
          .map((dynamic e) => int.parse(e as String))
          .toList(growable: false);

      expect(got.indices, wantIndices, reason: 'indices mismatch for $vf');
      expect(got.elements, wantElements, reason: 'elements mismatch for $vf');
    });
  }

  test('findLeaf returns the matching index when the preimage is present', () {
    const String vf = 'vector-05-odd.json';
    final Map<String, dynamic> v = _loadVector(vf);
    final Map<String, dynamic> priv =
        v['privateInputs'] as Map<String, dynamic>;
    final Map<String, dynamic> meta = v['meta'] as Map<String, dynamic>;
    final int leafIndex = meta['leafIndex'] as int;
    final int realCount = meta['realLeafCount'] as int;
    final BigInt preimage = BigInt.parse(priv['preimage'] as String);

    final List<BigInt> leaves = _reconstructLeaves(
      vf.replaceAll('.json', ''),
      realCount,
    );
    expect(findLeaf(preimage: preimage, leaves: leaves), leafIndex);
  });

  test('findLeaf returns null when the preimage is absent', () {
    final List<BigInt> leaves = _reconstructLeaves('vector-05-odd', 10);
    // 1 is essentially never produced by sha256-truncated-to-16-bytes.
    expect(findLeaf(preimage: BigInt.one, leaves: leaves), isNull);
  });
}
