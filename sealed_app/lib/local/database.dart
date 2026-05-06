import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

// Custom Exceptions
class DatabaseException implements Exception {
  final String message;
  final String? code;
  final StackTrace? stackTrace;

  DatabaseException(this.message, {this.code, this.stackTrace});

  @override
  String toString() =>
      'DatabaseException: $message${code != null ? ' ($code)' : ''}';
}

class DatabaseInitException extends DatabaseException {
  DatabaseInitException(super.message, [StackTrace? stackTrace])
    : super(code: 'INIT_ERROR', stackTrace: stackTrace);
}

class DatabaseOperationException extends DatabaseException {
  DatabaseOperationException(super.message, [StackTrace? stackTrace])
    : super(code: 'OPERATION_ERROR', stackTrace: stackTrace);
}

class LocalDatabase {
  static Database? _db;

  /// DEK source — must be set before [database] is first accessed.
  /// In production this is wired up via Riverpod (see databaseProvider).
  /// For tests, you can inject a fixed DEK.
  static Future<Uint8List> Function()? dekResolver;

  Future<void> _onCreate(Database db, int version) async {
    try {
      // ========================================================================
      // MESSAGES TABLE
      // ========================================================================
      await db.execute('''
        CREATE TABLE messages (
          id TEXT PRIMARY KEY,
          sender_wallet TEXT NOT NULL,
          sender_username TEXT,
          recipient_wallet TEXT NOT NULL,
          recipient_username TEXT,
          content TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          is_outgoing INTEGER NOT NULL,
          is_read INTEGER NOT NULL DEFAULT 1,
          on_chain_pubkey TEXT,
          created_at INTEGER DEFAULT (strftime('%s', 'now'))
        );
      ''');

      await db.execute('''
        CREATE INDEX idx_messages_conversation
        ON messages(recipient_wallet, sender_wallet, timestamp DESC)
      ''');

      // ========================================================================
      // SYNC STATE TABLE
      // ========================================================================
      await db.execute('''
        CREATE TABLE sync_state (
          key TEXT PRIMARY KEY,
          last_sync_timestamp INTEGER,
          last_processed_slot INTEGER
        )
      ''');

      await db.insert('sync_state', {
        'key': 'global',
        'last_sync_timestamp': 0,
        'last_processed_slot': 0,
      });

      // ========================================================================
      // INDEXER STATE TABLE
      // ========================================================================
      await db.execute('''
        CREATE TABLE indexer_state(
          key TEXT PRIMARY KEY,
          view_key_registered INTEGER,
          push_token TEXT,
          last_indexed_sync INTEGER
        )
      ''');

      // ========================================================================
      // USER PROFILE TABLE (current logged-in user)
      // ========================================================================
      await db.execute('''
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
      ''');

      // ========================================================================
      // CONTACTS CACHE TABLE (cached user profiles)
      // ========================================================================
      await db.execute('''
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
      ''');

      await db.execute('''
        CREATE INDEX idx_contacts_username ON contacts_cache(username)
      ''');

      // ========================================================================
      // ALIAS CHATS TABLE (per-conversation ephemeral identities)
      // ========================================================================
      await db.execute('''
        CREATE TABLE alias_chats (
          channel_id TEXT PRIMARY KEY,
          alias TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          is_creator INTEGER NOT NULL DEFAULT 1,
          invite_dismissed INTEGER NOT NULL DEFAULT 0
        )
      ''');

      // ========================================================================
      // ALIAS MESSAGES TABLE
      // ========================================================================
      await db.execute('''
        CREATE TABLE alias_messages (
          id TEXT PRIMARY KEY,
          channel_id TEXT NOT NULL,
          content TEXT NOT NULL,
          timestamp TEXT NOT NULL,
          is_outgoing INTEGER NOT NULL,
          is_read INTEGER NOT NULL DEFAULT 1,
          on_chain_ref TEXT,
          created_at INTEGER DEFAULT (strftime('%s', 'now')),
          FOREIGN KEY (channel_id) REFERENCES alias_chats(channel_id)
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_alias_messages_channel
        ON alias_messages(channel_id, timestamp DESC)
      ''');
    } catch (e, stackTrace) {
      throw DatabaseInitException(
        'Failed to create database schema: $e',
        stackTrace,
      );
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    try {
      print(
        '[LocalDatabase] 🔄 Upgrading database from v$oldVersion to v$newVersion',
      );

      // Migrate from v1 to v2: Add recipient_username column
      if (oldVersion < 2) {
        print('[LocalDatabase] ➕ Adding recipient_username column');
        await db.execute('''
          ALTER TABLE messages ADD COLUMN recipient_username TEXT
        ''');
        print('[LocalDatabase] ✅ Migration to v2 complete');
      }

      // Migrate from v2 to v3: Add is_read column for unread tracking
      if (oldVersion < 3) {
        print('[LocalDatabase] ➕ Adding is_read column');
        await db.execute('''
          ALTER TABLE messages ADD COLUMN is_read INTEGER NOT NULL DEFAULT 1
        ''');
        print('[LocalDatabase] ✅ Migration to v3 complete');
      }

      // Migrate from v3 to v4: allow nullable username/display_name in user tables
      if (oldVersion < 4) {
        print(
          '[LocalDatabase] 🔁 Rebuilding user_profile/contacts_cache for nullable username',
        );

        await db.execute('''
          CREATE TABLE user_profile_new (
            wallet_address TEXT PRIMARY KEY,
            username TEXT,
            display_name TEXT,
            encryption_pubkey BLOB NOT NULL,
            scan_pubkey BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            last_login INTEGER
          )
        ''');

        await db.execute('''
          INSERT INTO user_profile_new(
            wallet_address, username, display_name, encryption_pubkey, scan_pubkey, created_at, last_login
          )
          SELECT wallet_address, username, display_name, encryption_pubkey, scan_pubkey, created_at, last_login
          FROM user_profile
        ''');

        await db.execute('DROP TABLE user_profile');
        await db.execute('ALTER TABLE user_profile_new RENAME TO user_profile');

        await db.execute('''
          CREATE TABLE contacts_cache_new (
            wallet_address TEXT PRIMARY KEY,
            username TEXT,
            display_name TEXT,
            encryption_pubkey BLOB NOT NULL,
            scan_pubkey BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            cached_at INTEGER DEFAULT (strftime('%s', 'now'))
          )
        ''');

        await db.execute('''
          INSERT INTO contacts_cache_new(
            wallet_address, username, display_name, encryption_pubkey, scan_pubkey, created_at, cached_at
          )
          SELECT wallet_address, username, display_name, encryption_pubkey, scan_pubkey, created_at, cached_at
          FROM contacts_cache
        ''');

        await db.execute('DROP TABLE contacts_cache');
        await db.execute(
          'ALTER TABLE contacts_cache_new RENAME TO contacts_cache',
        );
        await db.execute(
          'CREATE INDEX idx_contacts_username ON contacts_cache(username)',
        );

        print('[LocalDatabase] ✅ Migration to v4 complete');
      }

      // Migrate from v4 to v5: add PQ key columns to contacts_cache
      if (oldVersion < 5) {
        print('[LocalDatabase] ➕ Adding PQ key columns to contacts_cache');
        await db.execute(
          'ALTER TABLE contacts_cache ADD COLUMN pq_public_key BLOB',
        );
        await db.execute(
          'ALTER TABLE contacts_cache ADD COLUMN pq_shared_secret BLOB',
        );
        print('[LocalDatabase] ✅ Migration to v5 complete');
      }

      // Migrate from v5 to v6: add alias_chats and alias_messages tables
      if (oldVersion < 6) {
        print('[LocalDatabase] ➕ Adding alias_chats and alias_messages tables');
        await db.execute('''
          CREATE TABLE alias_chats (
            channel_id TEXT PRIMARY KEY,
            alias TEXT NOT NULL,
            counterpart_pubkey BLOB,
            my_public_key BLOB NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL,
            app_id INTEGER,
            is_creator INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute('''
          CREATE TABLE alias_messages (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            is_outgoing INTEGER NOT NULL,
            is_read INTEGER NOT NULL DEFAULT 1,
            on_chain_ref TEXT,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            FOREIGN KEY (channel_id) REFERENCES alias_chats(channel_id)
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_alias_messages_channel
          ON alias_messages(channel_id, timestamp DESC)
        ''');
        print('[LocalDatabase] ✅ Migration to v6 complete');
      }

      // Migrate from v6 to v7: add counterpart_address to alias_chats
      if (oldVersion < 7) {
        print(
          '[LocalDatabase] ➕ Adding counterpart_address column to alias_chats',
        );
        await db.execute(
          'ALTER TABLE alias_chats ADD COLUMN counterpart_address TEXT',
        );
        print('[LocalDatabase] ✅ Migration to v7 complete');
      }

      // Migrate from v7 to v8: add invite_dismissed flag to alias_chats
      if (oldVersion < 8) {
        print(
          '[LocalDatabase] ➕ Adding invite_dismissed column to alias_chats',
        );
        await db.execute(
          'ALTER TABLE alias_chats ADD COLUMN invite_dismissed INTEGER NOT NULL DEFAULT 0',
        );
        print('[LocalDatabase] ✅ Migration to v8 complete');
      }

      // Migrate from v8 to v9: rebuild alias_chats without pubkey/address/appId
      if (oldVersion < 9) {
        print(
          '[LocalDatabase] 🔁 Rebuilding alias_chats table (drop pubkey/address/appId columns)',
        );
        await db.execute('''
          CREATE TABLE alias_chats_v9 (
            channel_id TEXT PRIMARY KEY,
            alias TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL,
            is_creator INTEGER NOT NULL DEFAULT 1,
            invite_dismissed INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          INSERT INTO alias_chats_v9 (channel_id, alias, status, created_at, is_creator, invite_dismissed)
          SELECT channel_id, alias, status, created_at, is_creator, invite_dismissed
          FROM alias_chats
        ''');
        await db.execute('DROP TABLE alias_chats');
        await db.execute('ALTER TABLE alias_chats_v9 RENAME TO alias_chats');
        print('[LocalDatabase] ✅ Migration to v9 complete');
      }

      // Migrate from v9 to v10: add pq_public_key to user_profile
      if (oldVersion < 10) {
        print('[LocalDatabase] ➕ Adding pq_public_key column to user_profile');
        await db.execute(
          'ALTER TABLE user_profile ADD COLUMN pq_public_key BLOB',
        );
        print('[LocalDatabase] ✅ Migration to v10 complete');
      }
    } catch (e, stackTrace) {
      print('[LocalDatabase] ❌ Migration failed: $e');
      throw DatabaseOperationException(
        'Failed to upgrade database: $e',
        stackTrace,
      );
    }
  }

  Future<Database> get database async {
    try {
      if (_db != null && _db!.isOpen) {
        return _db!;
      }

      final resolver = dekResolver;
      if (resolver == null) {
        throw DatabaseOperationException(
          'DEK resolver not set; call LocalDatabase.dekResolver = ... before opening DB',
        );
      }
      final dek = await resolver();
      final password = base64.encode(dek);

      // Invisible migration: if a plain (un-encrypted) DB exists from before
      // this upgrade, copy it into an encrypted DB on first open. The user
      // sees no prompts.
      await _migratePlainIfNeeded(password);

      _db = await openDatabase(
        'sealed_messages.db',
        password: password,
        version: 10,
        onCreate: (Database db, int version) async {
          await _onCreate(db, version);
        },
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          await _onUpgrade(db, oldVersion, newVersion);
        },
      );
      return _db!;
    } catch (e, stackTrace) {
      throw DatabaseOperationException(
        'Failed to open database: $e',
        stackTrace,
      );
    }
  }

  /// One-shot migration from a plain `sealed_messages.db` (pre-feature) to a
  /// SQLCipher-encrypted DB at the same path. Uses `sqlcipher_export` so all
  /// rows transfer. After success, the plain file is deleted and replaced
  /// with the encrypted file.
  static Future<void> _migratePlainIfNeeded(String password) async {
    final dbDir = await getDatabasesPath();
    final plainPath = p.join(dbDir, 'sealed_messages.db');
    final encPath = p.join(dbDir, 'sealed_messages.enc.db');
    final file = File(plainPath);
    if (!await file.exists()) return;

    // Detect whether the existing file is already encrypted. SQLCipher files
    // start with 16 random bytes; plain SQLite files start with the literal
    // "SQLite format 3\0". We sniff the magic header.
    final raf = await file.open();
    try {
      final header = await raf.read(16);
      const sqliteMagic = 'SQLite format 3 ';
      final isPlain =
          header.length == 16 && String.fromCharCodes(header) == sqliteMagic;
      if (!isPlain) return; // already encrypted (or unknown — leave alone)
    } finally {
      await raf.close();
    }

    // Stale scratch from a prior interrupted attempt — start clean.
    final scratch = File(encPath);
    if (await scratch.exists()) {
      await scratch.delete();
    }

    // Open the plain DB via sqflite_sqlcipher (no password). The SQLCipher
    // build transparently opens unencrypted SQLite files when no key is set,
    // and crucially exposes ATTACH ... KEY and sqlcipher_export() — neither
    // of which exists in the upstream sqflite plugin.
    final src = await openDatabase(plainPath, readOnly: false);
    try {
      await src.rawQuery("ATTACH DATABASE ? AS encrypted KEY ?", [
        encPath,
        password,
      ]);
      await src.rawQuery("SELECT sqlcipher_export('encrypted')");
      // Match the source's user_version so onUpgrade is skipped post-rename.
      final v = await src.rawQuery('PRAGMA user_version');
      final userVersion = (v.first.values.first as int?) ?? 0;
      await src.rawQuery("PRAGMA encrypted.user_version = $userVersion");
      await src.rawQuery("DETACH DATABASE encrypted");
    } finally {
      await src.close();
    }

    // Atomically replace plain with encrypted.
    await file.delete();
    await File(encPath).rename(plainPath);
  }

  Future<void> close() async {
    try {
      if (_db != null && _db!.isOpen) {
        await _db!.close();
        _db = null;
      }
    } catch (e, stackTrace) {
      throw DatabaseOperationException(
        'Failed to close database: $e',
        stackTrace,
      );
    }
  }

  /// True if the encrypted DB file exists on disk. Used by the bootstrap
  /// path to detect "stale keychain" — iOS Simulator (and some real-device
  /// scenarios) preserve `flutter_secure_storage` entries across app
  /// uninstalls, so the wrapped-DEK can survive while its DB file does
  /// not. Detecting that mismatch lets the bootstrap fall back to
  /// clearing PIN/DEK state instead of mounting a fresh empty DB with a
  /// stale key (which silently mounts read-only and fails on writes).
  static Future<bool> fileExists() async {
    final dbDir = await getDatabasesPath();
    return File(p.join(dbDir, 'sealed_messages.db')).exists();
  }

  /// Close the open handle (if any) and delete the encrypted SQLite file
  /// from disk. Used by logout/wipe paths so the next bootstrap creates a
  /// fresh DB under the new DEK — otherwise SQLCipher silently mounts the
  /// old file with the wrong key and write attempts fail with
  /// "attempt to write a readonly database".
  static Future<void> closeAndDelete() async {
    try {
      if (_db != null && _db!.isOpen) {
        await _db!.close();
      }
    } catch (e) {
      print('[LocalDatabase] ⚠️ close failed during delete: $e');
    }
    _db = null;

    final dbDir = await getDatabasesPath();
    final main = File(p.join(dbDir, 'sealed_messages.db'));
    if (await main.exists()) {
      await main.delete();
    }
    final scratch = File(p.join(dbDir, 'sealed_messages.enc.db'));
    if (await scratch.exists()) {
      await scratch.delete();
    }
  }
}
