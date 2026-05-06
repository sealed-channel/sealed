import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sealed_app/features/chat/screens/accept_alias_chat_screen.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/services/alias_chat_service.dart';
import 'package:sealed_app/shared/widgets/theme.dart';
import 'package:sealed_app/core/snackbars.dart';

/// Settings → "My QR Code". Shows the current user's Algorand wallet address
/// as a scannable QR code plus the address as selectable monospaced text.
///
/// While this screen is mounted it polls for new incoming messages every
/// ~3 seconds. If a fresh incoming message body parses as a `sealed://alias?`
/// invite URI, it auto-routes into [AcceptAliasChatScreen] — this is how the
/// device that *displays* the QR learns about an alias chat invitation
/// triggered by another device scanning that QR.
class QrDisplayScreen extends ConsumerStatefulWidget {
  const QrDisplayScreen({super.key});

  @override
  ConsumerState<QrDisplayScreen> createState() => _QrDisplayScreenState();
}

class _QrDisplayScreenState extends ConsumerState<QrDisplayScreen> {
  static const Duration _pollInterval = Duration(seconds: 3);
  static const String _aliasUriPrefix = 'sealed://alias?';

  Timer? _pollTimer;
  bool _polling = false;
  bool _navigated = false;
  bool _baselineLoaded = false;
  // URIs that already existed on screen open — never auto-accept these.
  final Set<String> _baselineInvites = <String>{};
  // URIs we've already routed (or decided to skip) this session.
  final Set<String> _handledInvites = <String>{};

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    // Kick off an immediate sync so we don't wait the full interval on open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _pollOnce());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  Future<void> _pollOnce() async {
    if (_polling || _navigated || !mounted) return;
    _polling = true;
    try {
      await ref.read(messagesNotifierProvider.notifier).syncMessages();
      if (!mounted || _navigated) return;

      final conversations = ref.read(messagesNotifierProvider).asData?.value;
      if (conversations == null) return;

      // First successful poll → snapshot the existing alias URIs as the
      // baseline. Anything in this set predates the screen opening and
      // must not auto-accept.
      if (!_baselineLoaded) {
        for (final c in conversations) {
          final preview = c.lastMessagePreview;
          if (!c.isLastMessageOutgoing && preview.startsWith(_aliasUriPrefix)) {
            _baselineInvites.add(preview);
          }
        }
        _baselineLoaded = true;
        return;
      }

      final aliasService = await ref.read(aliasChatServiceProvider.future);

      for (final c in conversations) {
        final preview = c.lastMessagePreview;
        if (c.isLastMessageOutgoing) continue;
        if (!preview.startsWith(_aliasUriPrefix)) continue;
        if (_baselineInvites.contains(preview)) continue;
        if (_handledInvites.contains(preview)) continue;

        // Skip invites for chats we already know about locally (pending
        // or active) — those have either been processed before or are
        // still mid-handshake from a prior session.
        final parsed = AliasChatService.parseInviteUri(preview);
        if (parsed != null) {
          final existing = await aliasService.getAliasChat(parsed.inviteSecret);
          if (existing != null) {
            _handledInvites.add(preview);
            continue;
          }
        }

        _handledInvites.add(preview);
        _navigated = true;
        _pollTimer?.cancel();
        _pollTimer = null;

        if (!mounted) return;
        AcceptAliasChatScreen.handleInviteUri(
          context,
          preview,
          senderUsername: c.contactUsername,
        );
        break;
      }
    } catch (_) {
      // Swallow: polling is best-effort. Next tick will retry.
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final walletState = ref.watch(localWalletProvider);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: sealedBackgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(context),
              Expanded(
                child: walletState.when(
                  data: (state) {
                    final address = state.walletAddress;
                    if (address == null || address.isEmpty) {
                      return const _Message(
                        text: 'No wallet address available.',
                      );
                    }
                    return _QrBody(address: address);
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _Message(text: 'Error loading wallet: $e'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(CupertinoIcons.back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Text(
            'My QR Code',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 22 / 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _QrBody extends StatelessWidget {
  const _QrBody({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: address,
              version: QrVersions.auto,
              size: 280,
              gapless: false,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              address,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            icon: Icon(CupertinoIcons.doc_on_doc, color: primaryColor),
            label: Text('Copy address', style: TextStyle(color: primaryColor)),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: address));
              if (!context.mounted) return;
              showInfoSnackBar(context, 'Address copied');
            },
          ),
          const SizedBox(height: 16),
          Text(
            'Share this wallet address so a contact can scan it and start a chat.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
