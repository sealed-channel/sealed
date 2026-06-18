/// Contacts-flow refactor — DB v20 → v21 migration test (`is_contact`).
///
/// Verifies:
///  - Upgrade from a true v20 table (bio present, no `is_contact` column):
///    the guarded ALTER adds the column, wallet rows backfill to 0, alias
///    rows to 1, existing data survives.
///  - Upgrade from <19 (e.g. v18 → 21): the v19 block already recreates the
///    table via _createContactsSchema, which now INCLUDES `is_contact` — the
///    v21 pragma guard must skip the ALTER (an unguarded ALTER throws
///    "duplicate column name" and bricks app launch for upgrading users).
///  - Fresh create has the column with DEFAULT 0.
///
/// SQL strings are inlined (mirror database.dart §_createContactsSchema /
/// §_onUpgrade v19–v21 blocks). Tests run on sqflite_ffi against in-memory
/// DBs and bypass SQLCipher/dekResolver.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ─── V20 contacts shape WITHOUT is_contact (what real v20 DBs have) ──────────

const _v20Contacts = '''
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
    bio               TEXT,
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

// ─── V21 contacts shape (mirror database.dart §_createContactsSchema) ────────
// Used by the <19→21 path: the v19 block recreates the table via the shared
// schema helper, which now carries is_contact.

const _v21Contacts = '''
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
    bio               TEXT,
    encryption_pubkey BLOB,
    scan_pubkey       BLOB,
    pq_public_key     BLOB,
    pq_pubkey_hash    BLOB,
    is_blocked        INTEGER NOT NULL DEFAULT 0,
    is_contact        INTEGER NOT NULL DEFAULT 0,
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

// ─── V21 upgrade logic (mirror database.dart §_onUpgrade v21 block) ──────────

Future<void> _applyV21Upgrade(Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(contacts)');
  final hasColumn = cols.any((c) => c['name'] == 'is_contact');
  if (!hasColumn) {
    await db.execute(
      'ALTER TABLE contacts ADD COLUMN is_contact INTEGER NOT NULL DEFAULT 0',
    );
  }
  await db.execute('UPDATE contacts SET is_contact = 1 WHERE is_alias = 1');
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

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

  group('DB v21 — upgrade from v20 (column added + backfill)', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v20Contacts);
      await _insertWalletRow(db, 'WALLETAAAA');
      await _insertAliasRow(db, 'alias1');
      await _applyV21Upgrade(db);
    });

    tearDown(() async => db.close());

    test('is_contact column exists with NOT NULL DEFAULT 0', () async {
      final info = await db.rawQuery('PRAGMA table_info(contacts)');
      final col = info.singleWhere((c) => c['name'] == 'is_contact');
      expect(col['notnull'], 1);
      expect(col['dflt_value'], '0');
    });

    test('existing rows survive the migration', () async {
      expect(await db.query('contacts'), hasLength(2));
    });

    test('wallet rows backfill to is_contact = 0', () async {
      final r = (await db.query('contacts', where: 'is_alias = 0')).single;
      expect(r['is_contact'], 0);
      expect(r['username'], 'alice');
    });

    test('alias rows backfill to is_contact = 1', () async {
      final r = (await db.query('contacts', where: 'is_alias = 1')).single;
      expect(r['is_contact'], 1);
    });
  });

  group('DB v21 — upgrade from <19 (table already has column)', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      // The v19 block on a <19→21 upgrade recreates `contacts` via
      // _createContactsSchema, which now includes is_contact.
      await db.execute(_v21Contacts);
    });

    tearDown(() async => db.close());

    test('pragma-guarded v21 block does not throw duplicate-column', () async {
      await _insertAliasRow(db, 'alias1');
      await _applyV21Upgrade(db); // must not throw
      final r = (await db.query('contacts', where: 'is_alias = 1')).single;
      expect(r['is_contact'], 1);
    });
  });

  group('DB v21 — fresh create', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(_v21Contacts);
    });

    tearDown(() async => db.close());

    test('new wallet row defaults to is_contact = 0', () async {
      await _insertWalletRow(db, 'WALLETBBBB');
      final r = (await db.query('contacts')).single;
      expect(r['is_contact'], 0);
    });
  });
}
