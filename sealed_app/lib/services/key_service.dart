/// Cryptographic key management and derivation service.
/// Handles identity keys, view keys, ephemeral keys, and secure storage operations
/// for both Ed25519 signing keys and X25519 encryption keys.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Import Kyber directly to avoid the broken Dilithium barrel export
// ignore: implementation_imports
import 'package:post_quantum/src/kyber.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chain/wallet_interface.dart';
import '../models/sealed_keys.dart';
import 'key_format_converter.dart';

// Custom Exceptions
class KeyServiceException implements Exception {
  final String message;
  final String? code;
  final StackTrace? stackTrace;

  KeyServiceException(this.message, {this.code, this.stackTrace});

  @override
  String toString() =>
      'KeyServiceException: $message${code != null ? ' ($code)' : ''}';
}

class KeyDerivationException extends KeyServiceException {
  KeyDerivationException(super.message, [StackTrace? stackTrace])
    : super(code: 'DERIVATION_ERROR', stackTrace: stackTrace);
}

class KeyStorageException extends KeyServiceException {
  KeyStorageException(super.message, [StackTrace? stackTrace])
    : super(code: 'STORAGE_ERROR', stackTrace: stackTrace);
}

class KeyValidationException extends KeyServiceException {
  KeyValidationException(super.message) : super(code: 'VALIDATION_ERROR');
}

class KeyService {
  FlutterSecureStorage get _storage => storage;
  X25519 get _x25519 => x25519;
  Hkdf get _hkdf => hkdf;
  SharedPreferences get _prefs => prefs;
  final FlutterSecureStorage storage;
  final SharedPreferences prefs;
  final X25519 x25519;
  final Hkdf hkdf;

  final ChainWallet? chainWallet;

  KeyService({
    required this.storage,
    required this.x25519,
    required this.hkdf,
    required this.prefs,
    required this.chainWallet,
  });

  /// Derive encryption and view keys from local wallet seed
  /// This is the new method that doesn't require external wallet signature
  Future<SealedKeys> deriveKeysFromLocalWallet() async {
    final startTime = DateTime.now();
    print('🔐 KeyService: Starting key derivation from local wallet...');

    if (chainWallet == null) {
      throw KeyValidationException('No wallet service provided');
    }

    final seedBytes = await chainWallet!.getSeedBytes();

    final walletAddress = chainWallet?.walletAddress;
    if (walletAddress == null) {
      throw KeyValidationException('Local wallet address not found');
    }

    try {
      // 1) Hash seed -> entropy (SHA-256)
      // Use different domain separator to get different keys than the signing keypair
      print('🔐 KeyService: Step 1 - Hashing seed with SHA-256...');
      var step1Start = DateTime.now();
      final algorithm = Sha256();
      // Add domain separator to derive different keys
      final preimage = Uint8List.fromList([
        ...utf8.encode('sealed-messaging-keys-v1:'),
        ...seedBytes,
      ]);
      final Hash hash = await algorithm.hash(preimage);
      final Uint8List entropy = Uint8List.fromList(hash.bytes);
      print(
        '🔐 KeyService: Step 1 complete (${DateTime.now().difference(step1Start).inMilliseconds}ms)',
      );

      // 2) Derive two 32-byte seeds via HKDF
      print('🔐 KeyService: Step 2 - Deriving encryption seed with HKDF...');
      var step2Start = DateTime.now();
      final SecretKey encSeedKey = await _hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-encryption-v1'),
      );
      final Uint8List encryptionSeed = Uint8List.fromList(
        await encSeedKey.extractBytes(),
      );
      print(
        '🔐 KeyService: Encryption seed derived (${DateTime.now().difference(step2Start).inMilliseconds}ms)',
      );

      print('🔐 KeyService: Step 2b - Deriving view seed with HKDF...');
      var step2bStart = DateTime.now();
      final SecretKey viewSeedKey = await _hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-view-v1'),
      );
      final Uint8List viewSeed = Uint8List.fromList(
        await viewSeedKey.extractBytes(),
      );
      print(
        '🔐 KeyService: View seed derived (${DateTime.now().difference(step2bStart).inMilliseconds}ms)',
      );

      // 3) Create X25519 keypairs from seeds
      print('🔐 KeyService: Step 3 - Creating X25519 keypairs...');
      var step3Start = DateTime.now();
      final SimpleKeyPair encryptionKeyPair = await _x25519.newKeyPairFromSeed(
        encryptionSeed,
      );
      final SimpleKeyPair viewKeyPair = await _x25519.newKeyPairFromSeed(
        viewSeed,
      );

