///  AliasKeyService dual X25519 keypair (enc + scan) round-trip tests.
///
/// Bootstrap payload v2 carries both an enc pubkey and a scan pubkey, so
/// `generateTempKeyPair` must persist two independent keypairs and
/// `loadTempKeyPair` must return both. Verified:
///  - generate → load round-trip produces matching bytes for both roles
///  - enc and scan keypairs are independent (different bytes)
///  - eraseTempKeys removes both
///  - getTempKeyPairForCrypto returns the enc role
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/contact.dart';
import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  @override
  Map<String, List<ValueChanged<String?>>> get getListeners => const {};

  final Map<String, String> _store = {};

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
      _store.remove(key);
    } else {
      _store[key] = value;
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
  }) async => _store[key];

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
    _store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_store);

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.containsKey(key);

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.clear();
  }

  // Unused getters — match interface defaults.
  @override
  IOSOptions get iOptions => IOSOptions.defaultOptions;
  @override
  AndroidOptions get aOptions => AndroidOptions.defaultOptions;
  @override
  LinuxOptions get lOptions => LinuxOptions.defaultOptions;
  @override
  WindowsOptions get wOptions => WindowsOptions.defaultOptions;
  @override
  WebOptions get webOptions => WebOptions.defaultOptions;
  @override
  MacOsOptions get mOptions => MacOsOptions.defaultOptions;

  @override
  void registerListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {}
  @override
  void unregisterListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {}
  @override
  void unregisterAllListenersForKey({required String key}) {}
  @override
  void unregisterAllListeners() {}

  @override
  Future<bool?> isCupertinoProtectedDataAvailable() async => true;

  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged =>
      const Stream.empty();
}

/// Minimal fake [ContactRepository] for alias scan_priv lookup tests.
/// All methods other than [getAliasContact] / [getAllAliasContacts] throw via
/// [noSuchMethod] — none should be exercised by [AliasKeyService].
class _FakeContactRepository implements ContactRepository {
  final Map<String, AliasContact> _byId = {};

  void put(AliasContact c) {
    _byId[c.contactId] = c;
  }

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

void main() {
  group('AliasKeyService dual X25519 (enc + scan)', () {
    late AliasKeyService svc;

    setUp(() {
      svc = AliasKeyService(storage: _FakeSecureStorage());
    });

    test('generate returns 32B enc + scan pubkeys, persists both', () async {
      final out = await svc.generateTempKeyPair('secret-A');
      expect(out.enc.publicKey, hasLength(32));
      expect(out.enc.privateKey, hasLength(32));
      expect(out.scan.publicKey, hasLength(32));
      expect(out.scan.privateKey, hasLength(32));

      final loaded = await svc.loadTempKeyPair('secret-A');
      expect(loaded, isNotNull);
      expect(loaded!.enc.privateKey, equals(out.enc.privateKey));
      expect(loaded.enc.publicKey, equals(out.enc.publicKey));
      expect(loaded.scan.privateKey, equals(out.scan.privateKey));
      expect(loaded.scan.publicKey, equals(out.scan.publicKey));
    });

    test('enc and scan keypairs are independent', () async {
      final out = await svc.generateTempKeyPair('secret-B');
      expect(out.enc.privateKey, isNot(equals(out.scan.privateKey)));
      expect(out.enc.publicKey, isNot(equals(out.scan.publicKey)));
    });

    test('loadTempKeyPair returns null when nothing stored', () async {
      expect(await svc.loadTempKeyPair('missing'), isNull);
    });

    test('eraseTempKeys clears both enc and scan keypairs', () async {
      await svc.generateTempKeyPair('secret-C');
      expect(await svc.loadTempKeyPair('secret-C'), isNotNull);
      await svc.eraseTempKeys('secret-C');
      expect(await svc.loadTempKeyPair('secret-C'), isNull);
    });

    test(
      'loadAliasScanPrivForContact returns null without contact repo',
      () async {
        expect(await svc.loadAliasScanPrivForContact('x'), isNull);
      },
    );

    test('loadAllAliasScanPrivs returns [] without contact repo', () async {
      expect(await svc.loadAllAliasScanPrivs(), isEmpty);
    });

    test('loadAliasScanPrivForContact returns scanSk from repo', () async {
      final repo = _FakeContactRepository();
      final scanSk = Uint8List.fromList(List<int>.generate(32, (i) => i));
      repo.put(_makeAlias('c1', scanSk));
      final s = AliasKeyService(
        storage: _FakeSecureStorage(),
        contactRepository: repo,
      );
      expect(await s.loadAliasScanPrivForContact('c1'), equals(scanSk));
      expect(await s.loadAliasScanPrivForContact('missing'), isNull);
    });

    test('loadAllAliasScanPrivs maps every contact', () async {
      final repo = _FakeContactRepository();
      final a = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final b = Uint8List.fromList(List<int>.generate(32, (i) => 31 - i));
      repo.put(_makeAlias('c1', a));
      repo.put(_makeAlias('c2', b));
      final s = AliasKeyService(
        storage: _FakeSecureStorage(),
        contactRepository: repo,
      );
      final all = await s.loadAllAliasScanPrivs();
      expect(all, hasLength(2));
      final ids = all.map((e) => e.contactId).toSet();
      expect(ids, equals({'c1', 'c2'}));
      for (final e in all) {
        expect(e.scanPriv.length, 32);
      }
    });

    test('getTempKeyPairForCrypto returns the enc-role keypair', () async {
      final out = await svc.generateTempKeyPair('secret-D');
      final kp = await svc.getTempKeyPairForCrypto('secret-D');
      expect(kp, isNotNull);
      final priv = await kp!.extractPrivateKeyBytes();
      final pub = (await kp.extractPublicKey()).bytes;
      expect(priv, equals(out.enc.privateKey));
      expect(pub, equals(out.enc.publicKey));
    });
  });
}
