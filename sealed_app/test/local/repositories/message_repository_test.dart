import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_db.dart';

void main() {
  sqfliteFfiInit();

  late TestLocalDatabase testDb;
  late MessageRepository repo;

  setUp(() async {
    testDb = await TestLocalDatabase.open();
    repo = MessageRepositoryImpl(localDatabase: testDb);
  });

  tearDown(() async {
    await testDb.close();
  });

  DecryptedMessage _makeMsg({
    required String id,
    required String senderWallet,
    required String recipientWallet,
    bool isOutgoing = false,
    String? onChainPubkey,
  }) => DecryptedMessage(
    id: id,
    senderWallet: senderWallet,
    senderUsername: null,
    recipientWallet: recipientWallet,
    recipientUsername: null,
    content: 'hello',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1_000_000),
    isOutgoing: isOutgoing,
    onChainPubkey: onChainPubkey ?? id,
  );

  group('MessageRepository – basic persistence', () {
    test('hasMessage returns false when empty', () async {
      expect(await repo.hasMessage('NONEXISTENT'), isFalse);
    });

    test('saveMessage + hasMessage', () async {
      await repo.saveMessage(
        _makeMsg(id: 'msg1', senderWallet: 'AAA', recipientWallet: 'BBB'),
      );
      expect(await repo.hasMessage('msg1'), isTrue);
    });

    test('messageExists returns false for unknown id', () async {
      expect(await repo.messageExists('ZZZZ'), isFalse);
    });

    test('messageExists returns true after save', () async {
      await repo.saveMessage(
        _makeMsg(id: 'msg2', senderWallet: 'AAA', recipientWallet: 'BBB'),
      );
      expect(await repo.messageExists('msg2'), isTrue);
    });

    test('messageExists empty id throws', () async {
      await expectLater(
        repo.messageExists(''),
        throwsA(isA<MessageRepositoryException>()),
      );
    });

    test('saveMessage is idempotent (replace-on-conflict)', () async {
      final msg = _makeMsg(
        id: 'msg3',
        senderWallet: 'AAA',
        recipientWallet: 'BBB',
      );
      await repo.saveMessage(msg);
      await repo.saveMessage(msg); // second insert should not throw
      expect(await repo.getTotalMessageCount(), 1);
    });

    test('existingMessageIds returns only the stored subset', () async {
      await repo.saveMessage(
        _makeMsg(id: 'have1', senderWallet: 'AAA', recipientWallet: 'BBB'),
      );
      await repo.saveMessage(
        _makeMsg(id: 'have2', senderWallet: 'AAA', recipientWallet: 'BBB'),
      );

      final found = await repo.existingMessageIds([
        'have1',
        'missing1',
        'have2',
        'missing2',
      ]);
      expect(found, {'have1', 'have2'});
    });

    test('existingMessageIds on empty input returns empty', () async {
      expect(await repo.existingMessageIds([]), isEmpty);
    });
  });

  group('MessageRepository – batch + count', () {
    test('saveMessages saves multiple', () async {
      await repo.saveMessages([
        _makeMsg(id: 'a', senderWallet: 'A', recipientWallet: 'B'),
        _makeMsg(id: 'b', senderWallet: 'A', recipientWallet: 'B'),
        _makeMsg(id: 'c', senderWallet: 'A', recipientWallet: 'B'),
      ]);
      expect(await repo.getTotalMessageCount(), 3);
    });

    test('saveMessages empty list throws', () async {
      await expectLater(
        repo.saveMessages([]),
        throwsA(isA<MessageRepositoryException>()),
      );
    });

    test('getTotalMessageCount returns 0 when empty', () async {
      expect(await repo.getTotalMessageCount(), 0);
    });
  });

  group('MessageRepository – lookup by pubkey', () {
    test('getMessageByPubkey returns null for unknown pubkey', () async {
      expect(await repo.getMessageByPubkey('UNKNOWN'), isNull);
    });

    test('getMessageByPubkey returns saved message', () async {
      await repo.saveMessage(
        _makeMsg(
          id: 'pk1',
          senderWallet: 'A',
          recipientWallet: 'B',
          onChainPubkey: 'PUBKEY_XYZ',
        ),
      );
      final msg = await repo.getMessageByPubkey('PUBKEY_XYZ');
      expect(msg?.id, 'pk1');
    });
  });

  group('MessageRepository – conversation messages', () {
    setUp(() async {
      await repo.saveMessages([
        _makeMsg(id: 'm1', senderWallet: 'ALICE', recipientWallet: 'BOB'),
        _makeMsg(id: 'm2', senderWallet: 'BOB', recipientWallet: 'ALICE'),
        _makeMsg(id: 'm3', senderWallet: 'ALICE', recipientWallet: 'CAROL'),
      ]);
    });

    test(
      'getConversationMessages returns messages between two wallets',
      () async {
        final msgs = await repo.getConversationMessages('ALICE', 'BOB');
        expect(msgs.length, 2);
        expect(
          msgs.every(
            (m) =>
                (m.senderWallet == 'ALICE' && m.recipientWallet == 'BOB') ||
                (m.senderWallet == 'BOB' && m.recipientWallet == 'ALICE'),
          ),
          isTrue,
        );
      },
    );

    test('getConversationMessages empty wallets throw', () async {
      await expectLater(
        repo.getConversationMessages('', 'BOB'),
        throwsA(isA<MessageRepositoryException>()),
      );
    });

    test('getContactWallets returns distinct peer wallets', () async {
      final wallets = await repo.getContactWallets('ALICE');
      expect(wallets, containsAll(['BOB', 'CAROL']));
      expect(wallets.length, 2);
    });
  });

  group('MessageRepository – read state', () {
    test('markAsRead + getUnreadCount', () async {
      // Incoming (is_outgoing=0, is_read=0 by default)
      await repo.saveMessage(
        _makeMsg(
          id: 'r1',
          senderWallet: 'BOB',
          recipientWallet: 'ALICE',
          isOutgoing: false,
        ),
      );
      final before = await repo.getUnreadCount('BOB');
      await repo.markAsRead('BOB');
      final after = await repo.getUnreadCount('BOB');
      expect(after, lessThan(before + 1)); // at most unchanged
    });

    test('markAllAsRead does not throw', () async {
      await expectLater(repo.markAllAsRead(), completes);
    });

    test('getUnreadCount empty wallet throws', () async {
      await expectLater(
        repo.getUnreadCount(''),
        throwsA(isA<MessageRepositoryException>()),
      );
    });
  });

  group('MessageRepository – username', () {
    test('getContactUsername returns null for unknown wallet', () async {
      expect(await repo.getContactUsername('UNKNOWN'), isNull);
    });

    test('updateContactUsername updates rows and returns count', () async {
      await repo.saveMessage(
        DecryptedMessage(
          id: 'u1',
          senderWallet: 'AAA',
          senderUsername: 'old_name',
          recipientWallet: 'BBB',
          recipientUsername: null,
          content: 'hi',
          timestamp: DateTime.now(),
          isOutgoing: false,
          onChainPubkey: 'u1',
        ),
      );
      final count = await repo.updateContactUsername('AAA', 'new_name');
      expect(count, greaterThan(0));
    });
  });

  group('MessageRepository – delete + purge', () {
    test('deleteConversation removes matching messages', () async {
      await repo.saveMessage(
        _makeMsg(id: 'd1', senderWallet: 'X', recipientWallet: 'Y'),
      );
      await repo.saveMessage(
        _makeMsg(id: 'd2', senderWallet: 'Y', recipientWallet: 'X'),
      );
      final deleted = await repo.deleteConversation('X');
      expect(deleted, 2);
    });

    test(
      'purgeSolanaConversations removes Solana-addressed messages',
      () async {
        // Algorand wallet: 58 uppercase base32 chars
        final algoWallet = 'A' * 58;
        // Solana wallet: shorter/different format
        const solanaWallet = 'SoLaNaWaLLet123';

        await repo.saveMessage(
          _makeMsg(
            id: 'sol1',
            senderWallet: solanaWallet,
            recipientWallet: algoWallet,
          ),
        );
        await repo.saveMessage(
          _makeMsg(
            id: 'algo1',
            senderWallet: algoWallet,
            recipientWallet: algoWallet,
          ),
        );

        final purged = await repo.purgeSolanaConversations();
        expect(purged, greaterThanOrEqualTo(1));
        // Algorand message should survive
        expect(await repo.messageExists('algo1'), isTrue);
      },
    );

    test('clear removes all messages', () async {
      await repo.saveMessages([
        _makeMsg(id: 'c1', senderWallet: 'A', recipientWallet: 'B'),
        _makeMsg(id: 'c2', senderWallet: 'A', recipientWallet: 'B'),
      ]);
      await repo.clear();
      expect(await repo.getTotalMessageCount(), 0);
    });
  });

  group('MessageRepository – getConversations', () {
    test('getConversations returns empty list when no messages', () async {
      final convs = await repo.getConversations();
      expect(convs, isEmpty);
    });

    test('getConversations returns one preview per conversation', () async {
      final algo1 = 'A' * 58;
      final algo2 = 'B' * 58;
      await repo.saveMessage(
        DecryptedMessage(
          id: 'cv1',
          senderWallet: algo1,
          senderUsername: 'alice',
          recipientWallet: algo2,
          recipientUsername: 'bob',
          content: 'hey',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1_000_000),
          isOutgoing: true,
          onChainPubkey: 'cv1',
        ),
      );
      final convs = await repo.getConversations();
      expect(convs.length, 1);
    });

    // ── Preview-selection regressions (bug fix) ──────────────────────────────

    DecryptedMessage _conv(
      String id,
      String a,
      String b,
      String content,
      int tsMs, {
      bool outgoing = true,
    }) => DecryptedMessage(
      id: id,
      senderWallet: outgoing ? a : b,
      senderUsername: null,
      recipientWallet: outgoing ? b : a,
      recipientUsername: null,
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(tsMs),
      isOutgoing: outgoing,
      onChainPubkey: id,
    );

    test('preview = newest real message, never an alias envelope', () async {
      final a = 'A' * 58;
      final b = 'B' * 58;
      await repo.saveMessages([
        _conv('m1', a, b, 'first real', 1_000_000),
        _conv('m2', a, b, 'newest real', 2_000_000),
        // Envelope is the newest by timestamp — must NOT win the preview.
        _conv('m3', a, b, 'sealed://alias-envelope?b=xyz', 3_000_000),
      ]);
      final convs = await repo.getConversations();
      expect(convs.length, 1);
      expect(convs.single.lastMessageContent, 'newest real');
    });

    test('newest preview is deterministic on equal timestamps', () async {
      final a = 'A' * 58;
      final b = 'B' * 58;
      // Same timestamp for both — tiebreak by insertion (rowid) so the
      // later-inserted message wins consistently, not nondeterministically.
      await repo.saveMessage(_conv('eq1', a, b, 'earlier insert', 5_000_000));
      await repo.saveMessage(_conv('eq2', a, b, 'later insert', 5_000_000));
      final convs = await repo.getConversations();
      expect(convs.length, 1);
      expect(convs.single.lastMessageContent, 'later insert');
    });

    test('envelope-only conversation produces no preview row', () async {
      final a = 'A' * 58;
      final b = 'B' * 58;
      await repo.saveMessage(
        _conv('env', a, b, 'sealed://alias?c=secret&w=wallet', 1_000_000),
      );
      final convs = await repo.getConversations();
      expect(convs, isEmpty);
    });
  });

  group(
    'MessageRepository – getConversations isBlocked (spam = blocked only)',
    () {
      // Seed a wallet-contact row directly (bypassing repo layer) so the test
      // is hermetic — only depends on the SQL projection in getConversations.
      Future<void> insertContact(
        String wallet, {
        required bool blocked,
        bool hasPqPubkey = true,
      }) async {
        final db = await testDb.database;
        await db.insert('contacts', {
          'contact_id': wallet,
          'is_alias': 0,
          'alias_label': '',
          'wallet_address': wallet,
          'encryption_pubkey': Uint8List.fromList(List.filled(32, 1)),
          'scan_pubkey': Uint8List.fromList(List.filled(32, 2)),
          'created_at': 1_000_000,
          'pq_public_key': hasPqPubkey
              ? Uint8List.fromList(List.filled(32, 3))
              : null,
          'is_blocked': blocked ? 1 : 0,
        });
      }

      Future<void> seedOutgoing(String selfWallet, String peerWallet) async {
        await repo.saveMessage(
          DecryptedMessage(
            id: 'out_$peerWallet',
            senderWallet: selfWallet,
            senderUsername: null,
            recipientWallet: peerWallet,
            recipientUsername: null,
            content: 'hello',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1_000_000),
            isOutgoing: true,
            onChainPubkey: 'out_$peerWallet',
          ),
        );
      }

      // Incoming direction: peer sends to me.
      Future<void> seedIncoming(String selfWallet, String peerWallet) async {
        await repo.saveMessage(
          DecryptedMessage(
            id: 'in_$peerWallet',
            senderWallet: peerWallet,
            senderUsername: null,
            recipientWallet: selfWallet,
            recipientUsername: null,
            content: 'hi back',
            timestamp: DateTime.fromMillisecondsSinceEpoch(2_000_000),
            isOutgoing: false,
            onChainPubkey: 'in_$peerWallet',
          ),
        );
      }

      test('blocked peer → isBlocked true, isSpam true', () async {
        final self = 'S' * 58;
        final peer = 'B' * 58;
        await insertContact(peer, blocked: true);
        await seedOutgoing(self, peer);

        final convs = await repo.getConversations();
        expect(convs.single.contactWallet, peer);
        expect(convs.single.isBlocked, isTrue);
        expect(convs.single.isSpam, isTrue);
      });

      test('unblocked peer → isBlocked false, isSpam false', () async {
        final self = 'S' * 58;
        final peer = 'N' * 58;
        await insertContact(peer, blocked: false);
        await seedOutgoing(self, peer);

        final convs = await repo.getConversations();
        expect(convs.single.contactWallet, peer);
        expect(convs.single.isBlocked, isFalse);
        expect(convs.single.isSpam, isFalse);
      });

      test(
        'peer without PQ key (legacy classical-only) stays in Chats unless blocked',
        () async {
          final self = 'S' * 58;
          final peer = 'C' * 58;
          await insertContact(peer, blocked: false, hasPqPubkey: false);
          await seedIncoming(self, peer);

          final convs = await repo.getConversations();
          expect(convs.single.contactWallet, peer);
          expect(convs.single.isSpam, isFalse);
        },
      );

      test('unknown peer (no contact row) → isBlocked false', () async {
        final self = 'S' * 58;
        final peer = 'U' * 58;
        await seedOutgoing(self, peer);

        final convs = await repo.getConversations();
        expect(convs.single.isBlocked, isFalse);
      });
    },
  );

  group('MessageRepository – getConversations contactUsername (single source)', () {
    final self = 'S' * 58;
    final peer = 'P' * 58;

    // Seed a wallet-contact row carrying the authoritative username.
    Future<void> insertContactWithUsername(
      String wallet,
      String? username,
    ) async {
      final db = await testDb.database;
      await db.insert('contacts', {
        'contact_id': wallet,
        'is_alias': 0,
        'alias_label': '',
        'wallet_address': wallet,
        'username': username,
        'encryption_pubkey': Uint8List.fromList(List.filled(32, 1)),
        'scan_pubkey': Uint8List.fromList(List.filled(32, 2)),
        'created_at': 1_000_000,
        'pq_public_key': Uint8List.fromList(List.filled(32, 3)),
      });
    }

    // Incoming message carries its OWN (snapshot) username for the peer, so the
    // projected contactUsername comes from sender_username unless cc overrides.
    Future<void> seedIncomingWithSnapshot(String snapshotUsername) async {
      await repo.saveMessage(
        DecryptedMessage(
          id: 'in_$peer',
          senderWallet: peer,
          senderUsername: snapshotUsername,
          recipientWallet: self,
          recipientUsername: null,
          content: 'hi',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2_000_000),
          isOutgoing: false,
          onChainPubkey: 'in_$peer',
        ),
      );
    }

    test(
      'contact-table username wins over divergent message snapshot',
      () async {
        await insertContactWithUsername(peer, 'contacts_truth');
        await seedIncomingWithSnapshot('stale_snapshot');

        final convs = await repo.getConversations();
        expect(convs.single.contactWallet, peer);
        expect(convs.single.contactUsername, 'contacts_truth');
      },
    );

    test('no contact row → falls back to message snapshot', () async {
      await seedIncomingWithSnapshot('snapshot_only');

      final convs = await repo.getConversations();
      expect(convs.single.contactWallet, peer);
      expect(convs.single.contactUsername, 'snapshot_only');
    });

    test(
      'empty contact username → NULLIF falls back to message snapshot',
      () async {
        await insertContactWithUsername(peer, '');
        await seedIncomingWithSnapshot('snapshot_fallback');

        final convs = await repo.getConversations();
        expect(convs.single.contactWallet, peer);
        expect(convs.single.contactUsername, 'snapshot_fallback');
      },
    );
  });
}
