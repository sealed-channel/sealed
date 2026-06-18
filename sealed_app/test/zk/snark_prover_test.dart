// snark_prover_test.dart — end-to-end proof generation against
// vector-01-basic. The test loads the dev .zkey + .wasm produced by the
// circom toolchain in /circuits, runs snarkjs (via flutter_js) and
// asserts the returned public signals match the golden vector.
//
// Skipped when the artifacts are missing OR when flutter_js cannot
// initialise (pure-VM unit test environments without the platform shim).

import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';

const String _vectorPath =
    '../programs/sealed/test/snark-vectors/vector-01-basic.json';
const String _zkeyPath = '../circuits/keys/redeem_dev.zkey';
const String _wasmPath = '../circuits/build/redeem_js/redeem.wasm';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generateProof matches vector-01 public signals',
    () async {
      final zkeyFile = File(_zkeyPath);
      if (!zkeyFile.existsSync()) {
        markTestSkipped(
          'redeem_dev.zkey missing at $_zkeyPath — '
          'regenerate via circuits/scripts/setup-dev.mjs',
        );
        return;
      }
      final wasmFile = File(_wasmPath);
      if (!wasmFile.existsSync()) {
        markTestSkipped(
          'redeem.wasm missing at $_wasmPath — '
          'run `cd circuits && npm run build`',
        );
        return;
      }
      final vectorFile = File(_vectorPath);
      if (!vectorFile.existsSync()) {
        markTestSkipped('vector missing at $_vectorPath');
        return;
      }

      final Map<String, dynamic> vector =
          jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;
      final Map<String, dynamic> pub =
          vector['publicInputs'] as Map<String, dynamic>;
      final Map<String, dynamic> priv =
          vector['privateInputs'] as Map<String, dynamic>;

      final input = <String, dynamic>{
        'root': pub['root'],
        'nullifier': pub['nullifier'],
        'recipient': pub['recipient'],
        'denomination': pub['denomination'],
        'preimage': priv['preimage'],
        'pathElements': priv['pathElements'],
        'pathIndices': priv['pathIndices'],
      };

      final SnarkProver prover;
      try {
        prover = SnarkProver.platform();
      } on SnarkProverException catch (e) {
        markTestSkipped('snarkjs prover unavailable: ${e.message}');
        return;
      }

      final ProofResult result;
      try {
        result = await prover.generateProof(
          zkeyBytes: zkeyFile.readAsBytesSync(),
          wasmBytes: wasmFile.readAsBytesSync(),
          input: input,
          cancel: CancelToken(),
        );
      } on SnarkProverException catch (e) {
        if (e.kind == SnarkProverErrorKind.unavailable) {
          markTestSkipped('snarkjs prover unavailable: ${e.message}');
          return;
        }
        rethrow;
      }

      expect(result.publicSignals.length, 4);
      expect(result.publicSignals[0].toString(), pub['root']);
      expect(result.publicSignals[1].toString(), pub['nullifier']);
      expect(result.publicSignals[2].toString(), pub['recipient']);
      expect(result.publicSignals[3].toString(), pub['denomination']);

      // Proof is 8 BN254 limbs × 32 bytes = 256 bytes. Groth16 is
      // randomised — on-chain verification is the source of truth.
      expect(result.proof.length, 256);
      expect(result.proof, isA<Uint8List>());
    },
    // snarkjs in QuickJS is ~3-10s on device, slower on Dart VM hosts.
    timeout: const Timeout(Duration(minutes: 3)),
    // CI guard: opt in via SEALED_RUN_SNARK=1 to actually run the heavy
    // proof. Default is skipped so unit-test runs stay snappy.
    skip: Platform.environment['SEALED_RUN_SNARK'] != '1'
        ? 'set SEALED_RUN_SNARK=1 to run snarkjs prove (slow)'
        : null,
  );
}
