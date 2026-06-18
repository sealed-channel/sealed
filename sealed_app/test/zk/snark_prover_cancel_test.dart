// snark_prover_cancel_test.dart — cancellation semantics under the
// flutter_js / snarkjs backend.
//
// snarkjs.groth16.fullProve runs inside QuickJS and is NOT interruptible
// mid-execution. Cancellation is therefore checked at the call boundary:
//   • pre-call    → throws cancelled immediately
//   • mid-prove   → ignored (proof runs to completion, result discarded)
//   • post-prove  → throws cancelled before returning ProofResult
//
// We test the pre-call boundary here — it's the only one that doesn't
// require .zkey/.wasm assets to be present.

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';
import 'dart:typed_data';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pre-cancelled token throws cancelled before fullProve runs', () async {
    final SnarkProver prover;
    try {
      prover = SnarkProver.platform();
    } on SnarkProverException catch (e) {
      markTestSkipped('snarkjs prover unavailable: ${e.message}');
      return;
    }
    final cancel = CancelToken()..cancel();

    Object? caught;
    try {
      await prover.generateProof(
        zkeyBytes: Uint8List.fromList([1, 2, 3]),
        wasmBytes: Uint8List.fromList([4, 5, 6]),
        input: const <String, dynamic>{},
        cancel: cancel,
      );
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<SnarkProverException>());
    expect(
      (caught as SnarkProverException).kind,
      SnarkProverErrorKind.cancelled,
    );
  });
}
