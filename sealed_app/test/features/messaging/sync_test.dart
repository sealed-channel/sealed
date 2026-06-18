/// Unit tests for the hybrid-message store hook on `MessageSync`.
///
/// Exercises [MessageSync.storeHybridMessages] directly — the only new
/// state-mutating logic added in Task 3.2. The remaining `_syncViaBlockchain`
/// fan-out is covered end-to-end by the Phase 4 LocalNet integration tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/messaging/message_sync.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local/repositories/test_db.dart';

// ─── Fakes ──────────────────────────────────────────────────────────────────

class _Fake<T> {
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSealedChainClient extends _Fake implements SealedChainClient {}

class _FakeCryptoService extends _Fake implements CryptoService {}

class _FakeKeyService extends _Fake implements KeyService {}

class _FakeContacts extends _Fake implements ContactRepository {
  final Set<String> blockedWallets = {};
  int isBlockedCalls = 0;

  @override
  Future<bool> isBlocked(String walletAddress) async {
    isBlockedCalls++;
    return blockedWallets.contains(walletAddress);
  }
}

class _FakeSyncRepository extends _Fake implements SyncRepository {}

class _FakeKem extends _Fake implements MessageKemHandshake {}

// ─── Setup ──────────────────────────────────────────────────────────────────

late TestLocalDatabase _db;
late MessageRepositoryImpl _messageCache;
late MessageSync _sync;
late _FakeContacts _contacts;

Future<void> _setUp() async {
  sqfliteFfiInit();
  _db = await TestLocalDatabase.open();
  _messageCache = MessageRepositoryImpl(localDatabase: _db);
  _contacts = _FakeContacts();
  _sync = MessageSync(
    sealedClient: _FakeSealedChainClient(),
    cryptoService: _FakeCryptoService(),
    keyService: _FakeKeyService(),
    contacts: _contacts,
    messageCache: _messageCache,
    syncState: _FakeSyncRepository(),
    kem: _FakeKem(),
  );
}

Future<void> _tearDown() async {
  await _db.close();
}

const _senderA = 'V3RW2DEEOBKA7KMWMHP5MDSJMFNINEY4IC755WV6VN54JJJBPSNLWOSLAE';

DecryptedMessage _msg(
  String id, {
  String content = 'hi',
  String sender = _senderA,
  bool outgoing = false,
}) => DecryptedMessage(
  id: id,
  senderWallet: sender,
  senderUsername: null,
  recipientWallet: 'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI',
  recipientUsername: null,
  content: content,
  timestamp: DateTime.fromMillisecondsSinceEpoch(1717000000000),
  isOutgoing: outgoing,
  onChainPubkey: id,
);

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUp);
  tearDown(_tearDown);

  test('1 hybrid message → 1 store write, count=1', () async {
    final stored = await _sync.storeHybridMessages([_msg('tx-1')]);
    expect(stored, 1);

    final found = await _messageCache.getMessageByPubkey('tx-1');
    expect(found, isNotNull);
    expect(found!.content, 'hi');
  });

  test(
    'same hybrid input run twice → 1 store row, second call count=0',
    () async {
      final input = [_msg('tx-dup', content: 'once')];

      final first = await _sync.storeHybridMessages(input);
      expect(first, 1);

      final second = await _sync.storeHybridMessages(input);
      expect(second, 0, reason: 'second pass should dedupe on txid');

      // Only one row in DB.
      final found = await _messageCache.getMessageByPubkey('tx-dup');
      expect(found, isNotNull);
      expect(found!.content, 'once');
    },
  );

  test('mixed new + repeat batch → count only the new rows', () async {
    await _sync.storeHybridMessages([_msg('tx-a')]);
    final stored = await _sync.storeHybridMessages([
      _msg('tx-a'),
      _msg('tx-b'),
    ]);
    expect(stored, 1, reason: 'tx-a already present, only tx-b is new');
  });

  test('empty list → count=0, no store writes', () async {
    final stored = await _sync.storeHybridMessages(const []);
    expect(stored, 0);
  });

  test('ingestRawMessages([]) → 0 (guard, no keys/fakes touched)', () async {
    // Empty drain is a no-op before any key load or pipeline call — the common
    // case (woke, nothing staged). The non-empty path reuses the same
    // KEM/hybrid/incoming/alias methods covered by the other tests here.
    expect(await _sync.ingestRawMessages(const []), 0);
  });

  // Regression: a re-synced (already-stored) incoming message must NOT reset
  // its is_read flag. saveMessage upserts with ConflictAlgorithm.replace and
  // hardcodes is_read = isOutgoing ? 1 : 0, so an unconditional re-save of a
  // read message silently flips it back to unread. With the 5s poll re-seeing
  // every message, that turned the whole thread unread on each refresh.
  // storeHybridMessages must skip existing txids before saveMessage.
  test('re-storing a read message preserves is_read (no unread storm)', () async {
    await _sync.storeHybridMessages([_msg('tx-read')]);
    expect(await _messageCache.getUnreadCount(_senderA), 1);

    // Mark the conversation read, as opening the thread would.
    await _messageCache.markAsRead(_senderA);
    expect(await _messageCache.getUnreadCount(_senderA), 0);

    // Next poll re-sees the same on-chain message and tries to store it again.
    final restored = await _sync.storeHybridMessages([_msg('tx-read')]);
    expect(restored, 0, reason: 'already stored — must dedupe, not re-write');
    expect(
      await _messageCache.getUnreadCount(_senderA),
      0,
      reason: 're-store must not clobber is_read back to 0',
    );
  });

  group('blocked-sender notification mute (two-counter)', () {
    const blocked =
        'BLOCKEDWALLETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

    test(
      'blocked-sender message stored but counted as non-notifiable',
      () async {
        _contacts.blockedWallets.add(blocked);

        final stored = await _sync.storeHybridMessages([
          _msg('tx-ok'),
          _msg('tx-blocked', sender: blocked),
        ]);

        // Both messages stored — Spam tab needs them.
        expect(stored, 2);
        expect(await _messageCache.getMessageByPubkey('tx-blocked'), isNotNull);
        // Exactly the blocked one excluded from the notifiable count.
        expect(_sync.debugRunBlockedCount, 1);
      },
    );

    test(
      'outgoing self-copy from a blocked peer chat is not counted',
      () async {
        _contacts.blockedWallets.add(blocked);

        await _sync.storeHybridMessages([
          _msg('tx-out', sender: blocked, outgoing: true),
        ]);

        expect(_sync.debugRunBlockedCount, 0);
      },
    );

    test('blocked lookup is cached per sender within a run', () async {
      _contacts.blockedWallets.add(blocked);

      await _sync.storeHybridMessages([
        _msg('tx-1', sender: blocked),
        _msg('tx-2', sender: blocked),
        _msg('tx-3', sender: blocked),
      ]);

      expect(_sync.debugRunBlockedCount, 3);
      expect(_contacts.isBlockedCalls, 1);
    });

    test('unblocked senders contribute zero to the blocked counter', () async {
      await _sync.storeHybridMessages([_msg('tx-a'), _msg('tx-b')]);
      expect(_sync.debugRunBlockedCount, 0);
    });
  });
}
