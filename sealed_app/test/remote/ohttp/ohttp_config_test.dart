import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/remote/ohttp/ohttp_config.dart';

void main() {
  group('OhttpConfig', () {
    test('parses valid X25519 config', () {
      // Build a sample config:
      // keyId=0x01, kemId=0x0020 (X25519), 32-byte pubkey, symLen=4, kdf=0x0001, aead=0x0001
      final builder = BytesBuilder();
      builder.addByte(0x01); // keyId
      builder.add([0x00, 0x20]); // kemId = DHKEM(X25519)
      builder.add(List.filled(32, 0xAB)); // 32-byte public key
      builder.add([0x00, 0x04]); // symmetric_algorithms_length = 4
      builder.add([0x00, 0x01]); // kdfId = HKDF-SHA256
      builder.add([0x00, 0x01]); // aeadId = AES-128-GCM

      final config = OhttpConfig.fromBytes(
        Uint8List.fromList(builder.toBytes()),
      );

      expect(config.keyId, 0x01);
      expect(config.kemId, 0x0020);
      expect(config.kdfId, 0x0001);
      expect(config.aeadId, 0x0001);
      expect(config.publicKey.length, 32);
      expect(config.publicKey[0], 0xAB);
    });

    test('throws on too-short input', () {
      expect(
        () => OhttpConfig.fromBytes(Uint8List.fromList([0x01, 0x00])),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws on unsupported KEM ID', () {
      final builder = BytesBuilder();
      builder.addByte(0x01);
      builder.add([0xFF, 0xFF]); // unsupported KEM
      builder.add(List.filled(32, 0x00));

      expect(
        () => OhttpConfig.fromBytes(Uint8List.fromList(builder.toBytes())),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when no symmetric algorithms', () {
      final builder = BytesBuilder();
      builder.addByte(0x01);
      builder.add([0x00, 0x20]); // X25519
      builder.add(List.filled(32, 0x00)); // pubkey
      builder.add([0x00, 0x00]); // symLen = 0

      expect(
        () => OhttpConfig.fromBytes(Uint8List.fromList(builder.toBytes())),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
