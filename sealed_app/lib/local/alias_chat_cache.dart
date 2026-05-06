import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/models/alias_chat.dart';
import 'package:sqflite/sqflite.dart';

/// Local database operations for alias chats and alias messages.
class AliasChatCache {
  final LocalDatabase localDatabase;

  AliasChatCache({required this.localDatabase});

  // ---------------------------------------------------------------------------
  // Alias Chat CRUD
  // ---------------------------------------------------------------------------

  Future<void> saveAliasChat(AliasChat chat) async {
    final db = await localDatabase.database;
    await db.insert(
      'alias_chats',
      chat.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<AliasChat?> getAliasChat(String inviteSecret) async {
    final db = await localDatabase.database;
    final rows = await db.query(
      'alias_chats',
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AliasChat.fromMap(rows.first);
  }

  Future<List<AliasChat>> getAllAliasChats() async {
    final db = await localDatabase.database;
    final rows = await db.query(
      'alias_chats',
      where: "status != 'deleted'",
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => AliasChat.fromMap(r)).toList();
  }

  Future<void> updateAliasChatStatus(
    String inviteSecret,
    AliasChannelStatus status,
  ) async {
    final db = await localDatabase.database;
    await db.update(
      'alias_chats',
      {'status': status.name},
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
    );
  }

  Future<void> updateAlias(String inviteSecret, String alias) async {
    final db = await localDatabase.database;
    await db.update(
      'alias_chats',
      {'alias': alias},
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
    );
  }

  Future<void> markInviteDismissed(String inviteSecret) async {
    final db = await localDatabase.database;
    await db.update(
      'alias_chats',
      {'invite_dismissed': 1},
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
    );
  }

  Future<bool> isInviteDismissed(String inviteSecret) async {
    final db = await localDatabase.database;
    final rows = await db.query(
      'alias_chats',
      columns: ['invite_dismissed'],
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return (rows.first['invite_dismissed'] as int) == 1;
  }

  Future<void> deleteAliasChat(String inviteSecret) async {
    final db = await localDatabase.database;
    await db.delete(
      'alias_messages',
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
    );
    await db.delete(
      'alias_chats',
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
    );
  }

  /// Delete all alias chats and messages (used on logout).
  Future<void> clearAll() async {
    final db = await localDatabase.database;
    await db.delete('alias_messages');
    await db.delete('alias_chats');
  }

  // ---------------------------------------------------------------------------
  // Alias Messages
  // ---------------------------------------------------------------------------

  Future<void> saveAliasMessage(AliasMessage message) async {
    final db = await localDatabase.database;
    await db.insert(
      'alias_messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasAliasMessage(String id) async {
    final db = await localDatabase.database;
    final rows = await db.query(
      'alias_messages',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<AliasMessage>> getAliasMessages(String inviteSecret) async {
    final db = await localDatabase.database;
    final rows = await db.query(
      'alias_messages',
      where: 'channel_id = ?',
      whereArgs: [inviteSecret],
      orderBy: 'timestamp DESC',
    );
    return rows.map((r) => AliasMessage.fromMap(r)).toList();
  }

  Future<void> markAliasMessagesAsRead(String inviteSecret) async {
    final db = await localDatabase.database;
    await db.update(
      'alias_messages',
      {'is_read': 1},
      where: 'channel_id = ? AND is_read = 0',
      whereArgs: [inviteSecret],
    );
  }

  // ---------------------------------------------------------------------------
  // Alias Conversation Previews (for unified chat list)
  // ---------------------------------------------------------------------------

  Future<List<AliasConversationPreview>> getAliasConversationPreviews() async {
    final db = await localDatabase.database;

    final rows = await db.rawQuery('''
      SELECT
        ac.channel_id AS inviteSecret,
        ac.alias AS alias,
        ac.status AS status,
        ac.invite_dismissed AS inviteDismissed,
        COALESCE(am.content, CASE
          WHEN ac.status = 'pending' THEN 'Invitation pending...'
          ELSE 'Alias chat created'
        END) AS lastMessagePreview,
        COALESCE(am.timestamp, ac.created_at) AS lastMessageTimestamp,
        COALESCE(am.is_outgoing, 0) AS isLastMessageOutgoing,
        COALESCE(unread.cnt, 0) AS unreadCount
      FROM alias_chats ac
      LEFT JOIN (
        SELECT channel_id, content, timestamp, is_outgoing
        FROM alias_messages
        WHERE id IN (
          SELECT id FROM alias_messages am2
          WHERE am2.channel_id = alias_messages.channel_id
          ORDER BY timestamp DESC LIMIT 1
        )
      ) am ON am.channel_id = ac.channel_id
      LEFT JOIN (
        SELECT channel_id, COUNT(*) AS cnt
        FROM alias_messages
        WHERE is_read = 0 AND is_outgoing = 0
        GROUP BY channel_id
      ) unread ON unread.channel_id = ac.channel_id
      WHERE ac.status != 'deleted'
      ORDER BY COALESCE(am.timestamp, ac.created_at) DESC
    ''');

    return rows.map((r) => AliasConversationPreview.fromMap(r)).toList();
  }
}
