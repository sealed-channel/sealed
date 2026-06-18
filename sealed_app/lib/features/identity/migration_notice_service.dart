import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Tracks the one-shot post-login informational dialog that warns legacy
/// (12-word BIP39) restorers that on-chain usernames have been wiped due to
/// the new Algorand smart-contract `app id`.
///
/// Uses two flags in [FlutterSecureStorage]:
///
///   • `pending_migration_notice`        — set by the wallet restore flow when
///                                          a 12-word mnemonic restore
///                                          succeeds. Acts as a one-shot
///                                          trigger consumed at next login.
///   • `legacy_migration_notice_shown_v1` — sticky flag set after the dialog
///                                          has been acknowledged. Prevents
///                                          the notice from ever firing
///                                          again. Versioned suffix (`_v1`)
///                                          so that a future on-chain
///                                          migration can re-arm under
///                                          `_v2` without clobbering history.
class MigrationNoticeService {
  static const String pendingKey = 'pending_migration_notice';
  static const String shownKey = 'legacy_migration_notice_shown_v1';
  static const String _flagValue = '1';

  final FlutterSecureStorage _storage;

  MigrationNoticeService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Arm the notice. Call after a successful 12-word mnemonic restore.
  Future<void> markPending() =>
      _storage.write(key: pendingKey, value: _flagValue);

  /// Whether the dialog should be displayed on this login.
  ///
  /// Returns true only when the trigger was armed AND the dialog has never
  /// been acknowledged.
  Future<bool> shouldShow() async {
    final pending = await _storage.read(key: pendingKey);
    if (pending != _flagValue) return false;
    final shown = await _storage.read(key: shownKey);
    return shown != _flagValue;
  }

  /// Acknowledge the dialog. Persists the sticky flag and consumes the
  /// one-shot trigger. Idempotent.
  Future<void> markShown() async {
    await _storage.write(key: shownKey, value: _flagValue);
    await _storage.delete(key: pendingKey);
  }

  /// Wipe both flags. Intended for full-app wipe / logout flows that already
  /// purge secure storage; kept here so callers don't reach into key strings.
  Future<void> reset() async {
    await _storage.delete(key: pendingKey);
    await _storage.delete(key: shownKey);
  }
}
