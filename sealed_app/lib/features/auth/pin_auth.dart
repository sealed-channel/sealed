/// PIN authentication & duress termination.
///
/// Consolidates three previously-separate files:
///
///   - [PinService] — manages the user's 6-digit PIN. The PIN is never
///     stored. Argon2id(PIN, salt) derives a KEK that wraps the DEK (see
///     DekManager). Verifying a PIN = attempting to unwrap the DEK with
///     the derived KEK. AES-GCM authentication tag failure means wrong PIN.
///
///   - [PinAttemptTracker] — counts wrong-PIN strikes against a hard cap
///     ("five strikes and you're out"). The counter survives app kills via
///     `flutter_secure_storage`, so power-cycling the phone cannot reset
///     the budget.
///
///   - [TerminationService] — manages the duress / panic "termination
///     code". The termination code is a separate 6-digit code that, when
///     entered on the unlock screen, triggers a full wipe instead of
///     unlocking. Argon2id(code, salt) → KEK_term. We store an HMAC-SHA256
///     marker (`HMAC(KEK_term, "TERMINATE")`) so verification can be done
///     without unwrapping the DEK — we don't want the DEK in memory at the
///     moment we're about to destroy it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:sealed_app/infra/crypto/secure_random.dart';

import 'package:argon2/argon2.dart';
import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:flutter/foundation.dart';

import '../../infra/local/dek_manager.dart';

// ─── Secure-storage corruption recovery ──────────────────────────────────────

/// True when a [PlatformException] from secure storage means the
/// Keystore-wrapped app key is unusable (corruption), not a transient fault.
/// Happens e.g. when the encrypted SharedPreferences blob is restored from a
/// cloud/device backup but the device-bound Keystore key is not — the native
/// layer then throws "IllegalArgumentException: Empty key" from SecretKeySpec.
/// Mirrors KeyService._isStorageCorruption.
bool _isPinStorageCorruption(PlatformException e) {
  final haystack = '${e.code} ${e.message} ${e.details}'.toLowerCase();
  return haystack.contains('empty key') ||
      haystack.contains('bad_decrypt') ||
      haystack.contains('baddecrypt') ||
      haystack.contains('aeadbadtag') ||
      haystack.contains('illegalargument');
}

/// Read-only state probe that tolerates Keystore corruption. On a corruption
/// [PlatformException] the stored ciphertext is unrecoverable, so wipe the
/// dead store and report the value as absent — the app then routes to fresh
/// onboarding instead of crashing on the lock screen. The DEK is gone in this
/// state, so treating credentials as unset cannot bypass a real unlock.
/// Transient errors are rethrown.
Future<String?> _readOrRecover(FlutterSecureStorage storage, String key) async {
  try {
    return await storage.read(key: key);
  } on PlatformException catch (e) {
    if (!_isPinStorageCorruption(e)) rethrow;
    try {
      await storage.deleteAll();
    } catch (_) {
      // best-effort wipe; absent value is still the correct outcome
    }
    return null;
  }
}

// ─── Shared Argon2id KDF machinery ───────────────────────────────────────────

/// Immutable Argon2id cost parameters.
///
/// Persisted next to the salt at PIN/term-code setup so the *exact* params
/// used to wrap the DEK are reproduced at unlock. A parameter drift changes
/// the derived KEK and reads as a (false) wrong-PIN — so the verify path must
/// always derive under the same params the wrap used.
class KdfParams {
  final int memoryKb;
  final int iterations;
  final int parallelism;

  const KdfParams({
    required this.memoryKb,
    required this.iterations,
    required this.parallelism,
  });

  /// Fixed params shipped by every build before per-device calibration.
  /// Existing wraps store no params and MUST verify under these. 64 MiB here
  /// equals the old `memoryPowerOf2: 16` path — identical derived bytes.
  const KdfParams.legacy()
    : memoryKb = 64 * 1024,
      iterations = 3,
      parallelism = 1;

  String toJson() =>
      jsonEncode({'v': 1, 'm': memoryKb, 't': iterations, 'p': parallelism});

  /// Tolerant decode: a null or malformed blob degrades to legacy params, so a
  /// corrupted entry means "slow but unlockable", never lockout.
  static KdfParams fromJsonOrLegacy(String? raw) {
    if (raw == null) return const KdfParams.legacy();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return KdfParams(
        memoryKb: m['m'] as int,
        iterations: m['t'] as int,
        parallelism: m['p'] as int,
      );
    } catch (_) {
      return const KdfParams.legacy();
    }
  }

  bool get isLegacy => this == const KdfParams.legacy();

  @override
  bool operator ==(Object other) =>
      other is KdfParams &&
      other.memoryKb == memoryKb &&
      other.iterations == iterations &&
      other.parallelism == parallelism;

  @override
  int get hashCode => Object.hash(memoryKb, iterations, parallelism);
}

