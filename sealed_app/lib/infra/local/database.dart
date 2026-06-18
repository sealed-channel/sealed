import 'dart:convert';
import 'package:sealed_app/core/log.dart';
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

/// Raised when SQLCipher mounts the DB file with a mismatched key. The
/// open succeeds but the page-level cipher silently switches to read-only,
/// so the first INSERT/UPDATE explodes deep in a service. We probe right
/// after open and surface this code so the bootstrap layer can wipe + reset.
class DatabaseKeyMismatchException extends DatabaseException {
  DatabaseKeyMismatchException(super.message, [StackTrace? stackTrace])
    : super(code: 'KEY_MISMATCH', stackTrace: stackTrace);
}

/// Sentinel used to roll back the read-only probe transaction. Never escapes
/// the `database` getter.
class _ProbeRollback implements Exception {
  const _ProbeRollback();
}

class LocalDatabase {
  static Database? _db;

  /// DEK source — must be set before [database] is first accessed.
  /// In production this is wired up via Riverpod (see databaseProvider).
  /// For tests, you can inject a fixed DEK.
  static Future<Uint8List> Function()? dekResolver;

  /// Creates the unified `contacts` table + its indexes. Holds BOTH wallet
  /// contacts (`is_alias = 0` — former `contacts_cache` rows: cached profile +
  /// re-derivable pubkeys, contact_id = wallet_address) and alias contacts
  /// (`is_alias = 1` — self-contained handshake bundle).
  ///
  /// The 8 handshake/crypto BLOBs are nullable: they are populated only for
  /// alias rows. Wallet rows carry the profile columns (username, alias,
  /// encryption_pubkey, scan_pubkey, pq_public_key, pq_pubkey_hash, is_blocked,
  /// cached_at) and leave the crypto BLOBs NULL. The profile pubkey columns are
  /// kept distinct from the alias handshake pubkey columns on purpose — they are
  /// semantically different channels (cached/re-derivable vs fixed-handshake).
  ///
  /// All BLOBs live inside the SQLCipher-encrypted DB — at-rest-encrypted via
  /// the page-level cipher. Called from both `_onCreate` and the v19 upgrade so
  /// the two definitions can never drift.
  Future<void> _createContactsSchema(Database db) async {
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
  }

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
          created_at INTEGER DEFAULT (strftime('%s', 'now')),
          legacy_origin INTEGER NOT NULL DEFAULT 0
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

      // Wallet contacts (cached profiles) no longer live in a separate
      // `contacts_cache` table — they are unified into the `contacts` table
      // below as `is_alias = 0` rows (v19). See that table's definition.

      // ========================================================================
      // MIGRATION STATE TABLE (M29 — tracks one-shot legacy reconcile)
      // ========================================================================
      await db.execute('''
        CREATE TABLE migration_state (
          key TEXT PRIMARY KEY,
          started_at INTEGER,
          completed_at INTEGER,
          rows_touched INTEGER,
          notes TEXT
        )
      ''');

      // Install epoch: when THIS db (fresh install / reinstall) was created.
      // Alias invites whose on-chain timestamp predates this are not resurfaced
      // — after a reinstall an old invite can't be re-accepted without forking
      // the channel (keys are wiped), so we must not re-present it. A fresh
      // install has no prior on-chain history, so this is harmless there.
      await db.insert('migration_state', {
        'key': 'install_epoch',
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'notes':
            'ms-epoch of db creation; gates stale alias-invite resurfacing',
      });

