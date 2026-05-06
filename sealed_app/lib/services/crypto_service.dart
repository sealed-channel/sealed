/// Core cryptographic operations service.
/// Provides AES-256-GCM encryption/decryption, X25519 key exchange,
/// message padding, and post-quantum key encapsulation (ML-KEM-512).

import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
// Import Kyber directly to avoid the broken Dilithium barrel export
// ignore: implementation_imports
import 'package:post_quantum/src/kyber.dart';
// ignore: implementation_imports
import 'package:post_quantum/src/kyber_pke.dart';
import 'package:sealed_app/models/kem_result.dart';

// MessagePayload Model
class MessagePayload {
  final String senderWallet;
  final String senderUsername;
  final String content;
  final int timestamp;

  MessagePayload({
    required this.senderWallet,
    required this.senderUsername,
    required this.content,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'senderWallet': senderWallet,
    'senderUsername': senderUsername,
    'content': content,
    'timestamp': timestamp,
  };

  factory MessagePayload.fromJson(Map<String, dynamic> json) {
    return MessagePayload(
      senderWallet: json['senderWallet'] as String,
      senderUsername: json['senderUsername'] as String,
      content: json['content'] as String,
      timestamp: json['timestamp'] as int,
    );
  }
}

// Custom Exceptions
class CryptoException implements Exception {
  final String message;
  final String? code;
  final StackTrace? stackTrace;

  CryptoException(this.message, {this.code, this.stackTrace});

  @override
  String toString() =>
      'CryptoException: $message${code != null ? ' ($code)' : ''}';
}

class CryptoValidationException extends CryptoException {
  CryptoValidationException(super.message) : super(code: 'VALIDATION_ERROR');
}

class CryptoOperationException extends CryptoException {
  CryptoOperationException(super.message, [StackTrace? stackTrace])
    : super(code: 'OPERATION_ERROR', stackTrace: stackTrace);
}

class CryptoService {
  final X25519 _x25519;
  final Hkdf _hkdf;
  final AesGcm _aesGcm;
  final Hmac _hmac;
  CryptoService({
    required X25519 x25519,
    required Hkdf hkdf,
    required AesGcm aesGcm,
    required Hmac hmac,
  }) : _x25519 = x25519,
       _hkdf = hkdf,
       _aesGcm = aesGcm,
       _hmac = hmac;

  void _validateKeyLength(Uint8List key, int expectedLength, String keyName) {
    if (key.isEmpty) {
      throw CryptoValidationException('$keyName cannot be empty');
    }
    if (key.length != expectedLength) {
      throw CryptoValidationException(
        '$keyName has invalid length: ${key.length}, expected: $expectedLength',
      );
    }
  }

  void _validateString(String value, String fieldName) {
    if (value.isEmpty) {
      throw CryptoValidationException('$fieldName cannot be empty');
    }
  }

  /// Pads plaintext to exactly 1024 bytes using PKCS7 padding
  /// This prevents message length inference attacks
  Uint8List padTo1KB(Uint8List data) {
    try {
      if (data.isEmpty) {
        throw CryptoValidationException('data cannot be empty');
      }

      const int targetSize = 1024;
      if (data.length > targetSize) {
        throw CryptoValidationException(
          'data too large: ${data.length} bytes, maximum 1024 allowed',
        );
      }

      // PKCS7 padding: pad with bytes where each byte = padding length
      final int paddingLength = targetSize - data.length;
      final List<int> padded = List<int>.from(data);
      padded.addAll(List<int>.filled(paddingLength, paddingLength));

      return Uint8List.fromList(padded);
    } catch (e, stackTrace) {
      if (e is CryptoException) rethrow;
      throw CryptoOperationException('Failed to pad data: $e', stackTrace);
    }
  }

  /// Removes PKCS7 padding from 1KB-padded plaintext
  Uint8List unpadFrom1KB(Uint8List paddedData) {
    try {
      if (paddedData.isEmpty) {
        throw CryptoValidationException('paddedData cannot be empty');
      }

      if (paddedData.length != 1024) {
        throw CryptoValidationException(
          'paddedData invalid length: ${paddedData.length}, expected 1024',
        );
      }

      // Read the padding length from the last byte
      final int paddingLength = paddedData[1023];

      if (paddingLength <= 0 || paddingLength > 256) {
        throw CryptoValidationException(
          'Invalid PKCS7 padding: $paddingLength',
        );
      }

      // Verify all padding bytes are correct
      for (int i = 0; i < paddingLength; i++) {
        if (paddedData[1024 - 1 - i] != paddingLength) {
          throw CryptoValidationException('Invalid PKCS7 padding format');
        }
      }

      return Uint8List.fromList(paddedData.sublist(0, 1024 - paddingLength));
    } catch (e, stackTrace) {
      if (e is CryptoException) rethrow;
      throw CryptoOperationException('Failed to unpad data: $e', stackTrace);
    }
  }

