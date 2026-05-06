import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
// Import Kyber directly to avoid the broken Dilithium barrel export
// ignore: implementation_imports
import 'package:post_quantum/src/kyber.dart';
import 'package:sealed_app/services/crypto_service.dart';

void main() {
  late CryptoService cryptoService;
  late X25519 x25519;

  setUp(() {
    x25519 = X25519();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final aesGcm = AesGcm.with256bits();
    final hmac = Hmac.sha256();

    cryptoService = CryptoService(
      x25519: x25519,
      hkdf: hkdf,
      aesGcm: aesGcm,
      hmac: hmac,
    );
  });

  group('CryptoService', () {
    group('Tag generation (computeRecipientTag)', () {
      test('should generate a 32-byte tag from shared secret', () async {
        // Arrange: Create a mock shared secret (32 bytes)
        final sharedSecret = Uint8List.fromList(List.generate(32, (i) => i));

        // Act
        final tag = await cryptoService.computeRecipientTag(sharedSecret);

        // Assert
        expect(tag.length, 32);
        expect(tag, isA<Uint8List>());
      });

      test('same shared secret should produce same tag', () async {
        // Arrange
        final sharedSecret = Uint8List.fromList(
          List.generate(32, (i) => i * 2),
        );

        // Act
        final tag1 = await cryptoService.computeRecipientTag(sharedSecret);
        final tag2 = await cryptoService.computeRecipientTag(sharedSecret);

        // Assert
        expect(tag1, equals(tag2));
      });

      test('different shared secrets should produce different tags', () async {
        // Arrange
        final secret1 = Uint8List.fromList(List.generate(32, (i) => i));
        final secret2 = Uint8List.fromList(List.generate(32, (i) => i + 1));

        // Act
        final tag1 = await cryptoService.computeRecipientTag(secret1);
        final tag2 = await cryptoService.computeRecipientTag(secret2);

        // Assert
        expect(tag1, isNot(equals(tag2)));
      });
    });

    group('isMessageForMe', () {
      test(
        'positive - should return true for message addressed to me',
        () async {
          // Arrange: Generate keypairs for sender and recipient
          final senderKeyPair = await x25519.newKeyPair();
          final recipientKeyPair = await x25519.newKeyPair();

          final senderPubKey = await senderKeyPair.extractPublicKey();
          final recipientPrivateKeyBytes = await recipientKeyPair
              .extractPrivateKeyBytes();

          // Compute the shared secret from sender's perspective
          final senderSharedSecret = await cryptoService.computeSharedSecret(
            keyPair: senderKeyPair,
            publicKey: Uint8List.fromList(
              (await recipientKeyPair.extractPublicKey()).bytes,
            ),
          );

          // Compute the recipient tag that sender would generate
          final recipientTag = await cryptoService.computeRecipientTag(
            senderSharedSecret,
          );

          // Act: Recipient checks if message is for them
          final isForMe = await cryptoService.isMessageForMe(
            viewPrivateKey: Uint8List.fromList(recipientPrivateKeyBytes),
            senderEncryptionPubkey: Uint8List.fromList(senderPubKey.bytes),
            recipientTag: recipientTag,
          );

          // Assert
          expect(isForMe, isTrue);
        },
      );

      test(
        'negative - should return false for message not addressed to me',
        () async {
          // Arrange: Generate keypairs for sender, actual recipient, and unintended recipient
          final senderKeyPair = await x25519.newKeyPair();
          final actualRecipientKeyPair = await x25519.newKeyPair();
          final wrongRecipientKeyPair = await x25519.newKeyPair();

          final senderPubKey = await senderKeyPair.extractPublicKey();
          final wrongRecipientPrivateKeyBytes = await wrongRecipientKeyPair
              .extractPrivateKeyBytes();

          // Compute the shared secret from sender's perspective (with actual recipient)
          final senderSharedSecret = await cryptoService.computeSharedSecret(
            keyPair: senderKeyPair,
            publicKey: Uint8List.fromList(
              (await actualRecipientKeyPair.extractPublicKey()).bytes,
            ),
          );

          // Compute the recipient tag that sender would generate
          final recipientTag = await cryptoService.computeRecipientTag(
            senderSharedSecret,
          );

          // Act: Wrong recipient checks if message is for them
          final isForMe = await cryptoService.isMessageForMe(
            viewPrivateKey: Uint8List.fromList(wrongRecipientPrivateKeyBytes),
            senderEncryptionPubkey: Uint8List.fromList(senderPubKey.bytes),
            recipientTag: recipientTag,
          );

          // Assert
          expect(isForMe, isFalse);
        },
      );

      test(
        'should throw CryptoValidationException for empty viewPrivateKey',
        () async {
          // Arrange
          final emptyKey = Uint8List(0);
          final validKey = Uint8List(32);
          final validTag = Uint8List(32);

          // Act & Assert
          expect(
            () => cryptoService.isMessageForMe(
              viewPrivateKey: emptyKey,
              senderEncryptionPubkey: validKey,
              recipientTag: validTag,
            ),
            throwsA(isA<CryptoValidationException>()),
          );
        },
      );

      test(
        'should throw CryptoValidationException for invalid key length',
        () async {
          // Arrange
          final invalidKey = Uint8List(16); // Should be 32
          final validKey = Uint8List(32);
          final validTag = Uint8List(32);

          // Act & Assert
          expect(
            () => cryptoService.isMessageForMe(
              viewPrivateKey: invalidKey,
              senderEncryptionPubkey: validKey,
              recipientTag: validTag,
            ),
            throwsA(isA<CryptoValidationException>()),
          );
        },
      );
    });

    group('Encrypt/Decrypt roundtrip', () {
      // Note: The encrypt/decrypt methods in CryptoService use Ecdh.p256 internally,
      // which is incompatible with X25519 keys. This is a known issue in the production code.
      // These tests verify the validation logic and error handling instead.

      test(
        'should throw CryptoValidationException for empty plaintext',
        () async {
          // Arrange
          final senderKeyPair = await x25519.newKeyPair();
          final recipientKeyPair = await x25519.newKeyPair();
          final recipientPubKey = await recipientKeyPair.extractPublicKey();

          // Act & Assert
          expect(
            () => cryptoService.encryptHybrid(
              senderEncryptionKeyPair: senderKeyPair,
              recipientEncryptionPubkey: Uint8List.fromList(
                recipientPubKey.bytes,
              ),
              plainTextBytes: Uint8List(0),
            ),
            throwsA(isA<CryptoValidationException>()),
          );
        },
      );

      test(
        'should throw CryptoValidationException for short ciphertext',
        () async {
          // Arrange
          final recipientKeyPair = await x25519.newKeyPair();
          final senderKeyPair = await x25519.newKeyPair();
          final senderPubKey = await senderKeyPair.extractPublicKey();

          // Too short ciphertext (less than nonce + mac)
          final shortCiphertext = Uint8List(20);

          // Act & Assert
          expect(
            () => cryptoService.decryptHybrid(
              encryptionKeyPair: recipientKeyPair,
              senderEncryptionPubkey: Uint8List.fromList(senderPubKey.bytes),
              cipherText: shortCiphertext,
            ),
            throwsA(isA<CryptoValidationException>()),
          );
        },
      );

      test('should throw for invalid recipient pubkey length', () async {
        // Arrange
        final senderKeyPair = await x25519.newKeyPair();
        final invalidPubKey = Uint8List(16); // Should be 32
        final plaintext = Uint8List.fromList(utf8.encode('Test'));

        // Act & Assert
        expect(
          () => cryptoService.encryptHybrid(
            senderEncryptionKeyPair: senderKeyPair,
            recipientEncryptionPubkey: invalidPubKey,
            plainTextBytes: plaintext,
          ),
          throwsA(isA<CryptoValidationException>()),
        );
      });

      test(
        'should throw for invalid sender pubkey length in decrypt',
        () async {
          // Arrange
          final recipientKeyPair = await x25519.newKeyPair();
          final invalidSenderPubKey = Uint8List(16); // Should be 32
          final ciphertext = Uint8List(50);

          // Act & Assert
          expect(
            () => cryptoService.decryptHybrid(
              encryptionKeyPair: recipientKeyPair,
              senderEncryptionPubkey: invalidSenderPubKey,
              cipherText: ciphertext,
            ),
            throwsA(isA<CryptoValidationException>()),
          );
        },
      );
    });

    group('Padding', () {
      test('padTo1KB should pad short data to 1024 bytes', () {
        // Arrange
        final data = Uint8List.fromList([1, 2, 3, 4, 5]);

        // Act
        final padded = cryptoService.padTo1KB(data);

        // Assert
        expect(padded.length, 1024);
      });

      test(
        'unpadFrom1KB should restore original data for valid padding range',
        () {
          // Arrange: Use data that results in valid PKCS7 padding (1-256 bytes)
          // For data of length 768-1023, padding will be 1-256 bytes
          final originalData = Uint8List(800);
          for (int i = 0; i < 800; i++) {
            originalData[i] = i % 256;
          }
          final padded = cryptoService.padTo1KB(originalData);

          // Act
          final unpadded = cryptoService.unpadFrom1KB(padded);

          // Assert
          expect(unpadded, equals(originalData));
        },
      );

      test('padding and unpadding should work for data near 1024 bytes', () {
        // Arrange: Data that results in padding of exactly 1 byte
        final originalData = Uint8List(1023);
        for (int i = 0; i < 1023; i++) {
          originalData[i] = i % 256;
        }
        final padded = cryptoService.padTo1KB(originalData);

        // Verify padding is applied
        expect(padded.length, 1024);
        expect(padded[1023], 1); // Last byte should be padding length = 1

        // Act
        final unpadded = cryptoService.unpadFrom1KB(padded);

        // Assert
        expect(unpadded, equals(originalData));
      });

      test('should throw for data larger than 1024 bytes', () {
        // Arrange
        final largeData = Uint8List(1025);

        // Act & Assert
        expect(
          () => cryptoService.padTo1KB(largeData),
          throwsA(isA<CryptoValidationException>()),
        );
      });

      test('should throw for empty data', () {
        // Arrange
        final emptyData = Uint8List(0);

        // Act & Assert
        expect(
          () => cryptoService.padTo1KB(emptyData),
          throwsA(isA<CryptoValidationException>()),
        );
      });

      test('should throw for invalid padding format', () {
        // Arrange: Data with invalid PKCS7 padding
        final invalidPadded = Uint8List(1024);
        invalidPadded[1023] = 5; // Claims 5 bytes of padding
        invalidPadded[1022] = 3; // But this byte doesn't match

        // Act & Assert
        expect(
          () => cryptoService.unpadFrom1KB(invalidPadded),
          throwsA(isA<CryptoValidationException>()),
        );
      });

      test('should throw for data not exactly 1024 bytes when unpadding', () {
        // Arrange
        final wrongSize = Uint8List(500);

        // Act & Assert
        expect(
          () => cryptoService.unpadFrom1KB(wrongSize),
          throwsA(isA<CryptoValidationException>()),
        );
      });
    });

    group('Payload encoding/decoding', () {
      test('encodePayload should create valid JSON', () {
        // Arrange
        const senderWallet = 'wallet123';
        const senderUsername = 'alice';
        const content = 'Hello, Bob!';

        // Act
        final encoded = cryptoService.encodePayload(
          senderWallet: senderWallet,
          senderUsername: senderUsername,
          content: content,
        );

        // Assert
        final decoded = jsonDecode(encoded) as Map<String, dynamic>;
        expect(decoded['senderWallet'], senderWallet);
        expect(decoded['senderUsername'], senderUsername);
        expect(decoded['content'], content);
        expect(decoded['timestamp'], isA<int>());
      });

      test('decodePayload should parse valid JSON', () {
        // Arrange
        final jsonString = jsonEncode({
          'senderWallet': 'wallet456',
          'senderUsername': 'bob',
          'content': 'Hello, Alice!',
          'timestamp': 1706000000000,
        });

        // Act
        final payload = cryptoService.decodePayload(jsonString);

        // Assert
        expect(payload.senderWallet, 'wallet456');
        expect(payload.senderUsername, 'bob');
        expect(payload.content, 'Hello, Alice!');
        expect(payload.timestamp, 1706000000000);
      });

      test('decodePayload should throw for invalid JSON', () {
        // Arrange
        const invalidJson = 'not valid json';

        // Act & Assert
        expect(
          () => cryptoService.decodePayload(invalidJson),
          throwsA(isA<CryptoOperationException>()),
        );
      });

      test('encodePayload should throw for empty fields', () {
        // Act & Assert
        expect(
          () => cryptoService.encodePayload(
            senderWallet: '',
            senderUsername: 'alice',
            content: 'Hello',
          ),
          throwsA(isA<CryptoValidationException>()),
        );
      });
    });

    group('constantTimeEquals', () {
      test('should return true for equal arrays', () {
        // Arrange
        final a = Uint8List.fromList([1, 2, 3, 4, 5]);
        final b = Uint8List.fromList([1, 2, 3, 4, 5]);

        // Act & Assert
        expect(cryptoService.constantTimeEquals(a, b), isTrue);
      });

      test('should return false for different arrays', () {
        // Arrange
        final a = Uint8List.fromList([1, 2, 3, 4, 5]);
        final b = Uint8List.fromList([1, 2, 3, 4, 6]);

        // Act & Assert
        expect(cryptoService.constantTimeEquals(a, b), isFalse);
      });

      test('should return false for arrays of different lengths', () {
        // Arrange
        final a = Uint8List.fromList([1, 2, 3]);
        final b = Uint8List.fromList([1, 2, 3, 4]);

        // Act & Assert
        expect(cryptoService.constantTimeEquals(a, b), isFalse);
      });
    });

    // =========================================================================
    // Hybrid encryption (X25519 + PQ ML-KEM shared secret)
    // =========================================================================

    group('kemEncapsulate', () {
      test('returns 768-byte ciphertext and 32-byte shared secret', () async {
        final kyber = Kyber.kem512();
        final seed = Uint8List(64)..fillRange(0, 64, 0x42);
        final (pk, _) = kyber.generateKeys(seed);
        final recipientPqPubkey = pk.serialize();

        final result = await cryptoService.kemEncapsulate(recipientPqPubkey);

        expect(result.ciphertext.length, 768);
        expect(result.sharedSecret.length, 32);
      });

      test('throws CryptoOperationException for invalid pubkey', () async {
        final badKey = Uint8List(16); // wrong length
        expect(
          () => cryptoService.kemEncapsulate(badKey),
          throwsA(isA<CryptoOperationException>()),
        );
      });
    });

    group('kemDecapsulate', () {
      test('decapsulated secret matches encapsulated secret', () async {
        final kyber = Kyber.kem512();
        final seed = Uint8List(64)..fillRange(0, 64, 0xAB);
        final (pk, sk) = kyber.generateKeys(seed);

        final result = await cryptoService.kemEncapsulate(pk.serialize());
        final recovered = await cryptoService.kemDecapsulate(
          result.ciphertext,
          sk.serialize(),
        );

        expect(recovered, equals(result.sharedSecret));
      });

      test('throws CryptoOperationException for garbage ciphertext', () async {
        final kyber = Kyber.kem512();
        final seed = Uint8List(64)..fillRange(0, 64, 0x01);
        final (_, sk) = kyber.generateKeys(seed);

        final badCt = Uint8List(100); // too small / garbage
        expect(
          () => cryptoService.kemDecapsulate(badCt, sk.serialize()),
          throwsA(isA<CryptoOperationException>()),
        );
      });
    });

    group('deriveHybridKey', () {
      test(
        'returns a SecretKey when called with classical secret only',
        () async {
          final kp = await x25519.newKeyPair();
          final kp2 = await x25519.newKeyPair();
          final classical = await x25519.sharedSecretKey(
            keyPair: kp,
            remotePublicKey: await kp2.extractPublicKey(),
          );

          final key = await cryptoService.deriveHybridKey(
            classicalSharedSecret: classical,
          );
          final bytes = await key.extractBytes();
          expect(bytes.length, 32);
        },
      );

      test(
        'classical-only and hybrid produce different keys for same input',
        () async {
          final kp = await x25519.newKeyPair();
          final kp2 = await x25519.newKeyPair();
          final classical = await x25519.sharedSecretKey(
            keyPair: kp,
            remotePublicKey: await kp2.extractPublicKey(),
          );
          // Re-derive since SecretKey is consumed
          final classical2 = await x25519.sharedSecretKey(
            keyPair: kp,
            remotePublicKey: await kp2.extractPublicKey(),
          );

          final pqSecret = Uint8List(32)..fillRange(0, 32, 0xFF);
          final keyClassical = await cryptoService.deriveHybridKey(
            classicalSharedSecret: classical,
          );
          final keyHybrid = await cryptoService.deriveHybridKey(
            classicalSharedSecret: classical2,
            pqSharedSecret: pqSecret,
          );

          final bytesC = await keyClassical.extractBytes();
          final bytesH = await keyHybrid.extractBytes();
          expect(bytesC, isNot(equals(bytesH)));
        },
      );
    });

    group('encryptHybrid / decryptHybrid', () {
      test('classical-only roundtrip succeeds', () async {
        final senderKP = await x25519.newKeyPair();
        final recipientKP = await x25519.newKeyPair();
        final recipientPub = Uint8List.fromList(
          (await recipientKP.extractPublicKey()).bytes,
        );
        final plaintext = Uint8List.fromList(utf8.encode('hello hybrid'));

        final ct = await cryptoService.encryptHybrid(
          plainTextBytes: plaintext,
          senderEncryptionKeyPair: senderKP,
          recipientEncryptionPubkey: recipientPub,
        );

        final senderPub = Uint8List.fromList(
          (await senderKP.extractPublicKey()).bytes,
        );
        final decrypted = await cryptoService.decryptHybrid(
          cipherText: ct,
          encryptionKeyPair: recipientKP,
          senderEncryptionPubkey: senderPub,
        );

        expect(decrypted, equals(plaintext));
      });

      test('hybrid (with pqSharedSecret) roundtrip succeeds', () async {
        final senderKP = await x25519.newKeyPair();
        final recipientKP = await x25519.newKeyPair();
        final recipientPub = Uint8List.fromList(
          (await recipientKP.extractPublicKey()).bytes,
        );
        final senderPub = Uint8List.fromList(
          (await senderKP.extractPublicKey()).bytes,
        );
        final pqSecret = Uint8List(32)..fillRange(0, 32, 0xAA);
        final plaintext = Uint8List.fromList(utf8.encode('hybrid with PQ'));

        final ct = await cryptoService.encryptHybrid(
          plainTextBytes: plaintext,
          senderEncryptionKeyPair: senderKP,
          recipientEncryptionPubkey: recipientPub,
          pqSharedSecret: pqSecret,
        );

        final decrypted = await cryptoService.decryptHybrid(
          cipherText: ct,
          encryptionKeyPair: recipientKP,
          senderEncryptionPubkey: senderPub,
          pqSharedSecret: pqSecret,
        );

        expect(decrypted, equals(plaintext));
      });

      test('wrong pqSharedSecret causes decryption failure', () async {
        final senderKP = await x25519.newKeyPair();
        final recipientKP = await x25519.newKeyPair();
        final recipientPub = Uint8List.fromList(
          (await recipientKP.extractPublicKey()).bytes,
        );
        final senderPub = Uint8List.fromList(
          (await senderKP.extractPublicKey()).bytes,
        );
        final correctSecret = Uint8List(32)..fillRange(0, 32, 0xAA);
        final wrongSecret = Uint8List(32)..fillRange(0, 32, 0xBB);
        final plaintext = Uint8List.fromList(utf8.encode('secret message'));

        final ct = await cryptoService.encryptHybrid(
          plainTextBytes: plaintext,
          senderEncryptionKeyPair: senderKP,
          recipientEncryptionPubkey: recipientPub,
          pqSharedSecret: correctSecret,
        );

        expect(
          () => cryptoService.decryptHybrid(
            cipherText: ct,
            encryptionKeyPair: recipientKP,
            senderEncryptionPubkey: senderPub,
            pqSharedSecret: wrongSecret,
          ),
          throwsA(isA<CryptoOperationException>()),
        );
      });

      test(
        'classical-only encrypt cannot be decrypted with pqSharedSecret',
        () async {
          final senderKP = await x25519.newKeyPair();
          final recipientKP = await x25519.newKeyPair();
          final recipientPub = Uint8List.fromList(
            (await recipientKP.extractPublicKey()).bytes,
          );
          final senderPub = Uint8List.fromList(
            (await senderKP.extractPublicKey()).bytes,
          );
          final pqSecret = Uint8List(32)..fillRange(0, 32, 0xCC);
          final plaintext = Uint8List.fromList(utf8.encode('no pq'));

          final ct = await cryptoService.encryptHybrid(
            plainTextBytes: plaintext,
            senderEncryptionKeyPair: senderKP,
            recipientEncryptionPubkey: recipientPub,
            // no pqSharedSecret
          );

          expect(
            () => cryptoService.decryptHybrid(
              cipherText: ct,
              encryptionKeyPair: recipientKP,
              senderEncryptionPubkey: senderPub,
              pqSharedSecret: pqSecret, // different key derivation path
            ),
            throwsA(isA<CryptoOperationException>()),
          );
        },
      );

      test('encryptHybrid throws on empty plaintext', () async {
        final kp = await x25519.newKeyPair();
        final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
        expect(
          () => cryptoService.encryptHybrid(
            plainTextBytes: Uint8List(0),
            senderEncryptionKeyPair: kp,
            recipientEncryptionPubkey: pub,
          ),
          throwsA(isA<CryptoValidationException>()),
        );
      });

      test('decryptHybrid throws on too-short ciphertext', () async {
        final kp = await x25519.newKeyPair();
        final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
        expect(
          () => cryptoService.decryptHybrid(
            cipherText: Uint8List(10),
            encryptionKeyPair: kp,
            senderEncryptionPubkey: pub,
          ),
          throwsA(isA<CryptoValidationException>()),
        );
      });
    });
  });
}
