/// TerminationService — manages the duress / panic "termination code".
///
/// The termination code is a separate 6-digit code that, when entered on
/// the unlock screen, triggers a full wipe instead of unlocking. To avoid
/// signaling success or failure to an attacker (duress safety), the unlock
/// screen always shows "Incorrect PIN" after wiping.
///
/// Implementation: Argon2id(code, salt) → KEK_term. We store an HMAC-SHA256
/// marker (`HMAC(KEK_term, "TERMINATE")`) so verification can be done
/// **without unwrapping the DEK** — we don't want the DEK in memory at
/// the moment we're about to destroy it.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:argon2/argon2.dart';
import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../local/dek_manager.dart';

class TerminationException implements Exception {
  final String message;
  final String? code;
  TerminationException(this.message, {this.code});
  @override
  String toString() => 'TerminationException: $message';
}

class TerminationService {
  final FlutterSecureStorage _storage;
  static final _rng = Random.secure();

  static const _memoryKb = 64 * 1024;
  static const _iterations = 3;
  static const _parallelism = 1;
  static const _kekLen = 32;
  static const _markerInput = 'TERMINATE-v1';

  TerminationService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<bool> isConfigured() async {
    final marker = await _storage.read(key: DekStorageKeys.termMarker);
    return marker != null;
  }

  /// Set or replace the termination code.
  Future<void> setCode(String code) async {
    _validate(code);
    final salt = _randomBytes(16);
    final kek = await _deriveKek(code, salt);
    final marker = await _hmac(kek, utf8.encode(_markerInput));
    await _storage.write(
      key: DekStorageKeys.termSalt,
      value: base64.encode(salt),
    );
    await _storage.write(
      key: DekStorageKeys.termMarker,
      value: base64.encode(marker),
    );
  }

  /// Returns true if the supplied code matches the configured termination
  /// code. The caller is responsible for invoking WipeService on true.
  Future<bool> matches(String code) async {
    if (!await isConfigured()) return false;
    final saltB64 = await _storage.read(key: DekStorageKeys.termSalt);
    final markerB64 = await _storage.read(key: DekStorageKeys.termMarker);
    if (saltB64 == null || markerB64 == null) return false;
    final kek = await _deriveKek(code, base64.decode(saltB64));
    final candidate = await _hmac(kek, utf8.encode(_markerInput));
    final expected = base64.decode(markerB64);
    return _constantTimeEq(candidate, Uint8List.fromList(expected));
  }

  Future<void> disable() async {
    await _storage.delete(key: DekStorageKeys.termSalt);
    await _storage.delete(key: DekStorageKeys.termMarker);
  }

  void _validate(String code) {
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      throw TerminationException(
        'Termination code must be 6 digits',
        code: 'VALIDATION_ERROR',
      );
    }
  }

  Future<Uint8List> _deriveKek(String code, Uint8List salt) async {
    // Argon2id is a tight CPU loop (~500ms on a mid-range phone). Running
    // it on the main isolate freezes the UI between the 6th digit and the
    // unlock transition. Off-load to a worker isolate so the keypad stays
    // responsive (e.g. for the dot-fill animation) while the KDF runs.
    return await Isolate.run(
      () => _termArgon2idDeriveSync(
        code: code,
        salt: salt,
        iterations: _iterations,
        memoryKb: _memoryKb,
        parallelism: _parallelism,
        outLen: _kekLen,
      ),
    );
  }

  Future<Uint8List> _hmac(Uint8List key, List<int> input) async {
    final mac = await c.Hmac.sha256().calculateMac(
      input,
      secretKey: c.SecretKey(key),
    );
    return Uint8List.fromList(mac.bytes);
  }

  static bool _constantTimeEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static int _log2(int n) {
    var x = n;
    var r = 0;
    while (x > 1) {
      x >>= 1;
      r++;
    }
    return r;
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
/// `Isolate.run` doesn't capture the surrounding `TerminationService`
/// instance — only plain primitives + a `Uint8List` cross the isolate
/// boundary.
Uint8List _termArgon2idDeriveSync({
  required String code,
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
    memoryPowerOf2: _termLog2Pure(memoryKb),
    lanes: parallelism,
  );
  final gen = Argon2BytesGenerator()..init(params);
  final out = Uint8List(outLen);
  final codeBytes = Uint8List.fromList(utf8.encode(code));
  gen.generateBytes(codeBytes, out, 0, out.length);
  return out;
}

int _termLog2Pure(int n) {
  var x = n;
  var r = 0;
  while (x > 1) {
    x >>= 1;
    r++;
  }
  return r;
}
