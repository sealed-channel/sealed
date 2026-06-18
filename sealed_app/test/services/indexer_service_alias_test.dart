import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/models/contact.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';
import 'package:sealed_app/infra/network/indexer_service.dart';
import 'package:sealed_app/features/settings/app_settings_service.dart';

/// Fake [IndexerClient] that records calls and returns canned results.
/// Bypasses Dio entirely by extending the real client with a dummy base URL.
class _FakeIndexerClient extends IndexerClient {
  _FakeIndexerClient() : super(baseUrl: 'https://example.invalid');

  final List<
    ({Uint8List viewKey, String token, String platform, String? wallet})
  >
  registerCalls = [];
  final List<Uint8List> unregisterCalls = [];

  bool registerSucceeds = true;
  bool unregisterSucceeds = true;

  @override
  Future<IndexerResult<PushTokenRegistrationResponse>> registerPushToken({
    required Uint8List viewKey,
    required String token,
    required String platform,
    String? wallet,
  }) async {
    registerCalls.add((
      viewKey: viewKey,
      token: token,
      platform: platform,
      wallet: wallet,
    ));
    return IndexerSuccess(
      PushTokenRegistrationResponse(success: registerSucceeds, error: null),
    );
  }

  @override
  Future<IndexerResult<PushTokenRegistrationResponse>> unregisterPushToken({
    required Uint8List viewKey,
  }) async {
    unregisterCalls.add(viewKey);
    return IndexerSuccess(
      PushTokenRegistrationResponse(success: unregisterSucceeds, error: null),
    );
  }
}

class _FakeSyncRepository implements SyncRepository {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeKeyService implements KeyService {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeContactRepository implements ContactRepository {
  final Map<String, AliasContact> _byId = {};
  void put(AliasContact c) => _byId[c.contactId] = c;

  @override
  Future<AliasContact?> getAliasContact(String contactId) async =>
      _byId[contactId];
  @override
  Future<List<AliasContact>> getAllAliasContacts() async =>
      _byId.values.toList();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used in test: ${invocation.memberName}');
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _s = {};
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _s.remove(key);
    } else {
      _s[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _s[key];
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _s.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

AliasContact _makeAlias(String id, Uint8List scanSk) {
  final z = Uint8List(32);
  return AliasContact(
    contactId: id,
    nickname: id,
    createdAt: 0,
    keys: ContactKeys(
      sharedSecret: z,
      recipientTag: z,
      msgKey: z,
      peerX25519Pub: z,
      peerX25519Scan: z,
      myX25519Sk: z,
      myX25519ScanSk: scanSk,
      tagSalt: z,
    ),
    aliasHandle: id,
    inviteRef: 'ref_$id',
    isCreator: true,
  );
}

Uint8List _scanFor(int b) =>
    Uint8List.fromList(List<int>.generate(32, (_) => b));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeIndexerClient client;
  late _FakeContactRepository repo;
  late AliasKeyService aliasSvc;
  late AppSettingsService settings;
  late IndexerService svc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    client = _FakeIndexerClient();
    repo = _FakeContactRepository();
    aliasSvc = AliasKeyService(
      storage: _FakeSecureStorage(),
      contactRepository: repo,
    );
    settings = AppSettingsService(prefs: prefs);
    svc =
        IndexerService(
            indexerClient: client,
            syncState: _FakeSyncRepository(),
            keyService: _FakeKeyService(),
            aliasKeyService: aliasSvc,
            appSettings: settings,
          )
          ..debugPlatformTokenOverride = 'TESTTOKEN'
          ..debugPlatformOverride = 'ios';
  });

  group('IndexerService alias push', () {
    test('registerAliasViewKey forwards viewKey + token to client', () async {
      final scan = _scanFor(7);
      final ok = await svc.registerAliasViewKey(aliasScanPriv: scan);
      expect(ok, isTrue);
      expect(client.registerCalls, hasLength(1));
      expect(client.registerCalls.single.viewKey, equals(scan));
      expect(client.registerCalls.single.token, 'TESTTOKEN');
      expect(client.registerCalls.single.platform, 'ios');
    });

    test('registerAliasViewKey rejects wrong-sized scan key', () async {
      final ok = await svc.registerAliasViewKey(
        aliasScanPriv: Uint8List.fromList([1, 2, 3]),
      );
      expect(ok, isFalse);
      expect(client.registerCalls, isEmpty);
    });

    test('unregisterAliasViewKey forwards viewKey to client', () async {
      final scan = _scanFor(9);
      final ok = await svc.unregisterAliasViewKey(aliasScanPriv: scan);
      expect(ok, isTrue);
      expect(client.unregisterCalls, hasLength(1));
      expect(client.unregisterCalls.single, equals(scan));
    });

    test(
      'registerEnabledAliasViewKeys: skipped when global push off',
      () async {
        repo.put(_makeAlias('a', _scanFor(1)));
        await settings.setAliasPushEnabled('a', true);
        // global push remains off
        await svc.registerEnabledAliasViewKeys();
        expect(client.registerCalls, isEmpty);
      },
    );

    test(
      'registerEnabledAliasViewKeys: registers only opted-in aliases when global on',
      () async {
        repo.put(_makeAlias('a', _scanFor(1)));
        repo.put(_makeAlias('b', _scanFor(2)));
        repo.put(_makeAlias('c', _scanFor(3)));
        await settings.setTargetedPushEnabled(true);
        await settings.setAliasPushEnabled('a', true);
        await settings.setAliasPushEnabled('c', true);
        // 'b' left off.

        await svc.registerEnabledAliasViewKeys();

        final keysSent =
            client.registerCalls.map((c) => c.viewKey.toList()).toList()
              ..sort((a, b) => a.first.compareTo(b.first));
        expect(keysSent, hasLength(2));
        expect(keysSent[0], equals(_scanFor(1).toList()));
        expect(keysSent[1], equals(_scanFor(3).toList()));
      },
    );

    test(
      'unregisterAllAliasViewKeys: unregisters every alias contact',
      () async {
        repo.put(_makeAlias('a', _scanFor(1)));
        repo.put(_makeAlias('b', _scanFor(2)));
        await svc.unregisterAllAliasViewKeys();
        final sent = client.unregisterCalls.map((k) => k.toList()).toList()
          ..sort((a, b) => a.first.compareTo(b.first));
        expect(sent, equals([_scanFor(1).toList(), _scanFor(2).toList()]));
      },
    );

    test(
      'unregisterAllAliasViewKeys: no-op when aliasKeyService not wired',
      () async {
        final bare = IndexerService(
          indexerClient: client,
          syncState: _FakeSyncRepository(),
          keyService: _FakeKeyService(),
        );
        await bare.unregisterAllAliasViewKeys();
        expect(client.unregisterCalls, isEmpty);
      },
    );
  });
}
