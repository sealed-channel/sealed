import 'package:sealed_app/infra/local/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-memory [LocalDatabase] for repository unit tests.
class TestLocalDatabase extends LocalDatabase {
  final Database _db;
  TestLocalDatabase._(this._db);

  @override
  Future<Database> get database async => _db;

  static Future<TestLocalDatabase> open() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _onCreate,
        singleInstance: false,
      ),
    );
    return TestLocalDatabase._(db);
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE user_profile (
        wallet_address TEXT PRIMARY KEY,
        username TEXT,
        alias TEXT,
        bio TEXT,
        display_name TEXT,
        encryption_pubkey BLOB NOT NULL,
        scan_pubkey BLOB NOT NULL,
        pq_public_key BLOB,
        pq_pubkey_hash BLOB,
        created_at INTEGER NOT NULL,
        last_login INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        sender_wallet TEXT NOT NULL,
        sender_username TEXT,
        recipient_wallet TEXT NOT NULL,
        recipient_username TEXT,
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        is_outgoing INTEGER NOT NULL,
        is_read INTEGER NOT NULL DEFAULT 1,
        on_chain_pubkey TEXT,
        created_at INTEGER DEFAULT (strftime('%s', 'now')),
        legacy_origin INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // v19: unified contacts table — wallet (is_alias = 0) + alias (is_alias = 1).
    // Mirrors `_createContactsSchema` in lib/infra/local/database.dart.
    await db.execute('''
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
    ''');
    await db.execute(
      'CREATE INDEX idx_contacts_tag ON contacts(recipient_tag)',
    );
    await db.execute('CREATE INDEX idx_contacts_alias ON contacts(is_alias)');
    await db.execute(
      'CREATE INDEX idx_contacts_username ON contacts(username)',
    );

    await db.execute('''
      CREATE TABLE contact_messages (
        id              TEXT PRIMARY KEY,
        contact_id      TEXT NOT NULL REFERENCES contacts(contact_id) ON DELETE CASCADE,
        direction       INTEGER NOT NULL,
        content         TEXT NOT NULL,
        timestamp       INTEGER NOT NULL,
        on_chain_ref    TEXT,
        is_read         INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_invites (
        invite_ref       TEXT PRIMARY KEY,
        alias_display    TEXT NOT NULL,
        is_creator       INTEGER NOT NULL,
        status           TEXT NOT NULL,
        created_at       INTEGER NOT NULL,
        invite_dismissed INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ON DELETE CASCADE requires PRAGMA foreign_keys = ON per-connection.
    await db.execute('PRAGMA foreign_keys = ON');
  }

  @override
  Future<void> close() async => _db.close();
}
