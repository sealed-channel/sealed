import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:sealed_app/features/settings/screens/topup_screen.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

/// Screen shown before sending an alias chat invitation.
/// Displays info cards explaining how alias chat works, with a
/// "Send Invitation" button at the bottom and an X to cancel.
class CreateAliasChatScreen extends ConsumerStatefulWidget {
  final String? contactWallet;
  final String? contactUsername;

  const CreateAliasChatScreen({
    super.key,
    this.contactWallet,
    this.contactUsername,
  });

  @override
  ConsumerState<CreateAliasChatScreen> createState() =>
      _CreateAliasChatScreenState();
}

class _CreateAliasChatScreenState extends ConsumerState<CreateAliasChatScreen> {
  bool _isSending = false;
  String? _errorMessage;

  Future<void> _sendInvitation() async {
    final alias = widget.contactUsername ?? 'Alias Chat';

    setState(() {
      _isSending = true;
      _errorMessage = null;
    });

    try {
      final aliasChatService = await ref.read(aliasChatServiceProvider.future);

      final chat = await aliasChatService.createInvitation(
        alias: alias,
        contactWallet: widget.contactWallet!,
      );

      // Send invite link as a regular message to the contact
      if (widget.contactWallet != null) {
        try {
          final inviteUri = aliasChatService.generateInviteUri(chat);
          final messageService = await ref.read(messageServiceProvider.future);
          final chainClient = await ref.read(chainClientProvider.future);
          final myWallet = chainClient.activeWalletAddress!;

          await messageService.sendMessage(
            recipientWallet: widget.contactWallet!,
            recipientUsername: widget.contactUsername,
            plaintext: inviteUri,
            senderWallet: myWallet,
          );

          // Refresh conversations so the invite card appears immediately
          ref.read(messagesNotifierProvider.notifier).refresh();
        } catch (_) {
          // Continue even if message send fails — invite was created on-chain
        }
      }

      if (!mounted) return;

      // Return to the regular chat where the invite card is now visible
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      final isLowBalance =
          msg.contains('insufficient') ||
          msg.contains('balance') ||
          msg.contains('overspend') ||
          msg.contains('below min');

      setState(() {
        _isSending = false;
        _errorMessage = isLowBalance
            ? 'Insufficient balance to send invitation. Top up to continue.'
            : 'Failed to send invitation: $e';
      });

      if (isLowBalance) {
        showErrorSnackBar(
          context,
          'Insufficient balance to send invitation',
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'TOP UP',
            textColor: Colors.white,
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const TopUpScreen()));
            },
          ),
        );
      } else {
        showErrorSnackBar(context, 'Failed to send invitation');
      }
    }
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.04), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: primaryColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    final topSafeArea = MediaQuery.of(context).padding.top;
    final contactName = widget.contactUsername ?? 'Contact';

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 6, 6, 6),
      body: Column(
        children: [
          // ---- Header ----
          Container(
            padding: EdgeInsets.only(
              top: topSafeArea + 12,
              left: 20,
              right: 12,
              bottom: 16,
            ),
            child: Row(
              children: [
                // Lock icon + contact name
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: primaryColor.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    CupertinoIcons.lock_shield_fill,
                    color: primaryColor,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contactName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Alias Chat Invitation',
                        style: TextStyle(
                          color: primaryColor.withOpacity(0.8),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // X button
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      CupertinoIcons.xmark,
                      color: Colors.white.withOpacity(0.7),
                      size: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---- Scrollable content ----
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  // Shield icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      CupertinoIcons.lock_shield_fill,
                      size: 40,
                      color: primaryColor.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'How Alias Chat Works',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildInfoCard(
                    icon: CupertinoIcons.person_2_fill,
                    title: 'Zero Identity Link',
                    description:
                        'Each alias chat generates a unique random encryption keypair completely isolated from your wallet. Neither party can trace messages back to any wallet or real identity.',
                  ),
                  const SizedBox(height: 12),
                  _buildInfoCard(
                    icon: CupertinoIcons.shuffle,
                    title: 'Ephemeral Key Exchange',
                    description:
                        'Keys are exchanged through a temporary on-chain box that is automatically destroyed after both parties connect. No permanent trace remains.',
                  ),
                  const SizedBox(height: 12),
                  _buildInfoCard(
                    icon: CupertinoIcons.eye_slash_fill,
                    title: 'Unlinkable Messages',
                    description:
                        'Messages use unique recipient tags derived from alias keys. Even the indexer cannot link alias messages to your main wallet conversations.',
                  ),
                  const SizedBox(height: 12),
                  _buildInfoCard(
                    icon: CupertinoIcons.shield_lefthalf_fill,
                    title: '100% Protection',
                    description:
                        'No metadata, no IP logs, no wallet correlation. The alias chat is mathematically unlinkable to your identity — providing complete sender anonymity.',
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    _buildError(),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // ---- Bottom: Send Invitation button ----
          Container(
            padding: EdgeInsets.fromLTRB(20, 12, 20, bottomSafeArea + 16),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 6, 6, 6),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withOpacity(0.04),
                  width: 0.5,
                ),
              ),
            ),
            child: GestureDetector(
              onTap: _isSending ? null : _sendInvitation,
              child: Container(
                width: double.infinity,
                height: 52,
                decoration: BoxDecoration(
                  gradient: _isSending ? null : primaryGradient,
                  color: _isSending ? Colors.white.withOpacity(0.06) : null,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: _isSending
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: primaryColor,
                          ),
                        )
                      : const Text(
                          'Send Invitation',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.redAccent.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_triangle,
            color: Colors.redAccent,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
