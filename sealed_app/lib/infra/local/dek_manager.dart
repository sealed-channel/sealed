/// DekManager — manages the Database Encryption Key (DEK) lifecycle.
///
/// The DEK is a 32-byte random key passed to SQLCipher as the database
/// password. It is stable for the lifetime of the install — only its
/// *wrapping* changes when the user sets/changes their PIN, opts into
/// biometrics, or sets a termination code.
///
/// Wraps stored in flutter_secure_storage:
///   - dek_wrapped         : DEK ⊕ KEK_pin   (post-PIN) OR DEK ⊕ KEK_device (pre-PIN)
///   - dek_wrapped_bio     : DEK ⊕ KEK_bio   (when biometrics opt-in)
///   - dek_wrapped_term    : DEK ⊕ KEK_term  (termination "trap" wrap)
///   - device_secret       : random secret used as KEK material before a PIN is set
///   - dek_kek_kind        : 'device' | 'pin'  — which KEK is currently wrapping `dek_wrapped`
///
/// AES-GCM is used for wrapping. Each wrap = nonce(12) || ciphertext || tag(16).
library;

import 'dart:convert';
import 'package:sealed_app/infra/crypto/secure_random.dart';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keychain accessibility for the device secret. The push-prefetch background
/// isolate derives the staging-store KEK from this secret to unwrap staged
/// envelopes while the screen is locked, so it must remain readable after the
/// first unlock since boot. See internal/docs/spec-push-prefetch-sync.md task
/// Tk. The wrapped DEK itself (`dek_wrapped`) keeps the `whenUnlocked` default —
/// the background isolate never needs it (single DB-writer rule). Android has
/// no equivalent lock-state gate, so this only affects iOS/macOS.
const kDekBackgroundReadableIOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
);

/// Accessibility-agnostic options for reads and deletes. flutter_secure_storage
/// 10 puts `kSecAttrAccessible` into the keychain *query*, so a read with the
/// default (`unlocked`) cannot see items written with `first_unlock` — the DEK
/// device secret looked "missing" after the v9→v10 upgrade. Passing
/// `accessibility: null` omits the attribute from the query and matches items
/// written under any accessibility (old `unlocked`-era installs included).
const kDekAnyAccessibilityIOptions = IOSOptions(accessibility: null);

class DekException implements Exception {
  final String message;
  final String? code;
  DekException(this.message, {this.code});
  @override
  String toString() =>
      'DekException: $message${code != null ? ' ($code)' : ''}';
}

/// Storage keys (kept here so WipeService and tests can reference them).
class DekStorageKeys {
  static const dekWrapped = 'dek_wrapped';
  static const dekWrappedBio = 'dek_wrapped_bio';
  static const dekWrappedTerm = 'dek_wrapped_term';
  static const deviceSecret = 'dek_device_secret';
  static const dekKekKind = 'dek_kek_kind';
  static const pinSalt = 'pin_kdf_salt';
  static const termSalt = 'term_kdf_salt';
  static const termMarker = 'term_marker';
  static const pinAttempts = 'pin_attempts';
  static const pinLockedUntil = 'pin_locked_until';

  /// Per-device Argon2id parameters chosen at PIN/term-code setup so the KDF
  /// hits a wall-clock target on this device. Absent = legacy fixed params
  /// (64 MiB / iter 3). MUST match the params used when the DEK was wrapped or
  /// the derived KEK won't reproduce. See _Argon2idKdf in pin_auth.dart.
  static const pinKdfParams = 'pin_kdf_params';
  static const termKdfParams = 'term_kdf_params';

  /// All DEK/PIN-related keys — used by WipeService.
  static const all = <String>[
    dekWrapped,
    dekWrappedBio,
    dekWrappedTerm,
    deviceSecret,
    dekKekKind,
    pinSalt,
    termSalt,
    termMarker,
    pinAttempts,
    pinLockedUntil,
    pinKdfParams,
    termKdfParams,
  ];
}

class DekManager {
  final FlutterSecureStorage _storage;
  final c.AesGcm _aead = c.AesGcm.with256bits();

