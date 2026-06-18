// test/providers/app_settings_provider_test.dart
//
// Covers [appSettingsProvider] end-to-end:
//   - build() reflects service defaults.
//   - Each setter persists through the underlying [AppSettingsService] and
//     emits a new immutable [AppSettingsState].
//   - Multiple listeners on the same [ProviderContainer] see updated state
//     after a mutation (verifies the AsyncNotifier emits, not just persists).
//
// Strategy: use the real [AppSettingsService] backed by SharedPreferences
// with `setMockInitialValues({})` — idiomatic for this codebase (see
// test/services/app_settings_service_test.dart). The service is a thin pref
// wrapper; faking it would add no signal. We override
// [appSettingsServiceProvider] in the container only when we need to seed
// non-default initial pref values.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/settings/app_settings_service.dart';
import 'package:sealed_app/providers/app_settings_provider.dart';

ProviderContainer _containerWithPrefs(Map<String, Object> initial) {
  SharedPreferences.setMockInitialValues(initial);
  return ProviderContainer(
    overrides: [
      // Inject a fresh service over freshly-mocked prefs so each test starts
      // from a known baseline. The override returns a Future to match the
      // FutureProvider signature.
      appSettingsServiceProvider.overrideWith((ref) async {
        final prefs = await SharedPreferences.getInstance();
        return AppSettingsService(prefs: prefs);
      }),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('appSettingsProvider — build()', () {
    test('returns state matching service defaults (empty prefs)', () async {
      final c = _containerWithPrefs({});
      addTearDown(c.dispose);

      final state = await c.read(appSettingsProvider.future);

      // Service defaults: targetedPush = false, autoSync = true.
      expect(state.targetedPushEnabled, isFalse);
      expect(state.autoSyncEnabled, isTrue);
    });

    test('returns state matching pre-seeded pref values', () async {
      final c = _containerWithPrefs({
        'targeted_push_enabled': true,
        'auto_sync_enabled': false,
      });
      addTearDown(c.dispose);

      final state = await c.read(appSettingsProvider.future);

      expect(state.targetedPushEnabled, isTrue);
      expect(state.autoSyncEnabled, isFalse);
    });
  });

  group('appSettingsProvider — setters', () {
    test('setTargetedPushEnabled persists and updates state', () async {
      final c = _containerWithPrefs({});
      addTearDown(c.dispose);

      // Ensure build() resolves before mutating.
      await c.read(appSettingsProvider.future);

      await c.read(appSettingsProvider.notifier).setTargetedPushEnabled(true);

      final state = c.read(appSettingsProvider).requireValue;
      expect(state.targetedPushEnabled, isTrue);
      // Other field untouched.
      expect(state.autoSyncEnabled, isTrue);

      // Underlying pref actually flipped.
      final service = await c.read(appSettingsServiceProvider.future);
      expect(service.targetedPushEnabled, isTrue);
    });

    test('setAutoSyncEnabled persists and updates state', () async {
      final c = _containerWithPrefs({});
      addTearDown(c.dispose);

      await c.read(appSettingsProvider.future);

      await c.read(appSettingsProvider.notifier).setAutoSyncEnabled(false);

      final state = c.read(appSettingsProvider).requireValue;
      expect(state.autoSyncEnabled, isFalse);
      expect(state.targetedPushEnabled, isFalse);

      final service = await c.read(appSettingsServiceProvider.future);
      expect(service.autoSyncEnabled, isFalse);
    });

    test('alias-push pass-through persists per-contact', () async {
      final c = _containerWithPrefs({});
      addTearDown(c.dispose);

      await c.read(appSettingsProvider.future);
      final notifier = c.read(appSettingsProvider.notifier);

      expect(notifier.getAliasPushEnabled('c1'), isFalse);
      await notifier.setAliasPushEnabled('c1', true);
      expect(notifier.getAliasPushEnabled('c1'), isTrue);
      expect(notifier.getAliasPushEnabled('c2'), isFalse);

      // Consent dialog flag round-trips.
      expect(notifier.getAliasPushConsentShown('c1'), isFalse);
      await notifier.setAliasPushConsentShown('c1', true);
      expect(notifier.getAliasPushConsentShown('c1'), isTrue);
    });

    test('listEnabledAliasContactIds returns enabled set', () async {
      final c = _containerWithPrefs({});
      addTearDown(c.dispose);

      await c.read(appSettingsProvider.future);
      final notifier = c.read(appSettingsProvider.notifier);

      await notifier.setAliasPushEnabled('a', true);
      await notifier.setAliasPushEnabled('b', false);
      await notifier.setAliasPushEnabled('c', true);

      final ids = notifier.listEnabledAliasContactIds()..sort();
      expect(ids, equals(['a', 'c']));
    });

    test('clearAllAliasPushFlags wipes alias prefs only', () async {
      final c = _containerWithPrefs({});
      addTearDown(c.dispose);

      await c.read(appSettingsProvider.future);
      final notifier = c.read(appSettingsProvider.notifier);

      // Seed: enable alias push + consent for a contact, plus global push.
      await notifier.setAliasPushEnabled('a', true);
      await notifier.setAliasPushConsentShown('a', true);
      await notifier.setTargetedPushEnabled(true);

      await notifier.clearAllAliasPushFlags();

      expect(notifier.getAliasPushEnabled('a'), isFalse);
      expect(notifier.getAliasPushConsentShown('a'), isFalse);
      // Global push untouched.
      expect(
        c.read(appSettingsProvider).requireValue.targetedPushEnabled,
        isTrue,
      );
    });
  });

  group('appSettingsProvider — multi-consumer propagation', () {
    test(
      'second listener sees state updated by mutation through the notifier',
      () async {
        final c = _containerWithPrefs({});
        addTearDown(c.dispose);

        await c.read(appSettingsProvider.future);

        // Consumer A: tracks emissions.
        final emissionsA = <AppSettingsState>[];
        final subA = c.listen<AsyncValue<AppSettingsState>>(
          appSettingsProvider,
          (_, next) => next.whenData(emissionsA.add),
          fireImmediately: true,
        );
        addTearDown(subA.close);

        // Consumer B: separate listener on the same container.
        final emissionsB = <AppSettingsState>[];
        final subB = c.listen<AsyncValue<AppSettingsState>>(
          appSettingsProvider,
          (_, next) => next.whenData(emissionsB.add),
          fireImmediately: true,
        );
        addTearDown(subB.close);

        // Mutate via notifier.
        await c.read(appSettingsProvider.notifier).setTargetedPushEnabled(true);

        // Both consumers should observe both the initial state and the
        // post-mutation state.
        expect(emissionsA.length, greaterThanOrEqualTo(2));
        expect(emissionsB.length, greaterThanOrEqualTo(2));
        expect(emissionsA.last.targetedPushEnabled, isTrue);
        expect(emissionsB.last.targetedPushEnabled, isTrue);

        // Direct read through the container also reflects the change.
        expect(
          c.read(appSettingsProvider).requireValue.targetedPushEnabled,
          isTrue,
        );
      },
    );
  });

  group('AppSettingsState', () {
    test('copyWith preserves untouched fields', () {
      const a = AppSettingsState(
        targetedPushEnabled: false,
        autoSyncEnabled: true,
      );
      final b = a.copyWith(targetedPushEnabled: true);
      expect(b.targetedPushEnabled, isTrue);
      expect(b.autoSyncEnabled, isTrue);

      final c = a.copyWith(autoSyncEnabled: false);
      expect(c.targetedPushEnabled, isFalse);
      expect(c.autoSyncEnabled, isFalse);
    });

    test('value equality + hashCode', () {
      const a = AppSettingsState(
        targetedPushEnabled: true,
        autoSyncEnabled: false,
      );
      const b = AppSettingsState(
        targetedPushEnabled: true,
        autoSyncEnabled: false,
      );
      const c = AppSettingsState(
        targetedPushEnabled: false,
        autoSyncEnabled: false,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
