/// Alias chat cryptographic key management service.
/// Handles shared secret derivation, invitation keys, and
/// ephemeral cryptographic material for anonymous channels.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages cryptographic key material for alias chats.
///
/// During key exchange (pending state) a temporary X25519 keypair and a
/// temporary ML-KEM-512 keypair are stored here. Once key exchange completes
/// the enc_key (hybrid X25519 + ML-KEM derived key) is stored and all
/// temporary keypairs are erased.
///
/// After key exchange the device stores only:
///   alias_{inviteSecret}_enckey     — 32-byte symmetric enc_key
///   alias_{inviteSecret}_rectag     — 32-byte recipientTag (HMAC of enc_key)
class AliasKeyService {
  final FlutterSecureStorage _storage;
  final X25519 _x25519;

  AliasKeyService({FlutterSecureStorage? storage, X25519? x25519})
    : _storage = storage ?? const FlutterSecureStorage(),
      _x25519 = x25519 ?? X25519();

  // ---------------------------------------------------------------------------
  // Key naming
  // ---------------------------------------------------------------------------
  String _encKeyName(String inviteSecret) => 'alias_${inviteSecret}_enckey';
  String _recTagName(String inviteSecret) => 'alias_${inviteSecret}_rectag';
  // Temporary X25519 keypair (erased after key exchange)
  String _tempPrivName(String inviteSecret) => 'alias_${inviteSecret}_tmp_priv';
  String _tempPubName(String inviteSecret) => 'alias_${inviteSecret}_tmp_pub';
  // Temporary PQ keypair (erased after key exchange)
  String _pqPrivName(String inviteSecret) => 'alias_${inviteSecret}_pq_priv';
  String _pqPubName(String inviteSecret) => 'alias_${inviteSecret}_pq_pub';

  // ---------------------------------------------------------------------------
  // Temporary X25519 keypair (used during key-exchange only)
  // ---------------------------------------------------------------------------

  /// Generate a temporary X25519 keypair for a new alias chat and persist it
  /// until key exchange completes.
  Future<({Uint8List privateKey, Uint8List publicKey})> generateTempKeyPair(
    String inviteSecret,
  ) async {
    final keyPair = await _x25519.newKeyPair();
    final privateBytes = Uint8List.fromList(
      await keyPair.extractPrivateKeyBytes(),
    );
    final publicBytes = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );

    await _storage.write(
      key: _tempPrivName(inviteSecret),
      value: base64Encode(privateBytes),
    );
    await _storage.write(
      key: _tempPubName(inviteSecret),
      value: base64Encode(publicBytes),
    );

    return (privateKey: privateBytes, publicKey: publicBytes);
  }

  /// Load temporary X25519 keypair (null if already erased).
  Future<({Uint8List privateKey, Uint8List publicKey})?> loadTempKeyPair(
    String inviteSecret,
  ) async {
    final privB64 = await _storage.read(key: _tempPrivName(inviteSecret));
    final pubB64 = await _storage.read(key: _tempPubName(inviteSecret));
    if (privB64 == null || pubB64 == null) return null;
    return (
      privateKey: Uint8List.fromList(base64Decode(privB64)),
      publicKey: Uint8List.fromList(base64Decode(pubB64)),
    );
  }

  /// Reconstruct a [SimpleKeyPair] from stored temp bytes for use with CryptoService.
  Future<SimpleKeyPair?> getTempKeyPairForCrypto(String inviteSecret) async {
    final keys = await loadTempKeyPair(inviteSecret);
    if (keys == null) return null;
    return SimpleKeyPairData(
      keys.privateKey,
      publicKey: SimplePublicKey(keys.publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  // ---------------------------------------------------------------------------
  // Temporary ML-KEM-512 keypair (used during key-exchange only)
  // ---------------------------------------------------------------------------

  /// Persist a temporary PQ keypair generated externally (by CryptoService).
  Future<void> storeTempPqKeyPair(
    String inviteSecret, {
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await _storage.write(
      key: _pqPrivName(inviteSecret),
      value: base64Encode(privateKey),
    );
    await _storage.write(
      key: _pqPubName(inviteSecret),
      value: base64Encode(publicKey),
    );
  }

  /// Load the temporary PQ private key (null if already erased).
  Future<Uint8List?> loadTempPqPrivateKey(String inviteSecret) async {
    final b64 = await _storage.read(key: _pqPrivName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Load the temporary PQ public key (null if already erased).
  Future<Uint8List?> loadTempPqPublicKey(String inviteSecret) async {
    final b64 = await _storage.read(key: _pqPubName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  // ---------------------------------------------------------------------------
  // Derived enc_key + recipientTag (stored after key exchange)
  // ---------------------------------------------------------------------------

  /// Store the final enc_key and pre-computed recipientTag after key exchange.
  /// Call this after deriving enc_key; temporary keypairs can then be erased.
  Future<void> storeEncKey(
    String inviteSecret, {
    required Uint8List encKey,
    required Uint8List recipientTag,
  }) async {
    await _storage.write(
      key: _encKeyName(inviteSecret),
      value: base64Encode(encKey),
    );
    await _storage.write(
      key: _recTagName(inviteSecret),
      value: base64Encode(recipientTag),
    );
  }

  /// Load the enc_key for a channel (null if not yet derived or already wiped).
  Future<Uint8List?> getEncKey(String inviteSecret) async {
    final b64 = await _storage.read(key: _encKeyName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Load the pre-computed recipientTag for a channel.
  Future<Uint8List?> getRecipientTag(String inviteSecret) async {
    final b64 = await _storage.read(key: _recTagName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  // ---------------------------------------------------------------------------
  // Lifecycle helpers
  // ---------------------------------------------------------------------------

  /// Erase all temporary key material for a channel (X25519 + PQ).
  /// Call this immediately after storeEncKey() succeeds.
  Future<void> eraseTempKeys(String inviteSecret) async {
    await _storage.delete(key: _tempPrivName(inviteSecret));
    await _storage.delete(key: _tempPubName(inviteSecret));
    await _storage.delete(key: _pqPrivName(inviteSecret));
    await _storage.delete(key: _pqPubName(inviteSecret));
  }

  /// Erase enc_key and recipientTag for a channel (used when destroying the
  /// alias chat).
  Future<void> eraseEncKey(String inviteSecret) async {
    await _storage.delete(key: _encKeyName(inviteSecret));
    await _storage.delete(key: _recTagName(inviteSecret));
  }

  /// Erase everything associated with a channel.
  Future<void> deleteAll(String inviteSecret) async {
    await eraseTempKeys(inviteSecret);
    await eraseEncKey(inviteSecret);
  }

  /// Delete all alias key material (used on logout).
  Future<void> deleteAllChannels() async {
    final all = await _storage.readAll();
    for (final key in all.keys) {
      if (key.startsWith('alias_')) {
        await _storage.delete(key: key);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  /// Generate a random 32-byte invite secret (base64url-encoded).
  static String generateInviteSecret() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes);
  }
}
