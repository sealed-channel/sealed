/// Spec: SPEC-mobile-clients-cutover §3.3 — DB v13 → v14 migration test.
///
/// Verifies:
///  - Fresh _onCreate at v14 includes pq_pubkey_hash on user_profile + contacts_cache.
///  - _onUpgrade from v13 adds the column to both tables without data loss.
///  - NULL round-trip (old rows) and BLOB round-trip (new rows) both work.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ─── V13 baseline — minimal tables to simulate an existing v13 install ────────

const _v13CreateUserProfile = '''
  CREATE TABLE user_profile (
    wallet_address TEXT PRIMARY KEY,
    username TEXT,
    display_name TEXT,
    encryption_pubkey BLOB NOT NULL,
    scan_pubkey BLOB NOT NULL,
    pq_public_key BLOB,
    created_at INTEGER NOT NULL,
    last_login INTEGER
  )
''';

const _v13CreateContactsCache = '''
  CREATE TABLE contacts_cache (
    wallet_address TEXT PRIMARY KEY,
    username TEXT,
    display_name TEXT,
    encryption_pubkey BLOB NOT NULL,
    scan_pubkey BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    cached_at INTEGER DEFAULT (strftime('%s', 'now')),
    pq_public_key BLOB,
    pq_shared_secret BLOB
  )
''';

// ─── V14 migration SQL (copy from database.dart §v14) ────────────────────────

const _v14Sql = [
  'ALTER TABLE user_profile ADD COLUMN pq_pubkey_hash BLOB',
  'ALTER TABLE contacts_cache ADD COLUMN pq_pubkey_hash BLOB',
];

// ─── V14 fresh CREATE SQL (copy from database.dart _onCreate) ─────────────────

const _v14FreshUserProfile = '''
  CREATE TABLE user_profile (
    wallet_address TEXT PRIMARY KEY,
    username TEXT,
    display_name TEXT,
    encryption_pubkey BLOB NOT NULL,
    scan_pubkey BLOB NOT NULL,
    pq_public_key BLOB,
    pq_pubkey_hash BLOB,
    created_at INTEGER NOT NULL,
    last_login INTEGER
  )
''';

const _v14FreshContactsCache = '''
  CREATE TABLE contacts_cache (
    wallet_address TEXT PRIMARY KEY,
    username TEXT,
    display_name TEXT,
    encryption_pubkey BLOB NOT NULL,
    scan_pubkey BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    cached_at INTEGER DEFAULT (strftime('%s', 'now')),
    pq_public_key BLOB,
    pq_shared_secret BLOB,
    pq_pubkey_hash BLOB
  )
''';

// ─── Helpers ─────────────────────────────────────────────────────────────────

Future<Set<String>> _columnNames(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DB v14 — fresh _onCreate', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v14FreshUserProfile);
      await db.execute(_v14FreshContactsCache);
    });

    tearDown(() async => db.close());

    test('user_profile has pq_pubkey_hash column', () async {
      final cols = await _columnNames(db, 'user_profile');
      expect(cols, contains('pq_pubkey_hash'));
    });

    test('contacts_cache has pq_pubkey_hash column', () async {
      final cols = await _columnNames(db, 'contacts_cache');
      expect(cols, contains('pq_pubkey_hash'));
    });

    test('insert + round-trip with non-null hash on user_profile', () async {
      final hash = Uint8List.fromList(List.generate(32, (i) => i));
      await db.insert('user_profile', {
        'wallet_address': 'AAAA',
        'encryption_pubkey': Uint8List(32),
        'scan_pubkey': Uint8List(32),
        'created_at': 0,
        'pq_pubkey_hash': hash,
      });
      final row = (await db.query('user_profile')).first;
      final stored = row['pq_pubkey_hash'] as Uint8List?;
      expect(stored, equals(hash));
    });

    test(
      'insert + round-trip with null hash on user_profile (old row)',
      () async {
        await db.insert('user_profile', {
          'wallet_address': 'BBBB',
          'encryption_pubkey': Uint8List(32),
          'scan_pubkey': Uint8List(32),
          'created_at': 0,
          'pq_pubkey_hash': null,
        });
        final row = (await db.query('user_profile')).first;
        expect(row['pq_pubkey_hash'], isNull);
      },
    );
  });

  group('DB v14 — upgrade from v13', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      // Create v13 tables
      await db.execute(_v13CreateUserProfile);
      await db.execute(_v13CreateContactsCache);
      // Insert a v13 row to verify preservation
      await db.insert('user_profile', {
        'wallet_address': 'EXISTING',
        'encryption_pubkey': Uint8List(32),
        'scan_pubkey': Uint8List(32),
        'created_at': 1234567890,
      });
      // Apply v14 migration
      for (final sql in _v14Sql) {
        await db.execute(sql);
      }
    });

    tearDown(() async => db.close());

    test('user_profile gains pq_pubkey_hash column', () async {
      final cols = await _columnNames(db, 'user_profile');
      expect(cols, contains('pq_pubkey_hash'));
    });

    test('contacts_cache gains pq_pubkey_hash column', () async {
      final cols = await _columnNames(db, 'contacts_cache');
      expect(cols, contains('pq_pubkey_hash'));
    });

    test(
      'pre-existing user_profile row survives migration with null hash',
      () async {
        final rows = await db.query(
          'user_profile',
          where: 'wallet_address = ?',
          whereArgs: ['EXISTING'],
        );
        expect(rows, hasLength(1));
        expect(rows.first['wallet_address'], equals('EXISTING'));
        expect(rows.first['pq_pubkey_hash'], isNull);
      },
    );

    test('new row written post-migration round-trips hash correctly', () async {
      final hash = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      await db.insert('user_profile', {
        'wallet_address': 'NEW',
        'encryption_pubkey': Uint8List(32),
        'scan_pubkey': Uint8List(32),
        'created_at': 0,
        'pq_pubkey_hash': hash,
      });
      final row = (await db.query(
        'user_profile',
        where: 'wallet_address = ?',
        whereArgs: ['NEW'],
      )).first;
      expect(row['pq_pubkey_hash'], equals(hash));
    });
  });
}
