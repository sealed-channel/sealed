/// Unit tests for the sync cursor + lifecycle safety added in Phase 2:
///   • a fetch failure must NOT advance the cursor (no permanent message loss)
///   • a failed sync sets SyncStatus.error and rethrows
///   • missing keys (locked device) aborts cleanly without advancing the cursor
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/messaging/message_sync.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local/repositories/test_db.dart';

// ─── Fakes ──────────────────────────────────────────────────────────────────

class _Fake<T> {
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Chain client whose message fetch always fails — simulates an indexer/OHTTP
/// outage mid-sync.
class _ThrowingChainClient extends _Fake implements SealedChainClient {
  @override
  Future<List<Map<String, dynamic>>> fetchMessages({
    int? sinceTimestamp,
    int limit = 200,
  }) async => throw Exception('indexer unreachable');
}

class _FakeChainClient extends _Fake implements SealedChainClient {}

class _FakeCryptoService extends _Fake implements CryptoService {}

/// Key service with a configurable loadKeys() result.
class _StubKeyService extends _Fake implements KeyService {
  final SealedKeys? keys;
  _StubKeyService(this.keys);
  @override
  Future<SealedKeys?> loadKeys() async => keys;
}

class _FakeContacts extends _Fake implements ContactRepository {}

/// Sync repo that records whether the cursor was advanced.
class _RecordingSyncRepo extends _Fake implements SyncRepository {
  bool updateCalled = false;
  @override
  Future<DateTime> get lastSyncTime async =>
      DateTime.fromMillisecondsSinceEpoch(0);
  @override
  Future<void> updateLastSyncTime(DateTime time) async => updateCalled = true;
}

class _FakeKem extends _Fake implements MessageKemHandshake {}

// ─── Helpers ──────────────────────────────────────────────────────────────

Future<SealedKeys> _buildKeys() async {
  final x = X25519();
  final encKp = await x.newKeyPairFromSeed(Uint8List(32));
  final scanKp = await x.newKeyPairFromSeed(Uint8List(32)..[0] = 1);
  return SealedKeys(
    encryptionKeyPair: encKp,
    scanKeyPair: scanKp,
    walletAddress: 'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI',
    scanPubkey: Uint8List(32),
    encryptionPubkey: Uint8List(32),
    encryptionPrivateKey: Uint8List(32),
    viewPrivateKey: Uint8List(32),
    pqPublicKey: Uint8List(800),
    pqPrivateKey: Uint8List(1632),
  );
}

late TestLocalDatabase _db;
late MessageRepositoryImpl _cache;

Future<void> _setUp() async {
  sqfliteFfiInit();
  _db = await TestLocalDatabase.open();
  _cache = MessageRepositoryImpl(localDatabase: _db);
}

Future<void> _tearDown() async => _db.close();

MessageSync _build({
  required SealedChainClient client,
  required KeyService keyService,
  required SyncRepository syncState,
}) => MessageSync(
  sealedClient: client,
  cryptoService: _FakeCryptoService(),
  keyService: keyService,
  contacts: _FakeContacts(),
  messageCache: _cache,
  syncState: syncState,
  kem: _FakeKem(),
);

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUp);
  tearDown(_tearDown);

  test(
    'fetch failure rethrows, holds the cursor, and sets error status',
    () async {
      final keys = await _buildKeys();
      final syncRepo = _RecordingSyncRepo();
      final sync = _build(
        client: _ThrowingChainClient(),
        keyService: _StubKeyService(keys),
        syncState: syncRepo,
      );

      await expectLater(sync.syncMessages(), throwsA(isA<Exception>()));

      expect(
        syncRepo.updateCalled,
        isFalse,
        reason: 'cursor must NOT advance when the fetch failed',
      );
      expect(sync.syncStatus, SyncStatus.error);
    },
  );

  test('missing keys aborts cleanly without advancing the cursor', () async {
    final syncRepo = _RecordingSyncRepo();
    final sync = _build(
      client: _FakeChainClient(), // must never be touched
      keyService: _StubKeyService(null),
      syncState: syncRepo,
    );

    final count = await sync.syncMessages();

    expect(count, 0);
    expect(
      syncRepo.updateCalled,
      isFalse,
      reason: 'a locked device must not advance the cursor',
    );
    expect(sync.syncStatus, SyncStatus.idle);
  });
}
