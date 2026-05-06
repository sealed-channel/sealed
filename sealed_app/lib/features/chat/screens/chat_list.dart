import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gif/gif.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/core/extensions.dart';
import 'package:sealed_app/features/chat/screens/alias_chat_detail_screen.dart';
import 'package:sealed_app/features/chat/screens/chat_detail.dart';
import 'package:sealed_app/features/qr/qr_scan_coordinator.dart';
import 'package:sealed_app/models/alias_chat.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/shared/widgets/shimmer_loading.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

String _formatWalletAddress(String address) {
  if (address.length <= 12) return address;
  return '${address.substring(0, 6)}...${address.substring(address.length - 6)}';
}

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen>
    with TickerProviderStateMixin {
  final bool _hasSynced = false;
  late final GifController _gifController;
  // Cached at the size we actually render (240 logical px). Decodes the GIF
  // frames at this resolution instead of the source's native size, which
  // dramatically reduces per-frame memory for large source files.
  // cacheWidth is in physical pixels; ~3x DPR covers high-density screens.
  bool _gifPrecached = false;
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final _debouncer = Debouncer();
  String _searchQuery = '';
  bool _isSearching = false;
  Timer? _pendingAliasTimer;
  final Set<String> _hiddenConversations = {}; // contactWallet keys
  final Set<String> _hiddenAliasChannels = {}; // inviteSecret keys

  @override
  void initState() {
    super.initState();
    _gifController = GifController(vsync: this)
      ..duration = const Duration(seconds: 4);
    // Loop the empty-state animation forward/reverse on a 4s cycle.
    _gifController.repeat(reverse: true);

    _searchFocusNode.addListener(() {
      setState(() {}); // Rebuild to update AnimatedContainer
    });
    _startPendingAliasPolling();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode the GIF once into the image cache so the first time the empty
    // state is built, frames are already resident. Cheap if there are
    // conversations (cache hit; never used).
    if (!_gifPrecached) {
      _gifPrecached = true;
      precacheImage(AssetImage('assets/quantum-animation.gif'), context);
    }
  }

  @override
  void dispose() {
    _pendingAliasTimer?.cancel();
    _gifController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Periodically check pending alias chats for acceptance.
  void _startPendingAliasPolling() {
    _pendingAliasTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkPendingAliasChats(),
    );
  }

  Future<void> _checkPendingAliasChats() async {
    try {
      final aliasService = await ref.read(aliasChatServiceProvider.future);
      final allChats = await aliasService.getAllAliasChats();
      bool anyFinalized = false;
      for (final chat in allChats) {
        if (chat.status == AliasChannelStatus.pending) {
          final accepted = await aliasService.checkAndFinalizeChannel(
            chat.inviteSecret,
          );
          if (accepted) anyFinalized = true;
        }
      }
      if (anyFinalized && mounted) {
        ref.read(messageRefreshCounterProvider.notifier).state++;
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(messagesNotifierProvider);
    final searchResults = ref.watch(searchUsersProvider(_searchQuery));
    final headerHeight = topPadding(context) + 90;

    return Scaffold(
      body: Stack(
        children: [
          // Main content (scrolls behind header)
          Column(
            children: [
              _isSearching
                  ? Expanded(
                      child: searchResults.when(
                        data: (results) {
                          if (results.isEmpty) {
                            return _buildNoResultsState();
                          }
                          return _buildSearchResults(results, headerHeight);
                        },
                        loading: () => _buildLoadingState(),
                        error: (error, stack) => _buildSearchErrorState(),
                      ),
                    )
                  : Expanded(
                      child: RefreshIndicator(
                        color: primaryColor,
                        backgroundColor: cardColor,
                        edgeOffset: headerHeight,
                        onRefresh: () async {
                          try {
                            await ref
                                .read(messagesNotifierProvider.notifier)
                                .syncMessages();
                            // Also sync alias messages
                            try {
                              final aliasService = await ref.read(
                                aliasChatServiceProvider.future,
                              );
                              // Check pending channels for acceptance
                              final allChats = await aliasService
                                  .getAllAliasChats();
                              bool anyFinalized = false;
                              for (final chat in allChats) {
                                if (chat.status == AliasChannelStatus.pending) {
                                  final accepted = await aliasService
                                      .checkAndFinalizeChannel(
                                        chat.inviteSecret,
                                      );
                                  if (accepted) anyFinalized = true;
                                }
                              }
                              final newCount = await aliasService
                                  .syncAliasMessages();
                              if (newCount > 0 || anyFinalized) {
                                ref
                                    .read(
                                      messageRefreshCounterProvider.notifier,
                                    )
                                    .state++;
                              }
                            } catch (_) {}
                          } catch (e) {
                            if (mounted) {
                              context.showSyncError(
                                onRetry: () => ref
                                    .read(messagesNotifierProvider.notifier)
                                    .syncMessages(),
                              );
                            }
                          }
                        },
                        child: conversationsAsync.when(
                          data: (conversations) {
                            final aliasChats =
                                ref
                                    .watch(aliasConversationPreviewsProvider)
                                    .value ??
                                [];
                            if (conversations.isEmpty && aliasChats.isEmpty) {
                              return _buildEmptyState();
                            }
                            return _buildChatList(conversations, headerHeight);
                          },
                          loading: () => Padding(
                            padding: EdgeInsets.only(top: headerHeight),
                            child: const ConversationSkeletonList(itemCount: 6),
                          ),
                          error: (error, stack) =>
                              _buildConversationsErrorState(error, stack),
                        ),
                      ),
                    ),
            ],
          ),
          // Frosted Glass Header
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
                child: _buildHeader(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool isPressed = false;
  bool isQrPressed = false;
  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: topPadding(context) + 4,

        left: HORIZONTAL_PADDING,
        right: HORIZONTAL_PADDING,
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTapDown: (_) {
                setState(() {
                  isPressed = true;
                });
              },
              onTapUp: (_) {
                setState(() {
                  isPressed = false;
                });
              },
              onTapCancel: () {
                setState(() {
                  isPressed = false;
                });
              },
              child: AnimatedScale(
                duration: Duration(milliseconds: 100),
                scale: isPressed ? 0.98 : 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(
                      alpha: isPressed ? 0.04 : 0.06,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          textAlignVertical: TextAlignVertical.center,

                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          onChanged: (value) {
                            setState(() {
                              _isSearching = value.isNotEmpty;
                              _debouncer.run(() {
                                setState(() => _searchQuery = value);
                              });
                            });
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 16,
                            ),
                            suffixIcon: Icon(
                              CupertinoIcons.search,
                              color: Colors.white.withValues(alpha: 0.9),
                              size: 24,
                            ),
                            hintText: 'Search',
                            hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w400,
                              fontSize: 16,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          SizedBox(width: 12),
          GestureDetector(
            onTap: () => startConversationFromQrScan(context, ref),
            onTapDown: (_) {
              setState(() {
                isQrPressed = true;
              });
            },
            onTapUp: (_) {
              setState(() {
                isQrPressed = false;
              });
            },
            onTapCancel: () {
              setState(() {
                isQrPressed = false;
              });
            },
            child: AnimatedScale(
              duration: Duration(milliseconds: 100),
              scale: isQrPressed ? 0.98 : 1.0,
              child: Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: isQrPressed ? 0.04 : 0.06,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SvgPicture.asset(
                  'assets/icons/general/qr.svg',
                  color: Colors.white.withValues(alpha: 0.9),
                  width: 24,
                  height: 24,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      physics: AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: 64),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Gif(
                  image: AssetImage('assets/quantum-animation.gif'),
                  controller: _gifController,
                  width: 240,
                  height: 240,
                ),
                const SizedBox(height: 24),
                Text(
                  'No conversations yet',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Start a new chat by searching above.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    final headerHeight = topPadding(context) + 80;
    return Padding(
      padding: EdgeInsets.only(top: headerHeight),
      child: const ConversationSkeletonList(itemCount: 6),
    );
  }

  Widget _buildSearchErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: Colors.white.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'User not found',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Try a different username or wallet address',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationsErrorState(Object error, StackTrace stack) {
    final stackLines = stack.toString().split('\n');
    final stackPreview = stackLines.take(8).join('\n');
    final debugInfo =
        'Conversations load error\n\nError:\n${error.toString()}\n\nStack:\n${stack.toString()}';

    // Show snackbar with retry after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.showSyncError(
          onRetry: () =>
              ref.read(messagesNotifierProvider.notifier).syncMessages(),
        );
      }
    });

    return ListView(
      physics: AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: 150),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off,
                size: 48,
                color: Colors.white.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 12),
              Text(
                'Failed to load conversations',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 16,
                ),
              ),

              // const SizedBox(height: 10),
              // Padding(
              //   padding: const EdgeInsets.symmetric(horizontal: 20),
              //   child: SelectableText(
              //     'Error: ${error.toString()}',
              //     textAlign: TextAlign.center,
              //     style: TextStyle(
              //       color: Colors.white.withValues(alpha: 0.7),
              //       fontSize: 12,
              //     ),
              //   ),
              // ),

              // const SizedBox(height: 8),
              // Padding(
              //   padding: const EdgeInsets.symmetric(horizontal: 20),
              //   child: SelectableText(
              //     stackPreview,
              //     textAlign: TextAlign.left,
              //     style: TextStyle(
              //       color: Colors.white.withValues(alpha: 0.55),
              //       fontSize: 10,
              //     ),
              //   ),
              // ),

              // const SizedBox(height: 16),
              // GestureDetector(
              //   onTap: () async {
              //     await Clipboard.setData(ClipboardData(text: debugInfo));
              //     if (!mounted) return;
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       const SnackBar(
              //         content: Text('Debug info copied to clipboard'),
              //       ),
              //     );
              //   },
              //   child: Container(
              //     padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              //     decoration: BoxDecoration(
              //       color: Colors.white.withValues(alpha: 0.08),
              //       borderRadius: BorderRadius.circular(8),
              //       border: Border.all(
              //         color: Colors.white.withValues(alpha: 0.2),
              //       ),
              //     ),
              //     child: Row(
              //       mainAxisSize: MainAxisSize.min,
              //       children: [
              //         Icon(
              //           Icons.copy_rounded,
              //           color: Colors.white.withValues(alpha: 0.8),
              //           size: 16,
              //         ),
              //         SizedBox(width: 8),
              //         Text(
              //           'Copy debug info',
              //           style: TextStyle(
              //             color: Colors.white.withValues(alpha: 0.85),
              //             fontWeight: FontWeight.w500,
              //           ),
              //         ),
              //       ],
              //     ),
              //   ),
              // ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () =>
                    ref.read(messagesNotifierProvider.notifier).syncMessages(),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: primaryColor.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    'Tap to retry',
                    style: TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchResults(List<UserProfile> results, double headerHeight) {
    return ListView.separated(
      padding: EdgeInsets.only(
        top: headerHeight + 12,
        bottom: 12,
        left: 0,
        right: 0,
      ),
      separatorBuilder: (context, index) => SizedBox(height: 10),

      itemCount: results.length,
      itemBuilder: (context, index) {
        final user = results[index];
        return ListTile(
          leading: CircleAvatar(
            radius: 25,
            backgroundColor: primaryColor,
            child: Text(
              (user.username ?? _formatWalletAddress(user.walletAddress))
                  .substring(0, 1)
                  .toUpperCase(),
            ),
          ),
          tileColor: cardColor,
          title: Text(
            user.username ?? _formatWalletAddress(user.walletAddress),
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            user.walletAddress,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 11,
            ),
          ),
          onTap: () {
            _searchController.clear();

            Navigator.of(context)
                .push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) =>
                        ChatDetailScreen(
                          conversation: Conversation(
                            contactWallet: user.walletAddress,
                            contactUsername: user.username,
                          ),
                        ),
                    transitionsBuilder:
                        (context, animation, secondaryAnimation, child) {
                          return SlideTransition(
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
                          );
                        },
                    transitionDuration: const Duration(milliseconds: 300),
                  ),
                )
                .then((_) {
                  setState(() {
                    _isSearching = false;
                  });
                });
          },
          trailing: Icon(
            CupertinoIcons.chevron_right,
            color: Colors.white.withValues(alpha: 1),
            size: 14,
          ),
        );
      },
    );
  }

  Widget _buildNoResultsState() {
    return Center(
      child: Text(
        'No results found.',
        style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
      ),
    );
  }

  Widget _buildChatList(
    List<ConversationPreview> conversations,
    double headerHeight,
  ) {
    final aliasChatsAsync = ref.watch(aliasConversationPreviewsProvider);
    final aliasPreviews = aliasChatsAsync.value ?? [];

    // Secrets for alias chats that are already accepted (active). Used to
    // suppress the corresponding regular-conversation row when the only
    // message exchanged was the invite URI itself — after acceptance the
    // alias chat owns the relationship and the regular row is a stub.
    final acceptedInviteSecrets = <String>{
      for (final a in aliasPreviews)
        if (a.status == AliasChannelStatus.active) a.inviteSecret,
    };

    // Build unified list items: regular conversations + alias chats
    final List<_UnifiedChatItem> items = [];

    for (final conv in conversations) {
      // If the latest (and only) message in this regular conversation is an
      // alias invite URI whose alias chat has already been accepted, hide the
      // row entirely so the user just sees the alias chat entry.
      if (conv.messageCount == 1 &&
          conv.lastMessagePreview.startsWith('sealed://alias?')) {
        final secret = Uri.tryParse(
          conv.lastMessagePreview,
        )?.queryParameters['c'];
        if (secret != null && acceptedInviteSecrets.contains(secret)) {
          continue;
        }
      }
      items.add(_UnifiedChatItem.regular(conv));
    }
    for (final alias in aliasPreviews) {
      // Only show accepted (active) alias chats in the list.
      // Pending chats are invisible here — the invite card in the regular
      // chat detail is the only UI for a pending invitation.
      if (alias.status == AliasChannelStatus.pending) continue;
      items.add(_UnifiedChatItem.alias(alias));
    }

    // Sort by timestamp (newest first)
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Filter out hidden items
    final filteredItems = items.where((item) {
      if (item.conversation != null) {
        return !_hiddenConversations.contains(item.conversation!.contactWallet);
      }
      if (item.aliasPreview != null) {
        return !_hiddenAliasChannels.contains(item.aliasPreview!.inviteSecret);
      }
      return true;
    }).toList();

    return ListView.builder(
      padding: EdgeInsets.only(
        top: headerHeight,
        bottom: 16,
        left: HORIZONTAL_PADDING,
        right: HORIZONTAL_PADDING,
      ),
      itemCount: filteredItems.length,
      itemBuilder: (context, index) {
        final item = filteredItems[index];

        Widget child;
        String dismissKey;

        if (item.aliasPreview != null) {
          dismissKey = 'alias_${item.aliasPreview!.inviteSecret}';
          child = _AliasChatListItem(
            preview: item.aliasPreview!,
            onTap: () {
              Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                      AliasChatDetailScreen(
                        inviteSecret: item.aliasPreview!.inviteSecret,
                      ),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
                        return SlideTransition(
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
                        );
                      },
                  transitionDuration: const Duration(milliseconds: 300),
                ),
              );
            },
          );
        } else {
          dismissKey = 'conv_${item.conversation!.contactWallet}';
          child = _ChatListItem(
            conversation: item.conversation!,
            onTap: () {
              Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                      ChatDetailScreen(conversation: item.conversation!),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
                        return SlideTransition(
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
                        );
                      },
                  transitionDuration: const Duration(milliseconds: 300),
                ),
              );
            },
          );
        }

        return Dismissible(
          key: ValueKey(dismissKey),
          direction: DismissDirection.horizontal,
          // Swipe right → archive (green/teal)
          background: Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF1C8C5E),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  CupertinoIcons.archivebox_fill,
                  color: Colors.white.withOpacity(0.95),
                  size: 22,
                ),
                const SizedBox(height: 4),
                Text(
                  'Archive',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          // Swipe left → delete (red)
          secondaryBackground: Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  CupertinoIcons.trash_fill,
                  color: Colors.white.withOpacity(0.95),
                  size: 22,
                ),
                const SizedBox(height: 4),
                Text(
                  'Delete',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              // Archive — no confirmation needed
              return true;
            }
            // Delete — ask for confirmation
            return await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    title: const Text(
                      'Delete chat?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    content: Text(
                      item.aliasPreview != null
                          ? 'This will permanently delete the alias chat and its encrypted channel.'
                          : 'This will remove the conversation from your list.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(
                            color: Color(0xFFFF3B30),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ) ??
                false;
          },
          onDismissed: (direction) {
            if (item.aliasPreview != null) {
              setState(
                () => _hiddenAliasChannels.add(item.aliasPreview!.inviteSecret),
              );
              if (direction == DismissDirection.endToStart) {
                // Delete alias chat from blockchain + cache
                ref
                    .read(aliasChatServiceProvider.future)
                    .then(
                      (service) => service.destroyAliasChat(
                        item.aliasPreview!.inviteSecret,
                      ),
                    );
              }
            } else if (item.conversation != null) {
              setState(
                () =>
                    _hiddenConversations.add(item.conversation!.contactWallet),
              );
            }
          },
          child: child,
        );
      },
    );
  }
}

