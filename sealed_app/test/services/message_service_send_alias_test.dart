/// T6+T7 — ContactRepository.saveContactMessage / getContactMessages tests.
///
/// Tests the repo-layer methods added for alias message storage.
/// Full MessageService.sendAliasMessage integration covered in T12 e2e.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/contact.dart' as cmodel;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../local/repositories/test_db.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _b(int len, int seed) =>
    Uint8List.fromList(List.generate(len, (i) => (i + seed) & 0xff));

cmodel.ContactKeys _keys({int seed = 0}) => cmodel.ContactKeys(
  sharedSecret: _b(32, seed + 1),
  recipientTag: _b(32, seed + 2),
  msgKey: _b(32, seed + 3),
  peerX25519Pub: _b(32, seed + 4),
  peerX25519Scan: _b(32, seed + 5),
  myX25519Sk: _b(32, seed + 7),
  myX25519ScanSk: _b(32, seed + 8),
  tagSalt: _b(16, seed + 10),
);

cmodel.AliasContact _alias(String contactId) => cmodel.AliasContact(
  contactId: contactId,
  nickname: 'a',
  createdAt: 1,
  keys: _keys(seed: 10),
  aliasHandle: 'Ghost',
  inviteRef: 'ref_$contactId',
  isCreator: true,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late TestLocalDatabase testDb;
  late ContactRepositoryImpl repo;

  setUp(() async {
    sqfliteFfiInit();
    testDb = await TestLocalDatabase.open();
    repo = ContactRepositoryImpl(testDb);
  });

  tearDown(() async => testDb.close());

  group('saveContactMessage / getContactMessages', () {
    test('round-trip preserves all fields', () async {
      await repo.saveAliasContact(_alias('a1'));

      final msg = cmodel.ContactMessage(
        id: 'tx1',
        contactId: 'a1',
        direction: 1,
        content: 'hello',
        timestamp: 1000,
      );
      await repo.saveContactMessage(msg);

      final loaded = await repo.getContactMessages('a1');
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'tx1');
      expect(loaded.first.content, 'hello');
      expect(loaded.first.direction, 1);
      expect(loaded.first.contactId, 'a1');
      expect(loaded.first.timestamp, 1000);
    });

    test('returns messages ASC by timestamp', () async {
      await repo.saveAliasContact(_alias('a1'));

      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'm3',
          contactId: 'a1',
          direction: 0,
          content: 'third',
          timestamp: 3000,
        ),
      );
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'm1',
          contactId: 'a1',
          direction: 1,
          content: 'first',
          timestamp: 1000,
        ),
      );
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'm2',
          contactId: 'a1',
          direction: 0,
          content: 'second',
          timestamp: 2000,
        ),
      );

      final msgs = await repo.getContactMessages('a1');
      expect(msgs.map((m) => m.id).toList(), ['m1', 'm2', 'm3']);
    });

    test('upserts on duplicate id', () async {
      await repo.saveAliasContact(_alias('a1'));
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'dup',
          contactId: 'a1',
          direction: 1,
          content: 'original',
          timestamp: 1,
        ),
      );
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'dup',
          contactId: 'a1',
          direction: 1,
          content: 'updated',
          timestamp: 2,
        ),
      );
      final msgs = await repo.getContactMessages('a1');
      expect(msgs, hasLength(1));
      expect(msgs.first.content, 'updated');
    });

    test('returns empty list for contact with no messages', () async {
      await repo.saveAliasContact(_alias('a1'));
      expect(await repo.getContactMessages('a1'), isEmpty);
    });
  });

  group('markContactMessagesRead', () {
    test('sets is_read=1 for all unread rows', () async {
      await repo.saveAliasContact(_alias('a1'));
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'm1',
          contactId: 'a1',
          direction: 0,
          content: 'hi',
          timestamp: 1,
        ),
      );
      final db0 = await testDb.database;
      // Manually mark unread
      await db0.update(
        'contact_messages',
        {'is_read': 0},
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      // Mark read
      await repo.markContactMessagesRead('a1');
      final row = (await db0.query(
        'contact_messages',
        where: 'id = ?',
        whereArgs: ['m1'],
      )).first;
      expect(row['is_read'], 1);
    });

    test('does not affect other contacts', () async {
      await repo.saveAliasContact(_alias('a1'));
      await repo.saveAliasContact(_alias('a2'));
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'm1',
          contactId: 'a1',
          direction: 0,
          content: 'x',
          timestamp: 1,
        ),
      );
      await repo.saveContactMessage(
        cmodel.ContactMessage(
          id: 'm2',
          contactId: 'a2',
          direction: 0,
          content: 'y',
          timestamp: 1,
        ),
      );
      final db0 = await testDb.database;
      await db0.update('contact_messages', {'is_read': 0});
      await repo.markContactMessagesRead('a1');
      final m2 = (await db0.query(
        'contact_messages',
        where: 'id = ?',
        whereArgs: ['m2'],
      )).first;
      expect(m2['is_read'], 0); // untouched
    });
  });
}
