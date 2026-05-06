import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/features/chat/screens/alias_chat_detail_screen.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/services/alias_chat_service.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

/// Screen to accept an alias chat invitation.
/// Typically opened via deep link or by pasting an invite URI.
class AcceptAliasChatScreen extends ConsumerStatefulWidget {
  final String inviteSecret;
  final String creatorWallet;
  final String? senderUsername;

  const AcceptAliasChatScreen({
    super.key,
    required this.inviteSecret,
    required this.creatorWallet,
    this.senderUsername,
  });

  /// Try to parse a URI and navigate to this screen if valid.
  static void handleInviteUri(
    BuildContext context,
    String uri, {
    String? senderUsername,
  }) {
    final parsed = AliasChatService.parseInviteUri(uri);
    if (parsed == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AcceptAliasChatScreen(
          inviteSecret: parsed.inviteSecret,
          creatorWallet: parsed.creatorWallet,
          senderUsername: senderUsername,
        ),
      ),
    );
  }

  @override
  ConsumerState<AcceptAliasChatScreen> createState() =>
      _AcceptAliasChatScreenState();
}

class _AcceptAliasChatScreenState extends ConsumerState<AcceptAliasChatScreen> {
  bool _isAccepting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _acceptInvitation());
  }

  Future<void> _acceptInvitation() async {
    setState(() {
      _isAccepting = true;
      _errorMessage = null;
    });

    try {
      final service = await ref.read(aliasChatServiceProvider.future);
      await service.acceptInvitation(
        inviteSecret: widget.inviteSecret,
        alias: widget.senderUsername ?? 'Alias',
        creatorWallet: widget.creatorWallet,
      );

      ref.read(messageRefreshCounterProvider.notifier).state++;

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              AliasChatDetailScreen(inviteSecret: widget.inviteSecret),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isAccepting = false;
        _errorMessage = 'Failed to accept: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 3, 3, 3),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HORIZONTAL_PADDING),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Icon(
                      CupertinoIcons.back,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Alias Chat',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),

              const Spacer(),

              if (_isAccepting)
                Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(color: primaryColor),
                      const SizedBox(height: 16),
                      Text(
                        'Accepting invitation...',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),

              if (_errorMessage != null)
                Center(
                  child: Column(
                    children: [
                      Icon(
                        CupertinoIcons.exclamationmark_triangle,
                        color: Colors.redAccent,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: _acceptInvitation,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            gradient: primaryGradient,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            'Retry',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
