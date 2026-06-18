/// Unified view model for a single chat message, spanning both the legacy
/// wallet-addressed path ([DecryptedMessage]) and the alias-channel path
/// ([ContactMessage]). The chat UI and the grouping helper operate ONLY on this
/// type so nothing downstream sees the source-table split.
///
/// Mapping from the two source types lives with the chat controller; this module
/// stays pure (no Flutter, no repos) so it is trivially unit-testable.
library;

/// A message as the chat thread renders it.
///
/// There is deliberately NO "alias invite card" concept: alias invitation
/// envelopes are surfaced only in `ChatsScreen` (banner + invitation row) and
/// are filtered OUT of the thread — see [isAliasInviteEnvelope].
class ChatMessageVM {
  final String id;
  final String content;
  final bool isOutgoing;
  final DateTime timestamp;

  /// True while a locally-sent message has not yet been confirmed on-chain.
  /// Pending messages never show the "Sent" status indicator.
  final bool isPending;

  const ChatMessageVM({
    required this.id,
    required this.content,
    required this.isOutgoing,
    required this.timestamp,
    this.isPending = false,
  });
}

/// URI prefixes for alias invitation / accept envelopes that ride the
/// wallet-to-wallet DM channel. These must never render as chat bubbles.
const String kAliasInvitePrefix = 'sealed://alias?';
const String kAliasEnvelopePrefix = 'sealed://alias-envelope?';

/// True if [content] is an alias invite/accept envelope (not a real message).
/// Used to filter these out of the chat thread when mapping to [ChatMessageVM].
bool isAliasInviteEnvelope(String content) =>
    content.startsWith(kAliasInvitePrefix) ||
    content.startsWith(kAliasEnvelopePrefix);