class _ChatListItem extends StatefulWidget {
  const _ChatListItem({required this.conversation, required this.onTap});

  final ConversationPreview conversation;
  final VoidCallback onTap;

  @override
  State<_ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<_ChatListItem> {
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
        opacity: _isPressed ? 0.6 : 1.0,
        child: AnimatedScale(
          duration: Duration(milliseconds: 100),
          scale: _isPressed ? 0.98 : 1.0,
          child: Container(
            margin: EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              border: widget.conversation.unreadCount > 0
                  ? Border.all(color: Theme.of(context).primaryColor, width: 1)
                  : null,
              color: cardColor,
              borderRadius: BorderRadius.circular(24),
            ),
            padding: EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: primaryColor,
                  child: Text(
                    (widget.conversation.contactUsername ??
                            _formatWalletAddress(
                              widget.conversation.contactWallet,
                            ))
                        .substring(0, 1)
                        .toUpperCase(),
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.conversation.contactUsername ??
                            _formatWalletAddress(
                              widget.conversation.contactWallet,
                            ),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.1,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      widget.conversation.lastMessagePreview.startsWith(
                            'sealed://alias?',
                          )
                          ? Row(
                              children: [
                                Icon(
                                  CupertinoIcons.lock_shield_fill,
                                  color: primaryColor.withValues(alpha: 0.7),
                                  size: 13,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  widget.conversation.isLastMessageOutgoing
                                      ? 'Alias invite sent'
                                      : 'Alias chat invitation',
                                  style: TextStyle(
                                    color: primaryColor.withValues(alpha: 0.7),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              widget.conversation.lastMessagePreview.replaceAll(
                                '\n',
                                ' ',
                              ),

                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 14,
                                fontWeight: widget.conversation.unreadCount > 0
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                    ],
                  ),
                ),
                if (widget.conversation.unreadCount > 0) ...[
                  SizedBox(width: 6),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: primaryGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: BoxConstraints(minWidth: 20),
                    child: Text(
                      widget.conversation.unreadCount > 99
                          ? '99+'
                          : '${widget.conversation.unreadCount}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                Row(
                  children: [
                    SizedBox(width: 4),
                    Text(
                      _timestampToTime(
                        widget.conversation.lastMessageTimestamp,
                      ),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _timestampToTime(int lastMessageTimestamp) {
    int milliseconds = lastMessageTimestamp;
    if (lastMessageTimestamp < 10000000000) {
      milliseconds = lastMessageTimestamp * 1000;
    } else if (lastMessageTimestamp > 10000000000000) {
      milliseconds = lastMessageTimestamp ~/ 1000;
    }

    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${date.month}/${date.day}/${date.year}';
    } else {
      final hours = date.hour % 12 == 0 ? 12 : date.hour % 12;
      final minutes = date.minute.toString().padLeft(2, '0');
      final ampm = date.hour >= 12 ? 'PM' : 'AM';
      return '$hours:$minutes $ampm';
    }
  }
}

/// Unified item for the merged chat list — either a regular conversation or an alias chat.
class _UnifiedChatItem {
  final ConversationPreview? conversation;
  final AliasConversationPreview? aliasPreview;
  final int timestamp;

  _UnifiedChatItem._({
    this.conversation,
    this.aliasPreview,
    required this.timestamp,
  });

  factory _UnifiedChatItem.regular(ConversationPreview conv) =>
      _UnifiedChatItem._(
        conversation: conv,
        timestamp: conv.lastMessageTimestamp,
      );

  factory _UnifiedChatItem.alias(AliasConversationPreview alias) =>
      _UnifiedChatItem._(
        aliasPreview: alias,
        timestamp: alias.lastMessageTimestamp,
      );
}

class _AliasChatListItem extends StatefulWidget {
  const _AliasChatListItem({required this.preview, required this.onTap});

  final AliasConversationPreview preview;
  final VoidCallback onTap;

  @override
  State<_AliasChatListItem> createState() => _AliasChatListItemState();
}

class _AliasChatListItemState extends State<_AliasChatListItem> {
  bool _isPressed = false;

  bool get _isNew =>
      widget.preview.status == AliasChannelStatus.active &&
      !widget.preview.inviteDismissed;

  @override
  Widget build(BuildContext context) {
    const newColor = Color(0xFF34C759);
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedOpacity(
        duration: Duration(milliseconds: 100),
        opacity: _isPressed ? 0.6 : 1.0,
        child: AnimatedScale(
          duration: Duration(milliseconds: 100),
          scale: _isPressed ? 0.98 : 1.0,
          child: Container(
            margin: EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: _isNew ? newColor.withOpacity(0.08) : cardColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _isNew
                    ? newColor.withOpacity(0.45)
                    : primaryColor.withOpacity(0.15),
                width: _isNew ? 1.5 : 1,
              ),
            ),
            padding: EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: primaryColor.withOpacity(0.2),
                  child: Icon(
                    CupertinoIcons.lock_shield_fill,
                    color: primaryColor,
                    size: 18,
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              widget.preview.alias,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: widget.preview.unreadCount > 0
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                height: 1.1,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SizedBox(width: 4),

                          if (_isNew) ...[
                            SizedBox(width: 8),
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: newColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: newColor.withOpacity(0.4),
                                  width: 0.5,
                                ),
                              ),
                              child: Text(
                                'New',
                                style: TextStyle(
                                  color: newColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],

                          if (widget.preview.status ==
                              AliasChannelStatus.pending) ...[
                            SizedBox(width: 8),
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.orange.withOpacity(0.4),
                                  width: 0.5,
                                ),
                              ),
                              child: Text(
                                'Pending',
                                style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: 2),
                      Text(
                        widget.preview.status == AliasChannelStatus.pending
                            ? 'Waiting for acceptance...'
                            : widget.preview.lastMessagePreview.substring(
                                0,
                                widget.preview.lastMessagePreview.length > 30
                                    ? 30
                                    : widget.preview.lastMessagePreview.length,
                              ),
                        style: TextStyle(
                          color:
                              widget.preview.status ==
                                  AliasChannelStatus.pending
                              ? Colors.orange.withOpacity(0.6)
                              : Colors.white.withValues(alpha: 0.6),
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (widget.preview.unreadCount > 0) ...[
                  SizedBox(width: 6),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: primaryGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: BoxConstraints(minWidth: 20),
                    child: Text(
                      widget.preview.unreadCount > 99
                          ? '99+'
                          : '${widget.preview.unreadCount}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                Row(
                  children: [
                    SizedBox(width: 4),
                    Icon(
                      CupertinoIcons.lock_fill,
                      size: 10,
                      color: primaryColor.withOpacity(0.6),
                    ),
                    SizedBox(width: 2),
                    Text(
                      _timestampToTime(widget.preview.lastMessageTimestamp),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _timestampToTime(int lastMessageTimestamp) {
    int milliseconds = lastMessageTimestamp;
    if (lastMessageTimestamp < 10000000000) {
      milliseconds = lastMessageTimestamp * 1000;
    } else if (lastMessageTimestamp > 10000000000000) {
      milliseconds = lastMessageTimestamp ~/ 1000;
    }

    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${date.month}/${date.day}/${date.year}';
    } else {
      final hours = date.hour % 12 == 0 ? 12 : date.hour % 12;
      final minutes = date.minute.toString().padLeft(2, '0');
      final ampm = date.hour >= 12 ? 'PM' : 'AM';
      return '$hours:$minutes $ampm';
    }
  }
}
