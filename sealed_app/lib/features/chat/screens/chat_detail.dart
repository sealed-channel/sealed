import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:intl/intl.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/chat/screens/accept_alias_chat_screen.dart';
import 'package:sealed_app/features/chat/screens/alias_chat_detail_screen.dart';
import 'package:sealed_app/features/chat/screens/create_alias_chat_screen.dart';
import 'package:sealed_app/features/settings/screens/topup_screen.dart';
import 'package:sealed_app/models/alias_chat.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

class ChatDetailScreen extends ConsumerStatefulWidget {
  /// Set for a regular wallet-to-wallet conversation.
  final Conversation? conversation;

  /// Set for an alias chat. When non-null this screen renders the same UI
  /// as a regular chat with two differences:
  ///   1. The top-right "Alias Chat" pill is replaced with a lock icon
  ///      that opens a popup menu (Rename Alias / Destroy Chat).
  ///   2. Messages, send, and read tracking go through the alias service
  ///      (`aliasChatServiceProvider`) and `aliasMessagesProvider`.
  /// All visual layout (header, message list, input bar, bubble) is shared
  /// with the regular path so editing this file updates both modes.
  final String? aliasInviteSecret;

  const ChatDetailScreen({super.key, this.conversation, this.aliasInviteSecret})
    : assert(
        conversation != null || aliasInviteSecret != null,
        'ChatDetailScreen requires either a conversation or an aliasInviteSecret',
      );

  @override
  ConsumerState<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends ConsumerState<ChatDetailScreen>
    with TickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _backButtonPressed = false;
  final List<_PendingMessage> _pendingMessages = [];

  // Animation for Sealed logo
  late AnimationController _logoAnimationController;
  late Animation<double> _bottomSlideAnimation;
  late Animation<double> _topSlideAnimation;

  // Idle floating animation (runs continuously after initial animation)
  late AnimationController _idleAnimationController;
  late Animation<double> _idleFloatAnimation;

  bool _markedAsRead = false;

  // Alias-mode state. Unused (and never updated) in regular mode.
  bool _isAliasPending = true;
  bool _isAliasPolling = false;
  bool _isAliasSyncing = false;
  bool _isAliasSending = false;
  String _aliasDisplayName = '';

  bool get _isAliasMode => widget.aliasInviteSecret != null;

  @override
  void initState() {
    super.initState();
    _logoAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    );

    // Bottom part: slides from right to left (1.0 -> 0.0)
    _bottomSlideAnimation = Tween<double>(begin: .7, end: 0.0).animate(
      CurvedAnimation(
        parent: _logoAnimationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
      ),
    );

    // Top part: slides from left to right (-1.0 -> 0.0)
    _topSlideAnimation = Tween<double>(begin: -.7, end: 0.0).animate(
      CurvedAnimation(
        parent: _logoAnimationController,
        curve: const Interval(0.2, 0.8, curve: Curves.easeOutCubic),
      ),
    );

