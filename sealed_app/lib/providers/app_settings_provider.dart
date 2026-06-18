/// Riverpod surface for app-wide user settings.
///
/// Wraps the raw [AppSettingsService] (from [appSettingsServiceProvider]) in
/// an [AsyncNotifier] so UI can `ref.watch` immutable [AppSettingsState] and
/// route writes through one mutator per setting. Direct `.future` awaits and
/// direct setter calls on the service are no longer needed from UI.
///
/// Scope (Phase B3):
/// - [AppSettingsState] mirrors the **global** persistent settings on the
///   service — `targetedPushEnabled` and `autoSyncEnabled`. Per-alias push
///   flags are per-contact keyed and are exposed as pass-through methods on
///   the notifier (no Map state) rather than living in the immutable state.
/// - `setAliasPushEnabled` on this notifier is intentionally a *plain*
///   persistence call. The orchestrated alias-push toggle — viewKey
///   registration with the indexer + persistence + push setup — stays in the
///   relevant UI screens for now. Phase C3 will wrap that flow in a
///   dedicated `aliasPushToggleProvider`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/settings/app_settings_service.dart';

/// Immutable snapshot of the global app settings.
///
/// One field per *global* persistent setting on [AppSettingsService]. Per-
/// alias settings are per-contact and are not part of this state — they
/// remain on the notifier as pass-through methods.
class AppSettingsState {
  /// Whether the user has opted in to targeted push notifications. When
  /// `true`, the indexer holds `view_priv` and dispatches one visible push
  /// per matched on-chain message. Default `false` (privacy default).
  final bool targetedPushEnabled;

  /// Whether auto-sync on app start is enabled. Default `true`.
  final bool autoSyncEnabled;

  const AppSettingsState({
    required this.targetedPushEnabled,
    required this.autoSyncEnabled,
  });

  AppSettingsState copyWith({
    bool? targetedPushEnabled,
    bool? autoSyncEnabled,
  }) {
    return AppSettingsState(
      targetedPushEnabled: targetedPushEnabled ?? this.targetedPushEnabled,
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettingsState &&
          runtimeType == other.runtimeType &&
          targetedPushEnabled == other.targetedPushEnabled &&
          autoSyncEnabled == other.autoSyncEnabled;

  @override
  int get hashCode => Object.hash(targetedPushEnabled, autoSyncEnabled);

  @override
  String toString() =>
      'AppSettingsState(targetedPushEnabled: $targetedPushEnabled, '
      'autoSyncEnabled: $autoSyncEnabled)';
}

/// Async notifier wrapping [AppSettingsService].
///
/// `build()` resolves the service via [appSettingsServiceProvider] and reads
/// initial values. Setters write through to the service and then update
/// state so all listeners react.
class AppSettingsNotifier extends AsyncNotifier<AppSettingsState> {
  AppSettingsService? _service;

  @override
  Future<AppSettingsState> build() async {
    final service = await ref.watch(appSettingsServiceProvider.future);
    _service = service;
    return AppSettingsState(
      targetedPushEnabled: service.targetedPushEnabled,
      autoSyncEnabled: service.autoSyncEnabled,
    );
  }

  /// Returns the underlying service. Used by alias-push pass-throughs and
  /// by callers that need the raw service while migration is in flight.
  AppSettingsService _requireService() {
    final svc = _service;
    if (svc == null) {
      throw StateError(
        'AppSettingsNotifier accessed before build() resolved. '
        'Await the provider before calling mutators.',
      );
    }
    return svc;
  }

  // ─── Global settings ───────────────────────────────────────────────────

  /// Persist [enabled] for the global targeted-push opt-in and emit a new
  /// [AppSettingsState]. Side effects (indexer registration, OS permission
  /// request) remain in the UI layer for Phase B3.
  Future<void> setTargetedPushEnabled(bool enabled) async {
    final service = _requireService();
    await service.setTargetedPushEnabled(enabled);
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(targetedPushEnabled: enabled));
    }
  }

  /// Persist [enabled] for the auto-sync flag and emit a new state.
  Future<void> setAutoSyncEnabled(bool enabled) async {
    final service = _requireService();
    await service.setAutoSyncEnabled(enabled);
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(autoSyncEnabled: enabled));
    }
  }

  // ─── Per-alias push (pass-through, per-contact keyed) ──────────────────
  //
  // These do not appear in [AppSettingsState] — they're contact-id keyed
  // and would explode the state shape. Callers `ref.read` the notifier and
  // invoke these directly.

  /// Whether per-alias push is enabled for [contactId]. Default `false`.
  bool getAliasPushEnabled(String contactId) =>
      _requireService().getAliasPushEnabled(contactId);

  /// Persist the per-alias push flag for [contactId].
  ///
  /// **Note:** this is a plain pref write — no indexer side effects, no view-
  /// key registration. The orchestrated alias-push toggle lives in
  /// `chat_detail.dart` / `settings_screen.dart` until Phase C3 lifts it
  /// into `aliasPushToggleProvider`.
  Future<void> setAliasPushEnabled(String contactId, bool enabled) async {
    await _requireService().setAliasPushEnabled(contactId, enabled);
  }

  /// Whether the correlation-risk consent dialog has been shown for
  /// [contactId]. Used to gate the dialog to first-enable only.
  bool getAliasPushConsentShown(String contactId) =>
      _requireService().getAliasPushConsentShown(contactId);

  /// Persist whether the consent dialog has been shown for [contactId].
  Future<void> setAliasPushConsentShown(String contactId, bool shown) async {
    await _requireService().setAliasPushConsentShown(contactId, shown);
  }

  /// Every contactId currently opted into alias push.
  List<String> listEnabledAliasContactIds() =>
      _requireService().listEnabledAliasContactIds();

  /// Wipe every per-alias push pref (both enabled and consent-shown flags)
  /// for every contact. Called from logout/wipe and when the user disables
  /// the global push toggle.
  Future<void> clearAllAliasPushFlags() async {
    await _requireService().clearAllAliasPushFlags();
  }
}

/// Riverpod surface for app-wide user settings. See [AppSettingsNotifier].
final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettingsState>(
      AppSettingsNotifier.new,
    );