      // ========================================================================
      // EPHEMERAL WALLETS TABLE (per-channel Algorand identities, AES-GCM-wrapped)
      // ========================================================================
      await db.execute('''
        CREATE TABLE ephemeral_wallets (
          channel_id TEXT PRIMARY KEY,
          address TEXT NOT NULL,
          public_key BLOB NOT NULL,
          wrapped_sk BLOB NOT NULL,
          nonce BLOB NOT NULL,
          mac BLOB NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');

      // ========================================================================
      // CONTACTS TABLE (unified wallet + alias — v19)
      // ========================================================================
      await _createContactsSchema(db);

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

      await db.execute(
        'CREATE INDEX idx_contact_messages_contact ON contact_messages(contact_id, timestamp DESC)',
      );

      // ========================================================================
      // PENDING INVITES TABLE (alias onboarding pre-completion state)
      // ========================================================================
      // One row per in-flight alias invite (creator side: status='pending',
      // acceptor side: status='awaiting_accept'). Promoted to a `contacts` row
      // by `AliasOnboardingService.completeKeyExchange` in the same txn that
      // deletes this row. Raw inviteSecret never lives here — only its
      // sha256 hex as `invite_ref` (also the future contact_id).
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
    } catch (e, stackTrace) {
      throw DatabaseInitException(
        'Failed to create database schema: $e',
        stackTrace,
      );
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    try {
      Log.d(
        '[LocalDatabase] 🔄 Upgrading database from v$oldVersion to v$newVersion',
      );

      // Migrate from v1 to v2: Add recipient_username column
      if (oldVersion < 2) {
        Log.d('[LocalDatabase] ➕ Adding recipient_username column');
        await db.execute('''
          ALTER TABLE messages ADD COLUMN recipient_username TEXT
        ''');
        Log.d('[LocalDatabase] ✅ Migration to v2 complete');
      }

      // Migrate from v2 to v3: Add is_read column for unread tracking
      if (oldVersion < 3) {
        Log.d('[LocalDatabase] ➕ Adding is_read column');
        await db.execute('''
          ALTER TABLE messages ADD COLUMN is_read INTEGER NOT NULL DEFAULT 1
        ''');
        Log.d('[LocalDatabase] ✅ Migration to v3 complete');
      }

      // Migrate from v3 to v4: allow nullable username/display_name in user tables
      if (oldVersion < 4) {
        Log.d(
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

        Log.d('[LocalDatabase] ✅ Migration to v4 complete');
      }

      // Migrate from v4 to v5: add PQ key columns to contacts_cache
      if (oldVersion < 5) {
        Log.d('[LocalDatabase] ➕ Adding PQ key columns to contacts_cache');
        await db.execute(
          'ALTER TABLE contacts_cache ADD COLUMN pq_public_key BLOB',
        );
        await db.execute(
          'ALTER TABLE contacts_cache ADD COLUMN pq_shared_secret BLOB',
        );
        Log.d('[LocalDatabase] ✅ Migration to v5 complete');
      }

      // Migrate from v5 to v6: add alias_chats and alias_messages tables
      if (oldVersion < 6) {
        Log.d('[LocalDatabase] ➕ Adding alias_chats and alias_messages tables');
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
        Log.d('[LocalDatabase] ✅ Migration to v6 complete');
      }

      // Migrate from v6 to v7: add counterpart_address to alias_chats
      if (oldVersion < 7) {
        Log.d(
          '[LocalDatabase] ➕ Adding counterpart_address column to alias_chats',
        );
        await db.execute(
          'ALTER TABLE alias_chats ADD COLUMN counterpart_address TEXT',
        );
        Log.d('[LocalDatabase] ✅ Migration to v7 complete');
      }

      // Migrate from v7 to v8: add invite_dismissed flag to alias_chats
      if (oldVersion < 8) {
        Log.d(
          '[LocalDatabase] ➕ Adding invite_dismissed column to alias_chats',
        );
        await db.execute(
          'ALTER TABLE alias_chats ADD COLUMN invite_dismissed INTEGER NOT NULL DEFAULT 0',
        );
        Log.d('[LocalDatabase] ✅ Migration to v8 complete');
      }

      // Migrate from v8 to v9: rebuild alias_chats without pubkey/address/appId
      if (oldVersion < 9) {
        Log.d(
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
        Log.d('[LocalDatabase] ✅ Migration to v9 complete');
      }

      // Migrate from v9 to v10: add pq_public_key to user_profile
      if (oldVersion < 10) {
        Log.d('[LocalDatabase] ➕ Adding pq_public_key column to user_profile');
        await db.execute(
          'ALTER TABLE user_profile ADD COLUMN pq_public_key BLOB',
        );
        Log.d('[LocalDatabase] ✅ Migration to v10 complete');
      }

      // Migrate from v10 to v11: add ephemeral_wallets table (M14)
      if (oldVersion < 11) {
        Log.d('[LocalDatabase] ➕ Adding ephemeral_wallets table');
        await db.execute('''
          CREATE TABLE ephemeral_wallets (
            channel_id TEXT PRIMARY KEY,
            address TEXT NOT NULL,
            public_key BLOB NOT NULL,
            wrapped_sk BLOB NOT NULL,
            nonce BLOB NOT NULL,
            mac BLOB NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        Log.d('[LocalDatabase] ✅ Migration to v11 complete');
      }

      // Migrate from v11 to v12: legacy-origin tagging + migration_state ledger (M29).
      //
      // Pre-cutover rows came from the now-deprecated SEALED_MESSAGE_APP_ID +
      // ALIAS_CHANNEL_APP_ID flows. Schema is identical post-cutover, but the
      // UI needs to distinguish "this row was synced from a legacy app" so we
      // can render the migration banner and quarantine on read if the user
      // chooses. New rows default `legacy_origin=0`.
      if (oldVersion < 12) {
        Log.d(
          '[LocalDatabase] ➕ Adding legacy_origin columns + migration_state',
        );
        await db.execute(
          'ALTER TABLE messages ADD COLUMN legacy_origin INTEGER NOT NULL DEFAULT 0',
        );
        await db.execute(
          'ALTER TABLE alias_messages ADD COLUMN legacy_origin INTEGER NOT NULL DEFAULT 0',
        );
        await db.execute('''
          CREATE TABLE migration_state (
            key TEXT PRIMARY KEY,
            started_at INTEGER,
            completed_at INTEGER,
            rows_touched INTEGER,
            notes TEXT
          )
        ''');
        Log.d('[LocalDatabase] ✅ Migration to v12 complete');
      }

      // Migrate from v12 to v13: per-contact stable tag (Spec H §5.2).
      //
      // Adds the `contacts` + `contact_messages` tables that back the new
      // `OfflineContactService` / `AliasChatService`. M16 alias_chats /
      // alias_messages stay in place — already legacy-tagged in v12, surfaced
      // as Archived read-only. Users rescan QR / redo bootstrap to recreate
      // as a contact.
      if (oldVersion < 13) {
        Log.d('[LocalDatabase] ➕ Adding contacts + contact_messages (Spec H)');
        await db.execute('''
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
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS contact_messages (
            id              TEXT PRIMARY KEY,
            contact_id      TEXT NOT NULL REFERENCES contacts(contact_id),
            direction       INTEGER NOT NULL,
            content         TEXT NOT NULL,
            timestamp       INTEGER NOT NULL,
            on_chain_ref    TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_contacts_tag ON contacts(recipient_tag)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_contact_messages_contact ON contact_messages(contact_id, timestamp DESC)',
        );
        Log.d('[LocalDatabase] ✅ Migration to v13 complete');
      }

      // Migrate from v13 to v14: add pq_pubkey_hash column to user_profile
      // and contacts_cache (hash-anchor for indexer-served pq pubkey — spec
      // SPEC-mobile-clients-cutover.md §3.3). Additive ALTER, no row rewrite.
      if (oldVersion < 14) {
        Log.d(
          '[LocalDatabase] ➕ Adding pq_pubkey_hash to user_profile + contacts_cache',
        );
        await db.execute(
          'ALTER TABLE user_profile ADD COLUMN pq_pubkey_hash BLOB',
        );
        await db.execute(
          'ALTER TABLE contacts_cache ADD COLUMN pq_pubkey_hash BLOB',
        );
        Log.d('[LocalDatabase] ✅ Migration to v14 complete');
      }
      // Migrate from v14 to v15: alias-as-contact unification.
      //
      // Extends `contacts` with alias-only columns (is_alias, wallet_address,
      // alias_display, invite_ref, is_creator, peer_x25519_scan,
      // my_x25519_scan_sk, pq_shared_secret), relaxes peer_mlkem_pub +
      // my_mlkem_sk to nullable (classical-only peers), creates
      // `pending_invites`, and drops the legacy parallel-stack
      // `alias_chats` + `alias_messages` tables (pre-launch — no rows to
      // preserve). See `specs/alias-as-contact.spec.md` §2.
      if (oldVersion < 15) {
        Log.d(
          '[LocalDatabase] 🔁 v15: unifying alias chats into contacts (drop legacy alias tables, extend contacts, add pending_invites)',
        );

        // 1. Rebuild `contacts` with new alias columns + relaxed mlkem
        // nullability. SQLite cannot drop NOT NULL via ALTER, so we go via
        // rebuild-rename. Existing v13/v14 rows (wallet-kind only) survive
        // with is_alias=0 and scan fields backfilled from enc fields (until
        // a future master-keypair split lands).
        await db.execute('''
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
        ''');
        await db.execute('''
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
        ''');
        await db.execute('DROP TABLE contacts');
        await db.execute('ALTER TABLE contacts_v15 RENAME TO contacts');
        await db.execute(
          'CREATE INDEX idx_contacts_tag ON contacts(recipient_tag)',
        );
        await db.execute(
          'CREATE INDEX idx_contacts_alias ON contacts(is_alias)',
        );

        // 2. Rebuild `contact_messages` with ON DELETE CASCADE + is_read.
        await db.execute('''
          CREATE TABLE contact_messages_v15 (
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
          INSERT INTO contact_messages_v15 (
            id, contact_id, direction, content, timestamp, on_chain_ref
          )
          SELECT id, contact_id, direction, content, timestamp, on_chain_ref
          FROM contact_messages
        ''');
        await db.execute('DROP TABLE contact_messages');
        await db.execute(
          'ALTER TABLE contact_messages_v15 RENAME TO contact_messages',
        );
        await db.execute(
          'CREATE INDEX idx_contact_messages_contact ON contact_messages(contact_id, timestamp DESC)',
        );

        // 3. Create `pending_invites`.
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

        // 4. Drop legacy alias tables. Pre-launch — no row migration.
        await db.execute('DROP TABLE IF EXISTS alias_messages');
        await db.execute('DROP TABLE IF EXISTS alias_chats');

        Log.d('[LocalDatabase] ✅ Migration to v15 complete');
      }

      // Migrate from v15 to v16: add `alias` column to user_profile.
      // UserProfile model carries a nullable alias field used by the
      // settings/profile flow; schema never declared it, so INSERT OR
      // REPLACE INTO user_profile (..., alias, ...) failed with
      // "table user_profile has no column named alias". Additive ALTER.
      if (oldVersion < 16) {
        Log.d('[LocalDatabase] ➕ Adding alias column to user_profile');
        await db.execute('ALTER TABLE user_profile ADD COLUMN alias TEXT');
        Log.d('[LocalDatabase] ✅ Migration to v16 complete');
      }

      // Migrate from v16 to v17: add `alias` column to contacts_cache.
      // Symmetric with v16; ContactRepository.saveContact writes UserProfile
      // rows where toMap() includes `alias`, but the column never existed on
      // contacts_cache → INSERT OR REPLACE failed with "no column named
      // alias". Additive ALTER.
      if (oldVersion < 17) {
        Log.d('[LocalDatabase] ➕ Adding alias column to contacts_cache');
        await db.execute('ALTER TABLE contacts_cache ADD COLUMN alias TEXT');
        Log.d('[LocalDatabase] ✅ Migration to v17 complete');
      }

      // Migrate from v17 to v18: persistent manual block flag on contacts_cache.
      // Spam classification was read-time only (classical-only peers); a user
      // block of a hybrid/PQ contact needs durable state to stay in Spam across
      // sync/restart. Additive ALTER, DEFAULT 0 (not blocked).
      if (oldVersion < 18) {
        Log.d('[LocalDatabase] ➕ Adding is_blocked column to contacts_cache');
        await db.execute(
          'ALTER TABLE contacts_cache ADD COLUMN is_blocked INTEGER NOT NULL DEFAULT 0',
        );
        Log.d('[LocalDatabase] ✅ Migration to v18 complete');
      }

      // Migrate from v18 to v19: unify wallet contacts (`contacts_cache`) and
      // alias contacts into a single `contacts` table, discriminated by
      // `is_alias`. Fresh-wipe migration (no data preserved): both tables are
      // dropped and `contacts` is recreated empty in the unified shape, and
      // `contact_messages` (FK-bound to the dropped `contacts`) is cleared.
      // `user_profile` (device owner) and `messages` are untouched.
      if (oldVersion < 19) {
        Log.d(
          '[LocalDatabase] 🔀 Unifying contacts_cache + contacts (fresh wipe)',
        );
        await db.execute('DELETE FROM contact_messages');
        await db.execute('DROP TABLE IF EXISTS contacts_cache');
        await db.execute('DROP TABLE IF EXISTS contacts');
        await _createContactsSchema(db);
        Log.d('[LocalDatabase] ✅ Migration to v19 complete');
      }

      // Migrate from v19 to v20: profile bio (on-chain UserState v3). Additive
      // nullable column on the device-owner profile and cached wallet
      // contacts. A v18→v20 jump recreates `contacts` WITH bio in the v19
      // step above, so each ALTER is guarded against the column existing.
      if (oldVersion < 20) {
        Log.d('[LocalDatabase] 📝 Adding bio columns (v20)');
        for (final table in ['user_profile', 'contacts']) {
          final cols = await db.rawQuery('PRAGMA table_info($table)');
          final hasBio = cols.any((c) => c['name'] == 'bio');
          if (!hasBio) {
            await db.execute('ALTER TABLE $table ADD COLUMN bio TEXT');
          }
        }
        Log.d('[LocalDatabase] ✅ Migration to v20 complete');
      }

      // Migrate from v20 to v21: manual-contact flag. The `contacts` table is
      // a crypto key cache that auto-populates on send/receive; `is_contact`
      // marks rows the user deliberately added via "Add to contacts". Wallet
      // rows backfill to 0 (auto-inserted cache artifacts — no signal they
      // were deliberate adds); alias rows backfill to 1 (the alias handshake
      // is a deliberate mutual act).
      //
      // Guarded: a <19 → 21 upgrade already recreated `contacts` with the
      // column via _createContactsSchema, so an unguarded ALTER would throw
      // "duplicate column name".
      if (oldVersion < 21) {
        Log.d('[LocalDatabase] ➕ Adding is_contact column to contacts');
        final cols = await db.rawQuery('PRAGMA table_info(contacts)');
        final hasColumn = cols.any((c) => c['name'] == 'is_contact');
        if (!hasColumn) {
          await db.execute(
            'ALTER TABLE contacts ADD COLUMN is_contact INTEGER NOT NULL DEFAULT 0',
          );
        }
        await db.execute(
          'UPDATE contacts SET is_contact = 1 WHERE is_alias = 1',
        );
        Log.d('[LocalDatabase] ✅ Migration to v21 complete');
      }

      // Migrate to v22: install_epoch for stale alias-invite gating. EXISTING
      // installs backfill to 0 so their current pending invites still surface
      // (no regression) — only a fresh install / reinstall (onCreate) stamps a
      // real epoch, which is exactly the reinstall case we want to gate.
      if (oldVersion < 22) {
        Log.d('[LocalDatabase] 🕒 Adding install_epoch (v22, existing=0)');
        await db.insert('migration_state', {
          'key': 'install_epoch',
          'completed_at': 0,
          'notes': 'backfilled 0 for pre-v22 install (no invite gating)',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        Log.d('[LocalDatabase] ✅ Migration to v22 complete');
      }
    } catch (e, stackTrace) {
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
        version: 22,
        onCreate: (Database db, int version) async {
          await _onCreate(db, version);
        },
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          await _onUpgrade(db, oldVersion, newVersion);
        },
      );

      // Self-heal probe: SQLCipher silently mounts an existing file with a
      // mismatched key as read-only. Reads pass; writes fail later with
      // "attempt to write a readonly database". Detect now by writing a
      // no-op probe row inside a transaction (rolled back) so we surface a
      // dedicated KEY_MISMATCH code the caller can recover from by wiping
      // the file + DEK and rebootstrapping. See pin_provider._initialize.
      try {
        await _db!.transaction((txn) async {
          await txn.execute(
            'CREATE TABLE IF NOT EXISTS _key_probe (x INTEGER)',
          );
          await txn.execute('INSERT INTO _key_probe(x) VALUES (1)');
          // Force rollback so probe leaves no rows. Throwing inside a
          // sqflite transaction triggers ROLLBACK and rethrows.
          throw _ProbeRollback();
        });
      } on _ProbeRollback {
        // Expected — write succeeded, rolled back cleanly.
      } catch (e) {
        // Any other failure here = readonly mount / key mismatch.
        try {
          await _db!.close();
        } catch (_) {}
        _db = null;
        throw DatabaseKeyMismatchException(
          'DB opened read-only — DEK does not match file key. '
          'Wipe DB + DEK and rebootstrap.',
        );
      }
      return _db!;
    } on DatabaseKeyMismatchException {
      rethrow;
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
      Log.d('[LocalDatabase] ⚠️ close failed during delete: $e');
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

  /// Verify the given DEK actually decrypts the on-disk DB before the rest
  /// of the app starts issuing writes. Opens a throwaway handle, attempts a
  /// rolled-back write, and closes. Returns true if writable, false if the
  /// key produced a read-only mount or the open itself failed. No mutation
  /// to the singleton `_db`.
  ///
  /// Callers use this from the bootstrap path so they can wipe + rebootstrap
  /// when the wrapped DEK and DB file have drifted out of sync (the "both
  /// present, mismatched" case the (a)/(b) self-heal in pin_provider does
  /// not catch).
  static Future<bool> verifyKey(Uint8List dek) async {
    final hasFile = await fileExists();
    if (!hasFile) return true; // fresh DB will be created with this key
    final password = base64.encode(dek);
    Database? probe;
    try {
      probe = await openDatabase('sealed_messages.db', password: password);
      await probe.transaction((txn) async {
        await txn.execute('CREATE TABLE IF NOT EXISTS _key_probe (x INTEGER)');
        await txn.execute('INSERT INTO _key_probe(x) VALUES (1)');
        throw const _ProbeRollback();
      });
      // Unreachable: the transaction always throws _ProbeRollback to force
      // a rollback. Treat as success if sqflite ever changes behaviour.
      // ignore: dead_code
      return true;
    } on _ProbeRollback {
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await probe?.close();
      } catch (_) {}
    }
  }
}
