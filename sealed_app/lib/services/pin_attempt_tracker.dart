/// PinAttemptTracker — counts wrong-PIN strikes against a hard cap.
///
/// Replaces the previous time-based exponential-backoff schedule with a
/// simple "five strikes and you're out" policy:
///
///   attempts 1-3: free, just show "Incorrect PIN"
///   attempt   4: lock screen renders a final-attempt warning
///   attempt   5: caller wipes the device + logs out
///
/// The tracker itself only counts; the lock screen owns the policy. A
/// successful unlock or biometric pass calls [reset]. The counter survives
/// app kills via `flutter_secure_storage`, so power-cycling the phone
/// cannot reset the budget.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../local/dek_manager.dart';

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
    final s = await _storage.read(key: DekStorageKeys.pinAttempts);
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

  /// Reset on successful unlock (PIN or biometric).
  Future<void> reset() async {
    await _storage.delete(key: DekStorageKeys.pinAttempts);
    // Legacy key from the old time-based backoff schedule — clear it too
    // so an upgrade from a previous build can't keep a phantom lockout.
    await _storage.delete(key: DekStorageKeys.pinLockedUntil);
  }
}