/// Top-level (file-private) Argon2id derivation, runnable inside
/// `Isolate.run`.
///
/// Kept as a free function (not a method) so the closure passed to
/// `Isolate.run` doesn't capture any surrounding instance — only plain
/// primitives + a `Uint8List` cross the isolate boundary.
Uint8List _argon2idDeriveSync({
  required String input,
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
    // Raw KB (not memoryPowerOf2): calibrated memory floors need not be a
    // power of two (46 MiB == 47104 KB).
    memory: memoryKb,
    lanes: parallelism,
  );
  final gen = Argon2BytesGenerator()..init(params);
  final out = Uint8List(outLen);
  final inputBytes = Uint8List.fromList(utf8.encode(input));
  gen.generateBytes(inputBytes, out, 0, out.length);
  return out;
}

class _Argon2idKdf {
  static const kekLen = 32;

  /// Calibration aims for ~700 ms of KDF on the unlock path. Iterations scale
  /// to hit this on the device; memory is pinned at a security floor.
  static const targetMs = 700;

  /// Memory floor: 46 MiB. Below the old fixed 64 MiB to cut GC stalls on
  /// <1 GB-RAM Androids, well above OWASP's 19 MiB Argon2id floor.
  static const calibrationMemoryKb = 46 * 1024; // 47104

  /// Iteration clamp. Floor of 1: on a device where a single 46 MiB pass
  /// already meets/exceeds [targetMs], forcing a 2nd pass only doubles the
  /// unlock latency for no security gain — `m=46 MiB, t=1, p=1` is OWASP's
  /// top recommended Argon2id config, so one pass at this memory is a valid
  /// floor. Fast devices still scale up toward the ceiling. The ceiling caps
  /// the worst case on devices so slow even one pass is costly.
  static const _minIterations = 1;
  static const _maxIterations = 10;

  /// Derive a KEK under explicit params. The CPU-bound Argon2 loop runs on a
  /// worker isolate so the keypad / unlock transition stays responsive.
  static Future<Uint8List> deriveWith(
    String input,
    Uint8List salt,
    KdfParams params,
  ) async {
    return await Isolate.run(
      () => _argon2idDeriveSync(
        input: input,
        salt: salt,
        iterations: params.iterations,
        memoryKb: params.memoryKb,
        parallelism: params.parallelism,
        outLen: kekLen,
      ),
    );
  }

  /// Benchmark a single Argon2id pass at [calibrationMemoryKb] on this device
  /// and pick an iteration count landing near [targetMs]. Argon2 time is
  /// ~linear in iterations, so iterations ≈ target / single-pass-cost, clamped.
  /// Runs on a worker isolate; costs ~one pass (one extra KDF) at setup only.
  static Future<KdfParams> calibrate() async {
    final probeSalt = randomBytes(16);
    final sw = Stopwatch()..start();
    await Isolate.run(
      () => _argon2idDeriveSync(
        input: 'kdf-calibration-probe',
        salt: probeSalt,
        iterations: 1,
        memoryKb: calibrationMemoryKb,
        parallelism: 1,
        outLen: kekLen,
      ),
    );
    sw.stop();
    final perPassMs = sw.elapsedMilliseconds < 1 ? 1 : sw.elapsedMilliseconds;
    final iters = (targetMs / perPassMs).round().clamp(
      _minIterations,
      _maxIterations,
    );
    // [unlock-timing] Diagnostic for the low-end-Android slow-unlock report.
    // perPassMs is the single-pass cost of 46MiB Argon2id on THIS device; the
    // chosen iters × perPassMs ≈ the unlock KEK-derive cost. If one pass already
    // exceeds targetMs, the _minIterations=2 floor pins the unlock at ~2 passes.
    // debugPrint so it shows in profile builds. Remove once the fix lands.
    debugPrint(
      '[unlock-timing] calibrate: perPassMs=$perPassMs '
      'chosenIters=$iters projectedDeriveMs=${perPassMs * iters} '
      '(memory=${calibrationMemoryKb ~/ 1024}MiB, floor=$_minIterations)',
    );
    return KdfParams(
      memoryKb: calibrationMemoryKb,
      iterations: iters,
      parallelism: 1,
    );
  }

