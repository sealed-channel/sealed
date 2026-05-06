import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Sealed-box style encryption for push tokens.
///
/// Inverse partner of `sealed-indexer/src/push/dispatcher-seal.ts`. Both
/// sides MUST stay byte-exact:
///
///   envelope = eph_pub(32) || ciphertext(256) || mac(16)   = 304 bytes
///   shared   = X25519(eph_priv, dispatcher_pub)
///   salt     = eph_pub || dispatcher_pub                   (64 bytes)
///   nonce    = blake2b512(salt)[0..12]                     (12 bytes)
///   key      = HKDF-SHA256(ikm=shared, salt=salt,
///                          info="sealed-push-token-v1", L=32)
///   padded   = u16be(token.length) || token_utf8 || zero_pad   (256 bytes)
///   (ct, mac) = AES-256-GCM(key, nonce, padded)
class DispatcherSeal {
  static const int envelopeSize = 304;
  static const int ephPubSize = 32;
  static const int ciphertextSize = 256;
  static const int macSize = 16;
  static const int paddedTokenSize = 256;
  static const int keySize = 32;
  static const int nonceSize = 12;
  static const int maxTokenBytes = paddedTokenSize - 2;
  static const String hkdfInfo = 'sealed-push-token-v1';

  final X25519 _x25519;
  final Hkdf _hkdf;
  final Blake2b _blake2b;
  final AesGcm _aesGcm;

  DispatcherSeal({X25519? x25519, Hkdf? hkdf, Blake2b? blake2b, AesGcm? aesGcm})
    : _x25519 = x25519 ?? X25519(),
      _hkdf = hkdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: keySize),
      _blake2b = blake2b ?? Blake2b(),
      _aesGcm = aesGcm ?? AesGcm.with256bits();

  /// Encrypt [token] for the given 32-byte X25519 dispatcher public key and
  /// return a 304-byte envelope. Caller is responsible for base64-encoding.
  Future<Uint8List> sealToken(String token, Uint8List dispatcherPubKey) async {
    if (dispatcherPubKey.length != ephPubSize) {
      throw ArgumentError(
        'dispatcherPubKey must be 32 bytes, got ${dispatcherPubKey.length}',
      );
    }
    final tokenBytes = utf8.encode(token);
    if (tokenBytes.isEmpty) {
      throw ArgumentError('token must not be empty');
    }
    if (tokenBytes.length > maxTokenBytes) {
      throw ArgumentError(
        'token too long: ${tokenBytes.length} > $maxTokenBytes',
      );
    }

    final ephKeyPair = await _x25519.newKeyPair();
    final ephPubKey = await ephKeyPair.extractPublicKey();
    final ephPub = Uint8List.fromList(ephPubKey.bytes);

    final dispatcherPubKeyObj = SimplePublicKey(
      List<int>.from(dispatcherPubKey),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephKeyPair,
      remotePublicKey: dispatcherPubKeyObj,
    );
    final sharedBytes = await shared.extractBytes();

    final salt = Uint8List(ephPubSize * 2)
      ..setRange(0, ephPubSize, ephPub)
      ..setRange(ephPubSize, ephPubSize * 2, dispatcherPubKey);

    final nonce = await _deriveNonce(salt);
    final aesKey = await _hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: salt,
      info: utf8.encode(hkdfInfo),
    );

    final padded = Uint8List(paddedTokenSize);
    padded[0] = (tokenBytes.length >> 8) & 0xff;
    padded[1] = tokenBytes.length & 0xff;
    padded.setRange(2, 2 + tokenBytes.length, tokenBytes);

    final secretBox = await _aesGcm.encrypt(
      padded,
      secretKey: aesKey,
      nonce: nonce,
    );
    if (secretBox.cipherText.length != ciphertextSize) {
      throw StateError(
        'Unexpected ciphertext length: ${secretBox.cipherText.length}',
      );
    }
    if (secretBox.mac.bytes.length != macSize) {
      throw StateError('Unexpected mac length: ${secretBox.mac.bytes.length}');
    }

    final envelope = Uint8List(envelopeSize)
      ..setRange(0, ephPubSize, ephPub)
      ..setRange(ephPubSize, ephPubSize + ciphertextSize, secretBox.cipherText)
      ..setRange(
        ephPubSize + ciphertextSize,
        envelopeSize,
        secretBox.mac.bytes,
      );
    return envelope;
  }

  Future<Uint8List> _deriveNonce(Uint8List salt) async {
    final hash = await _blake2b.hash(salt);
    return Uint8List.fromList(hash.bytes.sublist(0, nonceSize));
  }
}
