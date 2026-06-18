/// T8 ordering guard: `performLogout` in `lib/features/auth/wipe.dart` must
/// call `indexerService.unregisterAllAliasViewKeys()` **BEFORE**
/// `aliasKeyService.deleteAllChannels()`. Otherwise the scan_priv bytes
/// needed to derive each alias row's `blinded_id` are wiped before the
/// unregister request leaves the device, and indexer push rows leak.
///
/// We cannot exercise `performLogout` end-to-end in a unit test — it pulls
/// the SQLCipher DB, secure storage, push subsystem, and a dozen providers.
/// Instead we lock the source-order invariant: the unregister call must
/// appear earlier in `wipe.dart` than the deleteAllChannels call. A
/// refactor that reorders them tips this test red.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('performLogout calls unregisterAllAliasViewKeys before '
      'aliasKeyService.deleteAllChannels (T8 ordering guard)', () async {
    final src = await File('lib/features/auth/wipe.dart').readAsString();

    // Match the actual `await ...unregisterAllAliasViewKeys()` and
    // `.deleteAllChannels()` invocations — not their references inside the
    // explanatory comment block.
    final unregMatch = RegExp(
      r'await\s+\w+\.unregisterAllAliasViewKeys\(',
    ).firstMatch(src);
    final deleteMatch =
        RegExp(
          r'\)\.deleteAllChannels\(\)|aliasKeyServiceProvider\)\.deleteAllChannels\(\)',
        ).firstMatch(src) ??
        RegExp(r'\.deleteAllChannels\(\)').firstMatch(src);

    expect(
      unregMatch,
      isNotNull,
      reason: 'wipe.dart must invoke unregisterAllAliasViewKeys()',
    );
    expect(
      deleteMatch,
      isNotNull,
      reason: 'wipe.dart must invoke aliasKeyService.deleteAllChannels()',
    );
    expect(
      unregMatch!.start < deleteMatch!.start,
      isTrue,
      reason:
          'CRITICAL: unregisterAllAliasViewKeys() MUST appear before '
          'deleteAllChannels() in wipe.dart. Reordering wipes alias scan '
          'keys before the indexer is notified — push rows leak.',
    );
  });

  test('performLogout also clears alias push flags (T8)', () async {
    final src = await File('lib/features/auth/wipe.dart').readAsString();
    expect(
      src.contains('clearAllAliasPushFlags'),
      isTrue,
      reason:
          'wipe.dart must call settings.clearAllAliasPushFlags() so '
          'per-alias prefs do not survive logout.',
    );
  });

  test(
    'wipeAll destroys local secrets BEFORE network cleanup (T10 duress)',
    () async {
      final src = await File('lib/features/auth/wipe.dart').readAsString();

      final start = src.indexOf('Future<void> wipeAll()');
      expect(start, greaterThanOrEqualTo(0), reason: 'wipeAll() must exist');
      final body = src.substring(start);

      final destroyIdx = body.indexOf('_destroyLocalSecrets(');
      final logoutIdx = body.indexOf('performLogout(');

      expect(
        destroyIdx,
        greaterThanOrEqualTo(0),
        reason: 'wipeAll must destroy local secrets explicitly',
      );
      expect(
        logoutIdx,
        greaterThanOrEqualTo(0),
        reason: 'wipeAll must run logout/network cleanup',
      );
      expect(
        destroyIdx < logoutIdx,
        isTrue,
        reason:
            'CRITICAL: under duress, local secret destruction MUST precede the '
            'network unregister in performLogout — otherwise a blackholed '
            'network keeps the seed/DEK alive during the wipe.',
      );
    },
  );

  test('wipeAll uses an accessibility-agnostic deleteAll (T11)', () async {
    final src = await File('lib/features/auth/wipe.dart').readAsString();
    expect(
      RegExp(
        r'deleteAll\(\s*iOptions:\s*const IOSOptions\(accessibility: null\)',
      ).hasMatch(src),
      isTrue,
      reason:
          'wipe must delete secure-storage items under any accessibility so '
          'first_unlock keys cannot survive the wipe (flutter_secure_storage '
          'v10 filters deletes by kSecAttrAccessible).',
    );
  });
}