  DekManager({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Clears every PIN / DEK / termination key from secure storage.
  ///
  /// Used by logout (so a follow-up account creation gets a fresh PIN
  /// prompt) and by [WipeService] (panic switch). Touches only the
  /// keys in [DekStorageKeys.all] — does **not** call `deleteAll()`,
  /// which would also nuke unrelated entries like push tokens.
  Future<void> clearPinAndDekState() async {
    for (final key in DekStorageKeys.all) {
      await _storage.delete(key: key, iOptions: kDekAnyAccessibilityIOptions);
    }
  }

  // ---------------------------------------------------------------------------
  // Bootstrap — called once on app launch before opening the DB.
  //
  // - If `dek_wrapped` exists: nothing to do. (Either device-wrapped or
  //   PIN-wrapped.)
  // - If it does not exist: this is a fresh install OR a pre-encryption
  //   install. Generate DEK + device_secret and persist a device-wrapped
  //   DEK so the DB can be opened automatically until the user sets a PIN.
  //
  // Returns true if bootstrap created a fresh DEK (caller should run the
  // plain→encrypted DB migration if a plain DB is on disk).
  // ---------------------------------------------------------------------------
  Future<bool> bootstrapIfNeeded() async {
    final existing = await _storage.read(
      key: DekStorageKeys.dekWrapped,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    if (existing != null) return false;

    final dek = _randomBytes(32);
    final deviceSecret = _randomBytes(32);
    // Delete accessibility-agnostic first: secure-storage v10 includes
    // kSecAttrAccessible in the write's lookup query, so an item left behind
    // under a different accessibility era would make SecItemAdd fail with
    // errSecDuplicateItem (-25299).
    await _storage.delete(
      key: DekStorageKeys.deviceSecret,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    await _storage.write(
      key: DekStorageKeys.deviceSecret,
      value: base64.encode(deviceSecret),
      iOptions: kDekBackgroundReadableIOptions,
    );

    final kek = await _deriveDeviceKek(deviceSecret);
    final wrapped = await _wrap(dek, kek);
    await _storage.write(
      key: DekStorageKeys.dekWrapped,
      value: base64.encode(wrapped),
    );
    await _storage.write(key: DekStorageKeys.dekKekKind, value: 'device');
    return true;
  }

  /// Returns the currently-active DEK by unwrapping with the device secret.
  /// Throws if PIN is configured (caller must use [unwrapWithPin] instead).
  Future<Uint8List> unwrapWithDeviceSecret() async {
    final kind = await _storage.read(
      key: DekStorageKeys.dekKekKind,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    if (kind != 'device') {
      throw DekException(
        'DEK is wrapped by PIN, not device secret',
        code: 'PIN_REQUIRED',
      );
    }
    final secretB64 = await _storage.read(
      key: DekStorageKeys.deviceSecret,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    final wrappedB64 = await _storage.read(
      key: DekStorageKeys.dekWrapped,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    if (secretB64 == null || wrappedB64 == null) {
      throw DekException(
        'Device-wrapped DEK missing',
        code: 'NOT_BOOTSTRAPPED',
      );
    }
    final kek = await _deriveDeviceKek(base64.decode(secretB64));
    return _unwrap(base64.decode(wrappedB64), kek);
  }

  /// Returns the DEK by unwrapping the PIN-wrapped blob with the supplied KEK.
  Future<Uint8List> unwrapWithKek(Uint8List kek, {String? wrappedKey}) async {
    final keyName = wrappedKey ?? DekStorageKeys.dekWrapped;
    final wrappedB64 = await _storage.read(
      key: keyName,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    if (wrappedB64 == null) {
      throw DekException(
        'Wrapped DEK missing for $keyName',
        code: 'WRAP_MISSING',
      );
    }
    return _unwrap(base64.decode(wrappedB64), kek);
  }

  /// Re-wrap the existing DEK under a new KEK and store it under [wrappedKey].
  Future<void> rewrap(
    Uint8List dek,
    Uint8List kek, {
    String wrappedKey = DekStorageKeys.dekWrapped,
    String? markKekKind,
  }) async {
    final wrapped = await _wrap(dek, kek);
    await _storage.write(key: wrappedKey, value: base64.encode(wrapped));
    if (markKekKind != null) {
      await _storage.write(key: DekStorageKeys.dekKekKind, value: markKekKind);
    }
  }

  /// Remove a wrap (e.g. when disabling biometrics or termination code).
  Future<void> deleteWrap(String wrappedKey) async {
    await _storage.delete(
      key: wrappedKey,
      iOptions: kDekAnyAccessibilityIOptions,
    );
  }

  /// `'device'` if the user has not set a PIN, `'pin'` if they have, null
  /// pre-bootstrap.
  Future<String?> currentKekKind() => _storage.read(
    key: DekStorageKeys.dekKekKind,
    iOptions: kDekAnyAccessibilityIOptions,
  );

  /// 32-byte key for the push-prefetch [WakeStageStore], derived via HKDF from
  /// the X25519 scan seed (`view_private`). CRITICAL: this must NOT use the DEK
  /// device secret — setting a PIN deletes that secret (pin_auth.dart), which
  /// would break the background path for exactly the locked+PIN users it
  /// targets. The scan seed survives PIN setup, is `first_unlock`
  /// (background-readable), and is already loaded by the matcher. HKDF domain
  /// separation keeps this distinct from message use; it only encrypts local
  /// stage/mirror metadata, never the DEK. Throws if the scan seed is missing.
  Future<Uint8List> deriveStagingKey() =>
      _deriveFromScanSeed('sealed-wake-stage-key-v1');

  /// 32-byte key for the push-prefetch block mirror (#17). Same PIN-surviving
  /// scan-seed root as [deriveStagingKey] (distinct HKDF label).
  Future<Uint8List> deriveBlockMirrorKey() =>
      _deriveFromScanSeed('sealed-block-mirror-v1');

  /// HKDF over the `view_private` scan seed — the background-readable,
  /// PIN-surviving root for prefetch/#17 keys.
  Future<Uint8List> _deriveFromScanSeed(String info) async {
    final seedB64 = await _storage.read(
      key: 'view_private',
      iOptions: kDekAnyAccessibilityIOptions,
    );
    if (seedB64 == null) {
      throw DekException(
        'scan seed (view_private) missing — cannot derive $info',
        code: 'NO_SCAN_SEED',
      );
    }
    final hkdf = c.Hkdf(hmac: c.Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: c.SecretKey(base64.decode(seedB64)),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<Uint8List> _wrap(Uint8List plain, Uint8List kek) async {
    final secretKey = c.SecretKey(kek);
    final nonce = _randomBytes(12);
    final box = await _aead.encrypt(plain, secretKey: secretKey, nonce: nonce);
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return Uint8List.fromList(out.toBytes());
  }

  Future<Uint8List> _unwrap(Uint8List wrapped, Uint8List kek) async {
    if (wrapped.length < 12 + 16) {
      throw DekException('Wrapped blob too short', code: 'DEK_UNWRAP_ERROR');
    }
    final nonce = wrapped.sublist(0, 12);
    final mac = c.Mac(wrapped.sublist(wrapped.length - 16));
    final ct = wrapped.sublist(12, wrapped.length - 16);
    final secretKey = c.SecretKey(kek);
    try {
      final clear = await _aead.decrypt(
        c.SecretBox(ct, nonce: nonce, mac: mac),
        secretKey: secretKey,
      );
      return Uint8List.fromList(clear);
    } catch (e) {
      throw DekException('Unwrap failed: $e', code: 'DEK_UNWRAP_ERROR');
    }
  }

  Future<Uint8List> _deriveDeviceKek(Uint8List deviceSecret) async {
    final hkdf = c.Hkdf(hmac: c.Hmac.sha256(), outputLength: 32);
    final out = await hkdf.deriveKey(
      secretKey: c.SecretKey(deviceSecret),
      info: utf8.encode('sealed-dek-device-kek-v1'),
      nonce: utf8.encode('sealed-static-salt-v1'),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  static Uint8List _randomBytes(int n) => secureRandomBytes(n);
}
