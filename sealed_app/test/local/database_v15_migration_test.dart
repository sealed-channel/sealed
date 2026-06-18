/// Spec: alias-as-contact §2 — DB v14 → v15 migration test.
///
/// Verifies:
///  - Fresh _onCreate at v15 has the unified `contacts` shape (alias columns,
///    nullable mlkem, peer_x25519_scan + my_x25519_scan_sk NOT NULL),
///    `contact_messages` with ON DELETE CASCADE + is_read, `pending_invites`,
///    and NO `alias_chats` / `alias_messages` tables.
///  - _onUpgrade from v14:
///      * preserves wallet-contact rows in `contacts` (is_alias=0,
///        peer_x25519_scan backfilled from peer_x25519_pub),
///      * drops legacy alias_chats + alias_messages,
///      * creates `pending_invites`,
///      * accepts NULL mlkem on new rows (classical-only peers),
///      * accepts NOT NULL scan columns on new rows.
///
/// SQL strings are inlined (mirror database.dart §_onCreate / §v15). Tests run
/// on sqflite_ffi against in-memory DBs and bypass SQLCipher/dekResolver.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ─── V14 baseline tables (subset relevant to v15) ────────────────────────────

const _v14Contacts = '''
  CREATE TABLE contacts (
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
''';

const _v14ContactMessages = '''
  CREATE TABLE contact_messages (
    id              TEXT PRIMARY KEY,
    contact_id      TEXT NOT NULL REFERENCES contacts(contact_id),
    direction       INTEGER NOT NULL,
    content         TEXT NOT NULL,
    timestamp       INTEGER NOT NULL,
    on_chain_ref    TEXT
  )
''';

const _v14AliasChats = '''
  CREATE TABLE alias_chats (
    channel_id TEXT PRIMARY KEY,
    alias TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL,
    is_creator INTEGER NOT NULL DEFAULT 1,
    invite_dismissed INTEGER NOT NULL DEFAULT 0
  )
''';

const _v14AliasMessages = '''
  CREATE TABLE alias_messages (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    content TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    is_outgoing INTEGER NOT NULL,
    is_read INTEGER NOT NULL DEFAULT 1,
    on_chain_ref TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    legacy_origin INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (channel_id) REFERENCES alias_chats(channel_id)
  )
''';

// ─── V15 fresh schema (mirror database.dart §_onCreate) ──────────────────────

const _v15FreshContacts = '''
  CREATE TABLE contacts (
    contact_id        TEXT PRIMARY KEY,
    is_alias          INTEGER NOT NULL DEFAULT 0,
    wallet_address    TEXT,
    alias_label       TEXT NOT NULL,
    alias_display     TEXT,
    invite_ref        TEXT,
    is_creator        INTEGER,
    shared_secret     BLOB NOT NULL,
    recipient_tag     BLOB NOT NULL,
    msg_key           BLOB NOT NULL,
    peer_x25519_pub   BLOB NOT NULL,
    peer_x25519_scan  BLOB NOT NULL,
    peer_mlkem_pub    BLOB,
    my_x25519_sk      BLOB NOT NULL,
    my_x25519_scan_sk BLOB NOT NULL,
    my_mlkem_sk       BLOB,
    tag_salt          BLOB NOT NULL,
    pq_shared_secret  BLOB,
    created_at        INTEGER NOT NULL
  )
''';

const _v15FreshContactMessages = '''
  CREATE TABLE contact_messages (
    id              TEXT PRIMARY KEY,
    contact_id      TEXT NOT NULL REFERENCES contacts(contact_id) ON DELETE CASCADE,
    direction       INTEGER NOT NULL,
    content         TEXT NOT NULL,
    timestamp       INTEGER NOT NULL,
    on_chain_ref    TEXT,
    is_read         INTEGER NOT NULL DEFAULT 1
  )
''';

const _v15FreshPendingInvites = '''
  CREATE TABLE pending_invites (
    invite_ref       TEXT PRIMARY KEY,
    alias_display    TEXT NOT NULL,
    is_creator       INTEGER NOT NULL,
    status           TEXT NOT NULL,
    created_at       INTEGER NOT NULL,
    invite_dismissed INTEGER NOT NULL DEFAULT 0
  )
''';

// ─── V15 upgrade SQL (mirror database.dart §_onUpgrade v15 block) ────────────

