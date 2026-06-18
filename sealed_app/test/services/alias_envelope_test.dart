/// Tests for AliasInviteEnvelope and AliasAcceptEnvelope codecs.
///
/// Covers:
///   - round-trip encode/tryParse for both types
///   - wrong tag → null
///   - short input → null
///   - empty input → null
///   - one-byte-over length → null
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';

Uint8List _fill(int length, int value) =>
    Uint8List.fromList(List.filled(length, value));

void main() {
  group('AliasInviteEnvelope', () {
    late Uint8List encPub;
    late Uint8List scanPub;
    late Uint8List pqPub;

    setUp(() {
      encPub = _fill(32, 0xAA);
      scanPub = _fill(32, 0xBB);
      pqPub = _fill(800, 0xCC);
    });

    test('encode produces 865 bytes with tag 0x01', () {
      final env = AliasInviteEnvelope(
        encPub: encPub,
        scanPub: scanPub,
        pqPub: pqPub,
      );
      final bytes = env.encode();
      expect(bytes.length, equals(inviteEnvelopeLength));
      expect(bytes.length, equals(865));
      expect(bytes[0], equals(aliasInviteTagByte));
    });

    test('round-trip preserves all fields', () {
      final env = AliasInviteEnvelope(
        encPub: encPub,
        scanPub: scanPub,
        pqPub: pqPub,
      );
      final parsed = AliasInviteEnvelope.tryParse(env.encode());
      expect(parsed, isNotNull);
      expect(parsed!.encPub, equals(encPub));
      expect(parsed.scanPub, equals(scanPub));
      expect(parsed.pqPub, equals(pqPub));
    });

    test('tryParse returns null for wrong tag (0x02)', () {
      final env = AliasInviteEnvelope(
        encPub: encPub,
        scanPub: scanPub,
        pqPub: pqPub,
      );
      final bytes = env.encode();
      bytes[0] = aliasAcceptTagByte;
      expect(AliasInviteEnvelope.tryParse(bytes), isNull);
    });

    test('tryParse returns null for short input', () {
      expect(AliasInviteEnvelope.tryParse(Uint8List(0)), isNull);
      expect(AliasInviteEnvelope.tryParse(Uint8List(1)), isNull);
      expect(AliasInviteEnvelope.tryParse(Uint8List(864)), isNull);
    });

    test('tryParse returns null for one-byte-over length', () {
      expect(AliasInviteEnvelope.tryParse(Uint8List(866)), isNull);
    });

    test('tryParse never throws', () {
      expect(() => AliasInviteEnvelope.tryParse(Uint8List(0)), returnsNormally);
      expect(
        () => AliasInviteEnvelope.tryParse(Uint8List(1000)),
        returnsNormally,
      );
    });
  });

  group('AliasAcceptEnvelope', () {
    late Uint8List inviteRefPrefix;
    late Uint8List encPub;
    late Uint8List scanPub;
    late Uint8List kemCiphertext;

    setUp(() {
      inviteRefPrefix = _fill(8, 0x11);
      encPub = _fill(32, 0x22);
      scanPub = _fill(32, 0x33);
      kemCiphertext = _fill(768, 0x44);
    });

    test('encode produces 841 bytes with tag 0x02', () {
      final env = AliasAcceptEnvelope(
        inviteRefPrefix: inviteRefPrefix,
        encPub: encPub,
        scanPub: scanPub,
        kemCiphertext: kemCiphertext,
      );
      final bytes = env.encode();
      expect(bytes.length, equals(acceptEnvelopeLength));
      expect(bytes.length, equals(841));
      expect(bytes[0], equals(aliasAcceptTagByte));
    });

    test('round-trip preserves all fields', () {
      final env = AliasAcceptEnvelope(
        inviteRefPrefix: inviteRefPrefix,
        encPub: encPub,
        scanPub: scanPub,
        kemCiphertext: kemCiphertext,
      );
      final parsed = AliasAcceptEnvelope.tryParse(env.encode());
      expect(parsed, isNotNull);
      expect(parsed!.inviteRefPrefix, equals(inviteRefPrefix));
      expect(parsed.encPub, equals(encPub));
      expect(parsed.scanPub, equals(scanPub));
      expect(parsed.kemCiphertext, equals(kemCiphertext));
    });

    test('tryParse returns null for wrong tag (0x01)', () {
      final env = AliasAcceptEnvelope(
        inviteRefPrefix: inviteRefPrefix,
        encPub: encPub,
        scanPub: scanPub,
        kemCiphertext: kemCiphertext,
      );
      final bytes = env.encode();
      bytes[0] = aliasInviteTagByte;
      expect(AliasAcceptEnvelope.tryParse(bytes), isNull);
    });

    test('tryParse returns null for short input', () {
      expect(AliasAcceptEnvelope.tryParse(Uint8List(0)), isNull);
      expect(AliasAcceptEnvelope.tryParse(Uint8List(1)), isNull);
      expect(AliasAcceptEnvelope.tryParse(Uint8List(840)), isNull);
    });

    test('tryParse returns null for one-byte-over length', () {
      expect(AliasAcceptEnvelope.tryParse(Uint8List(842)), isNull);
    });

    test('tryParse never throws', () {
      expect(() => AliasAcceptEnvelope.tryParse(Uint8List(0)), returnsNormally);
      expect(
        () => AliasAcceptEnvelope.tryParse(Uint8List(1000)),
        returnsNormally,
      );
    });
  });

  group('No tag collision', () {
    test('invite tag byte != accept tag byte', () {
      expect(aliasInviteTagByte, isNot(equals(aliasAcceptTagByte)));
    });

    test('both tags < 0x20 (no utf8 text collision)', () {
      expect(aliasInviteTagByte, lessThan(0x20));
      expect(aliasAcceptTagByte, lessThan(0x20));
    });

    test('invite tryParse rejects accept bytes', () {
      final acceptEnv = AliasAcceptEnvelope(
        inviteRefPrefix: _fill(8, 0x11),
        encPub: _fill(32, 0x22),
        scanPub: _fill(32, 0x33),
        kemCiphertext: _fill(768, 0x44),
      );
      expect(AliasInviteEnvelope.tryParse(acceptEnv.encode()), isNull);
    });

    test('accept tryParse rejects invite bytes', () {
      final inviteEnv = AliasInviteEnvelope(
        encPub: _fill(32, 0xAA),
        scanPub: _fill(32, 0xBB),
        pqPub: _fill(800, 0xCC),
      );
      expect(AliasAcceptEnvelope.tryParse(inviteEnv.encode()), isNull);
    });
  });
}
