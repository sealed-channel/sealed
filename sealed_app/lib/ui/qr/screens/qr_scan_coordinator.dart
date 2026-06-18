import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/chat_controller.dart';
import 'package:sealed_app/ui/chat/screens/chat.dart';
import 'package:sealed_app/ui/qr/screens/qr_scan_screen.dart';
import 'package:sealed_app/ui/qr/screens/scan_classifier.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// Push the QR scan screen, then route the result to a normal wallet chat.
///
/// The offline (combined-QR) alias handshake lives in the dedicated
/// offline-connection screens (`ui/chats/screens/alias/`); any invite envelope
/// in the scan result is ignored here.
///
/// Flow:
///   1. Scan QR → [ScannedQrResult] (address); null/empty → abort.
///   2. Self-scan → SnackBar, abort.
///   3. Resolve the scanned address's on-chain username (best-effort).
///   4. Push ChatScreen with the address + resolved username hint.
Future<void> startConversationFromQrScan(
  BuildContext context,
  WidgetRef ref,
) async {
  final scanned = await Navigator.of(context).push<ScannedQrResult>(
    MaterialPageRoute(builder: (_) => const QrScanScreen()),
  );
  if (scanned == null || scanned.address.isEmpty) return;
  if (!context.mounted) return;

  final address = scanned.address;
  final ownAddress = ref.read(walletAddressProvider);
  if (ownAddress != null && ownAddress == address) {
    showWarningSnackBar(context, "You can't start a chat with yourself.");
    return;
  }

  final username = await _resolveUsername(ref, address);
  if (!context.mounted) return;

  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          ChatScreen(identity: WalletChatId(address, username: username)),
    ),
  );
}

/// Best-effort on-chain username for [address]. Blocking but bounded — on
/// timeout, error, or no claimed username, returns null and the chat header
/// degrades to the short wallet (chat_controller's `formatWalletShort`).
///
/// This is the same OHTTP chain-read path the wallet chat already uses for keys
/// — no new privacy surface.
Future<String?> _resolveUsername(WidgetRef ref, String address) async {
  const timeout = Duration(seconds: 4);
  try {
    final chain = await ref
        .read(sealedChainClientProvider.future)
        .timeout(timeout);
    final profile = await chain.getUserByWallet(address).timeout(timeout);
    final name = profile?.username;
    return (name != null && name.isNotEmpty) ? name : null;
  } catch (_) {
    return null;
  }
}
