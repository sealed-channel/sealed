import 'package:flutter/foundation.dart';
import 'package:sealed_app/infra/chain/chain_address.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/infra/local/repositories/contact_keys.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/models/contact.dart' as model;
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/crypto/key_format_converter.dart';
import 'package:sqflite/sqflite.dart';

/// Lazy resolver for the async [SealedChainClient]. Allows the repository to
/// remain a synchronous provider while still consuming chain reads on demand.
typedef SealedChainClientResolver = Future<SealedChainClient> Function();

abstract class ContactRepository {
  // CRUD
  Future<void> saveContact(UserProfile profile);
  Future<UserProfile?> getContact(String walletAddress);
  Future<List<UserProfile>> getAllContacts();
  Future<void> deleteContact(String walletAddress);
  Future<void> clear();

  /// Persistent manual block. Blocked wallet contacts are surfaced in the Spam
  /// tab (the only spam predicate) and their messages no longer trigger local
  /// notifications; they survive sync/restart. Blocking also clears the
  /// manual-contact flag (is_contact = 0); unblocking does NOT restore it —
  /// the user must explicitly re-add.
  /// No-op if no wallet-contact row (is_alias = 0) exists for [walletAddress].
  Future<void> blockContact(String walletAddress);
  Future<void> unblockContact(String walletAddress);

  /// True if [walletAddress] is manually blocked. False if not blocked or no
  /// wallet-contact row (is_alias = 0) exists.
  Future<bool> isBlocked(String walletAddress);

  /// All currently-blocked wallet addresses (is_blocked = 1, is_alias = 0).
  /// Used to reconcile the PIN-free background block mirror (#17).
  Future<List<String>> getBlockedWallets();

  /// Manual-contact flag. The `contacts` table is a crypto key cache that
  /// auto-populates on send/receive; `is_contact = 1` marks rows the user
  /// deliberately added via "Add to contacts" on the profile screen. If no
  /// wallet-contact row exists yet, one is lazily created via the
  /// saveContactKeys resolver before the flag is set. Throws if the row
  /// cannot be created (e.g. offline and keys unresolvable).
  Future<void> addToContacts(String walletAddress);
  Future<void> removeFromContacts(String walletAddress);

  /// True if [walletAddress] was manually added to contacts. False if not
  /// added or no wallet-contact row (is_alias = 0) exists.
  Future<bool> isContact(String walletAddress);

  /// Manually-added wallet contacts only (is_alias = 0 AND is_contact = 1).
  /// This is what the Contacts screen lists — auto-inserted key-cache rows
  /// are excluded. Use [getAllContacts] for the full cache dump.
  Future<List<UserProfile>> getManualContacts();

  // Search
  /// Exact match: wallet address OR username.
  Future<UserProfile?> searchContact(String query);

  /// Fuzzy: LIKE %q% over username and wallet_address. Capped, sorted by cached_at DESC.
  Future<List<UserProfile>> searchContacts(String query, {int limit = 20});

  // Keys
  /// Returns whatever subset of keys is currently stored. Missing keys are null.
  Future<ContactKeys> getContactKeys(String walletAddress);

  /// Save any subset of keys independently. null = leave existing value untouched.
  Future<void> saveContactKeys(
    String walletAddress, {
    Uint8List? pqPublicKey,
    Uint8List? pqSharedSecret,
    Uint8List? encryptionPubkey,
    Uint8List? scanPubkey,
  });

  /// Clear cached PQ material (pq_public_key + pq_shared_secret) for a peer.
  /// Use when on-chain pqPubkeyHash rotates — forces fresh KEM handshake on
  /// the next send. Leaves classical encryption/scan pubkeys untouched.
  Future<void> invalidatePqCache(String walletAddress);

  /// One-shot recovery: clear pq_shared_secret for ALL contacts. Forces
  /// fresh KEM handshake on next send to anyone. Used to recover from
  /// historically diverged caches (sender + receiver holding mismatched
  /// secrets) once the underlying bug that caused divergence is fixed.
  /// Leaves classical pubkeys + pq_public_key untouched.
  Future<int> wipeAllPqSecrets();

