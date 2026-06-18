import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing app-wide settings and preferences
class AppSettingsService {
  final SharedPreferences _prefs;

  // Preference keys
  static const _keyTargetedPushEnabled = 'targeted_push_enabled';
  static const _keyAutoSync = 'auto_sync_enabled';

  AppSettingsService({required SharedPreferences prefs}) : _prefs = prefs;

  // ===========================================================================
  // PUSH NOTIFICATIONS
  // ===========================================================================
  //
  // Post Phase B (push cleanup), the only remaining push path is **targeted
  // push** — the user opts in per-device via [targetedPushEnabled]. The
  // legacy / blinded-fanout flags have been retired.
  // ---------------------------------------------------------------------------
  // Push Notifications (OPT-IN)
  //
  // When enabled, the indexer holds `view_priv` and dispatches one visible
  // push per matched on-chain message. Trades two privacy properties for
  // alert-style delivery:
  //   1. The indexer learns which messages are yours.
  //   2. Apple/Google see per-message wake timing.
  // Default: disabled. Surface only via the dual-disclosure consent dialog.
  // ---------------------------------------------------------------------------

  bool get targetedPushEnabled {
    return _prefs.getBool(_keyTargetedPushEnabled) ?? false;
  }

  Future<void> setTargetedPushEnabled(bool enabled) async {
    await _prefs.setBool(_keyTargetedPushEnabled, enabled);
  }

  // ===========================================================================
  // AUTO SYNC
  // ===========================================================================

  /// Check if auto-sync on app start is enabled
  bool get autoSyncEnabled {
    return _prefs.getBool(_keyAutoSync) ?? true;
  }

  /// Enable or disable auto-sync
  Future<void> setAutoSyncEnabled(bool enabled) async {
    await _prefs.setBool(_keyAutoSync, enabled);
  }

  // ===========================================================================
  // PER-ALIAS PUSH (privacy opt-in, per alias contact)
  // ===========================================================================
  //
  // Registering an alias contact's `scan_priv` at the indexer under the same
  // device push token as the main wallet's view_priv leaks correlation to
  // Apple/Google: both pushes wake the same device, allowing the push
  // provider to link the two identities by token + timing.
  //
  // To preserve alias anonymity, alias push is **OPT-IN per contact** —
  // disabled by default, gated by an explicit confirmation dialog the first
  // time the user enables it for any given contact.
  //
  // Wire shape:
  //   push_alias_<contactId>                 : bool (default false)
  //   push_alias_consent_shown_<contactId>   : bool (default false)
  // ---------------------------------------------------------------------------

  static const _prefixAliasPush = 'push_alias_';
  static const _prefixAliasConsent = 'push_alias_consent_shown_';

  String _aliasPushKey(String contactId) => '$_prefixAliasPush$contactId';
  String _aliasConsentKey(String contactId) => '$_prefixAliasConsent$contactId';

  /// Whether alias push is enabled for [contactId]. Default false.
  bool getAliasPushEnabled(String contactId) =>
      _prefs.getBool(_aliasPushKey(contactId)) ?? false;

  /// Persist the per-alias push flag.
  Future<void> setAliasPushEnabled(String contactId, bool enabled) async {
    await _prefs.setBool(_aliasPushKey(contactId), enabled);
  }

  /// Whether the correlation-risk consent dialog has been shown for
  /// [contactId]. Used to gate the dialog to first-enable only.
  bool getAliasPushConsentShown(String contactId) =>
      _prefs.getBool(_aliasConsentKey(contactId)) ?? false;

  Future<void> setAliasPushConsentShown(String contactId, bool shown) async {
    await _prefs.setBool(_aliasConsentKey(contactId), shown);
  }

  /// Every contactId currently opted into alias push. Used by the boot
  /// reconciler to re-register exactly the toggled-on aliases.
  List<String> listEnabledAliasContactIds() {
    final out = <String>[];
    for (final k in _prefs.getKeys()) {
      if (k.startsWith(_prefixAliasPush) &&
          (_prefs.getBool(k) ?? false) == true) {
        out.add(k.substring(_prefixAliasPush.length));
      }
    }
    return out;
  }

  /// Wipe **all** per-alias push prefs (both the enabled bit and the consent
  /// shown bit) for every contact. Called from logout / wipe and when the
  /// user disables the global push toggle (alias push depends on the global
  /// channel).
  Future<void> clearAllAliasPushFlags() async {
    final keys = _prefs
        .getKeys()
        .where(
          (k) =>
              k.startsWith(_prefixAliasPush) ||
              k.startsWith(_prefixAliasConsent),
        )
        .toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
  }
}
