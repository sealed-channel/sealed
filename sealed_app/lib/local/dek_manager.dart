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
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  ];
}

class DekManager {
  final FlutterSecureStorage _storage;
  final c.AesGcm _aead = c.AesGcm.with256bits();
  static final _rng = Random.secure();

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
      await _storage.delete(key: key);
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
    final existing = await _storage.read(key: DekStorageKeys.dekWrapped);
    if (existing != null) return false;

    final dek = _randomBytes(32);
    final deviceSecret = _randomBytes(32);
    await _storage.write(
      key: DekStorageKeys.deviceSecret,
      value: base64.encode(deviceSecret),
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
    final kind = await _storage.read(key: DekStorageKeys.dekKekKind);
    if (kind != 'device') {
      throw DekException(
        'DEK is wrapped by PIN, not device secret',
        code: 'PIN_REQUIRED',
      );
    }
    final secretB64 = await _storage.read(key: DekStorageKeys.deviceSecret);
    final wrappedB64 = await _storage.read(key: DekStorageKeys.dekWrapped);
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
    final wrappedB64 = await _storage.read(key: keyName);
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
    await _storage.delete(key: wrappedKey);
  }

  /// `'device'` if the user has not set a PIN, `'pin'` if they have, null
  /// pre-bootstrap.
  Future<String?> currentKekKind() =>
      _storage.read(key: DekStorageKeys.dekKekKind);

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

  static Uint8List _randomBytes(int n) {
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = _rng.nextInt(256);
    }
    return b;
  }
}
