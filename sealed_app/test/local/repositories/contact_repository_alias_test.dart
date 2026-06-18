/// T4 — ContactRepository alias-as-contact CRUD + pending invite tests.
///
/// Verifies:
///  - saveAliasContact / getAliasContact round-trip preserves all fields
///  - getAliasContact returns null for wallet-kind rows (filtered by is_alias)
///  - getAllAliasContacts only returns alias rows
///  - deleteAliasContact removes row + cascades contact_messages
///  - getContactByInviteRef finds alias rows by invite_ref hex
///  - pending invite CRUD round-trip (save / get / getAll / delete / dismiss)
///  - promotePendingToContact is atomic (insert contact + delete pending in one txn)
///  - getAliasPreviews returns wallet + alias rows sorted by last-message ts
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/contact.dart';

import 'test_db.dart';

Uint8List _b(int len, int seed) =>
    Uint8List.fromList(List.generate(len, (i) => (i + seed) & 0xff));

ContactKeys _keys({int seed = 0, bool pq = true, Uint8List? pqShared}) =>
    ContactKeys(
      sharedSecret: _b(32, seed + 1),
      recipientTag: _b(32, seed + 2),
      msgKey: _b(32, seed + 3),
      peerX25519Pub: _b(32, seed + 4),
      peerX25519Scan: _b(32, seed + 5),
      peerMlkemPub: pq ? _b(800, seed + 6) : null,
      myX25519Sk: _b(32, seed + 7),
      myX25519ScanSk: _b(32, seed + 8),
      myMlkemSk: pq ? _b(1632, seed + 9) : null,
      tagSalt: _b(16, seed + 10),
      pqSharedSecret: pqShared,
    );

AliasContact _alias({
  String contactId = 'aliasA',
  String inviteRef = 'deadbeef',
  bool isCreator = true,
  String display = 'Stranger',
  int seed = 0,
  int createdAt = 1000,
}) => AliasContact(
  contactId: contactId,
  nickname: 'a',
  createdAt: createdAt,
  keys: _keys(seed: seed),
  aliasHandle: display,
  inviteRef: inviteRef,
  isCreator: isCreator,
);

