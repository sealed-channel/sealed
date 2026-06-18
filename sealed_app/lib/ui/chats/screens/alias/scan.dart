import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';
import 'package:sealed_app/providers/chat_controller.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/ui/chat/screens/chat.dart';
import 'package:sealed_app/ui/chats/screens/alias/generate.dart';
import 'package:sealed_app/ui/qr/screens/scan_classifier.dart';
import 'package:sealed_app/ui/qr/widgets/offline_handshake_scanner.dart';
import 'package:sealed_app/ui/qr/widgets/qr_camera_view.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/action_tile.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/secure_screen.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

/// Camera scan screen for the offline alias handshake. Two roles via
/// [postGenerate]:
///
///  - `postGenerate == false` — **acceptor (B)**: scans the creator's combined
///    invite QR (address + invite envelope), derives keys and promotes the
///    contact via `acceptInvitationFromEnvelope`, then offers "Generate Key" to
///    show the reply for the creator to scan back.
///  - `postGenerate == true` — **creator (A), complete step**: scans the
///    partner's reply (accept envelope), finalizes via
///    `completeFromAcceptEnvelope`, and opens the alias chat.
///
/// No chain side-effects.
class ScanKeyScreen extends ConsumerStatefulWidget {
  const ScanKeyScreen({super.key, this.postGenerate = false});

  /// False = acceptor scans invite; true = creator scans reply to complete.
  final bool postGenerate;

  @override
  ConsumerState<ScanKeyScreen> createState() => _ScanKeyScreenState();
}

enum _ScanPhase { scanning, working, replied, error }

class _ScanKeyScreenState extends ConsumerState<ScanKeyScreen> {
  QRViewController? _controller;

  // Acceptor (B) combined-QR frame assembler (single frame in practice).
  final OfflineHandshakeAccumulator _acc = OfflineHandshakeCodec.decoder();

  // Creator (A) reply-envelope assembler. Frames arrive via [QrCameraView]'s
  // per-code callback, so we bridge them through a controller into the
  // stream-based [OfflineHandshakeScanner].
  StreamController<String>? _replyFrames;
  OfflineHandshakeScanner? _replyScanner;
  StreamSubscription<Uint8List>? _replySub;

  _ScanPhase _phase = _ScanPhase.scanning;
  bool _consumed = false; // one-shot guard against rapid duplicate detections
  String? _error;

  // Acceptor reply state, carried into the Generate (reply) screen.
  Uint8List? _acceptBytes;
  String? _contactId;

  @override
  void dispose() {
    _disposeReplyScanner();
    super.dispose();
  }

  void _disposeReplyScanner() {
    _replySub?.cancel();
    _replySub = null;
    _replyScanner?.dispose();
    _replyScanner = null;
    _replyFrames?.close();
    _replyFrames = null;
  }

  void _onCameraReady(QRViewController controller) {
    _controller = controller;
    if (widget.postGenerate) {
      // Creator completing: assemble the reply envelope across frames. Frames
      // are pushed in via [_onScan]; the scanner consumes them as a stream.
      final frames = StreamController<String>();
      final scanner = OfflineHandshakeScanner(frames.stream);
      _replyFrames = frames;
      _replyScanner = scanner;
      _replySub = scanner.payloads.listen(_onReplyPayload);
    }
  }

  void _onScan(String value) {
    if (widget.postGenerate) {
      // Creator: feed frames to the reply-envelope assembler.
      _replyFrames?.add(value);
      return;
    }
    // Acceptor scanning the combined invite QR.
    if (_consumed) return;
    switch (classifyScan(value, _acc)) {
      case ScanCombined(:final inviteEnvelope):
        _onInviteScanned(inviteEnvelope);
      case ScanAddress():
      case ScanAccumulating():
      case ScanInvalid():
        // Not a combined alias invite — keep scanning silently.
        break;
    }
  }

