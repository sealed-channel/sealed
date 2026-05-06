import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sqflite/sqflite.dart';

class MessageCacheException implements Exception {
  final String message;
  final String? code;

  MessageCacheException(this.message, {this.code});

  @override
  String toString() =>
      'MessageCacheException: $message${code != null ? ' ($code)' : ''}';
}

class MessageCache {
  final LocalDatabase localDatabase;
  MessageCache({required this.localDatabase});

  Future<void> saveMessage(DecryptedMessage message) async {
    try {
      print(
        '[MessageCache] 💾 saveMessage() - saving message ID: ${message.id}',
      );
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
        'is_read': message.isOutgoing ? 1 : 0,
        'on_chain_pubkey': message.onChainPubkey,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      print('[MessageCache] ✅ Message saved successfully');
    } catch (e) {
      print('[MessageCache] ❌ Failed to save message: $e');
      throw MessageCacheException(
        'Failed to save message: $e',
        code: 'SAVE_ERROR',
      );
    }
  }

  Future<bool> hasMessage(String txSignature) async {
    print('[MessageCache] 🔍 hasMessage() - checking for TX: $txSignature');
    final db = await localDatabase.database;
    final result = await db.query(
      'messages',
      columns: ['id'],
      where: 'on_chain_pubkey = ?',
      whereArgs: [txSignature],
      limit: 1,
    );
    final exists = result.isNotEmpty;
    print('[MessageCache] ✅ Message exists: $exists');
    return exists;
  }

  /// Get a message by its on-chain pubkey (tx signature)
  Future<DecryptedMessage?> getMessageByPubkey(String onChainPubkey) async {
    try {
      print(
        '[MessageCache] 🔍 getMessageByPubkey() - looking up: $onChainPubkey',
      );
      final db = await localDatabase.database;

      final List<Map<String, dynamic>> maps = await db.query(
        'messages',
        where: 'on_chain_pubkey = ?',
        whereArgs: [onChainPubkey],
        limit: 1,
      );

      if (maps.isEmpty) {
        print('[MessageCache] ⚠️ Message not found');
        return null;
      }

      print('[MessageCache] ✅ Message found');
      return DecryptedMessage.fromMap(maps.first);
    } catch (e) {
      print('[MessageCache] ❌ Failed to get message by pubkey: $e');
      return null;
    }
  }

