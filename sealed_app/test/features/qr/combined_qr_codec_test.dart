/// Tests for the combined-QR container codec (address + invite envelope).
///
/// Covers:
///   - round-trip encode/decode preserves address + envelope
///   - wrong magic → null
///   - length mismatch (short / over) → null
///   - non-invite trailing bytes → null
///   - magic disambiguation vs envelope tags + frame magic
///   - decode never throws
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/alias/combined_qr_codec.dart';
import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';

Uint8List _fill(int length, int value) =>
    Uint8List.fromList(List.filled(length, value));

const String _addr =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB'; // 58 chars

Uint8List _inviteBytes() => AliasInviteEnvelope(
  encPub: _fill(32, 0xAA),
  scanPub: _fill(32, 0xBB),
  pqPub: _fill(800, 0xCC),
).encode();

void main() {
  group('encodeCombinedQr', () {
    test('layout: magic 0x03, addrLen, addr, then 865B envelope', () {
      final invite = _inviteBytes();
      final bytes = encodeCombinedQr(address: _addr, inviteEnvelope: invite);

      expect(bytes[0], equals(combinedQrMagic));
      expect(bytes[0], equals(0x03));
      expect(bytes[1], equals(_addr.length));
      expect(bytes.length, equals(2 + _addr.length + inviteEnvelopeLength));
    });

    test('rejects oversized address', () {
      expect(
        () => encodeCombinedQr(
          address: 'x' * 256,
          inviteEnvelope: _inviteBytes(),
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-length envelope', () {
      expect(
        () => encodeCombinedQr(address: _addr, inviteEnvelope: _fill(100, 0)),
        throwsArgumentError,
      );
    });
  });

  group('decodeCombinedQr', () {
    test('round-trip preserves address + envelope', () {
      final invite = _inviteBytes();
      final decoded = decodeCombinedQr(
        encodeCombinedQr(address: _addr, inviteEnvelope: invite),
      );

      expect(decoded, isNotNull);
      expect(decoded!.address, equals(_addr));
      expect(decoded.inviteEnvelope, equals(invite));
      // The recovered envelope still parses.
      expect(AliasInviteEnvelope.tryParse(decoded.inviteEnvelope), isNotNull);
    });

    test('wrong magic → null', () {
      final bytes = encodeCombinedQr(
        address: _addr,
        inviteEnvelope: _inviteBytes(),
      );
      bytes[0] = 0x99;
      expect(decodeCombinedQr(bytes), isNull);
    });

    test('short input → null', () {
      expect(decodeCombinedQr(Uint8List(0)), isNull);
      expect(decodeCombinedQr(Uint8List(1)), isNull);
      expect(decodeCombinedQr(Uint8List(2)), isNull);
    });

    test('one-byte-over length → null', () {
      final bytes = encodeCombinedQr(
        address: _addr,
        inviteEnvelope: _inviteBytes(),
      );
      final over = Uint8List(bytes.length + 1)
        ..setRange(0, bytes.length, bytes);
      expect(decodeCombinedQr(over), isNull);
    });

    test('non-invite trailing bytes (tag != 0x01) → null', () {
      final invite = _inviteBytes();
      final bytes = encodeCombinedQr(address: _addr, inviteEnvelope: invite);
      bytes[2 + _addr.length] = aliasAcceptTagByte; // flip envelope tag to 0x02
      expect(decodeCombinedQr(bytes), isNull);
    });

    test('never throws on garbage', () {
      expect(() => decodeCombinedQr(_fill(1000, 0x03)), returnsNormally);
      expect(() => decodeCombinedQr(_fill(5, 0x03)), returnsNormally);
    });
  });

  group('magic disambiguation', () {
    test('combined magic distinct from envelope tags + frame magic', () {
      expect(combinedQrMagic, isNot(equals(aliasInviteTagByte))); // 0x01
      expect(combinedQrMagic, isNot(equals(aliasAcceptTagByte))); // 0x02
      expect(
        combinedQrMagic,
        isNot(equals(OfflineHandshakeCodec.magic)),
      ); // 0xA1
      expect(combinedQrMagic, lessThan(0x20)); // no utf8 text collision
    });
  });

  group('survives the multi-frame codec round-trip', () {
    test('encode -> frame -> accumulate -> decode', () async {
      final invite = _inviteBytes();
      final container = encodeCombinedQr(
        address: _addr,
        inviteEnvelope: invite,
      );

      final frames = await OfflineHandshakeCodec.encode(container);
      final acc = OfflineHandshakeCodec.decoder();
      Uint8List? assembled;
      for (final f in frames) {
        assembled = acc.feed(f) ?? assembled;
      }

      expect(assembled, isNotNull);
      final decoded = decodeCombinedQr(assembled!);
      expect(decoded, isNotNull);
      expect(decoded!.address, equals(_addr));
      expect(decoded.inviteEnvelope, equals(invite));
    });
  });
}