  String encodePayload({
    required String senderWallet,
    required String senderUsername,
    required String content,
  }) {
    try {
      // Validate inputs
      _validateString(senderWallet, 'senderWallet');
      _validateString(senderUsername, 'senderUsername');
      _validateString(content, 'content');

      final payload = MessagePayload(
        senderWallet: senderWallet,
        senderUsername: senderUsername,
        content: content,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      return jsonEncode(payload.toJson());
    } on CryptoException {
      rethrow;
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'Failed to encode payload: $e',
        stackTrace,
      );
    }
  }

  MessagePayload decodePayload(String jsonString) {
    try {
      if (jsonString.isEmpty) {
        throw CryptoValidationException('jsonString cannot be empty');
      }

      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return MessagePayload.fromJson(json);
    } on CryptoException {
      rethrow;
    } on FormatException catch (e, stackTrace) {
      throw CryptoOperationException(
        'Invalid JSON format: ${e.message}',
        stackTrace,
      );
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'Failed to decode payload: $e',
        stackTrace,
      );
    }
  }

  Future<Uint8List> computeRecipientTag(Uint8List sharedSecret) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      'sealed-recipient-tag-v1'.codeUnits,
      secretKey: SecretKey(sharedSecret),
    );
    return Uint8List.fromList(mac.bytes);
  }

  // Compute Shared Secret
  Future<Uint8List> computeSharedSecret({
    required SimpleKeyPair keyPair,
    required Uint8List publicKey,
  }) async {
    // Create remote public key
    final remotePublicKey = SimplePublicKey(
      publicKey,
      type: KeyPairType.x25519,
    );

    // Perform ECDH
    final sharedSecretKey = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );

    // Extract bytes
    final sharedSecretBytes = await sharedSecretKey.extractBytes();
    return Uint8List.fromList(sharedSecretBytes);
  }

  bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<bool> isMessageForMe({
    required Uint8List viewPrivateKey,
    required Uint8List senderEncryptionPubkey,
    required Uint8List recipientTag,
  }) async {
    try {
      // Validate inputs
      _validateKeyLength(viewPrivateKey, 32, 'viewPrivateKey');
      _validateKeyLength(senderEncryptionPubkey, 32, 'senderEncryptionPubkey');
      _validateKeyLength(recipientTag, 32, 'recipientTag');

      final myKeyPair = await _x25519.newKeyPairFromSeed(viewPrivateKey);
      final senderPubKey = SimplePublicKey(
        senderEncryptionPubkey,
        type: KeyPairType.x25519,
      );

      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: myKeyPair,
        remotePublicKey: senderPubKey,
      );

      final mac = await _hmac.calculateMac(
        utf8.encode('sealed-recipient-tag-v1'),
        secretKey: sharedSecret,
      );

      return constantTimeEquals(Uint8List.fromList(mac.bytes), recipientTag);
    } on CryptoException {
      rethrow;
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'Failed to verify message recipient: $e',
        stackTrace,
      );
    }
  }

  Future<SimpleKeyPair> generateEphemeralKeyPair() async {
    try {
      final keyPair = await _x25519.newKeyPair();
      return keyPair;
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'Failed to generate ephemeral key pair: $e',
        stackTrace,
      );
    }
  }

  // Future<Uint8List> encrypt({
  //   required SimpleKeyPair senderEncryptionKeyPair,
  //   required Uint8List recipientEncryptionPubkey,
  //   required Uint8List plainTextBytes,
  // }) async {
  //   try {
  //     // Validate inputs
  //     _validateKeyLength(
  //       recipientEncryptionPubkey,
  //       32,
  //       'recipientEncryptionPubkey',
  //     );
  //     if (plainTextBytes.isEmpty) {
  //       throw CryptoValidationException('plainTextBytes cannot be empty');
  //     }

  //     final sharedSecret = await _x25519.sharedSecretKey(
  //       keyPair: senderEncryptionKeyPair,
  //       remotePublicKey: SimplePublicKey(
  //         recipientEncryptionPubkey,
  //         type: KeyPairType.x25519,
  //       ),
  //     );

  //     final secretKey = await _hkdf.deriveKey(
  //       secretKey: sharedSecret,
  //       info: utf8.encode('sealed-aes-gcm-v1'),
  //     );

  //     // Generate a random nonce
  //     final nonce = _aesGcm.newNonce();

  //     final secretBox = await _aesGcm.encrypt(
  //       plainTextBytes,
  //       secretKey: secretKey,
  //       nonce: nonce,
  //     );

  //     // Pack nonce and ciphertext together + mac
  //     final combined = Uint8List.fromList([
  //       ...nonce,
  //       ...secretBox.cipherText,
  //       ...secretBox.mac.bytes,
  //     ]);

  //     return combined;
  //   } on CryptoException {
  //     rethrow;
  //   } catch (e, stackTrace) {
  //     throw CryptoOperationException(
  //       'Failed to encrypt message: $e',
  //       stackTrace,
  //     );
  //   }
  // }

  // Future<Uint8List> decrypt({
  //   required SimpleKeyPair encryptionKeyPair,
  //   required Uint8List senderEncryptionPubkey,
  //   required Uint8List cipherText,
  // }) async {
  //   try {
  //     // Validate inputs
  //     _validateKeyLength(senderEncryptionPubkey, 32, 'senderEncryptionPubkey');

  //     // Ciphertext must be at least 12 (nonce) + 16 (mac) bytes
  //     if (cipherText.length < 28) {
  //       throw CryptoValidationException(
  //         'cipherText too short: ${cipherText.length} bytes, minimum 28 required',
  //       );
  //     }

  //     final sharedSecret = await _x25519.sharedSecretKey(
  //       keyPair: encryptionKeyPair,
  //       remotePublicKey: SimplePublicKey(
  //         senderEncryptionPubkey,
  //         type: KeyPairType.x25519,
  //       ),
  //     );

  //     final secretKey = await _hkdf.deriveKey(
  //       secretKey: sharedSecret,
  //       info: utf8.encode('sealed-aes-gcm-v1'),
  //     );

  //     // Extract nonce, ciphertext, and mac from combined
  //     final nonce = cipherText.sublist(0, 12); // AES-GCM nonce
  //     final macBytes = cipherText.sublist(
  //       cipherText.length - 16,
  //     ); // AES-GCM mac
  //     final actualCipherText = cipherText.sublist(12, cipherText.length - 16);

  //     final secretBox = SecretBox(
  //       actualCipherText,
  //       nonce: nonce,
  //       mac: Mac(macBytes),
  //     );

  //     final clearTextBytes = await _aesGcm.decrypt(
  //       secretBox,
  //       secretKey: secretKey,
  //     );
  //     return Uint8List.fromList(clearTextBytes);
  //   } on CryptoException {
  //     rethrow;
  //   } catch (e, stackTrace) {
  //     throw CryptoOperationException(
  //       'Failed to decrypt message: $e',
  //       stackTrace,
  //     );
  //   }
  // }

  /// Generate a new ML-KEM-512 keypair.
  /// Returns serialized public key (800 bytes) and private key (1632 bytes).
  Future<({Uint8List publicKey, Uint8List privateKey})>
  generatePqKeyPair() async {
    final random = Random.secure();
    final seed = Uint8List.fromList(
      List.generate(64, (_) => random.nextInt(256)),
    );
    final kyber = Kyber.kem512();
    final (pk, sk) = kyber.generateKeys(seed);
    return (
      publicKey: Uint8List.fromList(pk.serialize()),
      privateKey: Uint8List.fromList(sk.serialize()),
    );
  }

  /// Perform ML-KEM-512 encapsulation against recipient's PQ public key.
  /// Returns KEM ciphertext (768 bytes) and shared secret (32 bytes).
  Future<KemResult> kemEncapsulate(Uint8List recipientPqPubkey) async {
    try {
      final kyber = Kyber.kem512();
      final pk = KemPublicKey.deserialize(recipientPqPubkey, 2);
      final random = Random.secure();
      final nonce = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      );
      final (cipher, sharedSecret) = kyber.encapsulate(pk, nonce);
      return KemResult(
        ciphertext: cipher.serialize(),
        sharedSecret: sharedSecret,
      );
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'KEM encapsulation failed: $e',
        stackTrace,
      );
    }
  }

  /// Perform ML-KEM-512 decapsulation using own PQ private key.
  /// Returns 32-byte shared secret.
  Future<Uint8List> kemDecapsulate(
    Uint8List kemCiphertext,
    Uint8List myPqPrivateKey,
  ) async {
    try {
      final kyber = Kyber.kem512();
      final sk = KemPrivateKey.deserialize(myPqPrivateKey, 2);
      final cipher = PKECypher.deserialize(kemCiphertext, 2);
      return Uint8List.fromList(kyber.decapsulate(cipher, sk));
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'KEM decapsulation failed: $e',
        stackTrace,
      );
    }
  }

  /// Derive AES key using hybrid key material (classical X25519 + PQ ML-KEM).
  /// If pqSharedSecret is null, falls back to classical-only (backward compat).
  Future<SecretKey> deriveHybridKey({
    required SecretKey classicalSharedSecret,
    Uint8List? pqSharedSecret,
  }) async {
    final classicalBytes = await classicalSharedSecret.extractBytes();

    final combined = pqSharedSecret != null
        ? Uint8List.fromList([...classicalBytes, ...pqSharedSecret])
        : Uint8List.fromList(classicalBytes);

    final info = pqSharedSecret != null
        ? 'sealed-hybrid-aes-gcm-v1'
        : 'sealed-aes-gcm-v1';

    return _hkdf.deriveKey(
      secretKey: SecretKey(combined),
      info: utf8.encode(info),
    );
  }

  /// Encrypt with hybrid key derivation (X25519 + optional PQ shared secret).
  Future<Uint8List> encryptHybrid({
    required Uint8List plainTextBytes,
    required SimpleKeyPair senderEncryptionKeyPair,
    required Uint8List recipientEncryptionPubkey,
    Uint8List? pqSharedSecret,
  }) async {
    try {
      _validateKeyLength(
        recipientEncryptionPubkey,
        32,
        'recipientEncryptionPubkey',
      );
      if (plainTextBytes.isEmpty) {
        throw CryptoValidationException('plainTextBytes cannot be empty');
      }

      final classicalSecret = await _x25519.sharedSecretKey(
        keyPair: senderEncryptionKeyPair,
        remotePublicKey: SimplePublicKey(
          recipientEncryptionPubkey,
          type: KeyPairType.x25519,
        ),
      );

      final aesKey = await deriveHybridKey(
        classicalSharedSecret: classicalSecret,
        pqSharedSecret: pqSharedSecret,
      );

      final nonce = _aesGcm.newNonce();
      final secretBox = await _aesGcm.encrypt(
        plainTextBytes,
        secretKey: aesKey,
        nonce: nonce,
      );

      return Uint8List.fromList([
        ...nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);
    } on CryptoException {
      rethrow;
    } catch (e, stackTrace) {
      throw CryptoOperationException('Hybrid encrypt failed: $e', stackTrace);
    }
  }

  /// Decrypt with hybrid key derivation (X25519 + optional PQ shared secret).
  Future<Uint8List> decryptHybrid({
    required Uint8List cipherText,
    required SimpleKeyPair encryptionKeyPair,
    required Uint8List senderEncryptionPubkey,
    Uint8List? pqSharedSecret,
  }) async {
    try {
      _validateKeyLength(senderEncryptionPubkey, 32, 'senderEncryptionPubkey');
      if (cipherText.length < 28) {
        throw CryptoValidationException(
          'cipherText too short: ${cipherText.length} bytes',
        );
      }

      final classicalSecret = await _x25519.sharedSecretKey(
        keyPair: encryptionKeyPair,
        remotePublicKey: SimplePublicKey(
          senderEncryptionPubkey,
          type: KeyPairType.x25519,
        ),
      );

      final aesKey = await deriveHybridKey(
        classicalSharedSecret: classicalSecret,
        pqSharedSecret: pqSharedSecret,
      );

      final nonce = cipherText.sublist(0, 12);
      final macBytes = cipherText.sublist(cipherText.length - 16);
      final actualCipherText = cipherText.sublist(12, cipherText.length - 16);

      final secretBox = SecretBox(
        actualCipherText,
        nonce: nonce,
        mac: Mac(macBytes),
      );
      final clearTextBytes = await _aesGcm.decrypt(
        secretBox,
        secretKey: aesKey,
      );
      return Uint8List.fromList(clearTextBytes);
    } on CryptoException {
      rethrow;
    } catch (e, stackTrace) {
      throw CryptoOperationException('Hybrid decrypt failed: $e', stackTrace);
    }
  }

  // ---------------------------------------------------------------------------
  // Alias chat symmetric encryption (enc_key is already the AES key)
  // ---------------------------------------------------------------------------

  /// Encrypt plaintext using the alias channel enc_key directly.
  ///
  /// The enc_key is a 32-byte key that was derived during the alias key
  /// exchange (hybrid X25519 + ML-KEM-512 via HKDF). No per-message ECDH
  /// is needed — the key exchange already provides forward secrecy.
  ///
  /// Output layout: [12B nonce][NB ciphertext][16B AES-GCM mac]
  Future<Uint8List> encryptWithEncKey({
    required Uint8List encKey,
    required Uint8List plainTextBytes,
  }) async {
    try {
      if (encKey.length != 32) {
        throw CryptoValidationException(
          'encKey must be 32 bytes, got ${encKey.length}',
        );
      }
      if (plainTextBytes.isEmpty) {
        throw CryptoValidationException('plainTextBytes cannot be empty');
      }

      final secretKey = SecretKey(encKey);
      final nonce = _aesGcm.newNonce();
      final secretBox = await _aesGcm.encrypt(
        plainTextBytes,
        secretKey: secretKey,
        nonce: nonce,
      );

      return Uint8List.fromList([
        ...nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);
    } on CryptoException {
      rethrow;
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'Alias symmetric encrypt failed: $e',
        stackTrace,
      );
    }
  }

  /// Decrypt ciphertext using the alias channel enc_key directly.
  ///
  /// Expects layout: [12B nonce][NB ciphertext][16B AES-GCM mac]
  Future<Uint8List> decryptWithEncKey({
    required Uint8List encKey,
    required Uint8List cipherText,
  }) async {
    try {
      if (encKey.length != 32) {
        throw CryptoValidationException(
          'encKey must be 32 bytes, got ${encKey.length}',
        );
      }
      if (cipherText.length < 28) {
        throw CryptoValidationException(
          'cipherText too short: ${cipherText.length} bytes',
        );
      }

      final secretKey = SecretKey(encKey);
      final nonce = cipherText.sublist(0, 12);
      final macBytes = cipherText.sublist(cipherText.length - 16);
      final actualCipher = cipherText.sublist(12, cipherText.length - 16);

      final secretBox = SecretBox(
        actualCipher,
        nonce: nonce,
        mac: Mac(macBytes),
      );

      final clearTextBytes = await _aesGcm.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return Uint8List.fromList(clearTextBytes);
    } on CryptoException {
      rethrow;
    } catch (e, stackTrace) {
      throw CryptoOperationException(
        'Alias symmetric decrypt failed: $e',
        stackTrace,
      );
    }
  }

  /// Derive the recipientTag from an enc_key.
  /// recipientTag = HMAC-SHA256(enc_key, "sealed-recipient-tag-v1")
  /// This is deterministic — same enc_key always gives same tag.
  Future<Uint8List> computeAliasRecipientTag(Uint8List encKey) async {
    final mac = await _hmac.calculateMac(
      utf8.encode('sealed-recipient-tag-v1'),
      secretKey: SecretKey(encKey),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Check if a message (identified by its recipientTag) is addressed to us.
  /// Computes ECDH(myScanKeyPair, senderEncryptionPubkey) then
  /// HMAC-SHA256(sharedSecret, "sealed-recipient-tag-v1") and compares.
  Future<bool> checkRecipientTag({
    required Uint8List senderEncryptionPubkey,
    required Uint8List recipientTag,
    required SimpleKeyPair myScanKeyPair,
  }) async {
    try {
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: myScanKeyPair,
        remotePublicKey: SimplePublicKey(
          senderEncryptionPubkey,
          type: KeyPairType.x25519,
        ),
      );
      final mac = await _hmac.calculateMac(
        utf8.encode('sealed-recipient-tag-v1'),
        secretKey: sharedSecret,
      );
      final expected = Uint8List.fromList(mac.bytes);
      if (expected.length != recipientTag.length) return false;
      int diff = 0;
      for (int i = 0; i < expected.length; i++) {
        diff |= expected[i] ^ recipientTag[i];
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }
}