void main() {
  late TestLocalDatabase db;
  late ContactRepositoryImpl repo;

  setUp(() async {
    db = await TestLocalDatabase.open();
    repo = ContactRepositoryImpl(db);
  });

  tearDown(() async => db.close());

  group('saveAliasContact / getAliasContact', () {
    test('round-trip preserves all alias fields', () async {
      final a = _alias(seed: 100);
      await repo.saveAliasContact(a);
      final loaded = await repo.getAliasContact('aliasA');
      expect(loaded, isNotNull);
      expect(loaded!.contactId, 'aliasA');
      expect(loaded.aliasHandle, 'Stranger');
      expect(loaded.inviteRef, 'deadbeef');
      expect(loaded.isCreator, isTrue);
      expect(loaded.kind, ContactKind.alias);
      expect(loaded.keys.peerX25519Scan, equals(a.keys.peerX25519Scan));
    });

    test('returns null for non-existent contact', () async {
      expect(await repo.getAliasContact('missing'), isNull);
    });

    test('returns null for wallet-kind row (is_alias=0)', () async {
      final db0 = await db.database;
      await db0.insert('contacts', {
        'contact_id': 'walletA',
        'is_alias': 0,
        'wallet_address': 'WALLET',
        'alias_label': 'A',
        'shared_secret': _b(32, 0),
        'recipient_tag': _b(32, 0),
        'msg_key': _b(32, 0),
        'peer_x25519_pub': _b(32, 0),
        'peer_x25519_scan': _b(32, 0),
        'my_x25519_sk': _b(32, 0),
        'my_x25519_scan_sk': _b(32, 0),
        'tag_salt': _b(16, 0),
        'created_at': 1,
      });
      expect(await repo.getAliasContact('walletA'), isNull);
    });
  });

  group('getAllAliasContacts', () {
    test('returns only alias-kind rows, newest first', () async {
      final db0 = await db.database;
      await db0.insert('contacts', {
        'contact_id': 'walletA',
        'is_alias': 0,
        'alias_label': 'A',
        'shared_secret': _b(32, 0),
        'recipient_tag': _b(32, 0),
        'msg_key': _b(32, 0),
        'peer_x25519_pub': _b(32, 0),
        'peer_x25519_scan': _b(32, 0),
        'my_x25519_sk': _b(32, 0),
        'my_x25519_scan_sk': _b(32, 0),
        'tag_salt': _b(16, 0),
        'created_at': 500,
      });
      await repo.saveAliasContact(
        _alias(contactId: 'a1', inviteRef: 'r1', createdAt: 100, seed: 1),
      );
      await repo.saveAliasContact(
        _alias(contactId: 'a2', inviteRef: 'r2', createdAt: 200, seed: 2),
      );
      final all = await repo.getAllAliasContacts();
      expect(all.map((a) => a.contactId), ['a2', 'a1']);
    });
  });

  group('deleteAliasContact', () {
    test('removes row and cascades contact_messages', () async {
      await repo.saveAliasContact(_alias(contactId: 'a1', inviteRef: 'r1'));
      final db0 = await db.database;
      await db0.insert('contact_messages', {
        'id': 'm1',
        'contact_id': 'a1',
        'direction': 1,
        'content': 'hi',
        'timestamp': 1,
      });
      await repo.deleteAliasContact('a1');
      expect(await repo.getAliasContact('a1'), isNull);
      final msgs = await db0.query(
        'contact_messages',
        where: 'contact_id = ?',
        whereArgs: ['a1'],
      );
      expect(msgs, isEmpty);
    });

    test('does not touch wallet-kind row with same id', () async {
      final db0 = await db.database;
      await db0.insert('contacts', {
        'contact_id': 'shared-id',
        'is_alias': 0,
        'alias_label': 'A',
        'shared_secret': _b(32, 0),
        'recipient_tag': _b(32, 0),
        'msg_key': _b(32, 0),
        'peer_x25519_pub': _b(32, 0),
        'peer_x25519_scan': _b(32, 0),
        'my_x25519_sk': _b(32, 0),
        'my_x25519_scan_sk': _b(32, 0),
        'tag_salt': _b(16, 0),
        'created_at': 1,
      });
      await repo.deleteAliasContact('shared-id');
      final rows = await db0.query(
        'contacts',
        where: 'contact_id = ?',
        whereArgs: ['shared-id'],
      );
      expect(rows, hasLength(1));
    });
  });

  group('getContactByInviteRef', () {
    test('finds alias by invite_ref', () async {
      await repo.saveAliasContact(_alias(contactId: 'a1', inviteRef: 'cafe'));
      final c = await repo.getContactByInviteRef('cafe');
      expect(c, isA<AliasContact>());
      expect((c as AliasContact).contactId, 'a1');
    });

    test('returns null when no match', () async {
      expect(await repo.getContactByInviteRef('nope'), isNull);
    });
  });

  group('pending invites', () {
    test('save + get round-trip', () async {
      const invite = PendingInvite(
        inviteRef: 'beef',
        aliasDisplay: 'Carol',
        isCreator: true,
        status: 'pending',
        createdAt: 99,
      );
      await repo.savePendingInvite(invite);
      final loaded = await repo.getPendingInvite('beef');
      expect(loaded, isNotNull);
      expect(loaded!.aliasDisplay, 'Carol');
      expect(loaded.status, 'pending');
      expect(loaded.isCreator, isTrue);
      expect(loaded.inviteDismissed, isFalse);
    });

    test('getAllPendingInvites sorted by created_at DESC', () async {
      await repo.savePendingInvite(
        const PendingInvite(
          inviteRef: 'r1',
          aliasDisplay: 'A',
          isCreator: true,
          status: 'pending',
          createdAt: 1,
        ),
      );
      await repo.savePendingInvite(
        const PendingInvite(
          inviteRef: 'r2',
          aliasDisplay: 'B',
          isCreator: false,
          status: 'awaiting_accept',
          createdAt: 2,
        ),
      );
      final all = await repo.getAllPendingInvites();
      expect(all.map((i) => i.inviteRef), ['r2', 'r1']);
    });

    test('deletePendingInvite removes row', () async {
      await repo.savePendingInvite(
        const PendingInvite(
          inviteRef: 'r1',
          aliasDisplay: 'A',
          isCreator: true,
          status: 'pending',
          createdAt: 1,
        ),
      );
      await repo.deletePendingInvite('r1');
      expect(await repo.getPendingInvite('r1'), isNull);
    });

    test('markInviteDismissed sets flag to 1', () async {
      await repo.savePendingInvite(
        const PendingInvite(
          inviteRef: 'r1',
          aliasDisplay: 'A',
          isCreator: true,
          status: 'pending',
          createdAt: 1,
        ),
      );
      await repo.markInviteDismissed('r1');
      final got = await repo.getPendingInvite('r1');
      expect(got!.inviteDismissed, isTrue);
    });
  });

  group('promotePendingToContact', () {
    test('inserts contact + deletes pending atomically', () async {
      await repo.savePendingInvite(
        const PendingInvite(
          inviteRef: 'cafe',
          aliasDisplay: 'Ghost',
          isCreator: false,
          status: 'awaiting_accept',
          createdAt: 5,
        ),
      );
      final contact = _alias(contactId: 'a1', inviteRef: 'cafe');
      await repo.promotePendingToContact(inviteRef: 'cafe', contact: contact);

      expect(await repo.getPendingInvite('cafe'), isNull);
      expect(await repo.getAliasContact('a1'), isNotNull);
    });

    test('throws when pending row is missing', () async {
      expect(
        () => repo.promotePendingToContact(
          inviteRef: 'absent',
          contact: _alias(contactId: 'a1', inviteRef: 'absent'),
        ),
        throwsStateError,
      );
    });
  });

  group('getAliasPreviews', () {
    test('returns only alias-kind contacts; wallet rows filtered', () async {
      final db0 = await db.database;
      // Wallet contact (created earlier, latest msg later) — must be filtered.
      await db0.insert('contacts', {
        'contact_id': 'walletA',
        'is_alias': 0,
        'wallet_address': 'W',
        'alias_label': 'Wallet',
        'shared_secret': _b(32, 0),
        'recipient_tag': _b(32, 0),
        'msg_key': _b(32, 0),
        'peer_x25519_pub': _b(32, 0),
        'peer_x25519_scan': _b(32, 0),
        'my_x25519_sk': _b(32, 0),
        'my_x25519_scan_sk': _b(32, 0),
        'tag_salt': _b(16, 0),
        'created_at': 1,
      });
      await db0.insert('contact_messages', {
        'id': 'm1',
        'contact_id': 'walletA',
        'direction': 0,
        'content': 'wallet-latest',
        'timestamp': 5000,
      });
      // Alias contact w/ older message — must appear.
      await repo.saveAliasContact(
        _alias(contactId: 'a1', inviteRef: 'r1', createdAt: 2),
      );
      await db0.insert('contact_messages', {
        'id': 'm2',
        'contact_id': 'a1',
        'direction': 1,
        'content': 'alias-older',
        'timestamp': 1000,
      });

      final previews = await repo.getAliasPreviews();
      expect(previews, hasLength(1));
      expect(previews.first.isAlias, isTrue);
      expect(previews.first.aliasContact!.contactId, 'a1');
      expect(previews.first.lastMessageContent, 'alias-older');
      expect(previews.first.lastMessageTimestamp, 1000);
    });

    test('alias contact with no messages still appears', () async {
      await repo.saveAliasContact(_alias(contactId: 'a1', inviteRef: 'r1'));
      final previews = await repo.getAliasPreviews();
      expect(previews, hasLength(1));
      expect(previews.first.aliasContact!.contactId, 'a1');
      expect(previews.first.lastMessageContent, isNull);
      expect(previews.first.lastMessageTimestamp, isNull);
    });
  });

  group('markAllContactMessagesRead', () {
    // Regression: on mnemonic restore the full sync re-pulls alias history with
    // is_read=0; without an all-contacts mark-read those land as unread badges.
    test('marks every unread incoming alias message read, across contacts',
        () async {
      final db0 = await db.database;
      // Two contacts, each with an unread incoming (direction=0) message.
      for (final c in ['a1', 'a2']) {
        await db0.insert('contact_messages', {
          'id': 'in-$c',
          'contact_id': c,
          'direction': 0,
          'content': 'incoming',
          'timestamp': 1000,
          'is_read': 0,
        });
      }
      // An already-read incoming and an outgoing — must stay untouched.
      await db0.insert('contact_messages', {
        'id': 'out-a1',
        'contact_id': 'a1',
        'direction': 1,
        'content': 'outgoing',
        'timestamp': 1001,
        'is_read': 1,
      });

      await repo.markAllContactMessagesRead();

      final rows = await db0.query('contact_messages', orderBy: 'id');
      for (final r in rows) {
        expect(r['is_read'], 1, reason: 'row ${r['id']} should be read');
      }
    });
  });
}
