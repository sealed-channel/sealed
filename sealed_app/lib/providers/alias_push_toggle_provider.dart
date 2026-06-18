import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/providers/alias_key_provider.dart';
import 'package:sealed_app/providers/app_settings_provider.dart';
import 'package:sealed_app/providers/indexer_provider.dart';

/// State surface for the per-contact alias push toggle. Tracks the persisted
/// flag, whether a register/unregister call is in flight, and the last error
/// message (so the widget can render a snackbar without having to await the
/// call result inline).
///
/// Scan-priv key material is consumed inside [AliasPushToggleNotifier] but
/// is never exposed on this state — privacy invariant.
class AliasPushToggleState {
  const AliasPushToggleState({
    required this.enabled,
    this.busy = false,
    this.lastError,
  });

  final bool enabled;
  final bool busy;
  final String? lastError;

  AliasPushToggleState copyWith({
    bool? enabled,
    bool? busy,
    String? lastError,
    bool clearError = false,
  }) {
    return AliasPushToggleState(
      enabled: enabled ?? this.enabled,
      busy: busy ?? this.busy,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

class AliasPushToggleNotifier extends AsyncNotifier<AliasPushToggleState> {
  AliasPushToggleNotifier(this.contactId);

  final String contactId;

  @override
  Future<AliasPushToggleState> build() async {
    // Initial enabled flag pulled from persisted settings via the reactive
    // settings notifier — guarantees we re-build when settings change elsewhere.
    await ref.watch(appSettingsProvider.future);
    final enabled = ref
        .read(appSettingsProvider.notifier)
        .getAliasPushEnabled(contactId);
    return AliasPushToggleState(enabled: enabled);
  }

  /// Toggle push for this alias. Enable orchestrates:
  ///   1. Load scan-priv from local store.
  ///   2. Register with indexer (passes key through; not retained).
  ///   3. Persist enabled=true in settings.
  /// Disable mirrors with unregister.
  ///
  /// State reflects the actual persisted result. On failure the persisted
  /// flag is NOT advanced and [lastError] is populated.
  Future<void> setEnabled(bool enable) async {
    final current = state.value;
    if (current == null || current.busy) return;

    state = AsyncData(current.copyWith(busy: true, clearError: true));

    try {
      final scanPriv = await ref.read(aliasKeyProvider(contactId).future);
      if (scanPriv == null) {
        state = AsyncData(
          current.copyWith(busy: false, lastError: 'Missing alias key.'),
        );
        return;
      }

      final indexer = await ref.read(indexerServiceProvider.future);
      final ok = enable
          ? await indexer.registerAliasViewKey(aliasScanPriv: scanPriv)
          : await indexer.unregisterAliasViewKey(aliasScanPriv: scanPriv);

      if (!ok) {
        state = AsyncData(
          current.copyWith(
            busy: false,
            lastError: enable
                ? 'Push registration failed.'
                : 'Push unregister failed.',
          ),
        );
        return;
      }

      await ref
          .read(appSettingsProvider.notifier)
          .setAliasPushEnabled(contactId, enable);

      state = AsyncData(AliasPushToggleState(enabled: enable));
    } catch (e) {
      state = AsyncData(
        current.copyWith(busy: false, lastError: 'Push toggle failed: $e'),
      );
    }
  }
}

final aliasPushToggleProvider =
    AsyncNotifierProvider.family<
      AliasPushToggleNotifier,
      AliasPushToggleState,
      String
    >(AliasPushToggleNotifier.new);
