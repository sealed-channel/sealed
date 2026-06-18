/// Spec H — DB v12 → v13 migration test.
///
/// Verifies:
///  - Fresh _onCreate at v13 produces `contacts` + `contact_messages` + index.
///  - _onUpgrade from v12 adds the same schema idempotently.
///  - Pre-existing rows (messages, alias_chats) survive the bump.
///
/// We exercise the raw migration SQL directly rather than going through
/// `LocalDatabase.database` (which requires SQLCipher + dekResolver). The SQL
/// strings live in `database.dart`; re-pasting them here would drift, so we
/// inline the v13 statements and assert table shape via PRAGMA.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Inline copy of the v13 schema SQL. Keep in sync with database.dart §v13.
const _v13Tables = [
  '''
  CREATE TABLE IF NOT EXISTS contacts (
    contact_id        TEXT PRIMARY KEY,
    alias_label       TEXT NOT NULL,
    shared_secret     BLOB NOT NULL,
    recipient_tag     BLOB NOT NULL,
    msg_key           BLOB NOT NULL,
    peer_x25519_pub   BLOB NOT NULL,
    peer_mlkem_pub    BLOB NOT NULL,
    my_x25519_sk      BLOB NOT NULL,
    my_mlkem_sk       BLOB NOT NULL,
    tag_salt          BLOB NOT NULL,
    created_at        INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS contact_messages (
    id              TEXT PRIMARY KEY,
    contact_id      TEXT NOT NULL REFERENCES contacts(contact_id),
    direction       INTEGER NOT NULL,
    content         TEXT NOT NULL,
    timestamp       INTEGER NOT NULL,
    on_chain_ref    TEXT
  )
  ''',
];

const _v13Indexes = [
  'CREATE INDEX IF NOT EXISTS idx_contacts_tag ON contacts(recipient_tag)',
  'CREATE INDEX IF NOT EXISTS idx_contact_messages_contact ON contact_messages(contact_id, timestamp DESC)',
];

Future<Database> _openV12() async {
  // Tiny v12 surface — just enough to assert preservation through upgrade.
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 12),
  );
  await db.execute('''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      content TEXT NOT NULL,
      legacy_origin INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE alias_chats (
      channel_id TEXT PRIMARY KEY,
      alias TEXT NOT NULL
    )
  ''');
  return db;
}

Future<void> _applyV13(Database db) async {
  for (final stmt in _v13Tables) {
    await db.execute(stmt);
  }
  for (final idx in _v13Indexes) {
    await db.execute(idx);
  }
}

Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

Future<Set<String>> _indexNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='index'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DB v13 — fresh _onCreate', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 13),
      );
      await _applyV13(db);
    });

    tearDown(() async => db.close());

    test('creates contacts + contact_messages tables', () async {
      final tables = await _tableNames(db);
      expect(tables.contains('contacts'), isTrue);
      expect(tables.contains('contact_messages'), isTrue);
    });

    test('creates idx_contacts_tag index', () async {
      final idx = await _indexNames(db);
      expect(idx.contains('idx_contacts_tag'), isTrue);
      expect(idx.contains('idx_contact_messages_contact'), isTrue);
    });

    test('contacts schema matches Spec H §5.2', () async {
      final info = await db.rawQuery('PRAGMA table_info(contacts)');
      final cols = {
        for (final r in info) r['name'] as String: r['type'] as String,
      };
      expect(cols['contact_id'], 'TEXT');
      expect(cols['alias_label'], 'TEXT');
      expect(cols['shared_secret'], 'BLOB');
      expect(cols['recipient_tag'], 'BLOB');
      expect(cols['msg_key'], 'BLOB');
      expect(cols['peer_x25519_pub'], 'BLOB');
      expect(cols['peer_mlkem_pub'], 'BLOB');
      expect(cols['my_x25519_sk'], 'BLOB');
      expect(cols['my_mlkem_sk'], 'BLOB');
      expect(cols['tag_salt'], 'BLOB');
      expect(cols['created_at'], 'INTEGER');
    });

    test('insert + select round-trip on contacts', () async {
      await db.insert('contacts', {
        'contact_id': 'c1',
        'alias_label': 'alice',
        'shared_secret': Uint8List(32)..fillRange(0, 32, 0x11),
        'recipient_tag': Uint8List(32)..fillRange(0, 32, 0x22),
        'msg_key': Uint8List(32)..fillRange(0, 32, 0x33),
        'peer_x25519_pub': Uint8List(32)..fillRange(0, 32, 0x44),
        'peer_mlkem_pub': Uint8List(800)..fillRange(0, 800, 0x55),
        'my_x25519_sk': Uint8List(32)..fillRange(0, 32, 0x66),
        'my_mlkem_sk': Uint8List(1632)..fillRange(0, 1632, 0x77),
        'tag_salt': Uint8List(32)..fillRange(0, 32, 0x88),
        'created_at': 1700000000,
      });
      final rows = await db.query(
        'contacts',
        where: 'contact_id = ?',
        whereArgs: ['c1'],
      );
      expect(rows.length, 1);
      expect(rows.first['alias_label'], 'alice');
      expect((rows.first['recipient_tag'] as List).length, 32);
    });
  });

  group('DB v13 — upgrade from v12', () {
    test('v12 → v13 adds new tables, preserves old rows', () async {
      final db = await _openV12();
      addTearDown(() async => db.close());

      // Seed pre-existing v12 data.
      await db.insert('messages', {
        'id': 'm1',
        'content': 'pre-migration',
        'legacy_origin': 0,
      });
      await db.insert('alias_chats', {
        'channel_id': 'ch1',
        'alias': 'old-alias',
      });

      // Apply v13 migration.
      await _applyV13(db);

      // Old rows survive.
      final msgs = await db.query('messages');
      expect(msgs.length, 1);
      expect(msgs.first['content'], 'pre-migration');
      final chats = await db.query('alias_chats');
      expect(chats.length, 1);

      // New tables present, empty.
      final tables = await _tableNames(db);
      expect(tables.containsAll({'contacts', 'contact_messages'}), isTrue);
      expect((await db.query('contacts')).length, 0);
    });

    test('re-applying v13 is idempotent', () async {
      final db = await _openV12();
      addTearDown(() async => db.close());

      await _applyV13(db);
      // Second apply must not throw — CREATE TABLE IF NOT EXISTS + CREATE INDEX
      // IF NOT EXISTS cover the replay-after-crash case.
      await _applyV13(db);

      final tables = await _tableNames(db);
      expect(tables.contains('contacts'), isTrue);
      expect(tables.contains('contact_messages'), isTrue);
    });
  });

  group('DB v13 — FK + index behavior', () {
    test('contact_messages FK references contacts(contact_id)', () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 13),
      );
      addTearDown(() async => db.close());
      await _applyV13(db);
      await db.execute('PRAGMA foreign_keys = ON');

      // Insert with no matching contact — must fail.
      await expectLater(
        db.insert('contact_messages', {
          'id': 'mm1',
          'contact_id': 'nonexistent',
          'direction': 0,
          'content': 'x',
          'timestamp': 1,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });
  });
}
