import 'package:sealed_app/features/messaging/chat_message_vm.dart'
    show isAliasInviteEnvelope;
import 'package:sealed_app/models/chat_preview.dart';

/// Tabs shown in the chats screen.
enum ChatsTab { chats, aliasChats, spam }

/// Three disjoint buckets of the chats screen: regular DMs, alias chats,
/// and spam (classical-only peers who have written to us first).
class Partition {
  final List<ChatPreview> regularChats;
  final List<ChatPreview> aliasChats;
  final List<ChatPreview> spamChats;
  const Partition({
    required this.regularChats,
    required this.aliasChats,
    required this.spamChats,
  });
}

/// Splits a unified [ChatPreview] list into the three tab buckets.
///
/// Rules:
/// - Alias-side previews (`p.isAlias`) go to the alias bucket.
/// - A wallet conversation whose ONLY message is an alias invite/accept
///   envelope stub is dropped — invitations surface solely in `ChatsScreen`
///   (banner + invitation row), and once accepted the alias row owns the
///   relationship. Conversations with real wallet DMs (messageCount > 1) stay
///   even if the latest message happens to be a stub.
/// - Wallet rows that are spam (`isSpam` = classical-only OR blocked) go to
///   spam; otherwise to chats.
/// - Each bucket is sorted newest-first.
Partition partitionChats(List<ChatPreview> previews) {
  final aliasRows = <ChatPreview>[];
  final walletRows = <ChatPreview>[];
  for (final p in previews) {
    if (p.isAlias) {
      aliasRows.add(p);
    } else {
      walletRows.add(p);
    }
  }

  final regular = <ChatPreview>[];
  final spam = <ChatPreview>[];

  for (final conv in walletRows) {
    final lastMsg = conv.lastMessageContent ?? '';
    if (conv.messageCount == 1 && isAliasInviteEnvelope(lastMsg)) {
      continue;
    }

    if (conv.isSpam) {
      spam.add(conv);
    } else {
      regular.add(conv);
    }
  }

  int tsOrZero(ChatPreview p) => p.lastMessageTimestamp ?? 0;
  regular.sort((a, b) => tsOrZero(b).compareTo(tsOrZero(a)));
  spam.sort((a, b) => tsOrZero(b).compareTo(tsOrZero(a)));
  aliasRows.sort((a, b) {
    final at = a.lastMessageTimestamp ?? (a.aliasContact!.createdAt * 1000);
    final bt = b.lastMessageTimestamp ?? (b.aliasContact!.createdAt * 1000);
    return bt.compareTo(at);
  });

  return Partition(
    regularChats: regular,
    aliasChats: aliasRows,
    spamChats: spam,
  );
}
