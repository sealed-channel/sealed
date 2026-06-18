import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/shared/error_handler.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart'
    show PendingInvite;
import 'package:sealed_app/providers/chat_controller.dart'
    show
        ChatIdentity,
        WalletChatId,
        AliasChatId,
        PendingChatId,
        walletPeerNameProvider;
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/ui/chat/screens/chat.dart';
import 'package:sealed_app/ui/chat/widgets/alias_invitation.dart';
import 'package:sealed_app/ui/chats/partition.dart';
import 'package:sealed_app/ui/chats/screens/alias/new_message.dart';
import 'package:sealed_app/ui/chats/widgets/alias/alias_chat_row.dart';
import 'package:sealed_app/ui/chats/widgets/alias/alias_invitation.dart';
import 'package:sealed_app/ui/chats/widgets/alias/alias_inviations.dart';
import 'package:sealed_app/ui/chats/widgets/category_pill.dart';
import 'package:sealed_app/ui/chats/widgets/chat_row.dart';
import 'package:sealed_app/ui/qr/screens/qr_scan_coordinator.dart';

import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/search_hint_sliver.dart';
import 'package:sealed_app/ui/shared/widgets/search_top_bar.dart';
import 'package:sealed_app/ui/shared/widgets/shimmer_loading.dart';
import 'package:sealed_app/ui/shared/widgets/user_search_sliver.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen>
    implements SearchCollapsible {
  ChatsTab _tab = ChatsTab.chats;
  bool _isSearchExpanded = false;
  String _searchQuery = '';
  bool _isSearching = false;
  bool _fabPressed = false;

  // Drives the shared top bar's collapse() after a search result tap navigates.
  final GlobalKey<SearchTopBarState> _topBarKey =
      GlobalKey<SearchTopBarState>();

  /// Collapse the search field — called by the shell when this tab is left.
  @override
  void collapseSearch() => _topBarKey.currentState?.collapse();

  // ── Navigation helpers ───────────────────────────────────────────────────

  PageRouteBuilder<dynamic> _slideRoute(Widget child) {
    return PageRouteBuilder(
      pageBuilder: (_, _, _) => child,
      transitionsBuilder: (_, animation, _, child) {
        return SlideTransition(
          position:
              Tween<Offset>(
                begin: const Offset(1.0, 0.0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 300),
    );
  }

  void _openChat(ChatIdentity identity) {
    Navigator.of(
      context,
    ).push(_slideRoute(ChatScreen(identity: identity))).then((_) {
      if (mounted && _isSearching) _topBarKey.currentState?.collapse();
    });
  }

  /// Alias-tab search: tapping a hit pitches an alias invitation (popup) instead
  /// of opening a normal DM. Mirrors the New-message screen's invite flow. On a
  /// sent invite, collapse search so the pending row is visible on the tab.
  Future<void> _pitchAliasInvite(ChatIdentity identity) async {
    if (identity is! WalletChatId) return;
    final sent = await SealedDialog.show<bool>(
      context: context,
      dialog: AliasInvitationDialog(
        contactWallet: identity.wallet,
        contactUsername: (identity.username?.isNotEmpty == true)
            ? identity.username
            : null,
      ),
    );
    // The dialog bumps the refresh counter on a successful send, so the
    // creator waiting-row surfaces immediately. Just collapse search here.
    if (sent == true && mounted) _topBarKey.currentState?.collapse();
  }

  // ── Formatting helpers ───────────────────────────────────────────────────

  String _formatWallet(String addr) {
    if (addr.length <= 12) return addr;
    return '${addr.substring(0, 4)}...${addr.substring(addr.length - 4)}';
  }

  String _avatarInitial(String? username, String wallet) {
    final src = (username != null && username.isNotEmpty)
        ? username
        : _formatWallet(wallet);
    if (src.isEmpty) return '?';
    return src.substring(0, 1).toUpperCase();
  }

  String _timestampToTime(int ts) {
    int ms = ts;
    if (ts < 10000000000) {
      ms = ts * 1000;
    } else if (ts > 10000000000000) {
      ms = ts ~/ 1000;
    }
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(date);
    if (diff.inDays > 0) {
      return '${date.month}/${date.day}/${date.year}';
    }
    final hours = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minutes = date.minute.toString().padLeft(2, '0');
    final ampm = date.hour >= 12 ? 'PM' : 'AM';
    return '$hours:$minutes $ampm';
  }

  ////////////////////////////
  // ── Build ────────────────────────────────────────────────────────────────
  /////////////////////////

  @override
  Widget build(BuildContext context) {
    // Watch the refresh counter directly: provider-to-provider counter watches
    // (chatPreviewsProvider) don't reliably recompute on the restore path, but a
    // widget-level watch of this StateProvider does rebuild reliably. Combined
    // with the explicit chatPreviews invalidate in bumpRefresh(), a post-sync
    // bump rebuilds ChatsScreen, which re-reads the now-stale chatPreviews and
    // forces its recompute — surfacing recovered conversations without a tab tap.
    ref.watch(messageRefreshCounterProvider);
    final previewsAsync = ref.watch(chatPreviewsProvider);
    final previews = previewsAsync.value ?? const <ChatPreview>[];
    final partition = partitionChats(previews);
    final pending =
        ref.watch(pendingInvitesProvider).value ?? const <PendingInvite>[];

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      floatingActionButton: _buildNewMessageButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.miniEndFloat,
      extendBodyBehindAppBar: true,
      body: RefreshIndicator(
        color: primaryColor,
        backgroundColor: cardColor,
        displacement: MediaQuery.of(context).padding.top + 120.h,
        onRefresh: () async {
          if (_isSearching) return;
          try {
            await ref.read(messagesNotifierProvider.notifier).syncMessages();
          } catch (_) {
            if (mounted) {
              context.showSyncError(
                onRetry: () =>
                    ref.read(messagesNotifierProvider.notifier).syncMessages(),
              );
            }
          }
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildSliverHeader(partition),
            _buildBodySliver(partition, previewsAsync, pending),
          ],
        ),
      ),
    );
  }

  // ── Sliver header (liquid glass) ────────────────────────────────────────

  Widget _buildSliverHeader(Partition partition) {
    final showTabs = !_isSearchExpanded;
    final bottomHeight = showTabs ? (36.h + 8.h) : 0.0;
    return SliverAppBar(
      pinned: true,
      floating: false,
      // Opaque scaffold-coloured header so the chat list never shows through
      // the title/search/tabs when scrolled. A soft shadow fades in only once
      // content scrolls under it, giving separation without a (low-end-costly)
      // backdrop blur.
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 4,
      shadowColor: Colors.black,
      automaticallyImplyLeading: false,
      titleSpacing: horizontalPadding,
      toolbarHeight: 56.h,
      title: SearchTopBar(
        key: _topBarKey,
        title: 'Chats',
        onQrTap: () => startConversationFromQrScan(context, ref),
        onExpandedChanged: (v) => setState(() => _isSearchExpanded = v),
        onSearchingChanged: (v) => setState(() => _isSearching = v),
        onQueryChanged: (q) => setState(() => _searchQuery = q),
      ),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(bottomHeight),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: showTabs
              ? Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    4.h,
                  ),
                  child: _buildTabRow(partition),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildBodySliver(
    Partition partition,
    AsyncValue<List<ChatPreview>> conversationsAsync,
    List<PendingInvite> pending,
  ) {
    // The moment search opens, swap the chat list for a prompt — even before a
    // query is typed.
    if (_isSearchExpanded || _isSearching) {
      if (_searchQuery.trim().isEmpty) {
        return SearchHintSliver(
          subtitle: _tab == ChatsTab.aliasChats
              ? 'Type a name or wallet address to start an alias chat.'
              : 'Type a name or wallet address to start a chat.',
        );
      }
      // On the Alias Chats tab a search hit pitches an alias invitation rather
      // than opening a normal message thread.
      return UserSearchSliver(
        query: _searchQuery,
        onOpenChat: _tab == ChatsTab.aliasChats ? _pitchAliasInvite : _openChat,
      );
    }
    return _buildTabSliver(partition, conversationsAsync, pending);
  }

  Widget? _buildNewMessageButton() {
    // Only on the Alias Chats tab (and not while searching).
    if (_tab != ChatsTab.aliasChats || _isSearching) return null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _fabPressed = true),
      onTapUp: (_) => setState(() => _fabPressed = false),
      onTapCancel: () => setState(() => _fabPressed = false),
      onTap: () =>
          Navigator.of(context).push(_slideRoute(const NewMessageScreen())),
      child: Padding(
        // Lift above the shell's bottom nav bar (inner Scaffold can't see it).
        // miniEndFloat already clears the safe-area + its own 16px margin, so add
        // only the nav body (~36.h) + 20px gap − that 16px margin ≈ 40.h.
        padding: EdgeInsets.only(bottom: 64.h + 20.h),
        child: AnimatedScale(
          scale: _fabPressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _fabPressed ? 0.7 : 1.0,
            duration: const Duration(milliseconds: 80),
            child: Container(
              padding: EdgeInsets.all(16.w),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primaryColor,
              ),
              child: SvgPicture.asset(
                "assets/svg/chats/new.svg",
                width: 22.w,
                height: 22.w,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Tab row ──────────────────────────────────────────────────────────────

  Widget _buildTabRow(Partition partition) {
    final chatsUnread = partition.regularChats.any((c) => c.unreadCount > 0);
    final aliasUnread = partition.aliasChats.any((c) => c.unreadCount > 0);

    return Row(
      children: [
        CategoryPill(
          label: 'Chats',
          isSelected: _tab == ChatsTab.chats,
          isUnread: chatsUnread,
          onTap: () => setState(() => _tab = ChatsTab.chats),
        ),
        Gap(8.w),
        CategoryPill(
          label: 'Alias Chats',
          isSelected: _tab == ChatsTab.aliasChats,
          isUnread: aliasUnread,
          onTap: () => setState(() => _tab = ChatsTab.aliasChats),
        ),
        Gap(8.w),
        CategoryPill(
          label: 'Spam',
          isSelected: _tab == ChatsTab.spam,
          // Spam is intentionally muted: never show the tab unread dot. New spam
          // messages still appear (bold row) once the tab is opened.
          isUnread: false,
          onTap: () => setState(() => _tab = ChatsTab.spam),
        ),
      ],
    );
  }

  // ── Tab body ─────────────────────────────────────────────────────────────

  Widget _buildTabSliver(
    Partition partition,
    AsyncValue<List<ChatPreview>> conversationsAsync,
    List<PendingInvite> pending,
  ) {
    // Keep rendering the current list during a refresh: only swap to the
    // skeleton on the very first (valueless) load. messageRefresh re-runs the
    // provider, which briefly reports loading — without this guard the list
    // would flicker out to a shimmer and back, which is the jitter.
    if (conversationsAsync.isLoading && !conversationsAsync.hasValue) {
      return _loadingSkeletonSliver();
    }
    if (conversationsAsync.hasError && !conversationsAsync.hasValue) {
      return SliverFillRemaining(hasScrollBody: false, child: _errorContent());
    }
    switch (_tab) {
      case ChatsTab.chats:
        // Pending alias invitations surface as a banner above normal chats;
        // tapping it jumps to the Alias Chats tab.
        if (pending.isEmpty) {
          return _buildConversationSliver(
            partition.regularChats,
            ChatsTab.chats,
          );
        }
        final banner = Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            8.h,
            horizontalPadding,
            0,
          ),
          child: AliasInvitations(
            count: pending.length,
            onTap: () => setState(() => _tab = ChatsTab.aliasChats),
          ),
        );
        // No regular chats: anchor the empty placeholder to the full
        // viewport and float the invite banner on top, so the placeholder
        // sits in the same spot whether or not invites are present.
        if (partition.regularChats.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Stack(children: [_emptyContent(ChatsTab.chats), banner]),
          );
        }
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(child: banner),
            _buildConversationSliver(partition.regularChats, ChatsTab.chats),
          ],
        );
      case ChatsTab.aliasChats:
        return _buildAliasSliver(partition.aliasChats, pending);
      case ChatsTab.spam:
        return _buildConversationSliver(partition.spamChats, ChatsTab.spam);
    }
  }

  Widget _buildConversationSliver(List<ChatPreview> items, ChatsTab tabKind) {
    if (items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _emptyContent(tabKind),
      );
    }
    return SliverPadding(
      // Bottom clearance so the last row clears the shell's bottom nav bar +
      // the FAB (the inner Scaffold can't see them). Without it the last chat
      // hides behind the nav bar with nothing to scroll it into view.
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        8.h,
        horizontalPadding,
        8.h + MediaQuery.of(context).padding.bottom + 96.h,
      ),
      sliver: SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final conv = items[i];
          final wallet = conv.contactWallet ?? '';
          return ChatRow(
            key: ValueKey('wallet-$wallet'),
            conversation: conv,
            displayName: (conv.contactUsername?.isNotEmpty == true)
                ? conv.contactUsername!
                : _formatWallet(wallet),
            avatarInitial: _avatarInitial(conv.contactUsername, wallet),
            timeLabel: _timestampToTime(conv.lastMessageTimestamp ?? 0),
            onTap: () =>
                _openChat(WalletChatId(wallet, username: conv.contactUsername)),
          );
        },
      ),
    );
  }

  Widget _buildAliasSliver(
    List<ChatPreview> items,
    List<PendingInvite> pending,
  ) {
    // Creator-side invites still waiting for the peer to accept.
    final creatorPending =
        ref.watch(creatorPendingInvitesProvider).value ??
        const <PendingInvite>[];

    if (items.isEmpty && pending.isEmpty && creatorPending.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _emptyContent(ChatsTab.aliasChats),
      );
    }
    final pendingEnd = pending.length;
    final creatorEnd = pendingEnd + creatorPending.length;
    return SliverPadding(
      // Bottom clearance so the last alias row clears the shell's bottom nav
      // bar + FAB (the inner Scaffold can't see them).
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        8.h,
        horizontalPadding,
        8.h + MediaQuery.of(context).padding.bottom + 96.h,
      ),
      sliver: SliverList.builder(
        // Order: incoming invitations → outgoing "Pending…" → established chats.
        itemCount: creatorEnd + items.length,
        itemBuilder: (context, i) {
          if (i < pendingEnd) {
            final inv = pending[i];
            // Online invites carry an on-chain identity — show the inviter's
            // nickname; fall back to the shortened wallet only until it resolves.
            final peerName = ref
                .watch(walletPeerNameProvider(inv.aliasDisplay))
                .value;
            // Prefix '@' for a resolved nickname; the wallet fallback stays bare.
            final fromLabel = (peerName != null && peerName.isNotEmpty)
                ? '@$peerName'
                : _formatWallet(inv.aliasDisplay);
            return Padding(
              key: ValueKey('invite-${inv.inviteRef}'),
              padding: EdgeInsets.only(bottom: 4.h),
              child: AliasInvitation(
                fromLabel: fromLabel,
                timeLabel: _timestampToTime(inv.createdAt * 1000),
                onTap: () => _openChat(PendingChatId(inv.inviteRef)),
              ),
            );
          }
          if (i < creatorEnd) {
            return _creatorPendingRow(creatorPending[i - pendingEnd]);
          }
          final p = items[i - creatorEnd];
          final aliasContact = p.aliasContact!;
          return AliasChatRow(
            key: ValueKey('alias-${aliasContact.contactId}'),
            preview: p,
            onTap: () => _openChat(AliasChatId(aliasContact.contactId)),
          );
        },
      ),
    );
  }

  /// Outgoing alias invite still waiting for acceptance: a "Pending…" row that
  /// opens the creator-side waiting state.
  Widget _creatorPendingRow(PendingInvite inv) {
    final name = inv.aliasDisplay;
    // Usernames have no spaces; treat placeholders ("Unnamed", "Alias Chat") as
    // non-handles so they don't get an '@'.
    final isHandle =
        name.isNotEmpty && name != 'Unnamed' && !name.contains(' ');
    final label = isHandle ? name : 'Alias chat';
    return Material(
      key: ValueKey('cpending-${inv.inviteRef}'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openChat(PendingChatId(inv.inviteRef)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
          child: Row(
            children: [
              ClipOval(
                child: Container(
                  width: 40.w,
                  height: 40.w,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  alignment: Alignment.center,
                  child: SvgPicture.asset("assets/svg/chats/chat.svg"),
                ),
              ),
              Gap(16.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 2.h),
                    const _PendingLabel(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Content-only widgets (hosted by SliverFillRemaining) ─────────────────

  // Cold first-load skeleton: shimmer rows that mirror ChatRow's flat layout
  // (transparent, 12.w×12.h padding, 20.w avatar, 16.w gap, name + subtitle
  // bars, trailing time bar). Shown only when there is no cached preview value
  // yet (never on refresh), so the list fades in instead of popping.
  Widget _loadingSkeletonSliver() {
    return SliverPadding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 8.h,
      ),
      sliver: SliverList.builder(
        itemCount: 7,
        itemBuilder: (context, _) => _skeletonRow(),
      ),
    );
  }

  // Single shimmer row matched to ChatRow.build().
  Widget _skeletonRow() {
    return ShimmerLoading(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ShimmerBox(width: 40.w, height: 40.w, borderRadius: 20.w),
            Gap(16.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShimmerBox(width: 130.w, height: 14.sp),
                  SizedBox(height: 6.h),
                  ShimmerBox(width: 200.w, height: 13.sp),
                ],
              ),
            ),
            Gap(16.w),
            ShimmerBox(width: 36.w, height: 11.sp),
          ],
        ),
      ),
    );
  }

  Widget _emptyContent(ChatsTab tab) {
    final title = switch (tab) {
      ChatsTab.chats => 'No conversations yet',
      ChatsTab.aliasChats => 'No alias chats yet',
      ChatsTab.spam => 'No spam',
    };
    final subtitle = switch (tab) {
      ChatsTab.chats => 'Start a new chat by searching above.',
      ChatsTab.aliasChats => 'Alias chats appear here once accepted.',
      ChatsTab.spam => 'Contacts you move to spam show up here.',
    };
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24.w),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Gap(MediaQuery.of(context).size.height * 0.25),
            Text(
              title,
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            Gap(8.h),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.sp,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorContent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.showSyncError(
          onRetry: () =>
              ref.read(messagesNotifierProvider.notifier).syncMessages(),
        );
      }
    });
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off,
            size: 48,
            color: Colors.white.withValues(alpha: 0.4),
          ),
          Gap(12.h),
          Text(
            'Failed to load conversations',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 16.sp,
            ),
          ),
          Gap(12.h),
          GestureDetector(
            onTap: () =>
                ref.read(messagesNotifierProvider.notifier).syncMessages(),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: primaryColor.withValues(alpha: 0.4)),
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
    );
  }
}

/// "Pending" with an animated trailing ellipsis (0→3 dots), in [primaryColor].
/// Used in the Alias Chats list for an outgoing invite awaiting acceptance.
class _PendingLabel extends StatefulWidget {
  const _PendingLabel();

  @override
  State<_PendingLabel> createState() => _PendingLabelState();
}

class _PendingLabelState extends State<_PendingLabel> {
  Timer? _timer;
  int _dots = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      if (mounted) setState(() => _dots = (_dots + 1) % 4);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      'Waiting for acceptance${'.' * _dots}',
      style: TextStyle(
        color: primaryColor.withValues(alpha: 0.8),
        fontSize: 14.sp,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