      final SimplePublicKey encPub = await encryptionKeyPair.extractPublicKey();
      final SimplePublicKey viewPub = await viewKeyPair.extractPublicKey();
      print(
        '🔐 KeyService: Keypairs created (${DateTime.now().difference(step3Start).inMilliseconds}ms)',
      );

      // 4) Generate ML-KEM-512 (post-quantum) keypair
      print('🔐 KeyService: Step 4 - Generating ML-KEM-512 keypair...');
      var step4Start = DateTime.now();
      final pqKeys = await _ensurePqKeys(seedBytes);
      print(
        '🔐 KeyService: PQ keypair ready (${DateTime.now().difference(step4Start).inMilliseconds}ms)',
      );

      // 5) Save Keys
      print('🔐 KeyService: Step 5 - Saving keys to secure storage...');
      var step5Start = DateTime.now();
      await _saveKeys(
        walletAddress: walletAddress,
        encryptionPrivateKey: encryptionSeed,
        viewPrivateKey: viewSeed,
      );
      await savePqKeys(pqKeys.publicKey, pqKeys.privateKey);
      print(
        '🔐 KeyService: Keys saved (${DateTime.now().difference(step5Start).inMilliseconds}ms)',
      );

      // 6) Return SealedKeys
      final totalDuration = DateTime.now().difference(startTime);
      print(
        '🔐 KeyService: ✅ Key derivation complete! Total: ${totalDuration.inMilliseconds}ms',
      );

