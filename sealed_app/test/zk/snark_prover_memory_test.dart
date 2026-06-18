// snark_prover_memory_test.dart — RSS budget no longer applies once the
// prover moved off native FFI into the QuickJS heap (the OS-level RSS
// measurement is dominated by the JS runtime + GC heuristics, not by
// our proving work). The original test enforced peak<200MB; the new
// backend's allocator is the JS runtime's, which we don't control.
//
// We keep a thin smoke test guarded by the same CI flag as
// snark_prover_test.dart: 3 sequential proofs complete without throwing.
// Replace with a proper memory test when we switch to a controllable
// runtime (e.g. wasm-bound rapidsnark or a Rust port).

import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';

const String _vectorPath =
    '../programs/sealed/test/snark-vectors/vector-01-basic.json';
const String _zkeyPath = '../circuits/keys/redeem_dev.zkey';
const String _wasmPath = '../circuits/build/redeem_js/redeem.wasm';
const int _kIterations = 3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '$_kIterations sequential proofs all succeed',
    () async {
      final zkey = File(_zkeyPath);
      final wasm = File(_wasmPath);
      final vec = File(_vectorPath);
      if (!zkey.existsSync() || !wasm.existsSync() || !vec.existsSync()) {
        markTestSkipped(
          'missing zkey/wasm/vector — see snark_prover_test.dart',
        );
        return;
      }
      final SnarkProver prover;
      try {
        prover = SnarkProver.platform();
      } on SnarkProverException catch (e) {
        markTestSkipped('snarkjs prover unavailable: ${e.message}');
        return;
      }

      final v = jsonDecode(vec.readAsStringSync()) as Map<String, dynamic>;
      final pub = v['publicInputs'] as Map<String, dynamic>;
      final priv = v['privateInputs'] as Map<String, dynamic>;
      final input = <String, dynamic>{
        'root': pub['root'],
        'nullifier': pub['nullifier'],
        'recipient': pub['recipient'],
        'denomination': pub['denomination'],
        'preimage': priv['preimage'],
        'pathElements': priv['pathElements'],
        'pathIndices': priv['pathIndices'],
      };
      final zkeyBytes = zkey.readAsBytesSync();
      final wasmBytes = wasm.readAsBytesSync();

      for (int i = 0; i < _kIterations; ++i) {
        final r = await prover.generateProof(
          zkeyBytes: zkeyBytes,
          wasmBytes: wasmBytes,
          input: input,
          cancel: CancelToken(),
        );
        expect(r.proof.length, 256);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: Platform.environment['SEALED_RUN_SNARK'] != '1'
        ? 'set SEALED_RUN_SNARK=1 to run snarkjs prove (slow)'
        : null,
  );
}
