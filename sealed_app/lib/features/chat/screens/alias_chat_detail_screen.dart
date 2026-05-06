import 'package:flutter/material.dart';
import 'package:sealed_app/features/chat/screens/chat_detail.dart';

/// Alias chat detail screen.
///
/// This is now a thin wrapper around [ChatDetailScreen] running in alias
/// mode. All visual logic — header, message list, input bar, message
/// bubbles — lives in `chat_detail.dart`, so editing that file updates
/// both the regular and alias chat experiences.
///
/// The only intentional visual difference is that the top-right corner
/// shows a lock icon (with a Rename / Destroy popup menu) instead of the
/// "Alias Chat" pill button used in regular conversations. That swap is
/// handled inside [ChatDetailScreen] via the `aliasInviteSecret`
/// constructor parameter.
class AliasChatDetailScreen extends StatelessWidget {
  final String inviteSecret;

  const AliasChatDetailScreen({super.key, required this.inviteSecret});

  @override
  Widget build(BuildContext context) {
    return ChatDetailScreen(aliasInviteSecret: inviteSecret);
  }
}
