/// Cryptographic key management and derivation service.
/// Handles identity keys, view keys, ephemeral keys, and secure storage operations
/// for both Ed25519 signing keys and X25519 encryption keys.
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
// Pure-Dart HKDF/HMAC — see service_locator.dart. Native cryptography_flutter
// throws "Empty key" on our salt-less HKDF; pure-Dart matches RFC 5869 and
// yields identical bytes. Keyless Sha256() hashing stays on the native backend.
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Import Kyber directly to avoid the broken Dilithium barrel export
// ignore: implementation_imports
import 'package:post_quantum/src/kyber.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../chain/wallet_interface.dart';
import '../../models/sealed_keys.dart';
import 'key_format_converter.dart';

/// Keychain accessibility for the chain-decryption keys that the push-prefetch
/// background isolate must be able to read while the screen is locked (after
/// the first unlock since boot). See internal/docs/spec-push-prefetch-sync.md
/// task Tk. Only the keys written by [KeyService] carry `first_unlock`; PIN,
/// termination, and wallet keys keep the `whenUnlocked` default. Android has no
/// equivalent lock-state gate, so this only affects iOS/macOS.
const _kBackgroundReadableIOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
);

/// Accessibility-agnostic options for reads and deletes. flutter_secure_storage
/// 10 puts `kSecAttrAccessible` into the keychain *query*, so a read with the
/// default (`unlocked`) cannot see items written with `first_unlock`. Passing
/// `accessibility: null` omits the attribute from the query and matches items
/// written under any accessibility (old `unlocked`-era installs included).
const _kAnyAccessibilityIOptions = IOSOptions(accessibility: null);

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
  Future<SealedKeys> deriveKeysFromLocalWallet({bool isRetry = false}) async {
    final startTime = DateTime.now();
    Log.d('🔐 KeyService: Starting key derivation from local wallet...');

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

      Log.d('🔐 KeyService: Step 1 - Hashing seed with SHA-256...');
      var step1Start = DateTime.now();
      final algorithm = Sha256();
      // Add domain separator to derive different keys
      final preimage = Uint8List.fromList([
        ...utf8.encode('sealed-messaging-keys-v1:'),
        ...seedBytes,
      ]);
      final Hash hash = await algorithm.hash(preimage);
      final Uint8List entropy = Uint8List.fromList(hash.bytes);
      Log.d(
        '🔐 KeyService: Step 1 complete (${DateTime.now().difference(step1Start).inMilliseconds}ms)',
      );

      // 2) Derive two 32-byte seeds via HKDF
      Log.d('🔐 KeyService: Step 2 - Deriving encryption seed with HKDF...');
      var step2Start = DateTime.now();
      final SecretKey encSeedKey = await hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-encryption-v1'),
      );
      final Uint8List encryptionSeed = Uint8List.fromList(
        await encSeedKey.extractBytes(),
      );
      Log.d(
        '🔐 KeyService: Encryption seed derived (${DateTime.now().difference(step2Start).inMilliseconds}ms)',
      );

      Log.d('🔐 KeyService: Step 2b - Deriving view seed with HKDF...');
      var step2bStart = DateTime.now();
      final SecretKey viewSeedKey = await hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-view-v1'),
      );
      final Uint8List viewSeed = Uint8List.fromList(
        await viewSeedKey.extractBytes(),
      );
      Log.d(
        '🔐 KeyService: View seed derived (${DateTime.now().difference(step2bStart).inMilliseconds}ms)',
      );

      // 3) Create X25519 keypairs from seeds
      Log.d('🔐 KeyService: Step 3 - Creating X25519 keypairs...');
      var step3Start = DateTime.now();
      final SimpleKeyPair encryptionKeyPair = await x25519.newKeyPairFromSeed(
        encryptionSeed,
      );
      final SimpleKeyPair viewKeyPair = await x25519.newKeyPairFromSeed(
        viewSeed,
      );

      final SimplePublicKey encPub = await encryptionKeyPair.extractPublicKey();
      final SimplePublicKey viewPub = await viewKeyPair.extractPublicKey();
      Log.d(
        '🔐 KeyService: Keypairs created (${DateTime.now().difference(step3Start).inMilliseconds}ms)',
      );

      // 4) Generate ML-KEM-512 (post-quantum) keypair
      Log.d('🔐 KeyService: Step 4 - Generating ML-KEM-512 keypair...');
      var step4Start = DateTime.now();
      final pqKeys = await _ensurePqKeys();
      Log.d(
        '🔐 KeyService: PQ keypair ready (${DateTime.now().difference(step4Start).inMilliseconds}ms)',
      );

      // 5) Save Keys
      Log.d('🔐 KeyService: Step 5 - Saving keys to secure storage...');
      var step5Start = DateTime.now();
      await _saveKeys(
        walletAddress: walletAddress,
        encryptionPrivateKey: encryptionSeed,
        viewPrivateKey: viewSeed,
      );
      await savePqKeys(pqKeys.publicKey, pqKeys.privateKey);
      Log.d(
        '🔐 KeyService: Keys saved (${DateTime.now().difference(step5Start).inMilliseconds}ms)',
      );

      // 6) Return SealedKeys
      final totalDuration = DateTime.now().difference(startTime);
      Log.d(
        '🔐 KeyService: ✅ Key derivation complete! Total: ${totalDuration.inMilliseconds}ms',
      );
      // [create-timing] Profile-visible per-step split of the BACKGROUND key
      // derivation (runs while the user reads the backup phrase). Pinpoints
      // which step janks the main isolate. debugPrint survives profile builds.
      // Remove once the jank is fixed.
      debugPrint(
        '[create-timing] keyDerive total=${totalDuration.inMilliseconds}ms | '
        'hkdf(enc+view)=${step2bStart.difference(step2Start).inMilliseconds}ms | '
        'x25519(step3)=${step4Start.difference(step3Start).inMilliseconds}ms | '
        'mlkem(step4)=${step5Start.difference(step4Start).inMilliseconds}ms | '
        'save(step5)=${DateTime.now().difference(step5Start).inMilliseconds}ms',
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
    } on PlatformException catch (e, stackTrace) {
      // Android Keystore corruption: the device-bound key that wraps the
      // secure-storage AES app-key is missing or unusable (e.g. the encrypted
      // SharedPreferences blob was restored from a cloud/device backup but the
      // Keystore key was not). The native layer surfaces this as
      // "IllegalArgumentException: Empty key" from SecretKeySpec. The stored
      // ciphertext is unrecoverable, so wipe it and regenerate once — the seed
      // is still in memory (chainWallet), so derivation can proceed fresh.
      if (!isRetry && _isStorageCorruption(e)) {
        Log.d(
          '⚠️ KeyService: Secure storage corruption (${e.message}); '
          'wiping unusable key material and retrying derivation once',
        );
        try {
          await storage.deleteAll(iOptions: _kAnyAccessibilityIOptions);
        } catch (wipeError) {
          Log.d('⚠️ KeyService: deleteAll during recovery failed: $wipeError');
        }
        return deriveKeysFromLocalWallet(isRetry: true);
      }
      throw KeyDerivationException(
        'Failed to derive keys from local wallet: $e',
        stackTrace,
      );
    } catch (e, stackTrace) {
      throw KeyDerivationException(
        'Failed to derive keys from local wallet: $e',
        stackTrace,
      );
    }
  }

  /// True when a [PlatformException] from secure storage indicates the
  /// Keystore-wrapped app key is unusable (corruption), as opposed to a
  /// transient failure. Matches the native "Empty key" / bad-decrypt signatures.
  static bool _isStorageCorruption(PlatformException e) {
    final haystack = '${e.code} ${e.message} ${e.details}'.toLowerCase();
    return haystack.contains('empty key') ||
        haystack.contains('bad_decrypt') ||
        haystack.contains('baddecrypt') ||
        haystack.contains('aeadbadtag') ||
        haystack.contains('illegalargument');
  }

  /// Legacy method: Derive keys from wallet signature (for backward compatibility)
  @Deprecated('Use deriveKeysFromLocalWallet() instead')
  Future<SealedKeys> deriveKeys(String walletAddress, dynamic signature) async {
    final startTime = DateTime.now();
    Log.d('🔐 KeyService: Starting key derivation process...');

    try {
      if (walletAddress.isEmpty) {
        throw KeyValidationException('walletAddress cannot be empty');
      }

      if (signature == null) {
        throw KeyValidationException('signature cannot be null');
      }

      // 1) Obtain signature bytes
      Log.d('🔐 KeyService: Step 1 - Parsing signature...');
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
      Log.d(
        '🔐 KeyService: Step 1 complete (${DateTime.now().difference(step1Start).inMilliseconds}ms)',
      );

      // 2) Hash signature -> entropy (SHA-256)
      Log.d('🔐 KeyService: Step 2 - Hashing signature with SHA-256...');
      var step2Start = DateTime.now();
      final algorithm = Sha256();
      final Hash hash = await algorithm.hash(signatureBytes);
      final Uint8List entropy = Uint8List.fromList(hash.bytes);
      Log.d(
        '🔐 KeyService: Step 2 complete (${DateTime.now().difference(step2Start).inMilliseconds}ms)',
      );

      // 3) Derive two 32-byte seeds via HKDF
      Log.d('🔐 KeyService: Step 3 - Deriving encryption seed with HKDF...');
      var step3Start = DateTime.now();
      final SecretKey encSeedKey = await hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-encryption-v1'),
      );
      final Uint8List encryptionSeed = Uint8List.fromList(
        await encSeedKey.extractBytes(),
      );
      Log.d(
        '🔐 KeyService: Encryption seed derived (${DateTime.now().difference(step3Start).inMilliseconds}ms)',
      );

      Log.d('🔐 KeyService: Step 3b - Deriving view seed with HKDF...');
      var step3bStart = DateTime.now();
      final SecretKey viewSeedKey = await hkdf.deriveKey(
        secretKey: SecretKey(entropy),
        info: utf8.encode('sealed-view-v1'),
      );
      final Uint8List viewSeed = Uint8List.fromList(
        await viewSeedKey.extractBytes(),
      );
      Log.d(
        '🔐 KeyService: View seed derived (${DateTime.now().difference(step3bStart).inMilliseconds}ms)',
      );

      // 4) Create X25519 keypairs from seeds
      Log.d('🔐 KeyService: Step 4 - Creating X25519 keypairs...');
      var step4Start = DateTime.now();
      final SimpleKeyPair encryptionKeyPair = await x25519.newKeyPairFromSeed(
        encryptionSeed,
      );
      final SimpleKeyPair viewKeyPair = await x25519.newKeyPairFromSeed(
        viewSeed,
      );

      final SimplePublicKey encPub = await encryptionKeyPair.extractPublicKey();
      final SimplePublicKey viewPub = await viewKeyPair.extractPublicKey();
      Log.d(
        '🔐 KeyService: Keypairs created (${DateTime.now().difference(step4Start).inMilliseconds}ms)',
      );

      // Save Keys
      Log.d('🔐 KeyService: Step 5 - Saving keys to secure storage...');
      var step5Start = DateTime.now();
      await _saveKeys(
        walletAddress: walletAddress,
        encryptionPrivateKey: encryptionSeed,
        viewPrivateKey: viewSeed,
      );
      Log.d(
        '🔐 KeyService: Keys saved (${DateTime.now().difference(step5Start).inMilliseconds}ms)',
      );

      // 5b) Generate PQ keys from signature entropy
      Log.d('🔐 KeyService: Step 5b - Generating ML-KEM-512 keypair...');
      final pqKeys = await generateAndSavePqKeyPair();

      // 6) Return SealedKeys
      final totalDuration = DateTime.now().difference(startTime);
      Log.d(
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

  /// Write under `first_unlock`, tolerating an existing item written in a
  /// different accessibility era. flutter_secure_storage 10 includes
  /// `kSecAttrAccessible` in the lookup query, so a write cannot see (and
  /// update) an item stored under another accessibility — `SecItemAdd` then
  /// fails with errSecDuplicateItem (-25299) because keychain uniqueness is
  /// service+account only. Delete accessibility-agnostic first, then add;
  /// this also migrates old-era items to `first_unlock`.
  Future<void> _writeBackgroundReadable(String key, String value) async {
    await storage.delete(key: key, iOptions: _kAnyAccessibilityIOptions);
    await storage.write(
      key: key,
      value: value,
      iOptions: _kBackgroundReadableIOptions,
    );
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

      await _writeBackgroundReadable(
        'enc_private',
        base64.encode(encryptionPrivateKey),
      );
      await _writeBackgroundReadable(
        'view_private',
        base64.encode(viewPrivateKey),
      );
      await prefs.setString('wallet_address', walletAddress);
    } catch (e, stackTrace) {
      if (e is KeyServiceException) rethrow;
      throw KeyStorageException('Failed to save keys: $e', stackTrace);
    }
  }

  Future<void> deleteKeys() async {
    try {
      await storage.delete(
        key: 'enc_private',
        iOptions: _kAnyAccessibilityIOptions,
      );
      await storage.delete(
        key: 'view_private',
        iOptions: _kAnyAccessibilityIOptions,
      );
      // Wipe PQ material too. Without this, a follow-up wallet (logout →
      // create-new) would re-derive its PQ keypair from the prior wallet's
      // cached `pq_master_seed`, anchoring on-chain pqPubkeyHash to the
      // previous identity's pubkey. Any peer encapsulating against the new
      // wallet's published hash would land on the leaked old keypair —
      // breaking forward secrecy across wallet rotations.
      await storage.delete(
        key: 'pq_kem_pubkey',
        iOptions: _kAnyAccessibilityIOptions,
      );
      await storage.delete(
        key: 'pq_kem_privkey',
        iOptions: _kAnyAccessibilityIOptions,
      );
      await storage.delete(
        key: _pqMasterSeedStorageKey,
        iOptions: _kAnyAccessibilityIOptions,
      );
      await prefs.remove('wallet_address');
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to delete keys: $e', stackTrace);
    }
  }

  Future<bool> hasKeys() async {
    try {
      String? encPrivate = await storage.read(
        key: 'enc_private',
        iOptions: _kAnyAccessibilityIOptions,
      );
      String? viewPrivate = await storage.read(
        key: 'view_private',
        iOptions: _kAnyAccessibilityIOptions,
      );
      String? walletAddress = prefs.getString('wallet_address');

      return encPrivate != null && viewPrivate != null && walletAddress != null;
    } on PlatformException catch (e) {
      // Android Keystore corruption – clear unusable keys
      Log.d(
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
        encPrivateBase64 = await storage.read(
          key: 'enc_private',
          iOptions: _kAnyAccessibilityIOptions,
        );
        viewPrivateBase64 = await storage.read(
          key: 'view_private',
          iOptions: _kAnyAccessibilityIOptions,
        );
      } on PlatformException catch (e) {
        // Android Keystore corruption – clear unusable keys so they
        // can be re-derived from the wallet seed.
        Log.d(
          '⚠️ KeyService: Secure storage corrupted (${e.message}), clearing keys',
        );
        await deleteKeys();
        return null;
      }
      String? walletAddress = prefs.getString('wallet_address');

      // After a chain migration (e.g. Solana→Algorand) the persisted
      // wallet_address may be stale. Update it to the current chain wallet.
      final activeAddress = chainWallet?.walletAddress;
      if (activeAddress != null && activeAddress != walletAddress) {
        Log.d(
          '🔐 KeyService: Updating stale wallet address '
          '$walletAddress → $activeAddress',
        );
        await prefs.setString('wallet_address', activeAddress);
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
      final SimpleKeyPair encryptionKeyPair = await x25519.newKeyPairFromSeed(
        encryptionPrivateKey,
      );
      final SimpleKeyPair scanKeyPair = await x25519.newKeyPairFromSeed(
        viewPrivateKey,
      );

      final SimplePublicKey encPub = await encryptionKeyPair.extractPublicKey();
      final SimplePublicKey viewPub = await scanKeyPair.extractPublicKey();

      // Load or generate PQ keys — they must always be present.
      // _ensurePqKeys() internally invokes _ensurePqMasterSeed() which now
      // detects drift, wipes stale PQ keys, and re-derives from mnemonic.
      // If wipe occurred, loadPqKeys() returns null and we regenerate.
      var pqKeys = await loadPqKeys();
      if (pqKeys == null) {
        Log.d(
          '🔐 KeyService: PQ keys missing or drifted, regenerating from master seed...',
        );
        pqKeys = await _generatePqKeysFromMasterSeed();
      } else {
        // Verify pubkey matches canonical derivation. If not, force regen.
        // This catches cases where pq_kem_pubkey persisted but pq_master_seed
        // was drift-corrected without the keys getting wiped.
        try {
          final canonical = await _deriveCanonicalPqMasterSeed();
          final hkdf64 = DartHkdf(hmac: DartHmac.sha256(), outputLength: 64);
          final hkdfKey = await hkdf64.deriveKey(
            secretKey: SecretKey(canonical),
            info: utf8.encode('sealed-pq-kem-v1'),
          );
          final pqSeed = Uint8List.fromList(await hkdfKey.extractBytes());
          final kyber = Kyber.kem512();
          final (expectedPk, _) = kyber.generateKeys(pqSeed);
          final expectedPub = Uint8List.fromList(expectedPk.serialize());
          if (!_bytesEqual(expectedPub, pqKeys.publicKey)) {
            Log.d(
              '🔐 KeyService: PQ pubkey drift detected '
              'storedFp=${base64.encode(pqKeys.publicKey.sublist(0, 8))} '
              'expectedFp=${base64.encode(expectedPub.sublist(0, 8))} — regenerating',
            );
            await deletePqKeys();
            pqKeys = await _generatePqKeysFromMasterSeed();
          }
        } catch (e) {
          Log.d('🔐 KeyService: PQ pubkey verification skipped: $e');
        }
      }

      return SealedKeys(
        encryptionKeyPair: encryptionKeyPair,
        scanKeyPair: scanKeyPair,
        walletAddress: walletAddress,
        scanPubkey: Uint8List.fromList(viewPub.bytes),
        encryptionPubkey: Uint8List.fromList(encPub.bytes),
        encryptionPrivateKey: encryptionPrivateKey,
        viewPrivateKey: viewPrivateKey,
        pqPublicKey: pqKeys!.publicKey,
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
      String? viewPrivateBase64 = await storage.read(
        key: 'view_private',
        iOptions: _kAnyAccessibilityIOptions,
      );

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
      String? walletAddress = prefs.getString('wallet_address');

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

  static const _pqMasterSeedStorageKey = 'pq_master_seed';
  static const _pqMasterSeedHkdfInfo = 'sealed-pq-master-seed-v1';
  static const _pqMasterSeedLength = 64;

  /// Normalize a BIP39 mnemonic: trim, lowercase, collapse internal whitespace.
  String _normalizeMnemonic(String raw) =>
      raw.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  /// Return the 64-byte PQ master seed, bootstrapping from mnemonic if needed.
  ///
  /// Read-first: returns cached `pq_master_seed` from secure storage if present.
  /// On cache miss: reads mnemonic from [chainWallet], normalizes it,
  /// derives seed via HKDF-SHA256 (outputLength=64, info=`sealed-pq-master-seed-v1`),
  /// persists, and returns.
  ///
  /// Throws [KeyValidationException] if neither cache nor mnemonic is available.
  Future<Uint8List> _ensurePqMasterSeed() async {
    // Read-first: return cached seed if present, but verify it matches the
    // canonical mnemonic-derived value. Drift indicates a legacy/random/early
    // origin (Path A) or a divergent prior derivation (Path B); in either
    // case overwrite so on-chain pqPub stays anchored to the mnemonic.
    final cached = await storage.read(
      key: _pqMasterSeedStorageKey,
      iOptions: _kAnyAccessibilityIOptions,
    );
    final canonical = await _deriveCanonicalPqMasterSeed();

    if (cached != null) {
      final cachedBytes = base64.decode(cached);
      final matches = _bytesEqual(cachedBytes, canonical);
      Log.d(
        '🔐 PQ master seed source=CACHE '
        'cachedFp=${secretFp(cachedBytes)} '
        'canonicalFp=${secretFp(canonical)} '
        'aligned=$matches',
      );
      if (matches) return cachedBytes;
      Log.d(
        '🔐 PQ master seed drift detected — overwriting cache + wiping PQ keys '
        '(forces re-derive + republish)',
      );
      await _writeBackgroundReadable(
        _pqMasterSeedStorageKey,
        base64.encode(canonical),
      );
      await deletePqKeys();
      return canonical;
    }

    Log.d(
      '🔐 PQ master seed source=MNEMONIC '
      'canonicalFp=${secretFp(canonical)}',
    );
    await _writeBackgroundReadable(
      _pqMasterSeedStorageKey,
      base64.encode(canonical),
    );
    return canonical;
  }

  /// Deterministic 32B ML-KEM encapsulation nonce for a handshake to a peer
  /// holding [peerPqPubkey]. Derived from the PQ master seed (mnemonic) + the
  /// peer's PQ pubkey hash, so the initiator can re-encapsulate to the SAME
  /// (ciphertext, sharedSecret) after a logout/cache wipe — recovering its own
  /// chats. Keyed on the peer PQ pubkey (not wallet) so a peer PQ-key rotation
  /// naturally yields fresh coins (no nonce reuse across distinct ek).
  Future<Uint8List> deriveKemEncapsNonce(Uint8List peerPqPubkey) async {
    final masterSeed = await _deriveCanonicalPqMasterSeed();
    final peerHash = (await Sha256().hash(peerPqPubkey)).bytes;
    final hkdf = DartHkdf(hmac: DartHmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(masterSeed),
      info: Uint8List.fromList([
        ...utf8.encode('sealed-kem-encaps-v1:'),
        ...peerHash,
      ]),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Derive PQ master seed from mnemonic — canonical, single source of truth.
  /// Throws if mnemonic unavailable.
  Future<Uint8List> _deriveCanonicalPqMasterSeed() async {
    final mnemonic = await chainWallet?.getMnemonic();
    if (mnemonic == null) {
      throw KeyValidationException(
        'Cannot derive PQ master seed: mnemonic unavailable',
      );
    }
    final normalized = _normalizeMnemonic(mnemonic);
    final mnemonicBytes = utf8.encode(normalized);

    final hkdf64 = DartHkdf(
      hmac: DartHmac.sha256(),
      outputLength: _pqMasterSeedLength,
    );
    final derived = await hkdf64.deriveKey(
      secretKey: SecretKey(mnemonicBytes),
      info: utf8.encode(_pqMasterSeedHkdfInfo),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Constant-time byte equality.
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Ensure PQ keys exist — load from storage or generate from master seed.
  Future<({Uint8List publicKey, Uint8List privateKey})> _ensurePqKeys() async {
    final existing = await loadPqKeys();
    if (existing != null) return existing;
    return _generatePqKeysFromMasterSeed();
  }

  /// Generate ML-KEM-512 keypair deterministically from the PQ master seed.
  Future<({Uint8List publicKey, Uint8List privateKey})>
  _generatePqKeysFromMasterSeed() async {
    final masterSeed = await _ensurePqMasterSeed();

    final hkdf64 = DartHkdf(hmac: DartHmac.sha256(), outputLength: 64);
    final hkdfKey = await hkdf64.deriveKey(
      secretKey: SecretKey(masterSeed),
      info: utf8.encode('sealed-pq-kem-v1'),
    );
    final pqSeed = Uint8List.fromList(await hkdfKey.extractBytes());

    // ML-KEM-512 keygen is pure-Dart and takes hundreds of ms. Run it in a
    // background isolate so it never janks the UI (e.g. the seed-backup screen
    // during onboarding, where this runs while the user reads their phrase).
    final keys = await Isolate.run(() {
      final kyber = Kyber.kem512();
      final (pk, sk) = kyber.generateKeys(pqSeed);
      return (
        publicKey: Uint8List.fromList(pk.serialize()),
        privateKey: Uint8List.fromList(sk.serialize()),
      );
    });

    await savePqKeys(keys.publicKey, keys.privateKey);
    return (publicKey: keys.publicKey, privateKey: keys.privateKey);
  }

  /// Generate and save a fresh ML-KEM-512 keypair from the PQ master seed.
  ///
  /// Returns the public key (800 bytes) and private key (1632 bytes).
  /// Deterministically derived from mnemonic — regeneratable if keys are lost.
  Future<({Uint8List publicKey, Uint8List privateKey})>
  generateAndSavePqKeyPair() async {
    return _generatePqKeysFromMasterSeed();
  }

  /// Regenerate ML-KEM-512 keypair from master seed and overwrite stored keys.
  ///
  /// Always re-derives and overwrites — use in the redeem flow to ensure
  /// on-chain pqPub stays aligned with the deterministic local keypair.
  Future<({Uint8List publicKey, Uint8List privateKey})>
  regeneratePqKeysFromMasterSeed() async {
    return _generatePqKeysFromMasterSeed();
  }

  /// Save ML-KEM-512 keys to secure storage.
  Future<void> savePqKeys(Uint8List publicKey, Uint8List privateKey) async {
    try {
      await _writeBackgroundReadable('pq_kem_pubkey', base64.encode(publicKey));
      await _writeBackgroundReadable(
        'pq_kem_privkey',
        base64.encode(privateKey),
      );
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to save PQ keys: $e', stackTrace);
    }
  }

  /// Load ML-KEM-512 keys from secure storage. Returns null if not yet generated.
  Future<({Uint8List publicKey, Uint8List privateKey})?> loadPqKeys() async {
    try {
      final pubB64 = await storage.read(
        key: 'pq_kem_pubkey',
        iOptions: _kAnyAccessibilityIOptions,
      );
      final privB64 = await storage.read(
        key: 'pq_kem_privkey',
        iOptions: _kAnyAccessibilityIOptions,
      );
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
      await storage.delete(
        key: 'pq_kem_pubkey',
        iOptions: _kAnyAccessibilityIOptions,
      );
      await storage.delete(
        key: 'pq_kem_privkey',
        iOptions: _kAnyAccessibilityIOptions,
      );
    } catch (e, stackTrace) {
      throw KeyStorageException('Failed to delete PQ keys: $e', stackTrace);
    }
  }
}