  // ─── Alias-as-contact (v15; unified table v19) ─────────────────────────────
  // Backed by the unified `contacts` table (is_alias = 1 rows). Stores stable
  // per-counterpart handshake state (msg_key, recipient_tag, key bundle).
  // Wallet contacts share the same table as is_alias = 0 rows (v19).
  // See `models/contact.dart`.

  Future<void> saveAliasContact(model.AliasContact contact);
  Future<model.AliasContact?> getAliasContact(String contactId);
  Future<List<model.AliasContact>> getAllAliasContacts();
  Future<void> deleteAliasContact(String contactId);
  Future<void> updateNickname(String contactId, String? nickname);

  /// Lookup by `invite_ref` (sha256(inviteSecret) hex). Returns either kind —
  /// alias contacts use `invite_ref` as their key; wallet contacts are NULL.
  Future<model.Contact?> getContactByInviteRef(String inviteRef);

  // Pending invites — in-flight onboarding state. Promoted to a `contacts`
  // row by `AliasOnboardingService.completeKeyExchange` in the same txn that
  // deletes the pending row.
  Future<void> savePendingInvite(PendingInvite invite);
  Future<PendingInvite?> getPendingInvite(String inviteRef);
  Future<List<PendingInvite>> getAllPendingInvites();
  Future<void> deletePendingInvite(String inviteRef);
  Future<void> markInviteDismissed(String inviteRef);

  /// Atomic pending → contact promotion: inserts contact + deletes pending in
  /// the same sqflite transaction. Throws if the pending row is missing.
  Future<void> promotePendingToContact({
    required String inviteRef,
    required model.AliasContact contact,
  });

  /// Alias-contact preview list (Spec H contacts only), joined with each
  /// contact's latest `contact_messages` row. Pending invites are NOT
  /// included here; callers merge them in at the UI layer.
  Future<List<ChatPreview>> getAliasPreviews({int limit = 100});

  // ---------------------------------------------------------------------------
  // Contact messages (alias + future wallet-contact messages)
  // ---------------------------------------------------------------------------

  /// Persist a [ContactMessage] row. Upserts by `id`.
  Future<void> saveContactMessage(model.ContactMessage message);

  /// Load all messages for [contactId], ordered by timestamp ASC.
  Future<List<model.ContactMessage>> getContactMessages(String contactId);

  /// Mark all messages for [contactId] as read.
  /// Returns the number of rows flipped to read (0 = nothing was unread).
  Future<int> markContactMessagesRead(String contactId);

  /// Mark every incoming alias message across all contacts as read. Used by the
  /// restore / force-resync paths: recovered history carries no read state, so
  /// it is surfaced as already-read rather than a wall of unread badges.
  Future<void> markAllContactMessagesRead();
}

/// Pending-invite row from `pending_invites`. Lives only between
/// `acceptInvitation` / `createInvitation` and `completeKeyExchange`.
class PendingInvite {
  final String inviteRef;
  final String aliasDisplay;
  final bool isCreator;
  final String status; // 'pending' | 'awaiting_accept'
  final int createdAt;
  final bool inviteDismissed;

  const PendingInvite({
    required this.inviteRef,
    required this.aliasDisplay,
    required this.isCreator,
    required this.status,
    required this.createdAt,
    this.inviteDismissed = false,
  });

  Map<String, Object?> toRow() => {
    'invite_ref': inviteRef,
    'alias_display': aliasDisplay,
    'is_creator': isCreator ? 1 : 0,
    'status': status,
    'created_at': createdAt,
    'invite_dismissed': inviteDismissed ? 1 : 0,
  };

  static PendingInvite fromRow(Map<String, Object?> r) => PendingInvite(
    inviteRef: r['invite_ref'] as String,
    aliasDisplay: r['alias_display'] as String,
    isCreator: (r['is_creator'] as int? ?? 0) == 1,
    status: r['status'] as String,
    createdAt: r['created_at'] as int,
    inviteDismissed: (r['invite_dismissed'] as int? ?? 0) == 1,
  );
}

class ContactRepositoryImpl implements ContactRepository {
  ContactRepositoryImpl(
    this._db, {
    IndexerClient? indexer,
    SealedChainClientResolver? chainResolver,
  }) : _indexer = indexer,
       _chainResolver = chainResolver;

