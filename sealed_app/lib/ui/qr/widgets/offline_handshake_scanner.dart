/// Multi-frame QR scanner controller for offline alias handshake.
///
/// Wraps a `Stream<String>` of decoded QR strings (in production, the
/// `scannedDataStream` from `qr_code_scanner_plus`) and feeds each into an
/// [OfflineHandshakeAccumulator]. Emits one `Uint8List` per fully assembled
/// payload on its [payloads] stream.
///
/// The source stream is abstracted so unit tests can feed synthetic
/// strings. The controller is silent on garbage frames (wrong magic,
/// malformed base64, total mismatch) — matching the codec's silent-fail
/// contract — and switches accumulators when a new payloadId is observed
/// mid-stream.
///
/// Threat model note: scanner is transport-layer only. Envelope-level
/// authentication is the caller's responsibility.
///
/// No chain side-effects.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';

/// Stream wrapper that turns multi-frame QR scans into assembled payloads.
class OfflineHandshakeScanner {
  late final StreamSubscription<String> _sub;
  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();
  final OfflineHandshakeAccumulator _acc = OfflineHandshakeCodec.decoder();
  bool _disposed = false;

  /// Wrap [source] (typically `qrController.scannedDataStream.map(...)`).
  /// The scanner subscribes immediately.
  OfflineHandshakeScanner(Stream<String> source) {
    _sub = source.listen(_onFrame);
  }

  void _onFrame(String s) {
    if (_disposed) return;
    final assembled = _acc.feed(s);
    if (assembled != null) {
      _out.add(assembled);
    }
  }

  /// Stream of fully assembled payloads. Emits once per completed payload.
  Stream<Uint8List> get payloads => _out.stream;

  /// Cancel the source subscription and close the output stream.
  /// Idempotent — safe to call multiple times.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub.cancel();
    _out.close();
  }
}
