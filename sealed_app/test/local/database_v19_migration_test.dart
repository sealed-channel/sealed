/// Spec: contacts unification — DB v18 → v19 migration test.
///
/// Verifies:
///  - Fresh _onCreate at v19 has the unified `contacts` shape: wallet-profile
///    columns (username, encryption_pubkey, scan_pubkey, pq_public_key,
///    pq_pubkey_hash, is_blocked, cached_at) AND alias handshake columns, with
///    the 8 handshake/crypto BLOBs relaxed to NULLABLE (so wallet rows can omit
///    them) while alias-only metadata stays.
///  - _onUpgrade from v18 (FRESH WIPE): drops both `contacts_cache` and
///    `contacts`, clears `contact_messages`, recreates the unified `contacts`
///    table empty + its 3 indexes — and does NOT throw (a throw here propagates
///    out of the `database` getter and bricks app launch for upgrading users).
///  - Post-migration the unified table accepts both a wallet row (is_alias=0,
///    crypto BLOBs NULL) and an alias row (is_alias=1, crypto BLOBs set).
///
/// SQL strings are inlined (mirror database.dart §_createContactsSchema /
/// §_onUpgrade v19). Tests run on sqflite_ffi against in-memory DBs and bypass
/// SQLCipher/dekResolver.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ─── V18 baseline tables (pre-unification) ───────────────────────────────────

const _v18ContactsCache = '''
  CREATE TABLE contacts_cache (
    wallet_address TEXT PRIMARY KEY,
    username TEXT,
    display_name TEXT,
    alias TEXT,
    encryption_pubkey BLOB NOT NULL,
    scan_pubkey BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    cached_at INTEGER DEFAULT (strftime('%s', 'now')),
    pq_public_key BLOB,
    pq_shared_secret BLOB,
    pq_pubkey_hash BLOB,
    is_blocked INTEGER NOT NULL DEFAULT 0
  )
''';

const _v18Contacts = '''
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

const _v18ContactMessages = '''
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

// ─── V19 unified schema (mirror database.dart §_createContactsSchema) ─────────

const _v19Contacts = '''
  CREATE TABLE contacts (
    contact_id        TEXT PRIMARY KEY,
    is_alias          INTEGER NOT NULL DEFAULT 0,
    wallet_address    TEXT,
    alias_label       TEXT NOT NULL,
    alias_display     TEXT,
    invite_ref        TEXT,
    is_creator        INTEGER,
    username          TEXT,
    display_name      TEXT,
    alias             TEXT,
    encryption_pubkey BLOB,
    scan_pubkey       BLOB,
    pq_public_key     BLOB,
    pq_pubkey_hash    BLOB,
    is_blocked        INTEGER NOT NULL DEFAULT 0,
    cached_at         INTEGER DEFAULT (strftime('%s', 'now')),
    shared_secret     BLOB,
    recipient_tag     BLOB,
    msg_key           BLOB,
    peer_x25519_pub   BLOB,
    peer_x25519_scan  BLOB,
    peer_mlkem_pub    BLOB,
    my_x25519_sk      BLOB,
    my_x25519_scan_sk BLOB,
    my_mlkem_sk       BLOB,
    tag_salt          BLOB,
    pq_shared_secret  BLOB,
    created_at        INTEGER NOT NULL
  )
''';

const _v19Indexes = [
  'CREATE INDEX idx_contacts_tag ON contacts(recipient_tag)',
  'CREATE INDEX idx_contacts_alias ON contacts(is_alias)',
  'CREATE INDEX idx_contacts_username ON contacts(username)',
];

// ─── V19 upgrade SQL (mirror database.dart §_onUpgrade v19 block) ────────────

const _v19Upgrade = [
  'DELETE FROM contact_messages',
  'DROP TABLE IF EXISTS contacts_cache',
  'DROP TABLE IF EXISTS contacts',
  _v19Contacts,
  ..._v19Indexes,
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

Future<Set<String>> _indexNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='index'",
  );
  return rows.map((r) => r['name'] as String).whereType<String>().toSet();
}

Uint8List _b(int len, int seed) =>
    Uint8List.fromList(List.generate(len, (i) => (i + seed) & 0xff));

Future<void> _insertWalletRow(Database db, String wallet) async {
  await db.insert('contacts', {
    'contact_id': wallet,
    'is_alias': 0,
    'alias_label': '',
    'wallet_address': wallet,
    'username': 'alice',
    'encryption_pubkey': _b(32, 1),
    'scan_pubkey': _b(32, 2),
    'created_at': 1000,
    // crypto/handshake BLOBs intentionally omitted — must be nullable.
  });
}