  final LocalDatabase _db;
  final IndexerClient? _indexer;
  final SealedChainClientResolver? _chainResolver;

  @override
  Future<void> saveContact(UserProfile profile) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      // Preserve KEM-derived secrets AND user-state flags across REPLACE.
      // UserProfile.toMap() omits pq_shared_secret (and may omit
      // pq_public_key for legacy callers) plus is_blocked / is_contact — a
      // naive REPLACE would wipe the row's PQ material (breaking
      // hybrid-decrypt for this peer) and silently reset block/contact state
      // on every 120s username-refresh pass.
      final existing = await txn.query(
        'contacts',
        columns: [
          'pq_shared_secret',
          'pq_public_key',
          'is_blocked',
          'is_contact',
        ],
        where: 'contact_id = ? AND is_alias = 0',
        whereArgs: [profile.walletAddress],
        limit: 1,
      );
      final row = profile.toMap();
      // Unified-table required columns not carried by UserProfile.toMap():
      // wallet contacts key on contact_id = walletAddress, is_alias = 0, and
      // alias_label (legacy NOT NULL) is the empty-string sentinel.
      row['contact_id'] = profile.walletAddress;
      row['is_alias'] = 0;
      row['alias_label'] = '';
      if (existing.isNotEmpty) {
        final prevSecret = existing.first['pq_shared_secret'] as Uint8List?;
        final prevPqPub = existing.first['pq_public_key'] as Uint8List?;
        if (prevSecret != null && row['pq_shared_secret'] == null) {
          row['pq_shared_secret'] = prevSecret;
        }
        if (prevPqPub != null && row['pq_public_key'] == null) {
          row['pq_public_key'] = prevPqPub;
        }
        row['is_blocked'] = existing.first['is_blocked'] as int? ?? 0;
        row['is_contact'] = existing.first['is_contact'] as int? ?? 0;
      }
      await txn.insert(
        'contacts',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<UserProfile?> getContact(String walletAddress) async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UserProfile.fromMap(rows.first);
  }

  @override
  Future<List<UserProfile>> getAllContacts() async {
    final db = await _db.database;
    // MUST filter is_alias = 0: alias rows have NULL encryption_pubkey, which
    // would null-cast-crash UserProfile.fromMap.
    final rows = await db.query('contacts', where: 'is_alias = 0');
    return rows.map((e) => UserProfile.fromMap(e)).toList();
  }

  @override
  Future<void> deleteContact(String walletAddress) async {
    final db = await _db.database;
    await db.delete(
      'contacts',
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
    );
  }

  @override
  Future<void> clear() async {
    final db = await _db.database;
    // Wallet contacts only — alias contacts (is_alias = 1) are left intact.
    await db.delete('contacts', where: 'is_alias = 0');
  }

  @override
  Future<void> blockContact(String walletAddress) =>
      _setBlocked(walletAddress, true);

  @override
  Future<void> unblockContact(String walletAddress) =>
      _setBlocked(walletAddress, false);

