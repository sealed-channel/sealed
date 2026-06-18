/// Pure message-grouping logic for the chat thread. No Flutter, no repos —
/// unit-testable in isolation.
///
/// Two consecutive messages belong to the same visual group when they share a
/// sender (incoming vs outgoing) AND are within [kMessageGroupWindow] of each
/// other. Grouping drives rounded-corner stacking, the per-group timestamp
/// header, and the single TX-success ("Sent") status shown once per outgoing
/// run (so "Sent" does NOT appear under every bubble).
library;

import 'package:sealed_app/features/messaging/chat_message_vm.dart';

/// Messages closer together than this, from the same sender, stack into one
/// group. Matches the legacy 5-minute window.
const Duration kMessageGroupWindow = Duration(minutes: 5);

/// A [ChatMessageVM] decorated with its position within a visual group.
class GroupedChatMessage {
  final ChatMessageVM message;

  /// First message of a group → render the timestamp header above it.
  final bool isFirstInGroup;

  /// Last message of a group → bottom rounded corners + status anchor.
  final bool isLastInGroup;

  /// Show the timestamp header (equivalent to [isFirstInGroup]).
  final bool showTimestamp;

  /// Show the single TX-success "Sent" line. True only on the last outgoing
  /// message of a run that is no longer pending — never under every bubble.
  final bool showStatus;

  const GroupedChatMessage({
    required this.message,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.showTimestamp,
    required this.showStatus,
  });
}

/// Group a chronological (oldest → newest) list of messages.
///
/// Returns a list in the same order with per-message group flags. Deterministic;
/// safe on an empty list.
List<GroupedChatMessage> groupMessages(List<ChatMessageVM> chronological) {
  final out = <GroupedChatMessage>[];
  for (var i = 0; i < chronological.length; i++) {
    final cur = chronological[i];

    final isFirstInGroup = i == 0 || !_sameGroup(chronological[i - 1], cur);
    final isLastInGroup =
        i == chronological.length - 1 || !_sameGroup(cur, chronological[i + 1]);

    out.add(
      GroupedChatMessage(
        message: cur,
        isFirstInGroup: isFirstInGroup,
        isLastInGroup: isLastInGroup,
        showTimestamp: isFirstInGroup,
        showStatus: cur.isOutgoing && isLastInGroup && !cur.isPending,
      ),
    );
  }
  return out;
}

/// Two adjacent (chronological) messages stack together: same direction and
/// within [kMessageGroupWindow].
bool _sameGroup(ChatMessageVM a, ChatMessageVM b) {
  if (a.isOutgoing != b.isOutgoing) return false;
  final gap = b.timestamp.difference(a.timestamp).abs();
  return gap < kMessageGroupWindow;
}
