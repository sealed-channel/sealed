import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:sealed_app/shared/widgets/theme.dart';

/// Two ways to start a chat from a scanned wallet address.
enum ChatType { normal, alias }

/// Show the chat-type picker as a modal bottom sheet.
///
/// Resolves to:
///   - `ChatType.normal` → start a regular end-to-end encrypted chat
///   - `ChatType.alias`  → create a fresh alias-chat invitation
///   - `null`            → user dismissed the sheet
///
/// [address] is the scanned wallet address; shown truncated in the sheet so
/// the user knows what they're connecting to.
Future<ChatType?> showChatTypePicker(
  BuildContext context, {
  required String address,
}) {
  return showModalBottomSheet<ChatType>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => ChatTypePickerSheet(address: address),
  );
}

class ChatTypePickerSheet extends StatelessWidget {
  const ChatTypePickerSheet({super.key, required this.address});

  final String address;

  String get _truncated {
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Start a conversation',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'with $_truncated',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 20),
              _OptionRow(
                key: const ValueKey('chat-type-normal'),
                icon: CupertinoIcons.chat_bubble_2_fill,
                title: 'Normal chat',
                subtitle:
                    'Linked to your identity. Standard end-to-end encryption.',
                onTap: () => Navigator.of(context).pop(ChatType.normal),
              ),
              const SizedBox(height: 8),
              _OptionRow(
                key: const ValueKey('chat-type-alias'),
                icon: CupertinoIcons.eye_slash_fill,
                title: 'Alias chat',
                subtitle:
                    'Anonymous channel — no link to your wallet identity.',
                onTap: () => Navigator.of(context).pop(ChatType.alias),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: primaryColor, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                color: Colors.white.withValues(alpha: 0.3),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
