import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/features/chat/screens/alias_chat_detail_screen.dart';
import 'package:sealed_app/features/chat/screens/chat_detail.dart';
import 'package:sealed_app/features/qr/chat_type_picker_sheet.dart';
import 'package:sealed_app/features/qr/qr_scan_screen.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:sealed_app/providers/message_provider.dart';

/// Push the QR scan screen, then route the result to the appropriate chat.
///
/// Flow:
///   1. Scan QR → address (or null on back)
///   2. If self-scan → SnackBar, abort
///   3. Show chat-type picker (Normal vs Alias)
///   4. Normal → push ChatDetailScreen with the scanned address
///   5. Alias  → AliasChatService.createInvitation(`alias_<last4>`, address)
///              → push AliasChatDetailScreen with the new inviteSecret
///   6. Picker dismissed → no-op (back to caller)
Future<void> startConversationFromQrScan(
  BuildContext context,
  WidgetRef ref,
) async {
  final scanned = await Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
  if (scanned == null || scanned.isEmpty) return;
  if (!context.mounted) return;

  final ownAddress = ref.read(walletAddressProvider);
  if (ownAddress != null && ownAddress == scanned) {
    showWarningSnackBar(context, "You can't start a chat with yourself.");
    return;
  }

  final type = await showChatTypePicker(context, address: scanned);
  if (type == null || !context.mounted) return;

  switch (type) {
    case ChatType.normal:
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatDetailScreen(
            conversation: Conversation(contactWallet: scanned),
          ),
        ),
      );
    case ChatType.alias:
      await _createAndOpenAliasChat(context, ref, scanned);
  }
}

Future<void> _createAndOpenAliasChat(
  BuildContext context,
  WidgetRef ref,
  String contactWallet,
) async {
  // Show a non-blocking spinner overlay while the on-chain invite tx is sent.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  try {
    final aliasChatService = await ref.read(aliasChatServiceProvider.future);
    final aliasName =
        'alias_${contactWallet.substring(contactWallet.length - 4)}';
    final chat = await aliasChatService.createInvitation(
      alias: aliasName,
      contactWallet: contactWallet,
    );

    // Mirror create_alias_chat_screen.dart::_sendInvitation: deliver the
    // sealed://alias?... URI as a regular Sealed message so the recipient's
    // normal message sync (and the My QR poller) can discover the invite.
    try {
      final inviteUri = aliasChatService.generateInviteUri(chat);
      final messageService = await ref.read(messageServiceProvider.future);
      final chainClient = await ref.read(chainClientProvider.future);
      final myWallet = chainClient.activeWalletAddress;
      if (myWallet != null) {
        await messageService.sendMessage(
          recipientWallet: contactWallet,
          plaintext: inviteUri,
          senderWallet: myWallet,
        );
        ref.read(messagesNotifierProvider.notifier).refresh();
      }
    } catch (_) {
      // Non-fatal: on-chain invite memo is the source of truth; the URI
      // message is just a discovery hint.
    }

    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss spinner

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AliasChatDetailScreen(inviteSecret: chat.inviteSecret),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss spinner
    showErrorSnackBar(context, 'Failed to create alias chat: $e');
  }
}
