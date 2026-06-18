import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sealed_app/features/settings/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettingsService per-alias push prefs', () {
    late AppSettingsService svc;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      svc = AppSettingsService(prefs: prefs);
    });

    test('getAliasPushEnabled defaults to false', () {
      expect(svc.getAliasPushEnabled('c1'), isFalse);
    });

    test('setAliasPushEnabled / getAliasPushEnabled round-trip', () async {
      await svc.setAliasPushEnabled('c1', true);
      expect(svc.getAliasPushEnabled('c1'), isTrue);
      expect(svc.getAliasPushEnabled('c2'), isFalse);
      await svc.setAliasPushEnabled('c1', false);
      expect(svc.getAliasPushEnabled('c1'), isFalse);
    });

    test('consent flag defaults false and round-trips', () async {
      expect(svc.getAliasPushConsentShown('c1'), isFalse);
      await svc.setAliasPushConsentShown('c1', true);
      expect(svc.getAliasPushConsentShown('c1'), isTrue);
    });

    test('listEnabledAliasContactIds returns only true entries', () async {
      await svc.setAliasPushEnabled('a', true);
      await svc.setAliasPushEnabled('b', false);
      await svc.setAliasPushEnabled('c', true);
      final ids = svc.listEnabledAliasContactIds()..sort();
      expect(ids, equals(['a', 'c']));
    });

    test('clearAllAliasPushFlags wipes enabled + consent flags', () async {
      await svc.setAliasPushEnabled('a', true);
      await svc.setAliasPushConsentShown('a', true);
      await svc.setAliasPushEnabled('b', true);
      await svc.setTargetedPushEnabled(true);

      await svc.clearAllAliasPushFlags();

      expect(svc.getAliasPushEnabled('a'), isFalse);
      expect(svc.getAliasPushEnabled('b'), isFalse);
      expect(svc.getAliasPushConsentShown('a'), isFalse);
      // Global push pref untouched.
      expect(svc.targetedPushEnabled, isTrue);
    });
  });
}