    // Idle floating animation - subtle continuous movement
    _idleAnimationController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _idleFloatAnimation = Tween<double>(begin: -1.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _idleAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    // Start idle animation after initial animation completes
    _logoAnimationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _idleAnimationController.repeat(reverse: true);
      }
    });

    // Mark conversation as read when opening
    _markAsRead();

    // Auto-sync messages when entering conversation (especially for blockchain mode)
    _autoSyncOnEnter();

    if (_isAliasMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadAlias();
        _checkAliasStatusAndPoll();
        _dismissAliasInviteCard();
      });
    }
  }

  Future<void> _autoSyncOnEnter() async {
    if (_isAliasMode) return;
    try {
      // Sync immediately when entering conversation to pick up any missed messages
      print('[ChatDetail] 🔄 Syncing on conversation enter');
      ref.read(messagesNotifierProvider.notifier).syncMessages();
    } catch (e) {
      print('[ChatDetail] ⚠️ Failed to auto-sync: $e');
    }
  }

  Future<void> _markAsRead() async {
    if (_isAliasMode) {
      try {
        final cache = ref.read(aliasChatCacheProvider);
        await cache.markAliasMessagesAsRead(widget.aliasInviteSecret!);
        ref.read(messageRefreshCounterProvider.notifier).state++;
      } catch (e) {
        print('[ChatDetail] ⚠️ Failed to mark alias as read: $e');
      }
      return;
    }
    try {
      final messageService = await ref.read(messageServiceProvider.future);
      await messageService.markConversationAsRead(
        widget.conversation!.contactWallet,
      );
      // Refresh conversation list so unread badge disappears
      ref.invalidate(messagesNotifierProvider);
    } catch (e) {
      print('[ChatDetail] ⚠️ Failed to mark as read: $e');
    }
  }

  @override
  void dispose() {
    _isAliasPolling = false;
    _isAliasSyncing = false;
    _messageController.dispose();
    _scrollController.dispose();
    _logoAnimationController.dispose();
    _idleAnimationController.dispose();
    super.dispose();
  }

  String _formatWalletAddress(String address) {
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 6)}';
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inDays == 0) {
      return DateFormat('HH:mm').format(timestamp);
    } else if (diff.inDays == 1) {
      return 'Yesterday ${DateFormat('HH:mm').format(timestamp)}';
    } else if (diff.inDays < 7) {
      return DateFormat('EEE HH:mm').format(timestamp);
    } else {
      return DateFormat('MMM d, HH:mm').format(timestamp);
    }
  }

  Future<void> _sendMessage() async {
    if (_isAliasMode) {
      await _sendAliasMessage();
      return;
    }
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final pendingMessage = _PendingMessage(
      localId: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      content: text,
      timestamp: DateTime.now(),
    );

    _messageController.clear();
    setState(() {
      _pendingMessages.insert(0, pendingMessage);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });

    try {
      final messageService = await ref.read(messageServiceProvider.future);
      final chainClient = await ref.read(chainClientProvider.future);
      final myWallet = chainClient.activeWalletAddress!;

      await messageService.sendMessage(
        recipientWallet: widget.conversation!.contactWallet,
        recipientUsername: widget.conversation!.contactUsername,
        plaintext: text,
        senderWallet: myWallet,
      );

      if (mounted) {
        setState(() {
          _pendingMessages.removeWhere(
            (message) => message.localId == pendingMessage.localId,
          );
        });
      }

      // Refresh the messages
      ref.invalidate(
        conversationMessagesProvider(widget.conversation!.contactWallet),
      );

      // Also refresh the conversations list to update last message preview and timestamp
      ref.read(messagesNotifierProvider.notifier).refresh();

      // Scroll to bottom
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            0, // Since we're using reverse: true
            duration: Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _pendingMessages.removeWhere(
            (message) => message.localId == pendingMessage.localId,
          );
        });
      }
      if (mounted) {
        final sendError = SendMessageException.fromError(e);
        if (!sendError.isRetryable &&
            sendError.message.toLowerCase().contains('insufficient')) {
          await context.showInsufficientBalanceDialog(
            onTopUp: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const TopUpScreen()),
              );
            },
          );
        } else {
          context.showSendError(sendError.message, onRetry: _sendMessage);
        }
      }
    }
  }

  List<DecryptedMessage> _mergeMessagesWithPending(
    List<DecryptedMessage> saved,
  ) {
    if (_pendingMessages.isEmpty) return saved;

    final pendingAsMessages = _pendingMessages
        .map(
          (pending) => DecryptedMessage(
            id: pending.localId,
            senderWallet: '',
            recipientWallet: widget.conversation!.contactWallet,
            content: pending.content,
            timestamp: pending.timestamp,
            isOutgoing: true,
            onChainPubkey: '',
          ),
        )
        .toList();

    final combined = [...pendingAsMessages, ...saved];
    combined.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return combined;
  }

  void _copyWalletAddress() {
    Clipboard.setData(ClipboardData(text: widget.conversation!.contactWallet));
    showInfoSnackBar(
      context,
      'Wallet address copied',
      duration: const Duration(seconds: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Mark as read once when opening the conversation
    if (!_markedAsRead) {
      _markedAsRead = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _markAsRead());
    }

    if (_isAliasMode) {
      return _buildAliasScaffold(context);
    }

    // Listen for new incoming messages and auto-mark as read while viewing this conversation
    ref.listen(
      conversationMessagesProvider(widget.conversation!.contactWallet),
      (previous, next) {
        // If new messages arrived (count increased), mark as read
        next.whenData((messages) {
          final previousCount = previous?.asData?.value.length ?? 0;
          if (messages.length > previousCount) {
            // New message(s) arrived while viewing, mark as read
            _markAsRead();
          }
        });
      },
    );

    final messagesAsync = ref.watch(
      conversationMessagesProvider(widget.conversation!.contactWallet),
    );

    final displayName =
        widget.conversation!.contactUsername ??
        _formatWalletAddress(widget.conversation!.contactWallet);

    final headerHeight = topPadding(context) + 80;

    return Scaffold(
      backgroundColor: Color.fromARGB(255, 6, 6, 6),
      body: Stack(
        children: [
          // Messages List (full height, scrolls behind header)
          Column(
            children: [
              Expanded(
                child: messagesAsync.when(
                  data: (messages) {
                    final merged = _mergeMessagesWithPending(messages);
                    return _buildMessagesList(merged, headerHeight);
                  },
                  loading: () => Center(
                    child: CircularProgressIndicator(color: primaryColor),
                  ),
                  error: (error, _) => Center(
                    child: Text(
                      'Error loading messages: $error',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ),
              // Input Bar
              _buildInputBar(),
            ],
          ),

          // Frosted Glass Header (positioned on top)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: _buildHeader(context, displayName),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String displayName) {
    // Watch indexer status to control animation and color
    final indexerStatus = ref.watch(indexerStatusProvider);
    final isConnected = indexerStatus == IndexerStatus.connected;
    bool isAliasChatButtonPressed = false;
    // Control animation based on connection status
    if (isConnected) {
      if (!_logoAnimationController.isCompleted) {
        _logoAnimationController.forward();
      }
    } else {
      _logoAnimationController.reset();
      _idleAnimationController.stop();
      _idleAnimationController.reset();
    }

    return Container(
      padding: EdgeInsets.only(
        left: 4,
        right: 8,
        top: topPadding(context),
        bottom: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => setState(() => _backButtonPressed = true),
                onTapUp: (_) => setState(() => _backButtonPressed = false),
                onTapCancel: () => setState(() => _backButtonPressed = false),
                onTap: () => Navigator.of(context).pop(),
                child: AnimatedScale(
                  scale: _backButtonPressed ? 0.85 : 1.0,
                  duration: const Duration(milliseconds: 100),
                  child: AnimatedOpacity(
                    opacity: _backButtonPressed ? 0.6 : 1.0,
                    duration: const Duration(milliseconds: 100),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Icon(
                        CupertinoIcons.back,
                        size: 28,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8),
              CircleAvatar(
                radius: 20,
                backgroundColor: primaryColor,
                child: Text(
                  displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    GestureDetector(
                      onTap: _isAliasMode ? null : _copyWalletAddress,
                      child: Row(
                        children: [
                          Text(
                            _isAliasMode
                                ? 'Alias Chat'
                                : _formatWalletAddress(
                                    widget.conversation!.contactWallet,
                                  ),
                            style: TextStyle(
                              color: _isAliasMode
                                  ? primaryColor.withOpacity(0.8)
                                  : Colors.white.withOpacity(0.7),
                              fontSize: 12,
                            ),
                          ),
                          if (!_isAliasMode) ...[
                            SizedBox(width: 6),
                            Icon(
                              CupertinoIcons.doc_on_doc,
                              size: 14,
                              color: Colors.white.withOpacity(0.7),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_isAliasMode)
                _buildAliasTopRightAction()
              else
                GestureDetector(
                  onTapDown: (details) {
                    setState(() => isAliasChatButtonPressed = true);
                  },
                  onTapUp: (details) {
                    setState(() => isAliasChatButtonPressed = false);
                  },
                  onTapCancel: () {
                    setState(() => isAliasChatButtonPressed = false);
                  },
                  onTap: () => {_startAliasChat(context)},
                  child: AnimatedOpacity(
                    opacity: isAliasChatButtonPressed ? 0.95 : 1.0,
                    duration: const Duration(milliseconds: 100),
                    child: AnimatedScale(
                      scale: isAliasChatButtonPressed ? 0.95 : 1.0,
                      duration: const Duration(milliseconds: 100),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          "Alias Chat",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
            ],
          ),
        ],
      ),
    );
  }

  void _startAliasChat(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) => CreateAliasChatScreen(
              contactWallet: widget.conversation!.contactWallet,
              contactUsername:
                  widget.conversation!.contactUsername ??
                  _formatWalletAddress(widget.conversation!.contactWallet),
            ),
          ),
        )
        .then((_) {
          // Refresh chat list when returning
          ref.read(messageRefreshCounterProvider.notifier).state++;
        });
  }

  Widget _buildSealedLogoRow(bool isConnected) {
    // Define gradients
    final activeGradient = primaryGradient;
    final inactiveGradient = LinearGradient(
      colors: [Colors.white.withOpacity(0.6), Colors.grey.withOpacity(0.4)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    final gradient = isConnected ? activeGradient : inactiveGradient;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 28,
          height: 28,
        ), // Placeholder for logo to prevent layout shift
        // Animated Sealed Logo
        SizedBox(
          width: 28,
          height: 28,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _logoAnimationController,
              _idleAnimationController,
            ]),
            builder: (context, child) {
              // Calculate idle offset (only applies after initial animation completes)
              final idleOffset = _logoAnimationController.isCompleted
                  ? _idleFloatAnimation.value * 0.8
                  : 0.0;

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // Bottom part (slides from right to left, then floats)
                  Positioned.fill(
                    top: 0,
                    child: Transform.translate(
                      offset: Offset(
                        isConnected
                            ? _bottomSlideAnimation.value * 20 + idleOffset
                            : 0,
                        0,
                      ),
                      child: ShaderMask(
                        shaderCallback: (bounds) =>
                            gradient.createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: Image.asset(
                          'assets/sealed_bottom.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                  // Top part (slides from left to right, then floats opposite)
                  Positioned.fill(
                    top: -15,
                    child: Transform.translate(
                      offset: Offset(
                        isConnected
                            ? _topSlideAnimation.value * 20 - idleOffset
                            : 0,
                        0,
                      ),
                      child: ShaderMask(
                        shaderCallback: (bounds) =>
                            gradient.createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: Image.asset(
                          'assets/sealed_top.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        // Status text - fixed width to prevent layout shift
        Container(
          margin: EdgeInsets.only(bottom: 7.5, right: 20),

          child: Text(
            isConnected ? 'Sealed' : 'Real Time (Off)',
            style: TextStyle(
              color: isConnected ? primaryColor : Colors.grey,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        // if (isConnected) ...[
        //   Container(
        //     width: 6,
        //     height: 6,
        //     decoration: BoxDecoration(
        //       color: primaryColor,
        //       shape: BoxShape.circle,
        //       boxShadow: [
        //         BoxShadow(
        //           color: primaryColor.withOpacity(0.5),
        //           blurRadius: 4,
        //           spreadRadius: 1,
        //         ),
        //       ],
        //     ),
        //   ),
        // ],
      ],
    );
  }

  Widget _buildMessagesList(
    List<DecryptedMessage> messages,
    double headerHeight,
  ) {
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(height: 16),
            Text(
              'No messages yet',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      reverse: true, // Latest messages at bottom
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: headerHeight + 12,
        bottom: 12,
      ),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];

        // Check if we should show time separator
        // (more than 5 minutes gap from previous message or different sender)
        bool showTimestamp = true;
        bool isFirstInGroup = true;

        // Since list is reversed, "previous" message is at index + 1
        if (index < messages.length - 1) {
          final previousMessage = messages[index + 1];
          final timeDiff = message.timestamp
              .difference(previousMessage.timestamp)
              .abs();
          final sameSender = message.isOutgoing == previousMessage.isOutgoing;

          // Don't show timestamp if same sender and within 5 minutes
          if (sameSender && timeDiff.inMinutes < 5) {
            showTimestamp = false;
            isFirstInGroup = false;
          }
        }

        // Check if this is the last in a group (next message is different sender or >5min gap)
        bool isLastInGroup = true;
        if (index > 0) {
          final nextMessage = messages[index - 1];
          final timeDiff = nextMessage.timestamp
              .difference(message.timestamp)
              .abs();
          final sameSender = message.isOutgoing == nextMessage.isOutgoing;

          if (sameSender && timeDiff.inMinutes < 5) {
            isLastInGroup = false;
          }
        }

        return _SwipeableMessageBubble(
          message: message,
          showTimestamp: showTimestamp,
          isFirstInGroup: isFirstInGroup,
          isLastInGroup: isLastInGroup,
          isPending: message.id.startsWith('pending-'),
          formatTimestamp: _formatTimestamp,
          isIncoming: !message.isOutgoing,
        );
      },
    );
  }

  Widget _buildInputBar() {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    final charCount = _messageController.text.length;
    final isOverLimit = charCount > MAX_MESSAGE_CHARS;
    final isNearLimit = charCount > MAX_MESSAGE_CHARS * 0.8;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(color: cardColor),
      padding: EdgeInsets.only(
        left: 32,
        right: 32,
        top: 16,
        bottom: keyboardHeight > 0 ? 16 : bottomSafeArea + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 120),
                  child: TextField(
                    controller: _messageController,
                    style: TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: null,
                    maxLength: MAX_MESSAGE_CHARS,
                    textInputAction: TextInputAction.newline,
                    buildCounter:
                        (
                          context, {
                          required currentLength,
                          required isFocused,
                          maxLength,
                        }) => null,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: "Type your message here...",
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.4),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: _SendButton(onTap: isOverLimit ? () {} : _sendMessage),
              ),
            ],
          ),
          if (charCount > 0)
            Padding(
              padding: EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '$charCount / $MAX_MESSAGE_CHARS',
                    style: TextStyle(
                      fontSize: 11,
                      color: isOverLimit
                          ? Colors.red
                          : isNearLimit
                          ? Colors.orange
                          : Colors.white.withOpacity(0.3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ───────────────────────────── alias-mode ─────────────────────────────

  Future<void> _loadAlias() async {
    final cache = ref.read(aliasChatCacheProvider);
    final chat = await cache.getAliasChat(widget.aliasInviteSecret!);
    if (chat != null && mounted) {
      setState(() => _aliasDisplayName = chat.alias);
    }
  }

  Future<void> _dismissAliasInviteCard() async {
    try {
      final cache = ref.read(aliasChatCacheProvider);
      await cache.markInviteDismissed(widget.aliasInviteSecret!);
      ref.invalidate(aliasInviteDismissedProvider(widget.aliasInviteSecret!));
    } catch (_) {
      // Non-critical — ignore failures
    }
  }

  Future<void> _checkAliasStatusAndPoll() async {
    final cache = ref.read(aliasChatCacheProvider);
    final chat = await cache.getAliasChat(widget.aliasInviteSecret!);
    if (chat == null) return;

    if (chat.status == AliasChannelStatus.pending) {
      if (!mounted) return;
      setState(() {
        _isAliasPending = true;
        _isAliasPolling = true;
      });
      _pollAliasForAcceptance();
    } else {
      if (!mounted) return;
      setState(() {
        _isAliasPending = false;
        _isAliasPolling = false;
      });
      _startAliasMessageSync();
    }
  }

  Future<void> _startAliasMessageSync() async {
    _isAliasSyncing = true;
    await _syncAliasOnce();
    while (_isAliasSyncing && mounted) {
      await Future.delayed(const Duration(seconds: 8));
      if (!_isAliasSyncing || !mounted) break;
      await _syncAliasOnce();
    }
  }

  Future<void> _syncAliasOnce() async {
    try {
      final service = await ref.read(aliasChatServiceProvider.future);
      final newCount = await service.syncAliasMessages();
      if (newCount > 0 && mounted) {
        ref.invalidate(aliasMessagesProvider(widget.aliasInviteSecret!));
        await _markAsRead();
      }
    } catch (e) {
      debugPrint('[ChatDetail] Alias sync error: $e');
    }
  }

  Future<void> _pollAliasForAcceptance() async {
    while (_isAliasPolling && mounted) {
      try {
        final service = await ref.read(aliasChatServiceProvider.future);
        final accepted = await service.checkAndFinalizeChannel(
          widget.aliasInviteSecret!,
        );
        if (accepted && mounted) {
          setState(() {
            _isAliasPending = false;
            _isAliasPolling = false;
          });
          ref.read(messageRefreshCounterProvider.notifier).state++;
          _startAliasMessageSync();
          return;
        }
      } catch (_) {
        // Ignore errors during polling
      }
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _sendAliasMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isAliasSending) return;

    setState(() => _isAliasSending = true);
    _messageController.clear();

    try {
      final service = await ref.read(aliasChatServiceProvider.future);
      await service.sendAliasMessage(
        inviteSecret: widget.aliasInviteSecret!,
        plaintext: text,
      );
      ref.invalidate(aliasMessagesProvider(widget.aliasInviteSecret!));
      ref.read(messageRefreshCounterProvider.notifier).state++;
    } catch (e) {
      if (mounted) showErrorSnackBar(context, 'Failed to send: $e');
    } finally {
      if (mounted) setState(() => _isAliasSending = false);
    }
  }

  Future<void> _editAlias(String currentAlias) async {
    String? newAlias;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController(text: currentAlias);
        return AlertDialog(
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Text('Edit Alias', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter alias name',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              filled: true,
              fillColor: const Color.fromARGB(255, 3, 3, 3),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (v) {
              newAlias = v.trim();
              Navigator.of(dialogContext).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () {
                newAlias = controller.text.trim();
                Navigator.of(dialogContext).pop();
              },
              child: Text('Save', style: TextStyle(color: primaryColor)),
            ),
          ],
        );
      },
    );

    if (newAlias != null && newAlias!.isNotEmpty && newAlias != currentAlias) {
      final cache = ref.read(aliasChatCacheProvider);
      await cache.updateAlias(widget.aliasInviteSecret!, newAlias!);
      ref.read(messageRefreshCounterProvider.notifier).state++;
      setState(() => _aliasDisplayName = newAlias!);
    }
  }

  Future<void> _destroyAliasChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Destroy Alias Chat',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'This will permanently delete all messages, keys, and '
          'on-chain data for this alias chat. This cannot be undone.',
          style: TextStyle(color: Colors.white.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Destroy', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final service = await ref.read(aliasChatServiceProvider.future);
        _isAliasSyncing = false;
        await service.destroyAliasChat(widget.aliasInviteSecret!);
        ref.read(messageRefreshCounterProvider.notifier).state++;
        if (mounted) Navigator.of(context).pop();
      } catch (e) {
        if (mounted) showErrorSnackBar(context, 'Failed to destroy: $e');
      }
    }
  }

  /// Convert alias messages into the same shape `_buildMessagesList` already
  /// expects, so the regular message UI is reused verbatim.
  List<DecryptedMessage> _aliasMessagesAsDecrypted(List<AliasMessage> alias) {
    return alias
        .map(
          (m) => DecryptedMessage(
            id: m.id,
            senderWallet: '',
            recipientWallet: '',
            content: m.content,
            timestamp: m.timestamp,
            isOutgoing: m.isOutgoing,
            onChainPubkey: m.onChainRef ?? '',
          ),
        )
        .toList();
  }

  Widget _buildAliasScaffold(BuildContext context) {
    final aliasChatAsync = ref.watch(
      FutureProvider<AliasChat?>((ref) async {
        final cache = ref.watch(aliasChatCacheProvider);
        return cache.getAliasChat(widget.aliasInviteSecret!);
      }),
    );
    final messagesAsync = ref.watch(
      aliasMessagesProvider(widget.aliasInviteSecret!),
    );

    final resolvedAlias = aliasChatAsync.value?.alias;
    if (resolvedAlias != null && resolvedAlias != _aliasDisplayName) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _aliasDisplayName = resolvedAlias);
      });
    }
    final displayName = _aliasDisplayName.isNotEmpty
        ? _aliasDisplayName
        : 'Alias Chat';
    final chatStatus = aliasChatAsync.value?.status;
    final isPending =
        _isAliasPending || chatStatus == AliasChannelStatus.pending;
    final headerHeight = topPadding(context) + 80;

    return Scaffold(
      backgroundColor: Color.fromARGB(255, 6, 6, 6),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: isPending
                    ? _buildAliasPendingContent(displayName, headerHeight)
                    : messagesAsync.when(
                        data: (messages) => _buildMessagesList(
                          _aliasMessagesAsDecrypted(messages),
                          headerHeight,
                        ),
                        loading: () => Center(
                          child: CircularProgressIndicator(color: primaryColor),
                        ),
                        error: (e, _) => Center(
                          child: Text(
                            'Error: $e',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ),
              ),
              isPending
                  ? _buildAliasPendingInputBar(displayName)
                  : _buildInputBar(),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: _buildHeader(context, displayName),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAliasTopRightAction() {
    return PopupMenuButton<String>(
      icon: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          CupertinoIcons.lock_shield_fill,
          color: Colors.white,
          size: 16,
        ),
      ),
      color: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (value) {
        if (value == 'rename') {
          _editAlias(_aliasDisplayName);
        } else if (value == 'destroy') {
          _destroyAliasChat();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'rename',
          child: Row(
            children: [
              Icon(
                CupertinoIcons.pencil,
                size: 18,
                color: Colors.white.withOpacity(0.85),
              ),
              const SizedBox(width: 10),
              Text(
                'Rename Alias',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'destroy',
          child: Row(
            children: [
              Icon(CupertinoIcons.trash, size: 18, color: Colors.redAccent),
              const SizedBox(width: 10),
              Text(
                'Destroy Chat',
                style: TextStyle(color: Colors.redAccent, fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAliasPendingContent(String displayName, double headerHeight) {
    return Padding(
      padding: EdgeInsets.only(
        top: headerHeight + 12,
        left: 24,
        right: 24,
        bottom: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 0),
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
            const SizedBox(height: 24),
            Text(
              'How Alias Chat Works',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            _buildAliasInfoCard(
              icon: CupertinoIcons.person_2_fill,
              title: 'Zero Identity Link',
              description:
                  'Each alias chat generates a unique random encryption keypair completely isolated from your wallet. Neither party can trace messages back to any wallet or real identity.',
            ),
            const SizedBox(height: 12),
            _buildAliasInfoCard(
              icon: CupertinoIcons.shuffle,
              title: 'Ephemeral Key Exchange',
              description:
                  'Keys are exchanged through a temporary on-chain box that is automatically destroyed after both parties connect. No permanent trace remains.',
            ),
            const SizedBox(height: 12),
            _buildAliasInfoCard(
              icon: CupertinoIcons.eye_slash_fill,
              title: 'Unlinkable Messages',
              description:
                  'Messages use unique recipient tags derived from alias keys. Even the indexer cannot link alias messages to your main wallet conversations.',
            ),
            const SizedBox(height: 12),
            _buildAliasInfoCard(
              icon: CupertinoIcons.shield_lefthalf_fill,
              title: '100% Protection',
              description:
                  'No metadata, no IP logs, no wallet correlation. The alias chat is mathematically unlinkable to your identity — providing complete sender anonymity.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAliasInfoCard({
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
                  style: TextStyle(
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

  Widget _buildAliasPendingInputBar(String displayName) {
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: BoxDecoration(color: cardColor),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 14,
        bottom: bottomSafeArea + 14,
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.clock,
            size: 16,
            color: Colors.orange.withOpacity(0.8),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Waiting for "$displayName" to accept...',
              style: TextStyle(
                color: Colors.orange.withOpacity(0.8),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated send button with press feedback
class _SendButton extends StatefulWidget {
  final VoidCallback onTap;

  const _SendButton({required this.onTap});

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedOpacity(
        duration: Duration(milliseconds: 100),
        opacity: _isPressed ? 0.5 : 1.0,
        child: AnimatedScale(
          duration: Duration(milliseconds: 100),
          scale: _isPressed ? 0.85 : 1.0,
          child: ShaderMask(
            shaderCallback: (bounds) => iconGradient.createShader(bounds),
            child: SvgPicture.asset(
              "assets/icons/Paper_Plane.svg",
              width: 28,
              colorFilter: ColorFilter.mode(Colors.white, BlendMode.srcIn),
            ),
          ),
        ),
      ),
    );
  }
}

/// A message bubble that can be swiped right to reveal the timestamp (like iMessage)
class _SwipeableMessageBubble extends StatefulWidget {
  final DecryptedMessage message;
  final bool showTimestamp;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool isPending;
  final bool isIncoming;
  final String Function(DateTime) formatTimestamp;

  const _SwipeableMessageBubble({
    required this.message,
    required this.showTimestamp,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.isPending,
    required this.formatTimestamp,
    this.isIncoming = false,
  });

  @override
  State<_SwipeableMessageBubble> createState() =>
      _SwipeableMessageBubbleState();
}

class _SwipeableMessageBubbleState extends State<_SwipeableMessageBubble>
    with SingleTickerProviderStateMixin {
  double _dragOffset = 0;
  bool _showingTime = false;
  bool _isLongPressed = false;
  bool _isSelectingText = false;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // Maximum drag distance
  static const double _maxDragDistance = 80;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 0.6).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isPending) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeableMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPending && !oldWidget.isPending) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isPending && oldWidget.isPending) {
      _pulseController.stop();
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  bool get _isAliasInvite =>
      widget.message.content.startsWith('sealed://alias?');

  Widget _buildInviteCard() {
    final uri = Uri.tryParse(widget.message.content);
    final inviteSecret = uri?.queryParameters['c'];

    return Consumer(
      builder: (ctx, ref, _) {
        if (inviteSecret == null) {
          return const SizedBox.shrink();
        }

        // Parent build() already gates on dismissed / loading / expired,
        // so we just need to read the cached status to pick the right card.
        final statusAsync = ref.watch(aliasInviteStatusProvider(inviteSecret));

        final status = statusAsync.value;
        if (status == AliasChannelStatus.active) {
          return _buildAcceptedInviteCard(ctx, ref, inviteSecret);
        }
        return _buildPendingInviteCard(ctx);
      },
    );
  }

  Widget _buildPendingInviteCard(BuildContext ctx) {
    return GestureDetector(
      onTap: widget.isIncoming
          ? () => AcceptAliasChatScreen.handleInviteUri(
              ctx,
              widget.message.content,
              senderUsername: widget.message.senderUsername,
            )
          : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: primaryColor.withOpacity(0.3), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  CupertinoIcons.lock_shield_fill,
                  color: primaryColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isIncoming
                        ? 'Alias Chat Invitation'
                        : 'Alias Invite Sent',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.isIncoming
                  ? 'You received an anonymous alias chat invitation. Tap to accept and start chatting.'
                  : 'You sent an alias chat invitation. Waiting for acceptance.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
                height: 1.3,
              ),
            ),
            if (widget.isIncoming) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  gradient: primaryGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Text(
                    'Accept',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAcceptedInviteCard(
    BuildContext ctx,
    WidgetRef ref,
    String inviteSecret,
  ) {
    const green = Color(0xFF34C759);
    return GestureDetector(
      onTap: () async {
        // Mark dismissed so this card is hidden when user returns
        final cache = ref.read(aliasChatCacheProvider);
        await cache.markInviteDismissed(inviteSecret);
        ref.invalidate(aliasInviteDismissedProvider(inviteSecret));
        if (!ctx.mounted) return;
        Navigator.of(ctx).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                AliasChatDetailScreen(inviteSecret: inviteSecret),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) =>
                    SlideTransition(
                      position:
                          Tween<Offset>(
                            begin: const Offset(1.0, 0.0),
                            end: Offset.zero,
                          ).animate(
                            CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutCubic,
                            ),
                          ),
                      child: child,
                    ),
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: green.withOpacity(0.35), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(
                  CupertinoIcons.checkmark_shield_fill,
                  color: green,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isIncoming
                        ? 'Alias Chat Accepted'
                        : 'Invitation Accepted',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: green.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Active',
                    style: TextStyle(
                      color: green,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.isIncoming
                  ? 'You accepted this alias chat. Messages are end-to-end encrypted.'
                  : 'Your invitation was accepted. The alias channel is now live.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: green.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: green.withOpacity(0.35), width: 1),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Go to chat',
                    style: TextStyle(
                      color: green,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(CupertinoIcons.arrow_right, color: green, size: 13),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _enterSelectMode() {
    HapticFeedback.mediumImpact();
    setState(() => _isSelectingText = true);
  }

  void _copyAndDismiss(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    // Delay dismiss to let the chip animation play
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _isSelectingText = false);
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final isOutgoing = widget.message.isOutgoing;

    setState(() {
      if (isOutgoing) {
        // For outgoing (right side): swipe LEFT (negative delta) to reveal time
        _dragOffset = (_dragOffset - details.delta.dx).clamp(
          0,
          _maxDragDistance,
        );
      } else {
        // For incoming (left side): swipe RIGHT (positive delta) to reveal time
        _dragOffset = (_dragOffset + details.delta.dx).clamp(
          0,
          _maxDragDistance,
        );
      }
      _showingTime = _dragOffset > 20;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    setState(() {
      _dragOffset = 0;
      _showingTime = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // For alias invites, gate the ENTIRE bubble (timestamp, padding, "Sent"
    // row) on the invite status so nothing renders when dismissed, expired,
    // or still loading for the first time.
    if (_isAliasInvite) {
      final uri = Uri.tryParse(widget.message.content);
      final inviteSecret = uri?.queryParameters['c'];
      if (inviteSecret == null) return const SizedBox.shrink();

      return Consumer(
        builder: (ctx, ref, _) {
          final dismissedAsync = ref.watch(
            aliasInviteDismissedProvider(inviteSecret),
          );
          if (dismissedAsync.value == true) return const SizedBox.shrink();

          final statusAsync = ref.watch(
            aliasInviteStatusProvider(inviteSecret),
          );

          // First load — show nothing until we know the real status
          if (statusAsync.isLoading && !statusAsync.hasValue) {
            return const SizedBox.shrink();
          }

          final status = statusAsync.value;
          if (status == null || status == AliasChannelStatus.deleted) {
            return const SizedBox.shrink();
          }

          // Status is pending or active — render full bubble
          return _buildFullBubble(context);
        },
      );
    }

    return _buildFullBubble(context);
  }

  Widget _buildFullBubble(BuildContext context) {
    final isOutgoing = widget.message.isOutgoing;

    // Smaller padding when messages are grouped together
    final bottomPadding = widget.isLastInGroup ? 12.0 : 3.0;
    final topPadding = widget.showTimestamp ? 8.0 : 0.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding, top: topPadding),
      child: Column(
        crossAxisAlignment: isOutgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // Show timestamp header only if showTimestamp is true
          if (widget.showTimestamp)
            Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                widget.formatTimestamp(widget.message.timestamp),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 10,
                ),
              ),
            ),

          // Swipeable message row
          GestureDetector(
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            child: Stack(
              alignment: isOutgoing
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              children: [
                // Time indicator (revealed on swipe)
                AnimatedOpacity(
                  duration: Duration(milliseconds: 100),
                  opacity: _showingTime ? 1.0 : 0.0,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: isOutgoing ? 0 : 0,
                      right: isOutgoing ? 16 : 0,
                    ),
                    child: Text(
                      DateFormat('h:mm a').format(widget.message.timestamp),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),

                // Message bubble (slides on drag)
                AnimatedContainer(
                  duration: _dragOffset == 0
                      ? Duration(milliseconds: 200)
                      : Duration.zero,
                  curve: Curves.easeOut,
                  transform: Matrix4.translationValues(
                    isOutgoing ? -_dragOffset : _dragOffset,
                    0,
                    0,
                  ),
                  child: Row(
                    mainAxisAlignment: isOutgoing
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Column(
                          crossAxisAlignment: isOutgoing
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: widget.isPending
                                  ? null
                                  : _enterSelectMode,
                              onLongPressStart: (_) {
                                if (widget.isPending) return;
                                setState(() => _isLongPressed = true);
                              },
                              onLongPressEnd: (_) {
                                if (widget.isPending) return;
                                setState(() => _isLongPressed = false);
                              },
                              child: AnimatedScale(
                                scale: _isLongPressed ? 0.95 : 1.0,
                                duration: const Duration(milliseconds: 150),
                                child: FadeTransition(
                                  opacity: widget.isPending
                                      ? _pulseAnimation
                                      : const AlwaysStoppedAnimation(1.0),
                                  child: Container(
                                    constraints: BoxConstraints(
                                      maxWidth:
                                          MediaQuery.of(context).size.width *
                                          0.75,
                                    ),
                                    padding: _isAliasInvite
                                        ? EdgeInsets.zero
                                        : EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                    decoration: BoxDecoration(
                                      gradient: _isAliasInvite
                                          ? null
                                          : (isOutgoing
                                                ? outgoingMessage
                                                : incomingMessage),
                                      color: _isAliasInvite
                                          ? Colors.transparent
                                          : null,
                                      borderRadius: _getBubbleBorderRadius(
                                        isOutgoing,
                                      ),
                                    ),
                                    child: _isAliasInvite
                                        ? _buildInviteCard()
                                        : _isSelectingText
                                        ? SelectableText(
                                            widget.message.content,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w400,
                                            ),
                                            cursorColor: primaryColor,
                                            selectionControls:
                                                MaterialTextSelectionControls(),
                                          )
                                        : Text(
                                            widget.message.content,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                            // Inline action buttons (shown in select mode)
                            if (_isSelectingText)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _ActionChip(
                                      icon: CupertinoIcons.doc_on_doc,
                                      label: 'Copy Message',
                                      onTap: () => _copyAndDismiss(
                                        widget.message.content,
                                        'Message',
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _ActionChip(
                                      icon: CupertinoIcons.link,
                                      label: 'Copy Tx ID',
                                      onTap: () => _copyAndDismiss(
                                        widget.message.onChainPubkey,
                                        'Transaction ID',
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    GestureDetector(
                                      onTap: () => setState(
                                        () => _isSelectingText = false,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          CupertinoIcons.xmark,
                                          size: 14,
                                          color: Colors.white.withOpacity(0.8),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (widget.isLastInGroup &&
              widget.message.isOutgoing &&
              !_isAliasInvite)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!widget.isPending)
                  Text(
                    "Sent",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 10,
                    ),
                  ),
                SizedBox(width: 4),
                if (!widget.isPending)
                  ShaderMask(
                    shaderCallback: (bounds) =>
                        iconGradient.createShader(bounds),
                    child: SvgPicture.asset(
                      "assets/icons/Check.svg",
                      width: 16,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  BorderRadius _getBubbleBorderRadius(bool isOutgoing) {
    // Adjust border radius based on position in group for a more iMessage-like look
    const double largeRadius = 18;
    const double smallRadius = 6;

    if (widget.isFirstInGroup && widget.isLastInGroup) {
      // Single message - all corners rounded
      return BorderRadius.circular(largeRadius);
    }

    if (isOutgoing) {
      if (widget.isFirstInGroup) {
        return BorderRadius.only(
          topLeft: Radius.circular(largeRadius),
          topRight: Radius.circular(largeRadius),
          bottomLeft: Radius.circular(largeRadius),
          bottomRight: Radius.circular(smallRadius),
        );
      } else if (widget.isLastInGroup) {
        return BorderRadius.only(
          topLeft: Radius.circular(largeRadius),
          topRight: Radius.circular(smallRadius),
          bottomLeft: Radius.circular(largeRadius),
          bottomRight: Radius.circular(largeRadius),
        );
      } else {
        return BorderRadius.only(
          topLeft: Radius.circular(largeRadius),
          topRight: Radius.circular(smallRadius),
          bottomLeft: Radius.circular(largeRadius),
          bottomRight: Radius.circular(smallRadius),
        );
      }
    } else {
      if (widget.isFirstInGroup) {
        return BorderRadius.only(
          topLeft: Radius.circular(largeRadius),
          topRight: Radius.circular(largeRadius),
          bottomLeft: Radius.circular(smallRadius),
          bottomRight: Radius.circular(largeRadius),
        );
      } else if (widget.isLastInGroup) {
        return BorderRadius.only(
          topLeft: Radius.circular(smallRadius),
          topRight: Radius.circular(largeRadius),
          bottomLeft: Radius.circular(largeRadius),
          bottomRight: Radius.circular(largeRadius),
        );
      } else {
        return BorderRadius.only(
          topLeft: Radius.circular(smallRadius),
          topRight: Radius.circular(largeRadius),
          bottomLeft: Radius.circular(smallRadius),
          bottomRight: Radius.circular(largeRadius),
        );
      }
    }
  }
}

class _PendingMessage {
  final String localId;
  final String content;
  final DateTime timestamp;

  const _PendingMessage({
    required this.localId,
    required this.content,
    required this.timestamp,
  });
}

class _ActionChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_ActionChip> createState() => _ActionChipState();
}

class _ActionChipState extends State<_ActionChip>
    with SingleTickerProviderStateMixin {
  bool _done = false;
  late final AnimationController _scaleController;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scaleAnimation = TweenSequence<double>(
      [
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 40),
        TweenSequenceItem(tween: Tween(begin: 1.15, end: 1), weight: 30),
        TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0), weight: 30),
      ],
    ).animate(CurvedAnimation(parent: _scaleController, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (_done) return;
    HapticFeedback.lightImpact();
    setState(() => _done = true);
    _scaleController.forward();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _done ? primaryColor : Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _done
                ? Row(
                    key: const ValueKey('done'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Done',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : Row(
                    key: const ValueKey('label'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.icon,
                        size: 14,
                        color: Colors.white.withOpacity(0.8),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