const _v15Upgrade = [
  '''
    CREATE TABLE contacts_v15 (
      contact_id        TEXT PRIMARY KEY,
      is_alias          INTEGER NOT NULL DEFAULT 0,
      wallet_address    TEXT,
      alias_label       TEXT NOT NULL,
      alias_display     TEXT,
      invite_ref        TEXT,
      is_creator        INTEGER,
      shared_secret     BLOB NOT NULL,
      recipient_tag     BLOB NOT NULL,
      msg_key           BLOB NOT NULL,
      peer_x25519_pub   BLOB NOT NULL,
      peer_x25519_scan  BLOB NOT NULL,
      peer_mlkem_pub    BLOB,
      my_x25519_sk      BLOB NOT NULL,
      my_x25519_scan_sk BLOB NOT NULL,
      my_mlkem_sk       BLOB,
      tag_salt          BLOB NOT NULL,
      pq_shared_secret  BLOB,
      created_at        INTEGER NOT NULL
    )
  ''',
  '''
    INSERT INTO contacts_v15 (
      contact_id, is_alias, alias_label,
      shared_secret, recipient_tag, msg_key,
      peer_x25519_pub, peer_x25519_scan, peer_mlkem_pub,
      my_x25519_sk, my_x25519_scan_sk, my_mlkem_sk,
      tag_salt, created_at
    )
    SELECT
      contact_id, 0, alias_label,
      shared_secret, recipient_tag, msg_key,
      peer_x25519_pub, peer_x25519_pub, peer_mlkem_pub,
      my_x25519_sk, my_x25519_sk, my_mlkem_sk,
      tag_salt, created_at
    FROM contacts
  ''',
  'DROP TABLE contacts',
  'ALTER TABLE contacts_v15 RENAME TO contacts',
  'CREATE INDEX idx_contacts_tag ON contacts(recipient_tag)',
  'CREATE INDEX idx_contacts_alias ON contacts(is_alias)',
  '''
    CREATE TABLE contact_messages_v15 (
      id              TEXT PRIMARY KEY,
      contact_id      TEXT NOT NULL REFERENCES contacts(contact_id) ON DELETE CASCADE,
      direction       INTEGER NOT NULL,
      content         TEXT NOT NULL,
      timestamp       INTEGER NOT NULL,
      on_chain_ref    TEXT,
      is_read         INTEGER NOT NULL DEFAULT 1
    )
  ''',
  '''
    INSERT INTO contact_messages_v15 (
      id, contact_id, direction, content, timestamp, on_chain_ref
    )
    SELECT id, contact_id, direction, content, timestamp, on_chain_ref
    FROM contact_messages
  ''',
  'DROP TABLE contact_messages',
  'ALTER TABLE contact_messages_v15 RENAME TO contact_messages',
  'CREATE INDEX idx_contact_messages_contact ON contact_messages(contact_id, timestamp DESC)',
  '''
    CREATE TABLE pending_invites (
      invite_ref       TEXT PRIMARY KEY,
      alias_display    TEXT NOT NULL,
      is_creator       INTEGER NOT NULL,
      status           TEXT NOT NULL,
      created_at       INTEGER NOT NULL,
      invite_dismissed INTEGER NOT NULL DEFAULT 0
    )
  ''',
  'DROP TABLE IF EXISTS alias_messages',
  'DROP TABLE IF EXISTS alias_chats',
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

Future<Set<String>> _columnNames(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

Future<Map<String, Map<String, Object?>>> _columnInfo(
  Database db,
  String table,
) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final r in rows) r['name'] as String: r};
}

Future<bool> _tableExists(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [table],
  );
  return rows.isNotEmpty;
}

