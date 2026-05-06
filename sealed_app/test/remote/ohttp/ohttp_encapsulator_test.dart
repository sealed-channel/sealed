import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/remote/ohttp/ohttp_config.dart';
import 'package:sealed_app/remote/ohttp/ohttp_encapsulator.dart';

void main() {
  group('OhttpEncapsulator', () {
    late OhttpConfig config;

    setUp(() async {
      // Generate a "gateway" keypair for testing
      final x25519 = X25519();
      final gatewayKeyPair = await x25519.newKeyPair();
      final pubKey = await gatewayKeyPair.extractPublicKey();

      config = OhttpConfig(
        keyId: 0x80, // matches real gateway
        kemId: 0x0020,
        kdfId: 0x0001,
        aeadId: 0x0001,
        publicKey: Uint8List.fromList(pubKey.bytes),
      );
    });

    test('encapsulateRequest produces valid envelope structure', () async {
      final encapsulator = OhttpEncapsulator(config);

      final result = await encapsulator.encapsulateRequest(
        method: 'GET',
        targetUri: Uri.parse('https://testnet-api.4160.nodely.dev/v2/status'),
      );

      // Envelope: hdr(7) + enc(32) + ciphertext + tag(16)
      expect(result.encapsulatedMessage.length > 7 + 32 + 16, true);

      // Check header
      expect(result.encapsulatedMessage[0], 0x80); // keyId
      expect(result.encapsulatedMessage[1], 0x00); // kemId high
      expect(result.encapsulatedMessage[2], 0x20); // kemId low
      expect(result.encapsulatedMessage[3], 0x00); // kdfId high
      expect(result.encapsulatedMessage[4], 0x01); // kdfId low
      expect(result.encapsulatedMessage[5], 0x00); // aeadId high
      expect(result.encapsulatedMessage[6], 0x01); // aeadId low

      // enc and secret sizes
      expect(result.enc.length, 32);
      expect(result.secret.length, 16);
    });

    test('each encapsulation produces different ciphertext', () async {
      final encapsulator = OhttpEncapsulator(config);

      final r1 = await encapsulator.encapsulateRequest(
        method: 'GET',
        targetUri: Uri.parse('https://example.com/test'),
      );
      final r2 = await encapsulator.encapsulateRequest(
        method: 'GET',
        targetUri: Uri.parse('https://example.com/test'),
      );

      // Different ephemeral keys → different ciphertexts
      expect(r1.encapsulatedMessage, isNot(equals(r2.encapsulatedMessage)));
    });

    test('decapsulateResponse decrypts correctly', () async {
      final encapsulator = OhttpEncapsulator(config);

      // Build a plaintext Binary HTTP response
      final responseBuilder = BytesBuilder();
      responseBuilder.addByte(0x01); // Known-Length Response
      responseBuilder.add([0x40, 0xC8]); // status 200
      responseBuilder.addByte(0x00); // empty headers
      final body = '{"status":"ok"}'.codeUnits;
      responseBuilder.addByte(body.length);
      responseBuilder.add(body);
      responseBuilder.addByte(0x00); // empty trailers
      final plainResponse = Uint8List.fromList(responseBuilder.toBytes());

      // Simulate response key derivation matching our implementation:
      // We need enc and secret to derive keys the same way
      final enc = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final secret = Uint8List.fromList(List.filled(16, 0x42));

      // responseNonce length = max(Nk=16, Nn=12) = 16
      final responseNonce = Uint8List.fromList(
        List.generate(16, (i) => i + 10),
      );

      // Derive keys the same way decapsulateResponse will:
      // salt = enc || responseNonce
      final salt = Uint8List.fromList([...enc, ...responseNonce]);
      final hmac = Hmac.sha256();
      final prk = await hmac.calculateMac(
        secret,
        secretKey: SecretKey(salt.toList()),
      );

      // key = HKDF-Expand(prk, "key", 16)
      final keyInfo = Uint8List.fromList('key'.codeUnits);
      final keyMac = await hmac.calculateMac([
        ...keyInfo,
        1,
      ], secretKey: SecretKey(prk.bytes));
      final aeadKey = keyMac.bytes.sublist(0, 16);

      // nonce = HKDF-Expand(prk, "nonce", 12)
      final nonceInfo = Uint8List.fromList('nonce'.codeUnits);
      final nonceMac = await hmac.calculateMac([
        ...nonceInfo,
        1,
      ], secretKey: SecretKey(prk.bytes));
      final aeadNonce = nonceMac.bytes.sublist(0, 12);

      // Encrypt the response
      final aesGcm = AesGcm.with128bits();
      final secretBox = await aesGcm.encrypt(
        plainResponse,
        secretKey: SecretKey(aeadKey),
        nonce: aeadNonce,
        aad: Uint8List(0),
      );

      // Wire format: responseNonce(16) || ciphertext || tag
      final encryptedResponse = Uint8List.fromList([
        ...responseNonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);

      // Decapsulate
      final decoded = await encapsulator.decapsulateResponse(
        encryptedResponse: encryptedResponse,
        enc: enc,
        secret: secret,
      );

      expect(decoded.statusCode, 200);
      expect(String.fromCharCodes(decoded.body), '{"status":"ok"}');
    });
  });
}
