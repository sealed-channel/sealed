import 'package:sealed_app/services/message_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing app-wide settings and preferences
class AppSettingsService {
  final SharedPreferences _prefs;

  // Preference keys
  static const _keySyncLayer = 'preferred_sync_layer';
  static const _keyTargetedPushEnabled = 'targeted_push_enabled';
  static const _keyAutoSync = 'auto_sync_enabled';

  AppSettingsService({required SharedPreferences prefs}) : _prefs = prefs;


  /// Get the preferred sync layer. Returns null for "auto" mode.
  /// Default: blockchain (most private, no indexer needed)
  SyncLayer? get preferredSyncLayer {
    final value = _prefs.getString(_keySyncLayer);
    if (value == null) return SyncLayer.blockchain;
    if (value == 'auto') return null;
    return SyncLayer.values.firstWhere(
      (l) => l.name == value,
      orElse: () => SyncLayer.blockchain,
    );
  }

  /// Set the preferred sync layer. Pass null for "auto" mode.
  Future<void> setPreferredSyncLayer(SyncLayer? layer) async {
    if (layer == null) {
      await _prefs.setString(_keySyncLayer, 'auto');
    } else {
      await _prefs.setString(_keySyncLayer, layer.name);
    }
  }

  /// Get display name for sync layer
  static String getSyncLayerDisplayName(SyncLayer? layer) {
    if (layer == null) return 'Auto (Recommended)';
    switch (layer) {
  
      case SyncLayer.blockchain:
        return 'Blockchain (Most Private)';
    }
  }

  /// Get description for sync layer
  static String getSyncLayerDescription(SyncLayer? layer) {
    if (layer == null) {
      return 'Automatically selects the best available method';
    }
    switch (layer) {

      case SyncLayer.blockchain:
        return 'Safest option - all requests go directly from your phone to the blockchain RPC. No middleman.';
    }
  }

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
}