Uint8List _b(int len, int seed) =>
    Uint8List.fromList(List.generate(len, (i) => (i + seed) & 0xff));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DB v15 — fresh _onCreate', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v15FreshContacts);
      await db.execute(_v15FreshContactMessages);
      await db.execute(_v15FreshPendingInvites);
    });

    tearDown(() async => db.close());

    test('contacts has all alias-as-contact columns', () async {
      final cols = await _columnNames(db, 'contacts');
      expect(
        cols,
        containsAll([
          'is_alias',
          'wallet_address',
          'alias_display',
          'invite_ref',
          'is_creator',
          'peer_x25519_scan',
          'my_x25519_scan_sk',
          'pq_shared_secret',
        ]),
      );
    });

    test('peer_mlkem_pub + my_mlkem_sk are nullable', () async {
      final info = await _columnInfo(db, 'contacts');
      expect(info['peer_mlkem_pub']!['notnull'], 0);
      expect(info['my_mlkem_sk']!['notnull'], 0);
    });

    test('peer_x25519_scan + my_x25519_scan_sk are NOT NULL', () async {
      final info = await _columnInfo(db, 'contacts');
      expect(info['peer_x25519_scan']!['notnull'], 1);
      expect(info['my_x25519_scan_sk']!['notnull'], 1);
    });

    test('pending_invites has spec shape', () async {
      final cols = await _columnNames(db, 'pending_invites');
      expect(
        cols,
        containsAll([
          'invite_ref',
          'alias_display',
          'is_creator',
          'status',
          'created_at',
          'invite_dismissed',
        ]),
      );
    });

    test('inserting alias contact with NULL mlkem succeeds', () async {
      await db.insert('contacts', {
        'contact_id': 'alias1',
        'is_alias': 1,
        'alias_label': 'a',
        'alias_display': 'Anon',
        'invite_ref': 'deadbeef',
        'is_creator': 1,
        'shared_secret': _b(32, 1),
        'recipient_tag': _b(32, 2),
        'msg_key': _b(32, 3),
        'peer_x25519_pub': _b(32, 4),
        'peer_x25519_scan': _b(32, 5),
        'peer_mlkem_pub': null,
        'my_x25519_sk': _b(32, 6),
        'my_x25519_scan_sk': _b(32, 7),
        'my_mlkem_sk': null,
        'tag_salt': _b(16, 8),
        'pq_shared_secret': null,
        'created_at': 1000,
      });
      final row = (await db.query('contacts')).single;
      expect(row['is_alias'], 1);
      expect(row['peer_mlkem_pub'], isNull);
      expect(row['my_mlkem_sk'], isNull);
      expect(row['peer_x25519_scan'], equals(_b(32, 5)));
    });
  });

  group('DB v15 — upgrade from v14', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v14Contacts);
      await db.execute(_v14ContactMessages);
      await db.execute(_v14AliasChats);
      await db.execute(_v14AliasMessages);

      // Seed a v14 wallet-contact row + a contact_message.
      await db.insert('contacts', {
        'contact_id': 'walletA',
        'alias_label': 'Alice',
        'shared_secret': _b(32, 1),
        'recipient_tag': _b(32, 2),
        'msg_key': _b(32, 3),
        'peer_x25519_pub': _b(32, 9),
        'peer_mlkem_pub': _b(800, 4),
        'my_x25519_sk': _b(32, 10),
        'my_mlkem_sk': _b(1632, 5),
        'tag_salt': _b(16, 6),
        'created_at': 12345,
      });
      await db.insert('contact_messages', {
        'id': 'm1',
        'contact_id': 'walletA',
        'direction': 1,
        'content': 'hi',
        'timestamp': 100,
        'on_chain_ref': 'tx1',
      });
      // Seed a legacy alias row (should be dropped).
      await db.insert('alias_chats', {
        'channel_id': 'chan1',
        'alias': 'a',
        'status': 'pending',
        'created_at': '0',
      });

      for (final sql in _v15Upgrade) {
        await db.execute(sql);
      }
    });

    tearDown(() async => db.close());

    test('legacy alias_chats + alias_messages are dropped', () async {
      expect(await _tableExists(db, 'alias_chats'), isFalse);
      expect(await _tableExists(db, 'alias_messages'), isFalse);
    });

    test('pending_invites table exists', () async {
      expect(await _tableExists(db, 'pending_invites'), isTrue);
    });

    test(
      'wallet contact row survives with is_alias=0 + scan backfill',
      () async {
        final rows = await db.query('contacts');
        expect(rows, hasLength(1));
        final r = rows.first;
        expect(r['contact_id'], 'walletA');
        expect(r['is_alias'], 0);
        expect(r['peer_x25519_scan'], equals(_b(32, 9)));
        expect(r['my_x25519_scan_sk'], equals(_b(32, 10)));
        expect(r['pq_shared_secret'], isNull);
        expect(r['wallet_address'], isNull);
      },
    );

    test(
      'contact_messages row survives migration with is_read default',
      () async {
        final rows = await db.query('contact_messages');
        expect(rows, hasLength(1));
        expect(rows.first['id'], 'm1');
        expect(rows.first['is_read'], 1);
      },
    );

    test(
      'post-migration insert accepts NULL mlkem (classical-only alias)',
      () async {
        await db.insert('contacts', {
          'contact_id': 'alias2',
          'is_alias': 1,
          'alias_label': 'a',
          'alias_display': 'Bob',
          'invite_ref': 'cafe',
          'is_creator': 0,
          'shared_secret': _b(32, 11),
          'recipient_tag': _b(32, 12),
          'msg_key': _b(32, 13),
          'peer_x25519_pub': _b(32, 14),
          'peer_x25519_scan': _b(32, 15),
          'peer_mlkem_pub': null,
          'my_x25519_sk': _b(32, 16),
          'my_x25519_scan_sk': _b(32, 17),
          'my_mlkem_sk': null,
          'tag_salt': _b(16, 18),
          'pq_shared_secret': null,
          'created_at': 2000,
        });
        final r = (await db.query(
          'contacts',
          where: 'contact_id=?',
          whereArgs: ['alias2'],
        )).single;
        expect(r['peer_mlkem_pub'], isNull);
      },
    );

    test('pending_invites round-trip', () async {
      await db.insert('pending_invites', {
        'invite_ref': 'abc123',
        'alias_display': 'Carol',
        'is_creator': 1,
        'status': 'pending',
        'created_at': 9999,
      });
      final r = (await db.query('pending_invites')).single;
      expect(r['invite_ref'], 'abc123');
      expect(r['status'], 'pending');
      expect(r['invite_dismissed'], 0);
    });
  });
}
