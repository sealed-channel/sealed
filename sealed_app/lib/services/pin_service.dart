/// PinService — manages the user's 6-digit PIN.
///
/// The PIN is never stored. Instead, Argon2id(PIN, salt) derives a KEK that
/// wraps the DEK (see DekManager). Verifying a PIN = attempting to unwrap
/// the DEK with the derived KEK. AES-GCM authentication tag failure means
/// wrong PIN.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:argon2/argon2.dart';
import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../local/dek_manager.dart';

class PinException implements Exception {
  final String message;
  final String? code;
  PinException(this.message, {this.code});
  @override
  String toString() =>
      'PinException: $message${code != null ? ' ($code)' : ''}';
}

class PinIncorrectException extends PinException {
  PinIncorrectException() : super('Incorrect PIN', code: 'PIN_INCORRECT');
}

class PinNotSetException extends PinException {
  PinNotSetException() : super('PIN not set', code: 'PIN_NOT_SET');
}

class PinKdfException extends PinException {
  PinKdfException(super.message) : super(code: 'KDF_ERROR');
}

class PinService {
  final FlutterSecureStorage _storage;
  final DekManager _dek;
  static final _rng = Random.secure();

  // Argon2id parameters. Tuned to ~500ms on a mid-range phone.
  // memory: 64 MiB, iterations: 3, parallelism: 1.
  static const _memoryKb = 64 * 1024;
  static const _iterations = 3;
  static const _parallelism = 1;
  static const _kekLen = 32;

  PinService({FlutterSecureStorage? storage, DekManager? dekManager})
    : _storage = storage ?? const FlutterSecureStorage(),
      _dek = dekManager ?? DekManager(storage: storage);

  /// True if the user has configured a PIN.
  Future<bool> isPinSet() async {
    final kind = await _storage.read(key: DekStorageKeys.dekKekKind);
    return kind == 'pin';
  }

  /// Set the PIN for the first time. Requires the current device-wrapped DEK
  /// to still be available.
  Future<void> setPin(String pin) async {
    _validatePin(pin);
    if (await isPinSet()) {
      throw PinException(
        'PIN already set; use changePin',
        code: 'PIN_ALREADY_SET',
      );
    }
    final dek = await _dek.unwrapWithDeviceSecret();
    final salt = _randomBytes(16);
    final kek = await _deriveKek(pin, salt);
    await _storage.write(
      key: DekStorageKeys.pinSalt,
      value: base64.encode(salt),
    );
    await _dek.rewrap(dek, kek, markKekKind: 'pin');
    await _storage.delete(key: DekStorageKeys.deviceSecret);
  }

  /// Verify a PIN by unwrapping the DEK; throws PinIncorrectException on bad PIN.
  Future<Uint8List> verifyAndUnwrap(String pin) async {
    if (!await isPinSet()) throw PinNotSetException();
    final saltB64 = await _storage.read(key: DekStorageKeys.pinSalt);
    if (saltB64 == null) throw PinKdfException('Missing PIN salt');
    final kek = await _deriveKek(pin, base64.decode(saltB64));
    try {
      return await _dek.unwrapWithKek(kek);
    } on DekException catch (e) {
      if (e.code == 'DEK_UNWRAP_ERROR') throw PinIncorrectException();
      rethrow;
    }
  }

  /// Change PIN. Requires the old PIN to derive the current DEK.
  Future<void> changePin(String oldPin, String newPin) async {
    _validatePin(newPin);
    final dek = await verifyAndUnwrap(oldPin);
    final salt = _randomBytes(16);
    final kek = await _deriveKek(newPin, salt);
    await _storage.write(
      key: DekStorageKeys.pinSalt,
      value: base64.encode(salt),
    );
    await _dek.rewrap(dek, kek, markKekKind: 'pin');
  }

  /// Disable PIN — re-wraps DEK under a fresh device-secret.
  Future<void> disablePin(String currentPin) async {
    final dek = await verifyAndUnwrap(currentPin);
    final deviceSecret = _randomBytes(32);
    await _storage.write(
      key: DekStorageKeys.deviceSecret,
      value: base64.encode(deviceSecret),
    );
    final kek = await _hkdfDeviceKek(deviceSecret);
    await _dek.rewrap(dek, kek, markKekKind: 'device');
    await _storage.delete(key: DekStorageKeys.pinSalt);
  }

  // ---------------------------------------------------------------------------

  void _validatePin(String pin) {
    if (pin.length != 6 || !RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw PinException(
        'PIN must be exactly 6 digits',
        code: 'VALIDATION_ERROR',
      );
    }
  }

  Future<Uint8List> _deriveKek(String pin, Uint8List salt) async {
    try {
      // Argon2id is a tight CPU loop (~500ms on a mid-range phone). Running
      // it on the main isolate freezes the UI between the 6th digit and the
      // unlock transition. Off-load to a worker isolate so the keypad stays
      // responsive (e.g. for the dot-fill animation) while the KDF runs.
      return await Isolate.run(
        () => _argon2idDeriveSync(
          pin: pin,
          salt: salt,
          iterations: _iterations,
          memoryKb: _memoryKb,
          parallelism: _parallelism,
          outLen: _kekLen,
        ),
      );
    } catch (e) {
      throw PinKdfException('Argon2id failed: $e');
    }
  }

  /// HKDF-SHA256 — kept identical to DekManager._deriveDeviceKek.
  Future<Uint8List> _hkdfDeviceKek(Uint8List deviceSecret) async {
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

/// Top-level Argon2id derivation, runnable inside `Isolate.run`.
///
/// Kept as a free function (not a method) so the closure passed to
/// `Isolate.run` doesn't capture the surrounding `PinService` instance —
/// only plain primitives + a `Uint8List` cross the isolate boundary.
Uint8List _argon2idDeriveSync({
  required String pin,
  required Uint8List salt,
  required int iterations,
  required int memoryKb,
  required int parallelism,
  required int outLen,
}) {
  final params = Argon2Parameters(
    Argon2Parameters.ARGON2_id,
    salt,
    version: Argon2Parameters.ARGON2_VERSION_13,
    iterations: iterations,
    memoryPowerOf2: _log2Pure(memoryKb),
    lanes: parallelism,
  );
  final gen = Argon2BytesGenerator()..init(params);
  final out = Uint8List(outLen);
  final pinBytes = Uint8List.fromList(utf8.encode(pin));
  gen.generateBytes(pinBytes, out, 0, out.length);
  return out;
}

int _log2Pure(int n) {
  var x = n;
  var r = 0;
  while (x > 1) {
    x >>= 1;
    r++;
  }
  return r;
}