  Future<void> saveMessages(List<DecryptedMessage> messages) async {
    try {
      if (messages.isEmpty) {
        print('[MessageCache] ⚠️ saveMessages() - empty list provided');
        throw MessageCacheException(
          'messages list cannot be empty',
          code: 'EMPTY_LIST',
        );
      }

      print(
        '[MessageCache] 💾 saveMessages() - saving ${messages.length} messages in batch',
      );
      final db = await localDatabase.database;
      final batch = db.batch();

      for (var message in messages) {
        batch.insert('messages', {
          'id': message.id,
          'sender_wallet': message.senderWallet,
          'sender_username': message.senderUsername,
          'recipient_wallet': message.recipientWallet,
          'recipient_username': message.recipientUsername,
          'content': message.content,
          'timestamp': message.timestamp.toIso8601String(),
          'is_outgoing': message.isOutgoing ? 1 : 0,
          'is_read': message.isOutgoing ? 1 : 0,
          'on_chain_pubkey': message.onChainPubkey,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      await batch.commit(noResult: true);
      print('[MessageCache] ✅ Batch save completed successfully');
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Batch save failed: $e');
      throw MessageCacheException(
        'Failed to save messages: $e',
        code: 'BATCH_SAVE_ERROR',
      );
    }
  }

  Future<List<DecryptedMessage>> getConversationMessages(
    String walletA,
    String walletB,
  ) async {
    try {
      if (walletA.isEmpty || walletB.isEmpty) {
        print('[MessageCache] ❌ getConversationMessages() - invalid wallets');
        throw MessageCacheException(
          'wallets cannot be empty',
          code: 'INVALID_WALLETS',
        );
      }

      print(
        '[MessageCache] 🔍 getConversationMessages() - fetching between $walletA and $walletB',
      );
      final db = await localDatabase.database;

      final List<Map<String, dynamic>> maps = await db.query(
        'messages',
        where:
            '(sender_wallet = ? AND recipient_wallet = ?) OR (sender_wallet = ? AND recipient_wallet = ?)',
        whereArgs: [walletA, walletB, walletB, walletA],
        orderBy: 'timestamp DESC',
      );

      print('[MessageCache] ✅ Found ${maps.length} messages in conversation');
      return List.generate(maps.length, (i) {
        return DecryptedMessage.fromMap(maps[i]);
      });
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Failed to fetch conversation messages: $e');
      throw MessageCacheException(
        'Failed to fetch conversation messages: $e',
        code: 'QUERY_ERROR',
      );
    }
  }

  Future<void> markAsRead(String contactWallet) async {
    try {
      if (contactWallet.isEmpty) {
        print('[MessageCache] ❌ markAsRead() - invalid wallet');
        throw MessageCacheException(
          'contactWallet cannot be empty',
          code: 'INVALID_WALLET',
        );
      }

      print(
        '[MessageCache] 👁️ markAsRead() - marking messages from $contactWallet as read',
      );
      final db = await localDatabase.database;

      final count = await db.update(
        'messages',
        {'is_read': 1},
        where: 'sender_wallet = ? AND is_read = 0',
        whereArgs: [contactWallet],
      );
      print('[MessageCache] ✅ Marked $count messages as read');
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Failed to mark messages as read: $e');
      throw MessageCacheException(
        'Failed to mark messages as read: $e',
        code: 'MARK_READ_ERROR',
      );
    }
  }

  Future<void> markAllAsRead() async {
    try {
      print('[MessageCache] 👁️ markAllAsRead() - marking all unread messages');
      final db = await localDatabase.database;

      final count = await db.update('messages', {
        'is_read': 1,
      }, where: 'is_read = 0');
      print('[MessageCache] ✅ Marked $count messages as read');
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Failed to mark all as read: $e');
      throw MessageCacheException(
        'Failed to mark all messages as read: $e',
        code: 'MARK_ALL_READ_ERROR',
      );
    }
  }

  Future<int> getUnreadCount(String contactWallet) async {
    try {
      if (contactWallet.isEmpty) {
        print('[MessageCache] ❌ getUnreadCount() - invalid wallet');
        throw MessageCacheException(
          'contactWallet cannot be empty',
          code: 'INVALID_WALLET',
        );
      }

      print(
        '[MessageCache] 🔔 getUnreadCount() - counting unread from $contactWallet',
      );
      final db = await localDatabase.database;

      final result = await db.rawQuery(
        '''
        SELECT COUNT(*) as unreadCount
        FROM messages
        WHERE sender_wallet = ? AND is_outgoing = 0 AND is_read = 0
      ''',
        [contactWallet],
      );

      final count = Sqflite.firstIntValue(result) ?? 0;
      print('[MessageCache] ✅ Unread count: $count');
      return count;
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Failed to get unread count: $e');
      throw MessageCacheException(
        'Failed to get unread count: $e',
        code: 'UNREAD_COUNT_ERROR',
      );
    }
  }

  Future<List<ConversationPreview>> getConversations({
    String? currentUserWallet,
  }) async {
    try {
      print(
        '[MessageCache] 📋 getConversations() - fetching all conversation previews',
      );
      final db = await localDatabase.database;

      // Get the latest message for each conversation
      final List<Map<String, dynamic>> maps = await db.rawQuery('''
        SELECT
          latest_message.*,
          CASE
            WHEN latest_message.is_outgoing = 1 THEN latest_message.recipient_wallet
            ELSE latest_message.sender_wallet
          END AS contactWallet,
          CASE
            WHEN latest_message.is_outgoing = 1 THEN latest_message.recipient_username
            ELSE latest_message.sender_username
          END AS contactUsername,
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
          ) AS messageCount
        FROM messages AS latest_message
        INNER JOIN (
          SELECT
            CASE
              WHEN sender_wallet < recipient_wallet
              THEN sender_wallet || ':' || recipient_wallet
              ELSE recipient_wallet || ':' || sender_wallet
            END AS conversation_key,
            MAX(timestamp) AS max_timestamp
          FROM messages
          GROUP BY
            CASE
              WHEN sender_wallet < recipient_wallet
              THEN sender_wallet || ':' || recipient_wallet
              ELSE recipient_wallet || ':' || sender_wallet
            END
        ) AS grouped_latest
          ON grouped_latest.conversation_key = CASE
            WHEN latest_message.sender_wallet < latest_message.recipient_wallet
            THEN latest_message.sender_wallet || ':' || latest_message.recipient_wallet
            ELSE latest_message.recipient_wallet || ':' || latest_message.sender_wallet
          END
          AND latest_message.timestamp = grouped_latest.max_timestamp
        ORDER BY latest_message.timestamp DESC
      ''');

      print('[MessageCache] ✅ Found ${maps.length} conversations');

      // Debug: Print raw data to see what we're getting
      for (var i = 0; i < maps.length && i < 3; i++) {
        print('[MessageCache] 🔍 Conversation $i data:');
        print('  - contactWallet: ${maps[i]['contactWallet']}');
        print('  - contactUsername: ${maps[i]['contactUsername']}');
        print('  - sender_wallet: ${maps[i]['sender_wallet']}');
        print('  - sender_username: ${maps[i]['sender_username']}');
        print('  - recipient_wallet: ${maps[i]['recipient_wallet']}');
        print('  - is_outgoing: ${maps[i]['is_outgoing']}');
      }

      return List.generate(maps.length, (i) {
        return ConversationPreview.fromJson(maps[i]);
      });
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Failed to fetch conversations: $e');
      throw MessageCacheException(
        'Failed to fetch conversations: $e',
        code: 'CONVERSATIONS_ERROR',
      );
    }
  }

  Future<bool> messageExists(String messageId) async {
    try {
      if (messageId.isEmpty) {
        print('[MessageCache] ❌ messageExists() - invalid message ID');
        throw MessageCacheException(
          'messageId cannot be empty',
          code: 'INVALID_ID',
        );
      }

      print(
        '[MessageCache] 🔍 messageExists() - checking for message: $messageId',
      );
      final db = await localDatabase.database;

      final List<Map<String, dynamic>> maps = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );

      final exists = maps.isNotEmpty;
      print('[MessageCache] ✅ Message exists: $exists');
      return exists;
    } catch (e) {
      if (e is MessageCacheException) rethrow;
      print('[MessageCache] ❌ Failed to check message existence: $e');
      throw MessageCacheException(
        'Failed to check message existence: $e',
        code: 'EXISTS_ERROR',
      );
    }
  }

  Future<int> getTotalMessageCount() async {
    try {
      print('[MessageCache] 📊 getTotalMessageCount() - counting all messages');
      final db = await localDatabase.database;

      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM messages',
      );
      final count = Sqflite.firstIntValue(result) ?? 0;
      print('[MessageCache] ✅ Total message count: $count');
      return count;
    } catch (e) {
      print('[MessageCache] ❌ Failed to get message count: $e');
      throw MessageCacheException(
        'Failed to get message count: $e',
        code: 'COUNT_ERROR',
      );
    }
  }

  /// Look up the contact username for a wallet address from the most recent message.
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
        if (username != null && username.isNotEmpty) {
          return username;
        }
      }
      return null;
    } catch (e) {
      print('[MessageCache] ⚠️ Failed to get contact username: $e');
      return null;
    }
  }

  /// Update the username for a contact across all messages.
  /// Updates sender_username where sender_wallet matches, and
  /// recipient_username where recipient_wallet matches.
  Future<int> updateContactUsername(
    String walletAddress,
    String newUsername,
  ) async {
    try {
      print(
        '[MessageCache] ✏️ updateContactUsername() - updating username for $walletAddress to $newUsername',
      );
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

      final total = senderCount + recipientCount;
      print('[MessageCache] ✅ Updated username in $total message rows');
      return total;
    } catch (e) {
      print('[MessageCache] ❌ Failed to update contact username: $e');
      throw MessageCacheException(
        'Failed to update contact username: $e',
        code: 'UPDATE_USERNAME_ERROR',
      );
    }
  }

  /// Get distinct contact wallet addresses from messages for a given user.
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
      print('[MessageCache] ❌ Failed to get contact wallets: $e');
      return [];
    }
  }

  /// Delete all cached messages for a single contact wallet address.
  Future<int> deleteConversation(String contactWallet) async {
    try {
      print(
        '[MessageCache] 🗑️ deleteConversation() - deleting messages for $contactWallet',
      );
      final db = await localDatabase.database;
      final deleted = await db.delete(
        'messages',
        where: 'sender_wallet = ? OR recipient_wallet = ?',
        whereArgs: [contactWallet, contactWallet],
      );
      print('[MessageCache] ✅ Deleted $deleted messages for $contactWallet');
      return deleted;
    } catch (e) {
      print('[MessageCache] ❌ Failed to delete conversation: $e');
      throw MessageCacheException(
        'Failed to delete conversation: $e',
        code: 'DELETE_CONVERSATION_ERROR',
      );
    }
  }

  /// Algorand addresses are exactly 58 uppercase Base32 characters ([A-Z2-7]).
  /// Anything else (e.g. Solana's 32-44 char Base58 address) is not Algorand.
  static final _algorandAddressRe = RegExp(r'^[A-Z2-7]{58}$');

  static bool _isSolanaWallet(String wallet) =>
      !_algorandAddressRe.hasMatch(wallet);

  /// Scan every distinct wallet in the messages table and delete all messages
  /// whose peer wallet address is not a valid Algorand address (i.e. Solana
  /// legacy data). Returns the number of conversations purged.
  Future<int> purgeSolanaConversations() async {
    try {
      final db = await localDatabase.database;

      // Collect every distinct wallet address referenced in the messages table.
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

      if (solanaWallets.isEmpty) {
        print('[MessageCache] ✅ purgeSolanaConversations() - nothing to purge');
        return 0;
      }

      print(
        '[MessageCache] 🧹 purgeSolanaConversations() - purging ${solanaWallets.length} Solana wallet(s): $solanaWallets',
      );

      var purged = 0;
      for (final wallet in solanaWallets) {
        purged += await deleteConversation(wallet);
      }

      print(
        '[MessageCache] ✅ purgeSolanaConversations() - removed $purged messages across ${solanaWallets.length} conversation(s)',
      );
      return solanaWallets.length;
    } catch (e) {
      print('[MessageCache] ❌ purgeSolanaConversations() failed: $e');
      // Non-fatal – don't block the UI
      return 0;
    }
  }

  Future<void> clearMessages() async {
    try {
      print(
        '[MessageCache] 🗑️ clearMessages() - clearing all messages from cache',
      );
      final db = await localDatabase.database;
      await db.delete('messages');
      print('[MessageCache] ✅ Cache cleared successfully');
    } catch (e) {
      print('[MessageCache] ❌ Failed to clear messages: $e');
      throw MessageCacheException(
        'Failed to clear messages: $e',
        code: 'CLEAR_ERROR',
      );
    }
  }
}
