import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sqflite/sqflite.dart';

class MessageRepositoryException implements Exception {
  final String message;
  final String? code;

  MessageRepositoryException(this.message, {this.code});

  @override
  String toString() =>
      'MessageRepositoryException: $message${code != null ? ' ($code)' : ''}';
}

/// Transition alias so callers migrated from MessageCache can use either name.
typedef MessageCacheException = MessageRepositoryException;

/// True if [content] is an alias-handshake carrier DM (invite / accept / key
/// envelope). These are filtered out of the chat thread, so they must never
/// count as unread on the underlying wallet conversation. Mirrors
/// `isAliasInviteEnvelope` in the messaging feature — kept local so infra stays
/// feature-blind.
bool _isAliasCarrier(String content) =>
    content.startsWith('sealed://alias?') ||
    content.startsWith('sealed://alias-envelope?');

abstract class MessageRepository {
  Future<void> saveMessage(DecryptedMessage message);
  Future<bool> hasMessage(String txSignature);

  /// ms-since-epoch when this local DB was created (fresh install / reinstall),
  /// 0 for installs that predate the install_epoch migration. Used to gate
  /// resurfacing of stale alias invites whose on-chain timestamp predates it.
  Future<int> getInstallEpoch();

  /// Return the subset of [txSignatures] that already exist locally. Lets a
  /// sync pass pre-filter a batch with one query instead of N hasMessage calls.
  Future<Set<String>> existingMessageIds(List<String> txSignatures);
  Future<DecryptedMessage?> getMessageByPubkey(String onChainPubkey);
  Future<void> saveMessages(List<DecryptedMessage> messages);

  /// Newest-first conversation messages. When [limit] is set, returns only the
  /// latest [limit] messages (used for paginated chat loading); null = all.
  Future<List<DecryptedMessage>> getConversationMessages(
    String walletA,
    String walletB, {
    int? limit,
  });

  /// Returns the number of rows flipped to read (0 = nothing was unread).
  Future<int> markAsRead(String contactWallet);
  Future<void> markAllAsRead();
  Future<int> getUnreadCount(String contactWallet);
  Future<List<ChatPreview>> getConversations({String? currentUserWallet});
  Future<bool> messageExists(String messageId);
  Future<int> getTotalMessageCount();
  Future<String?> getContactUsername(String walletAddress);
  Future<int> updateContactUsername(String walletAddress, String newUsername);
  Future<List<String>> getContactWallets(String currentUserWallet);
  Future<int> deleteConversation(String contactWallet);
  Future<int> purgeSolanaConversations();
  Future<void> clear();
}

class MessageRepositoryImpl implements MessageRepository {
  MessageRepositoryImpl({required this.localDatabase});
  final LocalDatabase localDatabase;

  /// Algorand addresses are exactly 58 uppercase Base32 characters ([A-Z2-7]).
  static final _algorandAddressRe = RegExp(r'^[A-Z2-7]{58}$');

  static bool _isSolanaWallet(String wallet) =>
      !_algorandAddressRe.hasMatch(wallet);

  @override
  Future<int> getInstallEpoch() async {
    final db = await localDatabase.database;
    final rows = await db.query(
      'migration_state',
      columns: ['completed_at'],
      where: 'key = ?',
      whereArgs: ['install_epoch'],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['completed_at'] as int?) ?? 0;
  }