      return SealedKeys(
        encryptionKeyPair: encryptionKeyPair,
        scanKeyPair: viewKeyPair,
        walletAddress: walletAddress,
        scanPubkey: Uint8List.fromList(viewPub.bytes),
        encryptionPubkey: Uint8List.fromList(encPub.bytes),
        encryptionPrivateKey: encryptionSeed,
        viewPrivateKey: viewSeed,
        pqPublicKey: pqKeys.publicKey,
        pqPrivateKey: pqKeys.privateKey,
      );
    } on KeyServiceException {
      rethrow;
    } catch (e, stackTrace) {
      throw KeyDerivationException(
        'Failed to derive keys from local wallet: $e',
        stackTrace,
      );
    }
  }

  /// Legacy method: Derive keys from wallet signature (for backward compatibility)
  @Deprecated('Use deriveKeysFromLocalWallet() instead')
  Future<SealedKeys> deriveKeys(String walletAddress, dynamic signature) async {
    final startTime = DateTime.now();
    print('🔐 KeyService: Starting key derivation process...');

    try {
      if (walletAddress.isEmpty) {
        throw KeyValidationException('walletAddress cannot be empty');
      }

      if (signature == null) {
        throw KeyValidationException('signature cannot be null');
      }

      // 1) Obtain signature bytes
      print('🔐 KeyService: Step 1 - Parsing signature...');
      var step1Start = DateTime.now();
      Uint8List signatureBytes;
      if (signature is String) {
        try {
          signatureBytes = base64.decode(signature);
        } catch (e) {
          throw KeyValidationException('Invalid base64 signature format: $e');
        }
      } else if (signature is Uint8List) {
        signatureBytes = signature;
      } else {
        throw KeyValidationException(
          'Unsupported signature format: ${signature.runtimeType}',
        );
      }

      if (signatureBytes.isEmpty) {
        throw KeyValidationException('signature bytes cannot be empty');
      }
      print(
        '🔐 KeyService: Step 1 complete (${DateTime.now().difference(step1Start).inMilliseconds}ms)',
      );

      // 2) Hash signature -> entropy (SHA-256)
      print('🔐 KeyService: Step 2 - Hashing signature with SHA-256...');
      var step2Start = DateTime.now();
      final algorithm = Sha256();
      final Hash hash = await algorithm.hash(signatureBytes);
      final Uint8List entropy = Uint8List.fromList(hash.bytes);
      print(
        '🔐 KeyService: Step 2 complete (${DateTime.now().difference(step2Start).inMilliseconds}ms)',
      );

      // 3) Derive two 32-byte seeds via HKDF
      print('🔐 KeyService: Step 3 - Deriving encryption seed with HKDF...');
      var step3Start = DateTime.now();
      final SecretKey encSeedKey = await _hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-encryption-v1'),
      );
      final Uint8List encryptionSeed = Uint8List.fromList(
        await encSeedKey.extractBytes(),
      );
      print(
        '🔐 KeyService: Encryption seed derived (${DateTime.now().difference(step3Start).inMilliseconds}ms)',
      );

      print('🔐 KeyService: Step 3b - Deriving view seed with HKDF...');
      var step3bStart = DateTime.now();
      final SecretKey viewSeedKey = await _hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-view-v1'),
      );
      final Uint8List viewSeed = Uint8List.fromList(
        await viewSeedKey.extractBytes(),
      );
      print(
        '🔐 KeyService: View seed derived (${DateTime.now().difference(step3bStart).inMilliseconds}ms)',
      );

      // 4) Create X25519 keypairs from seeds
      print('🔐 KeyService: Step 4 - Creating X25519 keypairs...');
      var step4Start = DateTime.now();
      final SimpleKeyPair encryptionKeyPair = await _x25519.newKeyPairFromSeed(
        encryptionSeed,
      );
      final SimpleKeyPair viewKeyPair = await _x25519.newKeyPairFromSeed(
        viewSeed,
      );

      final SimplePublicKey encPub = await encryptionKeyPair.extractPublicKey();
      final SimplePublicKey viewPub = await viewKeyPair.extractPublicKey();
      print(
        '🔐 KeyService: Keypairs created (${DateTime.now().difference(step4Start).inMilliseconds}ms)',
      );

      // Save Keys
      print('🔐 KeyService: Step 5 - Saving keys to secure storage...');
      var step5Start = DateTime.now();
      await _saveKeys(
        walletAddress: walletAddress,
        encryptionPrivateKey: encryptionSeed,
        viewPrivateKey: viewSeed,
      );
      print(
        '🔐 KeyService: Keys saved (${DateTime.now().difference(step5Start).inMilliseconds}ms)',
      );

      // 5b) Generate PQ keys from signature entropy
      print('🔐 KeyService: Step 5b - Generating ML-KEM-512 keypair...');
      final pqKeys = await generateAndSavePqKeyPair();

      // 6) Return SealedKeys
      final totalDuration = DateTime.now().difference(startTime);
      print(
        '🔐 KeyService: ✅ Key derivation complete! Total: ${totalDuration.inMilliseconds}ms',
      );

      return SealedKeys(
        encryptionKeyPair: encryptionKeyPair,
        scanKeyPair: viewKeyPair,
        walletAddress: walletAddress,
        scanPubkey: Uint8List.fromList(viewPub.bytes),
        encryptionPubkey: Uint8List.fromList(encPub.bytes),
        encryptionPrivateKey: encryptionSeed,
        viewPrivateKey: viewSeed,
        pqPublicKey: pqKeys.publicKey,
        pqPrivateKey: pqKeys.privateKey,
      );
    } on KeyServiceException {
      rethrow;
    } catch (e, stackTrace) {
      throw KeyDerivationException('Failed to derive keys: $e', stackTrace);
    }
  }

  Future<void> _saveKeys({
    required String walletAddress,
    required Uint8List encryptionPrivateKey,
    required Uint8List viewPrivateKey,
  }) async {
    try {
      if (walletAddress.isEmpty) {
        throw KeyValidationException('walletAddress cannot be empty');
      }
      if (encryptionPrivateKey.isEmpty) {
        throw KeyValidationException('encryptionPrivateKey cannot be empty');
      }
      if (viewPrivateKey.isEmpty) {
        throw KeyValidationException('viewPrivateKey cannot be empty');
      }

      await _storage.write(
        key: 'enc_private',
        value: base64.encode(encryptionPrivateKey),
      );
      await _storage.write(
        key: 'view_private',
        value: base64.encode(viewPrivateKey),
      );
      await _prefs.setString('wallet_address', walletAddress);
    } catch (e, stackTrace) {
      if (e is KeyServiceException) rethrow;
      throw KeyStorageException('Failed to save keys: $e', stackTrace);
    }
  }

  Future<void> deleteKeys() async {
    try {
      await _storage.delete(key: 'enc_private');
      await _storage.delete(key: 'view_private');
      await _prefs.remove('wallet_address');
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to delete keys: $e', stackTrace);
    }
  }

  Future<bool> hasKeys() async {
    try {
      String? encPrivate = await _storage.read(key: 'enc_private');
      String? viewPrivate = await _storage.read(key: 'view_private');
      String? walletAddress = _prefs.getString('wallet_address');

      return encPrivate != null && viewPrivate != null && walletAddress != null;
    } on PlatformException catch (e) {
      // Android Keystore corruption – clear unusable keys
      print(
        '⚠️ KeyService: Secure storage corrupted (${e.message}), clearing keys',
      );
      await deleteKeys();
      return false;
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to check keys: $e', stackTrace);
    }
  }

  Future<SealedKeys?> loadKeys() async {
    try {
      String? encPrivateBase64;
      String? viewPrivateBase64;
      try {
        encPrivateBase64 = await _storage.read(key: 'enc_private');
        viewPrivateBase64 = await _storage.read(key: 'view_private');
      } on PlatformException catch (e) {
        // Android Keystore corruption – clear unusable keys so they
        // can be re-derived from the wallet seed.
        print(
          '⚠️ KeyService: Secure storage corrupted (${e.message}), clearing keys',
        );
        await deleteKeys();
        return null;
      }
      String? walletAddress = _prefs.getString('wallet_address');

      // After a chain migration (e.g. Solana→Algorand) the persisted
      // wallet_address may be stale. Update it to the current chain wallet.
      final activeAddress = chainWallet?.walletAddress;
      if (activeAddress != null && activeAddress != walletAddress) {
        print(
          '🔐 KeyService: Updating stale wallet address '
          '$walletAddress → $activeAddress',
        );
        await _prefs.setString('wallet_address', activeAddress);
        walletAddress = activeAddress;
      }

      if (encPrivateBase64 == null ||
          viewPrivateBase64 == null ||
          walletAddress == null) {
        return null;
      }

      Uint8List encryptionPrivateKey;
      Uint8List viewPrivateKey;
      try {
        encryptionPrivateKey = base64.decode(encPrivateBase64);
        viewPrivateKey = base64.decode(viewPrivateBase64);
      } catch (e) {
        throw KeyValidationException(
          'Invalid base64 encoding in stored keys: $e',
        );
      }

      // Recreate key pairs
      final SimpleKeyPair encryptionKeyPair = await _x25519.newKeyPairFromSeed(
        encryptionPrivateKey,
      );
      final SimpleKeyPair scanKeyPair = await _x25519.newKeyPairFromSeed(
        viewPrivateKey,
      );

      final SimplePublicKey encPub = await encryptionKeyPair.extractPublicKey();
      final SimplePublicKey viewPub = await scanKeyPair.extractPublicKey();

      // Load or generate PQ keys — they must always be present
      var pqKeys = await loadPqKeys();
      if (pqKeys == null) {
        print('🔐 KeyService: PQ keys missing, generating on load...');
        pqKeys = await generateAndSavePqKeyPair();
      }

      return SealedKeys(
        encryptionKeyPair: encryptionKeyPair,
        scanKeyPair: scanKeyPair,
        walletAddress: walletAddress,
        scanPubkey: Uint8List.fromList(viewPub.bytes),
        encryptionPubkey: Uint8List.fromList(encPub.bytes),
        encryptionPrivateKey: encryptionPrivateKey,
        viewPrivateKey: viewPrivateKey,
        pqPublicKey: pqKeys.publicKey,
        pqPrivateKey: pqKeys.privateKey,
      );
    } on KeyServiceException {
      rethrow;
    } catch (e, stackTrace) {
      throw KeyDerivationException('Failed to load keys: $e', stackTrace);
    }
  }

  Future<Uint8List> getViewKey() async {
    try {
      String? viewPrivateBase64 = await _storage.read(key: 'view_private');

      if (viewPrivateBase64 == null) {
        throw KeyValidationException('View key not found in storage');
      }

      try {
        return base64.decode(viewPrivateBase64);
      } catch (e) {
        throw KeyValidationException('Invalid base64 encoding in view key: $e');
      }
    } catch (e, stackTrace) {
      if (e is KeyServiceException) rethrow;
      throw KeyStorageException('Failed to get view key: $e', stackTrace);
    }
  }

  Future<Uint8List> getPubKey() async {
    try {
      final keys = await loadKeys();
      if (keys == null) {
        throw KeyValidationException('Keys not found in storage');
      }
      return keys.encryptionPubkey;
    } on KeyServiceException {
      rethrow;
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to get public key: $e', stackTrace);
    }
  }

  Future<String> getWalletAddress() async {
    try {
      String? walletAddress = _prefs.getString('wallet_address');

      if (walletAddress == null) {
        throw KeyValidationException('Wallet address not found in storage');
      }

      return walletAddress;
    } catch (e, stackTrace) {
      if (e is KeyServiceException) rethrow;
      throw KeyStorageException('Failed to get wallet address: $e', stackTrace);
    }
  }

  /// Get the wallet-derived X25519 keypair (Ed25519→X25519 conversion).
  ///
  /// This is the X25519 keypair that corresponds to the wallet's Ed25519
  /// keypair via the standard birational map. It is used as a fallback
  /// for receiving messages from senders who don't have the recipient's
  /// published HKDF-derived keys (e.g. unregistered wallets).
  Future<SimpleKeyPair?> getWalletDerivedX25519KeyPair() async {
    // Prefer chain wallet (Algorand) over local wallet service (Solana)
    if (chainWallet != null) {
      final seed = await chainWallet!.getSeedBytes();
      return ed25519SeedToX25519KeyPair(seed);
    }
    return null;
  }

  // ===========================================================================
  // Post-Quantum (ML-KEM-512) key management
  // ===========================================================================

  /// Ensure PQ keys exist — load from storage or generate from seed.
  /// Used during key derivation to guarantee PQ keys are always present.
  Future<({Uint8List publicKey, Uint8List privateKey})> _ensurePqKeys(
    Uint8List seedBytes,
  ) async {
    final existing = await loadPqKeys();
    if (existing != null) return existing;
    return _generatePqKeysFromSeed(seedBytes);
  }

  /// Generate ML-KEM-512 keypair deterministically from a wallet seed.
  Future<({Uint8List publicKey, Uint8List privateKey})> _generatePqKeysFromSeed(
    Uint8List seedBytes,
  ) async {
    final hkdf64 = Hkdf(hmac: Hmac(Sha256()), outputLength: 64);
    final hkdfKey = await hkdf64.deriveKey(
      secretKey: SecretKey(seedBytes),
      info: utf8.encode('sealed-pq-kem-v1'),
    );
    final pqSeed = Uint8List.fromList(await hkdfKey.extractBytes());

    final kyber = Kyber.kem512();
    final (pk, sk) = kyber.generateKeys(pqSeed);
    final publicKey = Uint8List.fromList(pk.serialize());
    final privateKey = Uint8List.fromList(sk.serialize());

    await savePqKeys(publicKey, privateKey);
    return (publicKey: publicKey, privateKey: privateKey);
  }

  /// Generate and save a fresh ML-KEM-512 keypair, seeded from the wallet.
  ///
  /// Returns the public key (800 bytes) and private key (1632 bytes).
  /// The seed is deterministically derived from the wallet so keys can be
  /// regenerated if lost.
  Future<({Uint8List publicKey, Uint8List privateKey})>
  generateAndSavePqKeyPair() async {
    final seedBytes = await chainWallet!.getSeedBytes();

    // Derive a 64-byte seed via HKDF for Kyber key generation.
    // Use a fresh Hkdf instance with outputLength: 64 (Kyber seed requirement).
    final hkdf64 = Hkdf(hmac: Hmac(Sha256()), outputLength: 64);
    final hkdfKey = await hkdf64.deriveKey(
      secretKey: SecretKey(seedBytes),
      info: utf8.encode('sealed-pq-kem-v1'),
    );
    final pqSeed = Uint8List.fromList(await hkdfKey.extractBytes());

    final kyber = Kyber.kem512();
    final (pk, sk) = kyber.generateKeys(pqSeed);
    final publicKey = pk.serialize();
    final privateKey = sk.serialize();

    await savePqKeys(publicKey, privateKey);
    return (publicKey: publicKey, privateKey: privateKey);
  }

  /// Save ML-KEM-512 keys to secure storage.
  Future<void> savePqKeys(Uint8List publicKey, Uint8List privateKey) async {
    try {
      await _storage.write(
        key: 'pq_kem_pubkey',
        value: base64.encode(publicKey),
      );
      await _storage.write(
        key: 'pq_kem_privkey',
        value: base64.encode(privateKey),
      );
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to save PQ keys: $e', stackTrace);
    }
  }

  /// Load ML-KEM-512 keys from secure storage. Returns null if not yet generated.
  Future<({Uint8List publicKey, Uint8List privateKey})?> loadPqKeys() async {
    try {
      final pubB64 = await _storage.read(key: 'pq_kem_pubkey');
      final privB64 = await _storage.read(key: 'pq_kem_privkey');
      if (pubB64 == null || privB64 == null) return null;
      return (
        publicKey: base64.decode(pubB64),
        privateKey: base64.decode(privB64),
      );
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to load PQ keys: $e', stackTrace);
    }
  }

  /// Delete ML-KEM-512 keys from secure storage.
  Future<void> deletePqKeys() async {
    try {
      await _storage.delete(key: 'pq_kem_pubkey');
      await _storage.delete(key: 'pq_kem_privkey');
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to delete PQ keys: $e', stackTrace);
    }
  }
}