Future<void> _insertAliasRow(Database db, String id) async {
  await db.insert('contacts', {
    'contact_id': id,
    'is_alias': 1,
    'alias_label': '',
    'alias_display': 'Anon',
    'invite_ref': 'deadbeef',
    'is_creator': 1,
    'shared_secret': _b(32, 1),
    'recipient_tag': _b(32, 2),
    'msg_key': _b(32, 3),
    'peer_x25519_pub': _b(32, 4),
    'peer_x25519_scan': _b(32, 5),
    'my_x25519_sk': _b(32, 6),
    'my_x25519_scan_sk': _b(32, 7),
    'tag_salt': _b(16, 8),
    'created_at': 2000,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DB v19 — fresh _onCreate', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v19Contacts);
      for (final sql in _v19Indexes) {
        await db.execute(sql);
      }
    });

    tearDown(() async => db.close());

    test('contacts carries both wallet-profile and alias columns', () async {
      final cols = await _columnNames(db, 'contacts');
      expect(
        cols,
        containsAll([
          // wallet-profile (former contacts_cache)
          'username', 'display_name', 'alias', 'encryption_pubkey',
          'scan_pubkey', 'pq_public_key', 'pq_pubkey_hash', 'is_blocked',
          'cached_at',
          // alias / handshake
          'is_alias', 'wallet_address', 'alias_display', 'invite_ref',
          'is_creator', 'peer_x25519_scan', 'my_x25519_scan_sk',
          'pq_shared_secret',
        ]),
      );
    });

    test('handshake/crypto BLOBs are now nullable', () async {
      final info = await _columnInfo(db, 'contacts');
      for (final c in const [
        'shared_secret',
        'recipient_tag',
        'msg_key',
        'peer_x25519_pub',
        'peer_x25519_scan',
        'my_x25519_sk',
        'my_x25519_scan_sk',
        'tag_salt',
      ]) {
        expect(info[c]!['notnull'], 0, reason: '$c must be nullable');
      }
    });

    test('all three indexes exist', () async {
      final idx = await _indexNames(db);
      expect(
        idx,
        containsAll([
          'idx_contacts_tag',
          'idx_contacts_alias',
          'idx_contacts_username',
        ]),
      );
    });

    test('wallet row inserts with crypto BLOBs NULL', () async {
      await _insertWalletRow(db, 'WALLETAAAA');
      final r = (await db.query('contacts')).single;
      expect(r['is_alias'], 0);
      expect(r['username'], 'alice');
      expect(r['shared_secret'], isNull);
      expect(r['msg_key'], isNull);
    });

    test('alias row inserts with crypto BLOBs set', () async {
      await _insertAliasRow(db, 'alias1');
      final r = (await db.query(
        'contacts',
        where: 'is_alias = 1',
      )).single;
      expect(r['contact_id'], 'alias1');
      expect(r['msg_key'], equals(_b(32, 3)));
      expect(r['encryption_pubkey'], isNull);
    });
  });

  group('DB v19 — upgrade from v18 (fresh wipe)', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v18ContactsCache);
      await db.execute(_v18Contacts);
      await db.execute(_v18ContactMessages);

      // Seed a wallet contact in contacts_cache + an alias contact in contacts
      // + a contact_message, to prove the migration runs against populated
      // tables (FK-bound contact_messages included).
      await db.insert('contacts_cache', {
        'wallet_address': 'WALLETAAAA',
        'username': 'alice',
        'encryption_pubkey': _b(32, 1),
        'scan_pubkey': _b(32, 2),
        'created_at': 1000,
      });
      await db.insert('contacts', {
        'contact_id': 'alias1',
        'is_alias': 1,
        'alias_label': '',
        'alias_display': 'Anon',
        'invite_ref': 'deadbeef',
        'is_creator': 1,
        'shared_secret': _b(32, 1),
        'recipient_tag': _b(32, 2),
        'msg_key': _b(32, 3),
        'peer_x25519_pub': _b(32, 4),
        'peer_x25519_scan': _b(32, 5),
        'my_x25519_sk': _b(32, 6),
        'my_x25519_scan_sk': _b(32, 7),
        'tag_salt': _b(16, 8),
        'created_at': 2000,
      });
      await db.insert('contact_messages', {
        'id': 'm1',
        'contact_id': 'alias1',
        'direction': 0,
        'content': 'hi',
        'timestamp': 100,
      });

      // Apply the v19 migration. Must not throw.
      for (final sql in _v19Upgrade) {
        await db.execute(sql);
      }
    });

    tearDown(() async => db.close());

    test('contacts_cache is dropped', () async {
      expect(await _tableExists(db, 'contacts_cache'), isFalse);
    });

    test('unified contacts table exists and is empty (fresh wipe)', () async {
      expect(await _tableExists(db, 'contacts'), isTrue);
      expect(await db.query('contacts'), isEmpty);
    });

    test('contact_messages is cleared', () async {
      expect(await db.query('contact_messages'), isEmpty);
    });

    test('unified contacts has the v19 shape', () async {
      final cols = await _columnNames(db, 'contacts');
      expect(
        cols,
        containsAll([
          'username',
          'encryption_pubkey',
          'is_blocked',
          'cached_at',
          'is_alias',
          'invite_ref',
          'pq_shared_secret',
        ]),
      );
    });

    test('post-migration accepts both wallet (NULL crypto) + alias rows', () async {
      await _insertWalletRow(db, 'WALLETBBBB');
      await _insertAliasRow(db, 'alias2');
      expect(await db.query('contacts', where: 'is_alias = 0'), hasLength(1));
      expect(await db.query('contacts', where: 'is_alias = 1'), hasLength(1));
    });
  });
}
