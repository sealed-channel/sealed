import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/features/messaging/alias/alias_onboarding_service.dart';
import 'package:sealed_app/features/messaging/alias/combined_qr_codec.dart';
import 'package:sealed_app/providers/chat_controller.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/chat/screens/chat.dart';
import 'package:sealed_app/ui/chats/screens/alias/scan.dart';
import 'package:sealed_app/ui/qr/widgets/offline_handshake_qr_view.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/action_tile.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/secure_screen.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

/// Show-QR screen for the offline alias handshake. Two roles via [postScan]:
///
///  - `postScan == false` — **creator (A)**: mints a fresh combined invite
///    (wallet address + invite envelope), shows it as a single static QR,
///    and offers "Scan Key" to scan the partner's reply back.
///  - `postScan == true` — **acceptor (B), reply step**: shows the 841-byte
///    accept envelope ([acceptEnvelopeBytes]) for the creator to scan, then
///    "Open chat" opens the promoted alias conversation ([contactId]).
///
/// No chain side-effects. A's minted-but-unused invite is discarded on dispose
/// (no-op once the handshake promotes it to a contact).
class GenerateKeyScreen extends ConsumerStatefulWidget {
  const GenerateKeyScreen({
    super.key,
    this.postScan = false,
    this.acceptEnvelopeBytes,
    this.contactId,
  });

  /// False = creator mints+shows invite; true = acceptor shows reply.
  final bool postScan;

  /// Reply-step only: the accept envelope to display for the creator to scan.
  final Uint8List? acceptEnvelopeBytes;

  /// Reply-step only: the already-promoted alias contact to open on "Open chat".
  final String? contactId;

  @override
  ConsumerState<GenerateKeyScreen> createState() => _GenerateKeyScreenState();
}

class _GenerateKeyScreenState extends ConsumerState<GenerateKeyScreen> {
  // ── Creator (A) invite state ──────────────────────────────────────────────
  Uint8List? _combinedPayload;
  String? _inviteRef;
  // Captured at mint time so dispose can discard without ref/context access.
  AliasOnboardingService? _onboardingService;
  bool _generating = false;
  bool _completed = false;
  String? _generateError;

  @override
  void dispose() {
    _maybeDiscardInvite();
    super.dispose();
  }

  /// On leaving before the partner's reply completes the handshake, discard the
  /// minted-but-unused invite (erase temp keys + delete the pending row). Uses
  /// the service captured at mint time. No-op once promoted to a contact
  /// (a completed handshake is never torn down). Fire-and-forget.
  void _maybeDiscardInvite() {
    final inviteRef = _inviteRef;
    final svc = _onboardingService;
    if (inviteRef == null || _completed || svc == null) return;
    svc.discardPendingInvite(inviteRef).catchError((_) {});
  }

  /// Mint a fresh invite (once) and encode it with [address] into the combined
  /// QR payload. Guarded so repeated builds don't re-generate.
  Future<void> _ensureInvite(String address) async {
    if (_combinedPayload != null || _generating) return;
    _generating = true;
    try {
      final svc = await ref.read(aliasOnboardingServiceProvider.future);
      _onboardingService = svc; // captured for dispose-time discard
      // A never learns the partner's wallet (alias hides identity), so the
      // creator-side contact label is just "Unnamed" — renamable later.
      final built = await svc.createInvitationEnvelope(alias: 'Unnamed');
      final payload = encodeCombinedQr(
        address: address,
        inviteEnvelope: built.envelopeBytes,
      );
      if (!mounted) return;
      setState(() {
        _combinedPayload = payload;
        _inviteRef = built.inviteRef;
        _generateError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _generateError = '$e');
    } finally {
      _generating = false;
    }
  }

  void _openCreatorReplyScanner() {
    // The creator's invite must outlive this push (its pending row backs the
    // completion), so navigate without disposing — Scan completes and clears
    // the offline-flow stack itself.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ScanKeyScreen(postGenerate: true),
      ),
    );
  }

  void _openChat() {
    _completed = true; // promoted contact — don't discard on dispose
    ref.read(messagesNotifierProvider.notifier).bumpRefresh();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ChatScreen(identity: AliasChatId(widget.contactId!)),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Key material on screen — capture-protected while mounted.
    return SecureScreen(
      child: widget.postScan ? _buildReply(context) : _buildInvite(context),
    );
  }

  // ── Acceptor reply step (postScan == true) ────────────────────────────────
  Widget _buildReply(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      topBar: TopBar(label: "Generate Key"),
      children: [
        Text(
          "Have the other person scan this code to finish the connection",
          style: Theme.of(
            context,
          ).textTheme.labelMedium!.copyWith(color: primaryColor),
        ),
        Gap(8.h),
        _qrCard(
          child: OfflineHandshakeQrView(payload: widget.acceptEnvelopeBytes!),
        ),
        Gap(24.h),
        ActionTile(
          label: "Open chat",
          subtitle: "Start the conversation",
          assetColor: Colors.white.withValues(alpha: 0.9),
          assetPath: "assets/svg/chats/new.svg",
          onTap: _openChat,
        ),
      ],
    );
  }

  // ── Creator invite step (postScan == false) ───────────────────────────────
  Widget _buildInvite(BuildContext context) {
    final address = ref.watch(walletAddressProvider);
    if (address == null || address.isEmpty) {
      return SealedLayout(
        crossAxisAlignment: CrossAxisAlignment.start,
        topBar: TopBar(label: "Generate Key"),
        children: [
          Text(
            'No wallet address available.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      );
    }
    // Mint the invite + encode the combined QR once.
    _ensureInvite(address);

    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      topBar: TopBar(label: "Generate Key"),
      children: [
        Text(
          "Share this code with the other person",
          style: Theme.of(
            context,
          ).textTheme.labelMedium!.copyWith(color: primaryColor),
        ),
        Gap(8.h),
        _qrCard(child: _qrBody()),
        Gap(16.h),
        Text(
          'A secure offline connection requires creating two keys. After the other person scans this code, you must scan the code generated by them.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Gap(24.h),
        ActionTile(
          label: "Scan Key",
          subtitle: "Scan the code generated by the other person",
          assetPath: 'assets/svg/chats/qr.svg',
          onTap: _openCreatorReplyScanner,
        ),
      ],
    );
  }

  Widget _qrCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 16.h),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12.r),
        color: Colors.white.withValues(alpha: 0.08),
      ),
      child: Center(child: child),
    );
  }

  Widget _qrBody() {
    if (_generateError != null) {
      return SizedBox(
        width: 240.w,
        height: 240.w,
        child: Center(
          child: Text(
            'Could not build invite:\n$_generateError',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    final payload = _combinedPayload;
    if (payload == null) {
      return SizedBox(
        width: 240.w,
        height: 240.w,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return OfflineHandshakeQrView(payload: payload);
  }
}