  // ── Acceptor (B): scanned the creator's invite ────────────────────────────
  Future<void> _onInviteScanned(Uint8List inviteBytes) async {
    if (_consumed) return;
    _consumed = true;
    await _controller?.pauseCamera();

    final env = AliasInviteEnvelope.tryParse(inviteBytes);
    if (env == null) {
      _fail('Scanned data is not a valid alias invite.');
      return;
    }
    setState(() => _phase = _ScanPhase.working);
    try {
      final svc = await ref.read(aliasOnboardingServiceProvider.future);
      // Symmetric naming: both sides start "Unnamed" — renamable later.
      final result = await svc.acceptInvitationFromEnvelope(
        env: env,
        alias: 'Unnamed',
      );
      if (!mounted) return;

      // Idempotent re-scan: already a contact, no reply to show — open it.
      if (result.acceptEnvelopeBytes.isEmpty) {
        ref.read(messagesNotifierProvider.notifier).bumpRefresh();
        _openChat(result.contact.contactId);
        return;
      }

      setState(() {
        _acceptBytes = result.acceptEnvelopeBytes;
        _contactId = result.contact.contactId;
        _phase = _ScanPhase.replied;
      });
    } catch (e) {
      _fail('Failed to accept invite: $e');
    }
  }

  // ── Creator (A): scanned the partner's reply ──────────────────────────────
  Future<void> _onReplyPayload(Uint8List bytes) async {
    if (_consumed) return;
    final env = AliasAcceptEnvelope.tryParse(bytes);
    if (env == null) {
      _fail('Scanned data is not a valid alias reply.');
      return;
    }
    _consumed = true;
    await _controller?.pauseCamera();
    _disposeReplyScanner();
    setState(() => _phase = _ScanPhase.working);
    try {
      final svc = await ref.read(aliasOnboardingServiceProvider.future);
      final contact = await svc.completeFromAcceptEnvelope(env);
      if (!mounted) return;
      if (contact == null) {
        _fail('No matching pending invite for this reply.');
        return;
      }
      ref.read(messagesNotifierProvider.notifier).bumpRefresh();
      _openChat(contact.contactId);
    } catch (e) {
      _fail('Failed to complete handshake: $e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _phase = _ScanPhase.error;
    });
  }

  void _openChat(String contactId) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ChatScreen(identity: AliasChatId(contactId)),
      ),
      (route) => route.isFirst,
    );
  }

  void _showReply() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GenerateKeyScreen(
          postScan: true,
          acceptEnvelopeBytes: _acceptBytes,
          contactId: _contactId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Handshake key material on screen — capture-protected while mounted.
    return SecureScreen(
      child: switch (_phase) {
        _ScanPhase.scanning => _buildScanning(),
        _ScanPhase.working => _buildWorking(),
        _ScanPhase.replied => _buildReplied(),
        _ScanPhase.error => _buildError(),
      },
    );
  }

  Widget _buildScanning() {
    return QrCameraView(
      topBarLabel: "Scan Key",
      onControllerReady: _onCameraReady,
      onScan: _onScan,
    );
  }

  Widget _buildWorking() {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.center,
      topBar: TopBar(label: "Scan Key"),
      children: [
        Gap(80.h),
        Center(child: CircularProgressIndicator(color: primaryColor)),
        Gap(16.h),
        Text(
          widget.postGenerate
              ? 'Completing connection…'
              : 'Accepting invitation…',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  // Acceptor success: prompt to generate the reply key.
  Widget _buildReplied() {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      topBar: TopBar(label: "Scan Key"),
      children: [
        Text(
          "Key scanned",
          style: Theme.of(
            context,
          ).textTheme.labelMedium!.copyWith(color: primaryColor),
        ),
        Gap(8.h),
        Text(
          'To continue, create a second key for the other participant to scan.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Gap(16.h),
        ActionTile(
          label: "Generate Key",
          subtitle: "Generate a QR code for the other person",
          assetPath: "assets/svg/key.svg",
          onTap: _showReply,
        ),
      ],
    );
  }

  Widget _buildError() {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      topBar: TopBar(label: "Scan Key"),
      children: [
        Text(
          _error ?? 'Something went wrong.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(color: Colors.redAccent),
        ),
        Gap(16.h),
        ActionTile(
          label: "Try again",
          subtitle: "Scan the code again",
          assetPath: 'assets/svg/chats/qr.svg',
          onTap: () {
            _consumed = false;
            _disposeReplyScanner();
            setState(() {
              _error = null;
              _phase = _ScanPhase.scanning;
            });
          },
        ),
      ],
    );
  }
}
