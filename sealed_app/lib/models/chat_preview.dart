/// Unified chat-list row, spanning legacy wallet-addressed DMs and Spec H
/// alias-channel contacts. Concrete (not polymorphic) — discriminate kind via
/// [isAlias] / [aliasContact] presence. Phase 2 (storage unify) collapses the
/// two underlying tables; until then wallet rows hydrate from `messages` and
/// alias rows hydrate from `contacts` + `contact_messages`.
library;

import 'package:sealed_app/models/contact.dart' show AliasContact;

class ChatPreview {
  // ── wallet side (null for alias rows) ───────────────────────────────────
  final String? contactWallet;
  final String? contactUsername;
  final int messageCount;
  final bool isLastMessageOutgoing;

  // ── alias side (null for wallet rows) ───────────────────────────────────
  final AliasContact? aliasContact;

  // ── common ──────────────────────────────────────────────────────────────
  final String? lastMessageContent;
  final int? lastMessageTimestamp;
  final int unreadCount;

  /// Persistent manual block (v18, wallet contacts only). The sole Spam-tab
  /// predicate; see [isSpam].
  final bool isBlocked;

  const ChatPreview({
    this.contactWallet,
    this.contactUsername,
    this.messageCount = 0,
    this.isLastMessageOutgoing = false,
    this.aliasContact,
    this.lastMessageContent,
    this.lastMessageTimestamp,
    this.unreadCount = 0,
    this.isBlocked = false,
  });

  bool get isAlias => aliasContact != null;

  /// Spam-tab membership: manually blocked conversations only.
  bool get isSpam => isBlocked;

  /// Hydrate from the `messages`-table preview row produced by
  /// `MessageRepository.getConversations`.
  factory ChatPreview.fromWalletRow(Map<String, dynamic> json) {
    final tsRaw = json['lastMessageTimestamp'];
    final int ts;
    if (tsRaw is int) {
      ts = tsRaw;
    } else if (tsRaw is String) {
      ts = DateTime.parse(tsRaw).microsecondsSinceEpoch;
    } else {
      ts = DateTime.now().microsecondsSinceEpoch;
    }
    return ChatPreview(
      contactWallet: json['contactWallet'] as String,
      contactUsername: json['contactUsername'] as String?,
      lastMessageContent: json['lastMessagePreview'] as String?,
      lastMessageTimestamp: ts,
      isLastMessageOutgoing: (json['isLastMessageOutgoing'] as int) == 1,
      unreadCount: json['unreadCount'] as int,
      messageCount: (json['messageCount'] as int?) ?? 0,
      isBlocked: (json['isBlocked'] as int?) == 1,
    );
  }

  /// Hydrate from a Spec-H alias contact + its latest `contact_messages` row.
  factory ChatPreview.fromAliasRow({
    required AliasContact contact,
    String? lastMessageContent,
    int? lastMessageTimestamp,
    int? lastMessageDirection,
    int unreadCount = 0,
  }) {
    return ChatPreview(
      aliasContact: contact,
      lastMessageContent: lastMessageContent,
      lastMessageTimestamp: lastMessageTimestamp,
      isLastMessageOutgoing: lastMessageDirection == 1,
      unreadCount: unreadCount,
    );
  }
}
