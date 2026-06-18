import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/contact_keys.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_db.dart';

void main() {
  sqfliteFfiInit();

  late TestLocalDatabase testDb;
  late ContactRepository repo;

  setUp(() async {
    testDb = await TestLocalDatabase.open();
    repo = ContactRepositoryImpl(testDb);
  });

  tearDown(() async {
    await testDb.close();
  });

  final _enc = Uint8List.fromList(List.filled(32, 0x01));
  final _scan = Uint8List.fromList(List.filled(32, 0x02));

  UserProfile _makeContact(String wallet, {String? username}) => UserProfile(
    walletAddress: wallet,
    username: username,
    encryptionPubkey: _enc,
    scanPubkey: _scan,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  group('ContactRepository – CRUD', () {
    test('getContact returns null when not stored', () async {
      expect(await repo.getContact('AAAA'), isNull);
    });

    test('saveContact + getContact round-trip', () async {
      await repo.saveContact(_makeContact('AAAA', username: 'alice'));
      final c = await repo.getContact('AAAA');
      expect(c?.walletAddress, 'AAAA');
      expect(c?.username, 'alice');
    });

    test('saveContact replace-on-conflict', () async {
      await repo.saveContact(_makeContact('AAAA', username: 'alice'));
      await repo.saveContact(_makeContact('AAAA', username: 'alice2'));
      final c = await repo.getContact('AAAA');
      expect(c?.username, 'alice2');
    });

    test('getAllContacts returns all saved contacts', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.saveContact(_makeContact('BBBB'));
      final all = await repo.getAllContacts();
      expect(all.length, 2);
    });

    test('deleteContact removes contact', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.deleteContact('AAAA');
      expect(await repo.getContact('AAAA'), isNull);
    });

    test('deleteContact on missing wallet does not throw', () async {
      await expectLater(repo.deleteContact('ZZZZ'), completes);
    });

    test('clear removes all contacts', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.saveContact(_makeContact('BBBB'));
      await repo.clear();
      expect(await repo.getAllContacts(), isEmpty);
    });
  });

  // v19: wallet + alias share one `contacts` table. The wallet-facing methods
  // must ignore alias rows (is_alias = 1) — and must not crash on them (alias
  // rows have NULL encryption_pubkey, which would null-cast UserProfile.fromMap).
  group('ContactRepository – unified table isolation (v19)', () {
    Future<void> seedAliasRow(String contactId) async {
      final db = await testDb.database;
      await db.insert('contacts', {
        'contact_id': contactId,
        'is_alias': 1,
        'alias_label': '',
        'alias_display': 'Unnamed',
        'invite_ref': contactId,
        'is_creator': 1,
        'created_at': 0,
      });
    }

    Future<int> aliasRowCount() async {
      final db = await testDb.database;
      final rows = await db.query('contacts', where: 'is_alias = 1');
      return rows.length;
    }

    test('getAllContacts ignores alias rows and does not throw', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await seedAliasRow('alias1');
      final all = await repo.getAllContacts();
      expect(all.length, 1);
      expect(all.single.walletAddress, 'AAAA');
    });

    test('getContact does not resolve an alias contactId', () async {
      await seedAliasRow('alias1');
      expect(await repo.getContact('alias1'), isNull);
    });

    test('clear removes wallet rows but leaves alias rows', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await seedAliasRow('alias1');
      await repo.clear();
      expect(await repo.getAllContacts(), isEmpty);
      expect(await aliasRowCount(), 1);
    });
  });

  group('ContactRepository – block (v18)', () {
    Future<int> blockedFlag(String wallet) async {
      final db = await testDb.database;
      final rows = await db.query(
        'contacts',
        columns: ['is_blocked'],
        where: 'wallet_address = ? AND is_alias = 0',
        whereArgs: [wallet],
        limit: 1,
      );
      return rows.first['is_blocked'] as int;
    }

    test('new contact defaults to not blocked', () async {
      await repo.saveContact(_makeContact('AAAA'));
      expect(await blockedFlag('AAAA'), 0);
    });

    test('blockContact sets is_blocked = 1', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.blockContact('AAAA');
      expect(await blockedFlag('AAAA'), 1);
    });

    test('isBlocked reflects state; false for unknown wallet', () async {
      await repo.saveContact(_makeContact('AAAA'));
      expect(await repo.isBlocked('AAAA'), isFalse);
      await repo.blockContact('AAAA');
      expect(await repo.isBlocked('AAAA'), isTrue);
      expect(await repo.isBlocked('ZZZZ'), isFalse);
    });

    test('unblockContact resets is_blocked = 0', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.blockContact('AAAA');
      await repo.unblockContact('AAAA');
      expect(await blockedFlag('AAAA'), 0);
    });

    test('block on missing wallet is a no-op (no row created)', () async {
      await expectLater(repo.blockContact('ZZZZ'), completes);
      final db = await testDb.database;
      final rows = await db.query(
        'contacts',
        where: 'wallet_address = ? AND is_alias = 0',
        whereArgs: ['ZZZZ'],
      );
      expect(rows, isEmpty);
    });
  });

  group('ContactRepository – manual contact flag (v20)', () {
    Future<int> contactFlag(String wallet) async {
      final db = await testDb.database;
      final rows = await db.query(
        'contacts',
        columns: ['is_contact'],
        where: 'wallet_address = ? AND is_alias = 0',
        whereArgs: [wallet],
        limit: 1,
      );
      return rows.first['is_contact'] as int;
    }

    test('new contact defaults to not-a-contact (key cache only)', () async {
      await repo.saveContact(_makeContact('AAAA'));
      expect(await contactFlag('AAAA'), 0);
      expect(await repo.isContact('AAAA'), isFalse);
    });

    test('addToContacts sets flag on existing row', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.addToContacts('AAAA');
      expect(await contactFlag('AAAA'), 1);
      expect(await repo.isContact('AAAA'), isTrue);
    });

    test('removeFromContacts resets flag', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.addToContacts('AAAA');
      await repo.removeFromContacts('AAAA');
      expect(await repo.isContact('AAAA'), isFalse);
    });

    test('isContact false for unknown wallet', () async {
      expect(await repo.isContact('ZZZZ'), isFalse);
    });

    test(
      'blockContact evicts from contacts; unblock does not restore',
      () async {
        await repo.saveContact(_makeContact('AAAA'));
        await repo.addToContacts('AAAA');
        await repo.blockContact('AAAA');
        expect(await repo.isContact('AAAA'), isFalse);
        await repo.unblockContact('AAAA');
        expect(await repo.isContact('AAAA'), isFalse);
        expect(await repo.isBlocked('AAAA'), isFalse);
      },
    );

    test('addToContacts on missing row without resolver throws', () async {
      // Repo constructed without indexer/chainResolver — lazy row creation
      // cannot resolve keys, so the flag has no row to land on.
      await expectLater(repo.addToContacts('ZZZZ'), throwsStateError);
    });

    test(
      'saveContact REPLACE preserves is_contact (username refresh)',
      () async {
        await repo.saveContact(_makeContact('AAAA', username: 'alice'));
        await repo.addToContacts('AAAA');
        // Simulates the 120s username-refresh loop re-saving the profile.
        await repo.saveContact(_makeContact('AAAA', username: 'alice2'));
        expect(await repo.isContact('AAAA'), isTrue);
        expect((await repo.getContact('AAAA'))?.username, 'alice2');
      },
    );

    test('saveContact REPLACE preserves is_blocked too', () async {
      await repo.saveContact(_makeContact('AAAA'));
      await repo.blockContact('AAAA');
      await repo.saveContact(_makeContact('AAAA', username: 'fresh'));
      expect(await repo.isBlocked('AAAA'), isTrue);
    });

    test('getManualContacts returns only flagged wallet rows', () async {
      await repo.saveContact(_makeContact('AAAA', username: 'alice'));
      await repo.saveContact(_makeContact('BBBB', username: 'bob'));
      await repo.addToContacts('AAAA');
      // Alias row with is_contact=1 must still be excluded (is_alias=1).
      final db = await testDb.database;
      await db.insert('contacts', {
        'contact_id': 'alias1',
        'is_alias': 1,
        'alias_label': '',
        'alias_display': 'Unnamed',
        'invite_ref': 'alias1',
        'is_creator': 1,
        'is_contact': 1,
        'created_at': 0,
      });
      final manual = await repo.getManualContacts();
      expect(manual.map((c) => c.walletAddress), ['AAAA']);
    });
  });

  group('ContactRepository – search', () {
    setUp(() async {
      await repo.saveContact(_makeContact('AAAA1111', username: 'alice'));
      await repo.saveContact(_makeContact('BBBB2222', username: 'bob'));
      await repo.saveContact(_makeContact('CCCC3333', username: 'charlie'));
    });

    test('searchContact exact wallet match', () async {
      final result = await repo.searchContact('AAAA1111');
      expect(result?.walletAddress, 'AAAA1111');
    });

    test('searchContact exact username match', () async {
      final result = await repo.searchContact('bob');
      expect(result?.walletAddress, 'BBBB2222');
    });

    test('searchContact returns null for unknown query', () async {
      expect(await repo.searchContact('xyz'), isNull);
    });

    test('searchContacts fuzzy by username', () async {
      final results = await repo.searchContacts('ali');
      expect(results.any((c) => c.username == 'alice'), isTrue);
    });

    test('searchContacts fuzzy by wallet', () async {
      final results = await repo.searchContacts('BBBB');
      expect(results.any((c) => c.walletAddress == 'BBBB2222'), isTrue);
    });

    test('searchContacts respects limit', () async {
      final results = await repo.searchContacts('', limit: 2);
      expect(results.length, lessThanOrEqualTo(2));
    });

    test('searchContacts returns empty for no match', () async {
      expect(await repo.searchContacts('ZZZZZZZZZ'), isEmpty);
    });
  });

  group('ContactRepository – keys', () {
    const wallet = 'KEYTEST1';
    final pqPub = Uint8List.fromList(List.filled(32, 0xAA));
    final pqSecret = Uint8List.fromList(List.filled(32, 0xBB));
    final encKey = Uint8List.fromList(List.filled(32, 0xCC));
    final scanKey = Uint8List.fromList(List.filled(32, 0xDD));

    setUp(() async {
      await repo.saveContact(_makeContact(wallet));
    });

    test('getContactKeys returns null pq keys when no keys saved', () async {
      final keys = await repo.getContactKeys(wallet);
      // enc/scan are populated from saveContact; pq keys start null
      expect(keys.pqPublicKey, isNull);
      expect(keys.pqSharedSecret, isNull);
    });

    test('getContactKeys returns empty bundle for unknown wallet', () async {
      final keys = await repo.getContactKeys('UNKNOWN');
      expect(keys.pqPublicKey, isNull);
    });

    test('saveContactKeys saves pqPublicKey only', () async {
      await repo.saveContactKeys(wallet, pqPublicKey: pqPub);
      final keys = await repo.getContactKeys(wallet);
      expect(keys.pqPublicKey, equals(pqPub));
      expect(keys.pqSharedSecret, isNull);
      // enc/scan from saveContact remain
    });

    test('saveContactKeys saves pqSharedSecret only', () async {
      await repo.saveContactKeys(wallet, pqSharedSecret: pqSecret);
      final keys = await repo.getContactKeys(wallet);
      expect(keys.pqSharedSecret, equals(pqSecret));
      expect(keys.pqPublicKey, isNull);
    });

    test('saveContactKeys partial update does not clear other keys', () async {
      // Save pqPublicKey first
      await repo.saveContactKeys(wallet, pqPublicKey: pqPub);
      // Then save pqSharedSecret separately
      await repo.saveContactKeys(wallet, pqSharedSecret: pqSecret);

      final keys = await repo.getContactKeys(wallet);
      // Both should survive
      expect(keys.pqPublicKey, equals(pqPub));
      expect(keys.pqSharedSecret, equals(pqSecret));
    });

    test('saveContactKeys saves all 4 keys at once', () async {
      await repo.saveContactKeys(
        wallet,
        pqPublicKey: pqPub,
        pqSharedSecret: pqSecret,
        encryptionPubkey: encKey,
        scanPubkey: scanKey,
      );
      final keys = await repo.getContactKeys(wallet);
      expect(keys.pqPublicKey, equals(pqPub));
      expect(keys.pqSharedSecret, equals(pqSecret));
      expect(keys.encryptionPubkey, equals(encKey));
      expect(keys.scanPubkey, equals(scanKey));
    });

    test('saveContactKeys with no params is no-op', () async {
      await repo.saveContactKeys(wallet, pqPublicKey: pqPub);
      await repo.saveContactKeys(wallet); // no-op
      final keys = await repo.getContactKeys(wallet);
      expect(keys.pqPublicKey, equals(pqPub));
    });
  });
}
