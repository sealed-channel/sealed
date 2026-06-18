/// T9 — Fake QR camera controller for widget + service tests.
///
/// Stands in for the production `qr_code_scanner_plus` camera controller in
/// tests. Exposes a [scannedDataStream] of `String` matching the scanner
/// wrapper's input expectation (the production stream is `Stream<Barcode>`
/// which the handshake screen `.map`s into `Stream<String>` before feeding
/// `OfflineHandshakeScanner` — we plug in at that downstream shape).
///
/// Tests push synthetic frames via [emit]. For convenience, [emitPayload]
/// runs the full [OfflineHandshakeCodec.encode] pipeline and emits each
/// resulting QR string. Closing the stream is the test's responsibility via
/// [dispose].
///
/// This is a test utility, not production code. Intentionally light: no
/// timing, no animation, no error injection — tests that need those layer
/// them on top.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';

/// Lightweight test double for a camera-backed multi-frame QR scanner.
class FakeQrCameraController {
  final StreamController<String> _ctrl = StreamController<String>.broadcast();
  bool _closed = false;

  /// Stream consumed by `OfflineHandshakeScanner` (or any other test that
  /// expects already-decoded QR string frames).
  Stream<String> get scannedDataStream => _ctrl.stream;

  /// Push a single pre-encoded QR string. Silently ignored if disposed.
  void emit(String frame) {
    if (_closed) return;
    _ctrl.add(frame);
  }

  /// Encode [bytes] via [OfflineHandshakeCodec.encode] and emit every frame
  /// in ascending `seq` order. Awaitable so tests can sequence multiple
  /// payloads deterministically.
  Future<void> emitPayload(Uint8List bytes) async {
    final frames = await OfflineHandshakeCodec.encode(bytes);
    for (final f in frames) {
      emit(f);
    }
  }

  /// Close the underlying stream. Idempotent.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _ctrl.close();
  }
}