  @override
  Future<void> saveMessage(DecryptedMessage message) async {
    try {
      final db = await localDatabase.database;
      await db.insert('messages', {
        'id': message.id,
        'sender_wallet': message.senderWallet,
        'sender_username': message.senderUsername,
        'recipient_wallet': message.recipientWallet,
        'recipient_username': message.recipientUsername,
        'content': message.content,
        'timestamp': message.timestamp.toIso8601String(),
        'is_outgoing': message.isOutgoing ? 1 : 0,
        // Alias handshake carrier DMs are filtered out of the thread, so they
        // must not count as unread on the wallet conversation.
        'is_read': (message.isOutgoing || _isAliasCarrier(message.content))
            ? 1
            : 0,
        'on_chain_pubkey': message.onChainPubkey,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      throw MessageRepositoryException(
        'Failed to save message: $e',
        code: 'SAVE_ERROR',
      );
    }
  }

  @override
  Future<bool> hasMessage(String txSignature) async {
    final db = await localDatabase.database;
    final result = await db.query(
      'messages',
      columns: ['id'],
      where: 'on_chain_pubkey = ?',
      whereArgs: [txSignature],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  @override
  Future<Set<String>> existingMessageIds(List<String> txSignatures) async {
    if (txSignatures.isEmpty) return <String>{};
    final db = await localDatabase.database;
    final found = <String>{};
    // Chunk to stay well under SQLite's variable limit (default 999).
    const chunkSize = 500;
    for (var i = 0; i < txSignatures.length; i += chunkSize) {
      final chunk = txSignatures.sublist(
        i,
        (i + chunkSize).clamp(0, txSignatures.length),
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'messages',
        columns: ['on_chain_pubkey'],
        where: 'on_chain_pubkey IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final r in rows) {
        final id = r['on_chain_pubkey'] as String?;
        if (id != null) found.add(id);
      }
    }
    return found;
  }

  @override
  Future<DecryptedMessage?> getMessageByPubkey(String onChainPubkey) async {
    try {
      final db = await localDatabase.database;
      final maps = await db.query(
        'messages',
        where: 'on_chain_pubkey = ?',
        whereArgs: [onChainPubkey],
        limit: 1,
      );
      if (maps.isEmpty) return null;
      return DecryptedMessage.fromMap(maps.first);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> saveMessages(List<DecryptedMessage> messages) async {
    try {
      if (messages.isEmpty) {
        throw MessageRepositoryException(
          'messages list cannot be empty',
          code: 'EMPTY_LIST',
        );
      }
      final db = await localDatabase.database;
      final batch = db.batch();
      for (final message in messages) {
        batch.insert('messages', {
          'id': message.id,
          'sender_wallet': message.senderWallet,
          'sender_username': message.senderUsername,
          'recipient_wallet': message.recipientWallet,
          'recipient_username': message.recipientUsername,
          'content': message.content,
          'timestamp': message.timestamp.toIso8601String(),
          'is_outgoing': message.isOutgoing ? 1 : 0,
          'is_read': (message.isOutgoing || _isAliasCarrier(message.content))
              ? 1
              : 0,
          'on_chain_pubkey': message.onChainPubkey,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to save messages: $e',
        code: 'BATCH_SAVE_ERROR',
      );
    }
  }

  @override
  Future<List<DecryptedMessage>> getConversationMessages(
    String walletA,
    String walletB, {
    int? limit,
  }) async {
    try {
      if (walletA.isEmpty || walletB.isEmpty) {
        throw MessageRepositoryException(
          'wallets cannot be empty',
          code: 'INVALID_WALLETS',
        );
      }
      final db = await localDatabase.database;
      final maps = await db.query(
        'messages',
        where:
            '(sender_wallet = ? AND recipient_wallet = ?) OR (sender_wallet = ? AND recipient_wallet = ?)',
        whereArgs: [walletA, walletB, walletB, walletA],
        orderBy: 'timestamp DESC',
        limit: limit,
      );
      return List.generate(
        maps.length,
        (i) => DecryptedMessage.fromMap(maps[i]),
      );
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to fetch conversation messages: $e',
        code: 'QUERY_ERROR',
      );
    }
  }

  @override
  Future<int> markAsRead(String contactWallet) async {
    try {
      if (contactWallet.isEmpty) {
        throw MessageRepositoryException(
          'contactWallet cannot be empty',
          code: 'INVALID_WALLET',
        );
      }
      final db = await localDatabase.database;
      return await db.update(
        'messages',
        {'is_read': 1},
        where: 'sender_wallet = ? AND is_read = 0',
        whereArgs: [contactWallet],
      );
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to mark messages as read: $e',
        code: 'MARK_READ_ERROR',
      );
    }
  }

  @override
  Future<void> markAllAsRead() async {
    try {
      final db = await localDatabase.database;
      await db.update('messages', {'is_read': 1}, where: 'is_read = 0');
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to mark all messages as read: $e',
        code: 'MARK_ALL_READ_ERROR',
      );
    }
  }

  @override
  Future<int> getUnreadCount(String contactWallet) async {
    try {
      if (contactWallet.isEmpty) {
        throw MessageRepositoryException(
          'contactWallet cannot be empty',
          code: 'INVALID_WALLET',
        );
      }
      final db = await localDatabase.database;
      final result = await db.rawQuery(
        '''
        SELECT COUNT(*) as unreadCount
        FROM messages
        WHERE sender_wallet = ? AND is_outgoing = 0 AND is_read = 0
      ''',
        [contactWallet],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to get unread count: $e',
        code: 'UNREAD_COUNT_ERROR',
      );
    }
  }

  @override
  Future<List<ChatPreview>> getConversations({
    String? currentUserWallet,
  }) async {
    try {
      final db = await localDatabase.database;
      final maps = await db.rawQuery('''
        SELECT
          latest_message.*,
          CASE
            WHEN latest_message.is_outgoing = 1 THEN latest_message.recipient_wallet
            ELSE latest_message.sender_wallet
          END AS contactWallet,
          -- Display name: the contacts table (cc) is the single source of truth
          -- for a known wallet contact, kept fresh by the username-refresh loop.
          -- The per-message snapshot (sender/recipient_username) is only a
          -- fallback for unknown peers with no contact row. This makes the Chats
          -- list and Contacts list read the SAME value — they can't drift.
          COALESCE(
            NULLIF(cc.username, ''),
            CASE
              WHEN latest_message.is_outgoing = 1
                THEN latest_message.recipient_username
              ELSE latest_message.sender_username
            END
          ) AS contactUsername,
          latest_message.content AS lastMessagePreview,
          latest_message.timestamp AS lastMessageTimestamp,
          latest_message.is_outgoing AS isLastMessageOutgoing,
          (
            SELECT COUNT(*)
            FROM messages m2
            WHERE m2.is_read = 0
              AND m2.is_outgoing = 0
              AND m2.sender_wallet = CASE
                WHEN latest_message.is_outgoing = 1 THEN latest_message.recipient_wallet
                ELSE latest_message.sender_wallet
              END
          ) AS unreadCount,
          (
            SELECT COUNT(*)
            FROM messages m3
            WHERE CASE
              WHEN m3.sender_wallet < m3.recipient_wallet
              THEN m3.sender_wallet || ':' || m3.recipient_wallet
              ELSE m3.recipient_wallet || ':' || m3.sender_wallet
            END = CASE
              WHEN latest_message.sender_wallet < latest_message.recipient_wallet
              THEN latest_message.sender_wallet || ':' || latest_message.recipient_wallet
              ELSE latest_message.recipient_wallet || ':' || latest_message.sender_wallet
            END
          ) AS messageCount,
          -- Persistent manual block (v18) — the sole Spam-tab predicate.
          -- All other conversations land in Chats (PQ hybrid is mandatory;
          -- the old classical-only spam classification is gone).
          COALESCE(cc.is_blocked, 0) AS isBlocked
        FROM messages AS latest_message
        LEFT JOIN contacts cc
          ON cc.is_alias = 0
          AND cc.wallet_address = CASE
            WHEN latest_message.is_outgoing = 1 THEN latest_message.recipient_wallet
            ELSE latest_message.sender_wallet
          END
        -- Pick exactly ONE preview row per conversation: the newest message
        -- that is NOT an alias invite/accept envelope. Envelopes ride the DM
        -- channel as synthetic rows but are control messages, so they must
        -- never become the preview. rowid is the tiebreaker so equal
        -- timestamps (second-resolution on-chain ts → frequent ties) resolve
        -- deterministically to the most-recently-inserted message instead of
        -- a nondeterministic pick, which previously surfaced a non-newest
        -- message. Conversations whose only message is an envelope match no
        -- row here and are dropped (they surface via the invitations banner).
        WHERE latest_message.rowid = (
          SELECT m.rowid
          FROM messages m
          WHERE (CASE
              WHEN m.sender_wallet < m.recipient_wallet
              THEN m.sender_wallet || ':' || m.recipient_wallet
              ELSE m.recipient_wallet || ':' || m.sender_wallet
            END) = (CASE
              WHEN latest_message.sender_wallet < latest_message.recipient_wallet
              THEN latest_message.sender_wallet || ':' || latest_message.recipient_wallet
              ELSE latest_message.recipient_wallet || ':' || latest_message.sender_wallet
            END)
            AND m.content NOT LIKE 'sealed://alias?%'
            AND m.content NOT LIKE 'sealed://alias-envelope?%'
          ORDER BY m.timestamp DESC, m.rowid DESC
          LIMIT 1
        )
        ORDER BY latest_message.timestamp DESC
      ''');
      return List.generate(
        maps.length,
        (i) => ChatPreview.fromWalletRow(maps[i]),
      );
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to fetch conversations: $e',
        code: 'CONVERSATIONS_ERROR',
      );
    }
  }

  @override
  Future<bool> messageExists(String messageId) async {
    try {
      if (messageId.isEmpty) {
        throw MessageRepositoryException(
          'messageId cannot be empty',
          code: 'INVALID_ID',
        );
      }
      final db = await localDatabase.database;
      final maps = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      return maps.isNotEmpty;
    } catch (e) {
      if (e is MessageRepositoryException) rethrow;
      throw MessageRepositoryException(
        'Failed to check message existence: $e',
        code: 'EXISTS_ERROR',
      );
    }
  }

  @override
  Future<int> getTotalMessageCount() async {
    try {
      final db = await localDatabase.database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM messages',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      throw MessageRepositoryException(
        'Failed to get message count: $e',
        code: 'COUNT_ERROR',
      );
    }
  }

  @override
  Future<String?> getContactUsername(String walletAddress) async {
    try {
      final db = await localDatabase.database;
      final results = await db.rawQuery(
        '''
        SELECT
          CASE
            WHEN sender_wallet = ? THEN sender_username
            ELSE recipient_username
          END AS contact_username
        FROM messages
        WHERE sender_wallet = ? OR recipient_wallet = ?
        ORDER BY timestamp DESC
        LIMIT 1
      ''',
        [walletAddress, walletAddress, walletAddress],
      );
      if (results.isNotEmpty) {
        final username = results.first['contact_username'] as String?;
        if (username != null && username.isNotEmpty) return username;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<int> updateContactUsername(
    String walletAddress,
    String newUsername,
  ) async {
    try {
      final db = await localDatabase.database;
      final senderCount = await db.update(
        'messages',
        {'sender_username': newUsername},
        where: 'sender_wallet = ?',
        whereArgs: [walletAddress],
      );
      final recipientCount = await db.update(
        'messages',
        {'recipient_username': newUsername},
        where: 'recipient_wallet = ?',
        whereArgs: [walletAddress],
      );
      return senderCount + recipientCount;
    } catch (e) {
      throw MessageRepositoryException(
        'Failed to update contact username: $e',
        code: 'UPDATE_USERNAME_ERROR',
      );
    }
  }

  @override
  Future<List<String>> getContactWallets(String currentUserWallet) async {
    try {
      final db = await localDatabase.database;
      final results = await db.rawQuery(
        '''
        SELECT DISTINCT
          CASE
            WHEN sender_wallet = ? THEN recipient_wallet
            ELSE sender_wallet
          END AS contactWallet
        FROM messages
        WHERE sender_wallet = ? OR recipient_wallet = ?
      ''',
        [currentUserWallet, currentUserWallet, currentUserWallet],
      );
      return results.map((r) => r['contactWallet'] as String).toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<int> deleteConversation(String contactWallet) async {
    try {
      final db = await localDatabase.database;
      return await db.delete(
        'messages',
        where: 'sender_wallet = ? OR recipient_wallet = ?',
        whereArgs: [contactWallet, contactWallet],
      );
    } catch (e) {
      throw MessageRepositoryException(
        'Failed to delete conversation: $e',
        code: 'DELETE_CONVERSATION_ERROR',
      );
    }
  }

  @override
  Future<int> purgeSolanaConversations() async {
    try {
      final db = await localDatabase.database;
      final rows = await db.rawQuery('''
        SELECT DISTINCT wallet FROM (
          SELECT sender_wallet    AS wallet FROM messages
          UNION
          SELECT recipient_wallet AS wallet FROM messages
        )
      ''');
      final solanaWallets = rows
          .map((r) => r['wallet'] as String)
          .where(_isSolanaWallet)
          .toList();
      if (solanaWallets.isEmpty) return 0;
      for (final wallet in solanaWallets) {
        await deleteConversation(wallet);
      }
      return solanaWallets.length;
    } catch (e) {
      return 0;
    }
  }

  @override
  Future<void> clear() async {
    try {
      final db = await localDatabase.database;
      await db.delete('messages');
    } catch (e) {
      throw MessageRepositoryException(
        'Failed to clear messages: $e',
        code: 'CLEAR_ERROR',
      );
    }
  }
}
