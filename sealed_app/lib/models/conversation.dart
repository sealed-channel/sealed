class ConversationPreview extends Conversation {
  final String lastMessagePreview;
  final int lastMessageTimestamp;
  final bool isLastMessageOutgoing;
  final int unreadCount;
  final int messageCount;

  ConversationPreview({
    required super.contactWallet,
    super.contactUsername,
    required this.lastMessagePreview,
    required this.lastMessageTimestamp,
    required this.isLastMessageOutgoing,
    required this.unreadCount,
    this.messageCount = 0,
  });

  factory ConversationPreview.fromJson(Map<String, dynamic> json) {
    print('[ConversationPreview] 📥 fromJson: $json ');
    final timestampRaw = json['lastMessageTimestamp'];
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
    return ConversationPreview(
      contactWallet: json['contactWallet'] as String,
      contactUsername: json['contactUsername'] as String?,
      lastMessagePreview: json['lastMessagePreview'] as String,
      lastMessageTimestamp: lastMessageTimestamp,
      isLastMessageOutgoing: (json['isLastMessageOutgoing'] as int) == 1,
      unreadCount: json['unreadCount'] as int,
      messageCount: (json['messageCount'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'lastMessagePreview': lastMessagePreview,
    'lastMessageTimestamp': lastMessageTimestamp,
    'isLastMessageOutgoing': isLastMessageOutgoing ? 1 : 0,
    'unreadCount': unreadCount,
    'messageCount': messageCount,
  };
}

class Conversation {
  final String contactWallet;
  final String? contactUsername;

  Conversation({required this.contactWallet, this.contactUsername});
}
