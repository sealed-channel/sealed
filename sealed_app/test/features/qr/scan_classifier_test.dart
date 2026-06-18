/// Tests for the pure QR-scan classifier.
///
/// Covers:
///   - legacy single-frame address → ScanAddress
///   - combined multi-frame QR assembles → ScanCombined
///   - mid-stream handshake frame → ScanAccumulating (silent)
///   - garbage / wrong-magic assembled → ScanInvalid
library;

import 'dart:typed_data';

import 'package:blockchain_utils/bip/address/algo_addr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/alias/combined_qr_codec.dart';
import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';
import 'package:sealed_app/ui/qr/screens/scan_classifier.dart';

Uint8List _fill(int length, int value) =>
    Uint8List.fromList(List.filled(length, value));

String _addressFor(List<int> pubkey) => AlgoAddrEncoder().encodeKey(pubkey);

Uint8List _inviteBytes() => AliasInviteEnvelope(
  encPub: _fill(32, 0xAA),
  scanPub: _fill(32, 0xBB),
  pqPub: _fill(800, 0xCC),
).encode();

void main() {
  final validAddr = _addressFor(List<int>.filled(32, 1));

  test('legacy single-frame address → ScanAddress', () {
    final acc = OfflineHandshakeCodec.decoder();
    final out = classifyScan('  $validAddr  ', acc); // also trims
    expect(out, isA<ScanAddress>());
    expect((out as ScanAddress).address, equals(validAddr));
  });

  test('combined single-frame QR (default chunk) → ScanCombined', () async {
    final invite = _inviteBytes();
    final container = encodeCombinedQr(
      address: validAddr,
      inviteEnvelope: invite,
    );
    final frames = await OfflineHandshakeCodec.encode(container);
    expect(frames.length, 1); // one static QR at the default chunk size

    final acc = OfflineHandshakeCodec.decoder();
    final out = classifyScan(frames.single, acc);
    expect(out, isA<ScanCombined>());
    final c = out as ScanCombined;
    expect(c.address, equals(validAddr));
    expect(c.inviteEnvelope, equals(invite));
  });

  test('combined multi-frame QR assembles → ScanCombined', () async {
    final invite = _inviteBytes();
    final container = encodeCombinedQr(
      address: validAddr,
      inviteEnvelope: invite,
    );
    final frames = await OfflineHandshakeCodec.encode(
      container,
      chunkSize: 380,
    );
    expect(frames.length, greaterThan(1)); // genuinely multi-frame

    final acc = OfflineHandshakeCodec.decoder();
    ScanOutcome? last;
    for (final f in frames) {
      last = classifyScan(f, acc);
    }
    expect(last, isA<ScanCombined>());
    final c = last as ScanCombined;
    expect(c.address, equals(validAddr));
    expect(c.inviteEnvelope, equals(invite));
  });

  test('non-final frames report ScanAccumulating (no toast)', () async {
    final container = encodeCombinedQr(
      address: validAddr,
      inviteEnvelope: _inviteBytes(),
    );
    final frames = await OfflineHandshakeCodec.encode(
      container,
      chunkSize: 380,
    );
    final acc = OfflineHandshakeCodec.decoder();

    // All but the last frame should be silent accumulation.
    for (var i = 0; i < frames.length - 1; i++) {
      expect(classifyScan(frames[i], acc), isA<ScanAccumulating>());
    }
  });

  test('empty / garbage → ScanInvalid', () {
    final acc = OfflineHandshakeCodec.decoder();
    expect(classifyScan('', acc), isA<ScanInvalid>());
    expect(
      classifyScan('not-base32-and-not-an-address!!', acc),
      isA<ScanInvalid>(),
    );
  });

  test(
    'assembled payload that is not a combined container → ScanInvalid',
    () async {
      // Frame a bare invite envelope (valid handshake payload, but NOT a
      // combined-QR container) — assembles, decodeCombinedQr fails → invalid.
      final frames = await OfflineHandshakeCodec.encode(_inviteBytes());
      final acc = OfflineHandshakeCodec.decoder();
      ScanOutcome? last;
      for (final f in frames) {
        last = classifyScan(f, acc);
      }
      expect(last, isA<ScanInvalid>());
    },
  );
}
