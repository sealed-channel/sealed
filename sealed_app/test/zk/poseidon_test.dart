// Walks the authentication path from each golden vector and asserts the
// reconstructed root matches publicInputs.root. This validates both
// Poseidon (hash1 + hash2) and the path direction convention end-to-end.

import 'dart:convert';
import 'dart:io';

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
  'vector-07-edge0.json',
  'vector-08-edgeN.json',
  'vector-09-mid2.json',
  'vector-10-spread.json',
];

String _vectorPath(String name) =>
    '../programs/sealed/test/snark-vectors/$name';

Map<String, dynamic> _loadVector(String name) =>
    jsonDecode(File(_vectorPath(name)).readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test(
    'Poseidon hash1(0) padding leaf matches gen-vectors padding constant',
    () {
      // The padding leaf used by circuits/scripts/gen-vectors.mjs is
      // poseidonHash1(0). For a tree whose only real leaf is at index 0,
      // the level-0 sibling in the auth path is exactly that padding value.
      // vector-01-basic.json places its only real leaf at idx 0, so its
      // pathElements[0] equals poseidonHash1(0). Use that as the oracle.
      final Map<String, dynamic> v = _loadVector('vector-01-basic.json');
      final BigInt expected = BigInt.parse(
        ((v['privateInputs'] as Map<String, dynamic>)['pathElements']
                as List<dynamic>)[0]
            as String,
      );
      expect(poseidonHash1(BigInt.zero), expected);
    },
  );

  for (final String vf in _vectorFiles) {
    test('walking path from preimage reproduces root: $vf', () {
      final Map<String, dynamic> v = _loadVector(vf);
      final Map<String, dynamic> pub =
          v['publicInputs'] as Map<String, dynamic>;
      final Map<String, dynamic> priv =
          v['privateInputs'] as Map<String, dynamic>;

      final BigInt expectedRoot = BigInt.parse(pub['root'] as String);
      final BigInt preimage = BigInt.parse(priv['preimage'] as String);
      final List<BigInt> elements = (priv['pathElements'] as List<dynamic>)
          .map((dynamic e) => BigInt.parse(e as String))
          .toList(growable: false);
      final List<int> indices = (priv['pathIndices'] as List<dynamic>)
          .map((dynamic e) => int.parse(e as String))
          .toList(growable: false);

      final BigInt leaf = poseidonHash1(preimage);
      final BigInt got = computeRoot(
        leaf: leaf,
        path: MerklePath(elements: elements, indices: indices),
      );
      expect(got, expectedRoot, reason: 'root mismatch for $vf');
    });
  }
}
