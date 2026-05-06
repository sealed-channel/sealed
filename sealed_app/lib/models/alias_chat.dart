/// Status of an alias chat channel.
enum AliasChannelStatus {
  /// Invitation created, waiting for counterpart to accept.
  pending,

  /// Both parties exchanged keys, channel is live.
  active,

  /// Channel has been deleted/destroyed.
  deleted,
}

/// A single alias chat conversation.
///
/// After key exchange completes the device stores only the invite secret,
/// display alias, status, and whether it is the creator. All cryptographic
/// key material (enc_key) is held exclusively in FlutterSecureStorage and
/// is never written to the SQLite database.
class AliasChat {
  /// 32-byte random invite secret (base64url-encoded for storage).
  final String inviteSecret;

  /// User-chosen display name for this alias conversation.
  final String alias;

  final AliasChannelStatus status;
  final DateTime createdAt;

  /// Whether we are the creator (true) or acceptor (false) of this channel.
  final bool isCreator;

  const AliasChat({
    required this.inviteSecret,
    required this.alias,
    required this.status,
    required this.createdAt,
    required this.isCreator,
  });

  factory AliasChat.fromMap(Map<String, dynamic> map) {
    return AliasChat(
      inviteSecret: map['channel_id'] as String,
      alias: map['alias'] as String,
      status: AliasChannelStatus.values.firstWhere(
        (e) => e.name == (map['status'] as String),
        orElse: () => AliasChannelStatus.pending,
      ),
      createdAt: DateTime.parse(map['created_at'] as String),
      isCreator: (map['is_creator'] as int) == 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'channel_id': inviteSecret,
      'alias': alias,
      'status': status.name,
      'created_at': createdAt.toIso8601String(),
      'is_creator': isCreator ? 1 : 0,
    };
  }

  AliasChat copyWith({String? alias, AliasChannelStatus? status}) {
    return AliasChat(
      inviteSecret: inviteSecret,
      alias: alias ?? this.alias,
      status: status ?? this.status,
      createdAt: createdAt,
      isCreator: isCreator,
    );
  }
}

/// A message within an alias chat.
///
/// Similar to [DecryptedMessage] but references an inviteSecret
/// instead of wallet addresses.
class AliasMessage {
  final String id;
  final String inviteSecret;
  final String content;
  final DateTime timestamp;
  final bool isOutgoing;
  final bool isRead;

  /// On-chain reference (tx ID or account pubkey).
  final String? onChainRef;

  const AliasMessage({
    required this.id,
    required this.inviteSecret,
    required this.content,
    required this.timestamp,
    required this.isOutgoing,
    this.isRead = true,
    this.onChainRef,
  });

  factory AliasMessage.fromMap(Map<String, dynamic> map) {
    final timestampRaw = map['timestamp'];
    final DateTime timestamp;
    if (timestampRaw is int) {
      timestamp = DateTime.fromMicrosecondsSinceEpoch(timestampRaw);
    } else if (timestampRaw is String) {
      timestamp = DateTime.parse(timestampRaw);
    } else {
      timestamp = DateTime.now();
    }

    final isOutgoingRaw = map['is_outgoing'];
    final bool isOutgoing = isOutgoingRaw is int
        ? isOutgoingRaw == 1
        : (isOutgoingRaw as bool);
    final isReadRaw = map['is_read'];
    final bool isRead = isReadRaw is int
        ? isReadRaw == 1
        : (isReadRaw as bool? ?? true);

    return AliasMessage(
      id: map['id'] as String,
      inviteSecret: map['channel_id'] as String,
      content: map['content'] as String,
      timestamp: timestamp,
      isOutgoing: isOutgoing,
      isRead: isRead,
      onChainRef: map['on_chain_ref'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'channel_id': inviteSecret,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'is_outgoing': isOutgoing ? 1 : 0,
      'is_read': isRead ? 1 : 0,
      'on_chain_ref': onChainRef,
    };
  }
}

/// Preview for alias chat in the unified conversation list.
class AliasConversationPreview {
  final String inviteSecret;
  final String alias;
  final String lastMessagePreview;
  final int lastMessageTimestamp;
  final bool isLastMessageOutgoing;
  final int unreadCount;
  final AliasChannelStatus status;
  final bool inviteDismissed;

  const AliasConversationPreview({
    required this.inviteSecret,
    required this.alias,
    required this.lastMessagePreview,
    required this.lastMessageTimestamp,
    required this.isLastMessageOutgoing,
    required this.unreadCount,
    required this.status,
    required this.inviteDismissed,
  });

  factory AliasConversationPreview.fromMap(Map<String, dynamic> map) {
    final timestampRaw = map['lastMessageTimestamp'];
    final int lastMessageTimestamp;
    if (timestampRaw is int) {
      lastMessageTimestamp = timestampRaw;
    } else if (timestampRaw is String) {
      lastMessageTimestamp = DateTime.parse(
        timestampRaw,
      ).microsecondsSinceEpoch;
    } else {
      lastMessageTimestamp = DateTime.now().microsecondsSinceEpoch;
    }

    return AliasConversationPreview(
      inviteSecret: map['inviteSecret'] as String,
      alias: map['alias'] as String,
      lastMessagePreview: map['lastMessagePreview'] as String,
      lastMessageTimestamp: lastMessageTimestamp,
      isLastMessageOutgoing: (map['isLastMessageOutgoing'] as int) == 1,
      unreadCount: map['unreadCount'] as int,
      status: AliasChannelStatus.values.firstWhere(
        (e) => e.name == (map['status'] as String),
        orElse: () => AliasChannelStatus.active,
      ),
      inviteDismissed: (map['inviteDismissed'] as int? ?? 0) == 1,
    );
  }
}