  static Uint8List randomBytes(int n) => secureRandomBytes(n);
}

// ─── PinService ─────────────────────────────────────────────────────────────

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

  PinService({FlutterSecureStorage? storage, DekManager? dekManager})
    : _storage = storage ?? const FlutterSecureStorage(),
      _dek = dekManager ?? DekManager(storage: storage);

  /// True if the user has configured a PIN.
  Future<bool> isPinSet() async {
    final kind = await _readOrRecover(_storage, DekStorageKeys.dekKekKind);
    return kind == 'pin';
  }

  /// Set the PIN for the first time. Requires the current device-wrapped DEK
  /// to still be available.
  ///
  /// Returns the plaintext DEK that was just re-wrapped under the PIN. The
  /// onboarding path commits this straight into the session — avoids a
  /// redundant second Argon2id derivation just to unwrap what we already
  /// held here (that double-KDF was the first-PIN-setup lag).
  Future<Uint8List> setPin(String pin) async {
    _validatePin(pin);
    if (await isPinSet()) {
      throw PinException(
        'PIN already set; use changePin',
        code: 'PIN_ALREADY_SET',
      );
    }
    final dek = await _dek.unwrapWithDeviceSecret();
    final salt = _Argon2idKdf.randomBytes(16);
    final params = await _Argon2idKdf.calibrate();
    final kek = await _deriveKek(pin, salt, params);
    // Persist salt + params before the rewrap. The PIN only counts as "set"
    // once rewrap flips kekKind to 'pin'; a crash before then re-runs setPin
    // and overwrites these, so an early write is safe.
    await _storage.write(
      key: DekStorageKeys.pinSalt,
      value: base64.encode(salt),
    );
    await _storage.write(
      key: DekStorageKeys.pinKdfParams,
      value: params.toJson(),
    );
    await _dek.rewrap(dek, kek, markKekKind: 'pin');
    // Accessibility-agnostic delete: the device secret is written under
    // `first_unlock` (see DekManager), so a default-options delete in
    // secure-storage v10 would not match it and the secret would linger.
    await _storage.delete(
      key: DekStorageKeys.deviceSecret,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    return dek;
  }

  /// Verify a PIN by unwrapping the DEK; throws PinIncorrectException on bad PIN.
  Future<Uint8List> verifyAndUnwrap(String pin) async {
    if (!await isPinSet()) throw PinNotSetException();
    final saltB64 = await _storage.read(key: DekStorageKeys.pinSalt);
    if (saltB64 == null) throw PinKdfException('Missing PIN salt');
    final salt = base64.decode(saltB64);
    final storedRaw = await _storage.read(key: DekStorageKeys.pinKdfParams);
    final params = KdfParams.fromJsonOrLegacy(storedRaw);
    // [unlock-timing] One-off diagnostic for the low-end-Android slow-unlock
    // report (Samsung M11, ~15s). Logs the cost params actually in force and
    // the wall-clock split KEK-derive vs DEK-unwrap. Non-secret (cost params
    // only, no key material). Remove once the regression is pinned + fixed.
    final isLegacyParams = storedRaw == null;
    final swKek = Stopwatch()..start();
    final kek = await _deriveKek(pin, salt, params);
    swKek.stop();
    // debugPrint (not Log.d) so the line survives PROFILE builds — Log.d is
    // kDebugMode-gated and the real perf must be measured in profile.
    debugPrint(
      '[unlock-timing] kdf=${isLegacyParams ? "LEGACY(64MiB/3)" : params.toJson()} '
      'kekDerive=${swKek.elapsedMilliseconds}ms',
    );
    try {
      final swUnwrap = Stopwatch()..start();
      final dek = await _dek.unwrapWithKek(kek);
      swUnwrap.stop();
      debugPrint('[unlock-timing] dekUnwrap=${swUnwrap.elapsedMilliseconds}ms');
      // No stored params → this device is still paying the legacy 64 MiB cost.
      // Recalibrate + rewrap once, off the critical path, so subsequent
      // unlocks are faster. Fire-and-forget: never block (or fail) the unlock.
      if (storedRaw == null) {
        unawaited(_maybeUpgradeKdf(pin, salt, dek));
      }
      return dek;
    } on DekException catch (e) {
      if (e.code != 'DEK_UNWRAP_ERROR') rethrow;
      // A crash between "params written" and "DEK rewrapped" during a prior
      // upgrade leaves stored params ahead of the wrap. The upgrade reuses the
      // SAME salt, so the legacy params still unwrap — recover + finish it.
      if (storedRaw != null && !params.isLegacy) {
        final dek = await _recoverWithLegacy(pin, salt, params);
        if (dek != null) return dek;
      }
      throw PinIncorrectException();
    }
  }

  /// One-time opportunistic upgrade of a legacy (un-calibrated) wrap to
  /// per-device params. Reuses the existing salt — only the cost params change
  /// — so the [verifyAndUnwrap] legacy-fallback can recover a torn write.
  ///
  /// Params are written BEFORE the rewrap: if killed in between, the next
  /// unlock derives the new params, fails, and [_recoverWithLegacy] unwraps
  /// under legacy (same salt) and retries the rewrap. Best-effort throughout —
  /// any failure leaves the user unlocked under legacy params.
  Future<void> _maybeUpgradeKdf(
    String pin,
    Uint8List salt,
    Uint8List dek,
  ) async {
    try {
      final params = await _Argon2idKdf.calibrate();
      if (params.isLegacy) return; // calibration matched legacy — nothing to do
      await _storage.write(
        key: DekStorageKeys.pinKdfParams,
        value: params.toJson(),
      );
      final kek = await _deriveKek(pin, salt, params);
      await _dek.rewrap(dek, kek, markKekKind: 'pin');
    } catch (_) {
      // Keep the user unlocked under legacy params on any failure.
    }
  }

  /// Recover from a torn upgrade: unwrap under legacy params (same salt) and,
  /// on success, finish the rewrap under the already-persisted [stored] params.
  /// Returns the DEK, or null if legacy also fails to unwrap (genuine wrong PIN).
  Future<Uint8List?> _recoverWithLegacy(
    String pin,
    Uint8List salt,
    KdfParams stored,
  ) async {
    final legacyKek = await _deriveKek(pin, salt, const KdfParams.legacy());
    try {
      final dek = await _dek.unwrapWithKek(legacyKek);
      try {
        final kek = await _deriveKek(pin, salt, stored);
        await _dek.rewrap(dek, kek, markKekKind: 'pin');
      } catch (_) {
        // Best-effort; the next unlock retries the same recovery.
      }
      return dek;
    } on DekException catch (e) {
      if (e.code == 'DEK_UNWRAP_ERROR') return null;
      rethrow;
    }
  }

  /// Change PIN. Requires the old PIN to derive the current DEK.
  Future<void> changePin(String oldPin, String newPin) async {
    _validatePin(newPin);
    final dek = await verifyAndUnwrap(oldPin);
    final salt = _Argon2idKdf.randomBytes(16);
    final params = await _Argon2idKdf.calibrate();
    final kek = await _deriveKek(newPin, salt, params);
    await _storage.write(
      key: DekStorageKeys.pinSalt,
      value: base64.encode(salt),
    );
    await _storage.write(
      key: DekStorageKeys.pinKdfParams,
      value: params.toJson(),
    );
    await _dek.rewrap(dek, kek, markKekKind: 'pin');
  }

  /// Disable PIN — re-wraps DEK under a fresh device-secret.
  Future<void> disablePin(String currentPin) async {
    final dek = await verifyAndUnwrap(currentPin);
    final deviceSecret = _Argon2idKdf.randomBytes(32);
    // Delete-then-write under `first_unlock`, matching DekManager's bootstrap
    // write: the push-prefetch background isolate must read this secret while
    // the screen is locked, and v10 writes fail with errSecDuplicateItem if a
    // different-accessibility item is left behind.
    await _storage.delete(
      key: DekStorageKeys.deviceSecret,
      iOptions: kDekAnyAccessibilityIOptions,
    );
    await _storage.write(
      key: DekStorageKeys.deviceSecret,
      value: base64.encode(deviceSecret),
      iOptions: kDekBackgroundReadableIOptions,
    );
    final kek = await _hkdfDeviceKek(deviceSecret);
    await _dek.rewrap(dek, kek, markKekKind: 'device');
    await _storage.delete(key: DekStorageKeys.pinSalt);
    await _storage.delete(key: DekStorageKeys.pinKdfParams);
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

  Future<Uint8List> _deriveKek(
    String pin,
    Uint8List salt,
    KdfParams params,
  ) async {
    try {
      return await _Argon2idKdf.deriveWith(pin, salt, params);
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
}

// ─── PinAttemptTracker ──────────────────────────────────────────────────────

/// Counts wrong-PIN strikes against a hard cap.
///
/// Replaces the previous time-based exponential-backoff schedule with a
/// simple "five strikes and you're out" policy:
///
///   attempts 1-3: free, just show "Incorrect PIN"
///   attempt   4: lock screen renders a final-attempt warning
///   attempt   5: caller wipes the device + logs out
///
/// The tracker itself only counts; the lock screen owns the policy. A
/// successful unlock or biometric pass calls [reset].
class PinAttemptTracker {
  /// Hard cap: on the [maxAttempts]th wrong PIN the lock screen wipes the
  /// device. Lower = stricter; higher = friendlier. 5 matches the iOS
  /// device-passcode warning UX users are already conditioned to.
  static const int maxAttempts = 5;

  final FlutterSecureStorage _storage;

  PinAttemptTracker({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Current count of consecutive wrong attempts. Returns 0 when no
  /// failures have been recorded since the last [reset].
  Future<int> attemptCount() async {
    final s = await _readOrRecover(_storage, DekStorageKeys.pinAttempts);
    return int.tryParse(s ?? '0') ?? 0;
  }

  /// Record a wrong PIN attempt and return the new attempt count.
  ///
  /// The caller should compare against [maxAttempts] to decide whether
  /// to surface a warning, or trigger the wipe-and-logout exit.
  Future<int> recordFailedAttempt() async {
    final next = (await attemptCount()) + 1;
    await _storage.write(
      key: DekStorageKeys.pinAttempts,
      value: next.toString(),
    );
    return next;
  }

  /// Overwrite the persisted attempt count with an exact value.
  ///
  /// Used to roll back a *speculative* pre-KDF strike on an infrastructure
  /// fault (KDF blowup, missing salt) — that is not a brute-force signal, so
  /// the budget must be restored to its prior value without clearing any
  /// genuine earlier strikes (which a plain [reset] would wipe). Values <= 0
  /// clear the key entirely.
  Future<void> setCount(int count) async {
    if (count <= 0) {
      await _storage.delete(key: DekStorageKeys.pinAttempts);
      return;
    }
    await _storage.write(
      key: DekStorageKeys.pinAttempts,
      value: count.toString(),
    );
  }

  /// Reset on successful unlock (PIN ).
  Future<void> reset() async {
    await _storage.delete(key: DekStorageKeys.pinAttempts);
    // Legacy key from the old time-based backoff schedule — clear it too
    // so an upgrade from a previous build can't keep a phantom lockout.
    await _storage.delete(key: DekStorageKeys.pinLockedUntil);
  }
}

// ─── TerminationService ─────────────────────────────────────────────────────

class TerminationException implements Exception {
  final String message;
  final String? code;
  TerminationException(this.message, {this.code});
  @override
  String toString() => 'TerminationException: $message';
}

class TerminationService {
  final FlutterSecureStorage _storage;

  static const _markerInput = 'TERMINATE-v1';

  TerminationService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<bool> isConfigured() async {
    final marker = await _readOrRecover(_storage, DekStorageKeys.termMarker);
    return marker != null;
  }

  /// Set or replace the termination code.
  Future<void> setCode(String code) async {
    _validate(code);
    final salt = _Argon2idKdf.randomBytes(16);
    final params = await _Argon2idKdf.calibrate();
    final kek = await _deriveKek(code, salt, params);
    final marker = await _hmac(kek, utf8.encode(_markerInput));
    await _storage.write(
      key: DekStorageKeys.termSalt,
      value: base64.encode(salt),
    );
    await _storage.write(
      key: DekStorageKeys.termKdfParams,
      value: params.toJson(),
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
    final params = KdfParams.fromJsonOrLegacy(
      await _storage.read(key: DekStorageKeys.termKdfParams),
    );
    final kek = await _deriveKek(code, base64.decode(saltB64), params);
    final candidate = await _hmac(kek, utf8.encode(_markerInput));
    final expected = base64.decode(markerB64);
    return _constantTimeEq(candidate, Uint8List.fromList(expected));
  }

  Future<void> disable() async {
    await _storage.delete(key: DekStorageKeys.termSalt);
    await _storage.delete(key: DekStorageKeys.termKdfParams);
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

  Future<Uint8List> _deriveKek(
    String code,
    Uint8List salt,
    KdfParams params,
  ) async {
    return await _Argon2idKdf.deriveWith(code, salt, params);
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
}