  @override
  Future<List<String>> getBlockedWallets() async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      columns: ['contact_id'],
      where: 'is_blocked = 1 AND is_alias = 0',
    );
    return [for (final r in rows) r['contact_id'] as String];
  }

  Future<void> _setBlocked(String walletAddress, bool blocked) async {
    final db = await _db.database;
    await db.update(
      'contacts',
      {
        'is_blocked': blocked ? 1 : 0,
        // Blocking evicts from Contacts too — unblocking deliberately does NOT
        // restore membership, so a freshly unblocked peer is not-a-contact
        // until the user re-adds them.
        if (blocked) 'is_contact': 0,
      },
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
    );
  }

  @override
  Future<bool> isBlocked(String walletAddress) async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      columns: ['is_blocked'],
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return (rows.first['is_blocked'] as int? ?? 0) == 1;
  }

  @override
  Future<void> addToContacts(String walletAddress) async {
    final db = await _db.database;
    final updated = await db.update(
      'contacts',
      {'is_contact': 1},
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
    );
    if (updated > 0) return;

    // No key-cache row yet (e.g. profile opened from search before any
    // message). Lazily resolve the peer's profile from chain/indexer (or
    // wallet-derived fallback) to create the row, then flag it. Note
    // saveContactKeys() can't be used here — it no-ops with no key args.
    final resolved = await _resolveProfile(walletAddress);
    if (resolved != null) {
      await saveContact(resolved);
    }
    final flagged = await db.update(
      'contacts',
      {'is_contact': 1},
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
    );
    if (flagged == 0) {
      throw StateError(
        'addToContacts: could not create contact row for $walletAddress '
        '(keys unresolvable — offline?)',
      );
    }
  }

  @override
  Future<void> removeFromContacts(String walletAddress) async {
    final db = await _db.database;
    await db.update(
      'contacts',
      {'is_contact': 0},
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
    );
  }

  @override
  Future<bool> isContact(String walletAddress) async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      columns: ['is_contact'],
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return (rows.first['is_contact'] as int? ?? 0) == 1;
  }

  @override
  Future<List<UserProfile>> getManualContacts() async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      where: 'is_alias = 0 AND is_contact = 1',
    );
    return rows.map((e) => UserProfile.fromMap(e)).toList();
  }

  @override
  Future<UserProfile?> searchContact(String query) async {
    // Try exact wallet match first, then exact username match.
    final byWallet = await getContact(query);
    if (byWallet != null) return byWallet;

    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      where: 'username = ? AND is_alias = 0',
      whereArgs: [query],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UserProfile.fromMap(rows.first);
  }

  @override
  Future<List<UserProfile>> searchContacts(
    String query, {
    int limit = 20,
  }) async {
    final db = await _db.database;
    final pattern = '%$query%';
    // is_contact = 1: only deliberate contacts, matching the Contacts screen.
    // Removing a contact soft-deletes (is_contact = 0), so it must drop out of
    // search too; raw key-cache rows (auto-inserted on message) are likewise
    // excluded — new users are still found via the remote username scope.
    final rows = await db.query(
      'contacts',
      where:
          '(username LIKE ? OR wallet_address LIKE ?) AND is_alias = 0 AND is_contact = 1',
      whereArgs: [pattern, pattern],
      orderBy: 'cached_at DESC',
      limit: limit,
    );
    return rows.map((e) => UserProfile.fromMap(e)).toList();
  }

  @override
  Future<ContactKeys> getContactKeys(String walletAddress) async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      columns: [
        'pq_public_key',
        'pq_shared_secret',
        'encryption_pubkey',
        'scan_pubkey',
      ],
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
      limit: 1,
    );
    final row = rows.isEmpty ? null : rows.first;
    final cached = ContactKeys(
      pqPublicKey: row?['pq_public_key'] as Uint8List?,
      pqSharedSecret: row?['pq_shared_secret'] as Uint8List?,
      encryptionPubkey: row?['encryption_pubkey'] as Uint8List?,
      scanPubkey: row?['scan_pubkey'] as Uint8List?,
    );

    // Fast path: everything we need is cached, or lazy-fetch deps unavailable.
    final hasClassicalCached =
        cached.encryptionPubkey != null && cached.scanPubkey != null;
    if ((cached.pqPublicKey != null && hasClassicalCached) ||
        _indexer == null ||
        _chainResolver == null) {
      return cached;
    }

    // Lazy lookup: try on-chain + indexer, then fall back to deriving the
    // classical X25519 keys from the wallet address for unregistered users.
    // NOTE: this method is a pure resolver — it does NOT persist anything.
    // The caller decides whether the resolved keys should be cached.
    final resolved = await _resolveProfile(walletAddress);
    if (resolved == null) return cached;

    return ContactKeys(
      pqPublicKey: cached.pqPublicKey ?? resolved.pqPublicKey,
      pqSharedSecret: cached.pqSharedSecret,
      encryptionPubkey: cached.encryptionPubkey ?? resolved.encryptionPubkey,
      scanPubkey: cached.scanPubkey ?? resolved.scanPubkey,
    );
  }

  /// Resolves a [UserProfile]-shaped key bundle for [walletAddress] without
  /// touching local storage.
  ///
  /// Resolution order:
  ///   1. On-chain `getUserByWallet` → published encryption/scan pubkeys.
  ///      If a `pqPubkeyHash` anchor exists, fetch the PQ pubkey from the
  ///      indexer and verify it against the anchor (constant-time).
  ///   2. If the wallet has no on-chain registration, derive X25519
  ///      encryption/scan pubkeys from the Ed25519 wallet address. PQ
  ///      remains null (free-user / unregistered → classical-only).
  ///
  /// Returns null only on unrecoverable errors (e.g. malformed wallet).
  Future<UserProfile?> _resolveProfile(String walletAddress) async {
    final indexer = _indexer;
    final chainResolver = _chainResolver;
    if (indexer == null || chainResolver == null) return null;

    try {
      final chain = await chainResolver();
      final onChain = await chain.getUserByWallet(walletAddress);

      if (onChain != null) {
        Uint8List? verifiedPq;
        final anchorHash = onChain.pqPubkeyHash;
        if (anchorHash != null) {
          verifiedPq = await _fetchAndVerifyPqPubkey(walletAddress, anchorHash);
        }

        // On-chain box exists but publishKeys was never called (or wiped) —
        // both classical pubkeys are 32 zero bytes. Treat as unregistered
        // and fall back to wallet-derived keys so the sender can still
        // encrypt to a key the recipient can actually derive.
        final encZero = _isAllZero(onChain.encryptionPubkey);
        final scanZero = _isAllZero(onChain.scanPubkey);
        if (encZero || scanZero) {
          final derived = _deriveProfileFromWallet(walletAddress);
          if (derived == null) return null;
          return UserProfile(
            walletAddress: onChain.walletAddress,
            username: onChain.username,
            alias: onChain.alias,
            encryptionPubkey: derived.encryptionPubkey,
            scanPubkey: derived.scanPubkey,
            pqPublicKey: verifiedPq,
            pqPubkeyHash: onChain.pqPubkeyHash,
            createdAt: onChain.createdAt,
          );
        }
        // return with verified PQ pubkey (may be null if no anchor or fetch/verify failed) —
        return UserProfile(
          walletAddress: onChain.walletAddress,
          username: onChain.username,
          alias: onChain.alias,
          encryptionPubkey: onChain.encryptionPubkey,
          scanPubkey: onChain.scanPubkey,
          pqPublicKey: verifiedPq,
          pqPubkeyHash: onChain.pqPubkeyHash,
          createdAt: onChain.createdAt,
        );
      }

      // No on-chain registration — derive classical X25519 keys from the
      // Ed25519 wallet pubkey so the sender can still encrypt to them.
      return _deriveProfileFromWallet(walletAddress);
    } catch (e) {
      debugPrint(
        '[ContactRepository] profile resolve error for $walletAddress: $e',
      );
      return null;
    }
  }

  /// Derives a minimal [UserProfile] for an unregistered wallet by mapping
  /// the Ed25519 wallet pubkey to X25519 via the birational map. Both
  /// encryption and scan pubkeys are set to the same derived value, which
  /// matches the fallback behavior in `MessageService.sendMessage`.
  UserProfile? _deriveProfileFromWallet(String walletAddress) {
    try {
      final walletBytes = ChainAddress.decode(walletAddress, 'algorand');
      if (walletBytes.length != 32) return null;
      final derived = ed25519PublicKeyToX25519(Uint8List.fromList(walletBytes));
      return UserProfile(
        walletAddress: walletAddress,
        encryptionPubkey: derived,
        scanPubkey: derived,
        createdAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint(
        '[ContactRepository] wallet-derived key fallback failed for '
        '$walletAddress: $e',
      );
      return null;
    }
  }

  bool _isAllZero(Uint8List bytes) {
    for (final b in bytes) {
      if (b != 0) return false;
    }
    return true;
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Fetches the PQ pubkey from the indexer and verifies its sha256 matches
  /// the on-chain `pqPubkeyHash` anchor. Returns null on any failure
  /// (NOT_PUBLISHED, hash mismatch, network error).
  Future<Uint8List?> _fetchAndVerifyPqPubkey(
    String walletAddress,
    Uint8List anchorHash,
  ) async {
    final indexer = _indexer;
    if (indexer == null) return null;

    final result = await indexer.getPqPublicKey(walletAddress);
    if (result is! IndexerSuccess<PqPublicKeyResponse>) {
      debugPrint(
        '[ContactRepository] indexer pq-pubkey fetch failed for '
        '$walletAddress',
      );
      return null;
    }

    final pq = result.data.pqPubkey;
    if (!UserProfile.verifyPqPubkey(pq, anchorHash)) {
      debugPrint(
        '[ContactRepository] ⚠️ pq pubkey hash mismatch for $walletAddress '
        '— indexer data rejected',
      );
      return null;
    }
    return pq;
  }

  @override
  Future<void> saveContactKeys(
    String walletAddress, {
    Uint8List? pqPublicKey,
    Uint8List? pqSharedSecret,
    Uint8List? encryptionPubkey,
    Uint8List? scanPubkey,
  }) async {
    final updates = <String, Object?>{};
    if (pqPublicKey != null) updates['pq_public_key'] = pqPublicKey;
    if (pqSharedSecret != null) updates['pq_shared_secret'] = pqSharedSecret;
    if (encryptionPubkey != null)
      updates['encryption_pubkey'] = encryptionPubkey;
    if (scanPubkey != null) updates['scan_pubkey'] = scanPubkey;

    if (updates.isEmpty) return;

    final db = await _db.database;
    await db.transaction((txn) async {
      // If caller supplied a new pqPublicKey that differs from cached, drop
      // pq_shared_secret unless caller also passed a fresh one. Prevents a
      // stale KEM-derived secret from being paired with a rotated pubkey
      // (= silent HKDF divergence on the peer = MAC fail on decrypt).
      if (pqPublicKey != null && pqSharedSecret == null) {
        final existing = await txn.query(
          'contacts',
          columns: ['pq_public_key'],
          where: 'contact_id = ? AND is_alias = 0',
          whereArgs: [walletAddress],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final prev = existing.first['pq_public_key'] as Uint8List?;
          final same =
              prev != null &&
              prev.length == pqPublicKey.length &&
              _bytesEqual(prev, pqPublicKey);
          if (!same) {
            updates['pq_shared_secret'] = null;
            debugPrint(
              '[ContactRepository] 🔄 pqPublicKey changed for $walletAddress — clearing pq_shared_secret',
            );
          }
        }
      }

      // PQ-pubkey backfill: if a row already exists with NULL pq_public_key
      // and the caller didn't pass one explicitly, lazy-resolve it from
      // chain/indexer once so a stub row inserted before the peer's
      // publishKeys txn was ingested still gains hybrid encryption on the
      // next send. (No longer drives spam classification — spam = blocked
      // only — purely a key-cache warm.)
      if (pqPublicKey == null) {
        final existing = await txn.query(
          'contacts',
          columns: ['pq_public_key'],
          where: 'contact_id = ? AND is_alias = 0',
          whereArgs: [walletAddress],
          limit: 1,
        );
        if (existing.isNotEmpty &&
            (existing.first['pq_public_key'] as Uint8List?) == null) {
          final resolved = await _resolveProfile(walletAddress);
          final resolvedPq = resolved?.pqPublicKey;
          if (resolvedPq != null) updates['pq_public_key'] = resolvedPq;
        }
      }

      final updated = await txn.update(
        'contacts',
        updates,
        where: 'contact_id = ? AND is_alias = 0',
        whereArgs: [walletAddress],
      );
      if (updated > 0) return;

      // Row didn't exist — insert. encryption_pubkey + scan_pubkey are NOT NULL
      // in the schema; if caller didn't supply them, resolve from chain/indexer
      // (or wallet-derive fallback) so the pq_shared_secret is not silently lost.
      // We also reuse the resolver result to backfill pq_public_key so a
      // first-incoming-from-new-peer flow gains hybrid encryption immediately.
      Uint8List? encPub = encryptionPubkey;
      Uint8List? scanPub = scanPubkey;
      Uint8List? resolvedPqPub;
      if (encPub == null || scanPub == null) {
        final resolved = await _resolveProfile(walletAddress);
        encPub ??= resolved?.encryptionPubkey;
        scanPub ??= resolved?.scanPubkey;
        resolvedPqPub = resolved?.pqPublicKey;
      }
      if (encPub == null || scanPub == null) {
        debugPrint(
          '[ContactRepository] ⚠️ saveContactKeys insert skipped for '
          '$walletAddress — encryption/scan pubkeys unresolvable',
        );
        return;
      }

      final pqPubToInsert = pqPublicKey ?? resolvedPqPub;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await txn.insert('contacts', {
        // Unified-table keys for a wallet contact: contact_id = walletAddress,
        // is_alias = 0, alias_label '' sentinel (legacy NOT NULL).
        'contact_id': walletAddress,
        'is_alias': 0,
        'alias_label': '',
        'wallet_address': walletAddress,
        'encryption_pubkey': encPub,
        'scan_pubkey': scanPub,
        'created_at': now,
        'cached_at': now,
        if (pqPubToInsert != null) 'pq_public_key': pqPubToInsert,
        if (pqSharedSecret != null) 'pq_shared_secret': pqSharedSecret,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> invalidatePqCache(String walletAddress) async {
    final db = await _db.database;
    await db.update(
      'contacts',
      {'pq_public_key': null, 'pq_shared_secret': null},
      where: 'contact_id = ? AND is_alias = 0',
      whereArgs: [walletAddress],
    );
  }

  @override
  Future<int> wipeAllPqSecrets() async {
    final db = await _db.database;
    // Wallet contacts only — alias rows manage their own pq_shared_secret.
    return db.update('contacts', {
      'pq_shared_secret': null,
    }, where: 'is_alias = 0');
  }

  // ─── Alias-as-contact (v15) ───────────────────────────────────────────────

  @override
  Future<void> saveAliasContact(model.AliasContact contact) async {
    final db = await _db.database;
    await db.insert(
      'contacts',
      contact.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<model.AliasContact?> getAliasContact(String contactId) async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      where: 'contact_id = ? AND is_alias = 1',
      whereArgs: [contactId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final c = model.Contact.fromRow(rows.first);
    return c is model.AliasContact ? c : null;
  }

  @override
  Future<List<model.AliasContact>> getAllAliasContacts() async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      where: 'is_alias = 1',
      orderBy: 'created_at DESC',
    );
    return rows
        .map(model.Contact.fromRow)
        .whereType<model.AliasContact>()
        .toList();
  }

  @override
  Future<void> deleteAliasContact(String contactId) async {
    final db = await _db.database;
    // Explicit cascade — `PRAGMA foreign_keys = ON` is per-connection and
    // not guaranteed on every sqflite handle (off by default on iOS/Android
    // sqflite plugin even when the schema declares ON DELETE CASCADE).
    // Delete inside a txn, and only touch rows when the contact really is
    // alias-kind so an id collision with a wallet-kind row is safe.
    await db.transaction((txn) async {
      final match = await txn.query(
        'contacts',
        columns: ['contact_id'],
        where: 'contact_id = ? AND is_alias = 1',
        whereArgs: [contactId],
        limit: 1,
      );
      if (match.isEmpty) return;
      await txn.delete(
        'contact_messages',
        where: 'contact_id = ?',
        whereArgs: [contactId],
      );
      await txn.delete(
        'contacts',
        where: 'contact_id = ? AND is_alias = 1',
        whereArgs: [contactId],
      );
    });
  }

  @override
  Future<void> updateNickname(String contactId, String? nickname) async {
    final db = await _db.database;
    await db.update(
      'contacts',
      {'alias_label': nickname ?? ''},
      where: 'contact_id = ? AND is_alias = 1',
      whereArgs: [contactId],
    );
  }

  @override
  Future<model.Contact?> getContactByInviteRef(String inviteRef) async {
    final db = await _db.database;
    final rows = await db.query(
      'contacts',
      where: 'invite_ref = ?',
      whereArgs: [inviteRef],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return model.Contact.fromRow(rows.first);
  }

  @override
  Future<void> savePendingInvite(PendingInvite invite) async {
    final db = await _db.database;
    await db.insert(
      'pending_invites',
      invite.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<PendingInvite?> getPendingInvite(String inviteRef) async {
    final db = await _db.database;
    final rows = await db.query(
      'pending_invites',
      where: 'invite_ref = ?',
      whereArgs: [inviteRef],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PendingInvite.fromRow(rows.first);
  }

  @override
  Future<List<PendingInvite>> getAllPendingInvites() async {
    final db = await _db.database;
    final rows = await db.query('pending_invites', orderBy: 'created_at DESC');
    return rows.map(PendingInvite.fromRow).toList();
  }

  @override
  Future<void> deletePendingInvite(String inviteRef) async {
    final db = await _db.database;
    await db.delete(
      'pending_invites',
      where: 'invite_ref = ?',
      whereArgs: [inviteRef],
    );
  }

  @override
  Future<void> markInviteDismissed(String inviteRef) async {
    final db = await _db.database;
    await db.update(
      'pending_invites',
      {'invite_dismissed': 1},
      where: 'invite_ref = ?',
      whereArgs: [inviteRef],
    );
  }

  @override
  Future<void> promotePendingToContact({
    required String inviteRef,
    required model.AliasContact contact,
  }) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final pending = await txn.query(
        'pending_invites',
        where: 'invite_ref = ?',
        whereArgs: [inviteRef],
        limit: 1,
      );
      if (pending.isEmpty) {
        throw StateError('No pending invite for $inviteRef');
      }
      await txn.insert(
        'contacts',
        contact.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'pending_invites',
        where: 'invite_ref = ?',
        whereArgs: [inviteRef],
      );
    });
  }

  @override
  Future<List<ChatPreview>> getAliasPreviews({int limit = 100}) async {
    final db = await _db.database;
    // Single query: alias-kind contacts LEFT JOIN their latest message via
    // a correlated subquery on contact_messages.timestamp DESC. Limit at
    // the SQL layer to avoid hydrating every row.
    final rows = await db.rawQuery(
      '''
      SELECT c.*,
             m.content    AS _last_content,
             m.timestamp  AS _last_ts,
             m.direction  AS _last_dir,
             (
               SELECT COUNT(*) FROM contact_messages u
               WHERE u.contact_id = c.contact_id
                 AND u.direction = 0
                 AND u.is_read = 0
             ) AS _unread_count
      FROM contacts c
      LEFT JOIN contact_messages m
        ON m.id = (
          SELECT id FROM contact_messages
          WHERE contact_id = c.contact_id
          ORDER BY timestamp DESC
          LIMIT 1
        )
      WHERE c.is_alias = 1
      ORDER BY COALESCE(m.timestamp, c.created_at * 1000) DESC
      LIMIT ?
      ''',
      [limit],
    );

    return rows.map((r) {
      final contact = model.Contact.fromRow(r) as model.AliasContact;
      return ChatPreview.fromAliasRow(
        contact: contact,
        lastMessageContent: r['_last_content'] as String?,
        lastMessageTimestamp: r['_last_ts'] as int?,
        lastMessageDirection: r['_last_dir'] as int?,
        unreadCount: (r['_unread_count'] as int?) ?? 0,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Contact messages
  // ---------------------------------------------------------------------------

  @override
  Future<void> saveContactMessage(model.ContactMessage message) async {
    final db = await _db.database;
    await db.insert(
      'contact_messages',
      message.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<model.ContactMessage>> getContactMessages(
    String contactId,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'contact_messages',
      where: 'contact_id = ?',
      whereArgs: [contactId],
      orderBy: 'timestamp DESC',
    );
    return rows.map(model.ContactMessage.fromRow).toList();
  }

  @override
  Future<int> markContactMessagesRead(String contactId) async {
    final db = await _db.database;
    return db.update(
      'contact_messages',
      {'is_read': 1},
      where: 'contact_id = ? AND is_read = 0',
      whereArgs: [contactId],
    );
  }

  @override
  Future<void> markAllContactMessagesRead() async {
    final db = await _db.database;
    await db.update('contact_messages', {'is_read': 1}, where: 'is_read = 0');
  }
}
