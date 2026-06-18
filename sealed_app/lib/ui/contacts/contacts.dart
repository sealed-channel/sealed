import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/svg.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/chat_controller.dart'
    show ChatIdentity, WalletChatId;
import 'package:sealed_app/providers/contacts_provider.dart';
import 'package:sealed_app/ui/chat/screens/chat.dart';
import 'package:sealed_app/ui/contacts/contact_profile.dart';
import 'package:sealed_app/ui/chat/widgets/alias_invitation.dart';
import 'package:sealed_app/ui/qr/screens/qr_scan_coordinator.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/search_hint_sliver.dart';
import 'package:sealed_app/ui/shared/widgets/search_top_bar.dart';
import 'package:sealed_app/ui/shared/widgets/user_search_sliver.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen>
    implements SearchCollapsible {
  String _searchQuery = '';
  bool _isSearching = false;
  bool _isSearchExpanded = false;

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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      body: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [_buildSliverHeader(), ..._buildBodySlivers()],
      ),
    );
  }

  List<Widget> _buildBodySlivers() {
    // The moment search opens, swap the contacts list for a prompt — even
    // before a query is typed.
    if (_isSearchExpanded || _isSearching) {
      if (_searchQuery.trim().isEmpty) {
        return const [
          SearchHintSliver(
            subtitle: 'Type a name or wallet address to find people.',
          ),
        ];
      }
      return [UserSearchSliver(query: _searchQuery, onOpenChat: _openChat)];
    }
    final contactsAsync = ref.watch(contactsProvider);
    return contactsAsync.when(
      loading: () => [
        SliverFillRemaining(hasScrollBody: false, child: _loadingContent()),
      ],
      error: (_, _) => [
        SliverFillRemaining(hasScrollBody: false, child: _errorContent()),
      ],
      data: (contacts) => contacts.isEmpty
          ? [SliverFillRemaining(hasScrollBody: false, child: _emptyContent())]
          : [_buildContactsSliver(contacts)],
    );
  }

  Widget _buildSliverHeader() {
    return SliverAppBar(
      pinned: true,
      floating: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: horizontalPadding,
      toolbarHeight: 56.h,
      title: SearchTopBar(
        key: _topBarKey,
        title: 'Contacts',
        onQrTap: () => startConversationFromQrScan(context, ref),
        onExpandedChanged: (v) => setState(() => _isSearchExpanded = v),
        onSearchingChanged: (v) => setState(() => _isSearching = v),
        onQueryChanged: (q) => setState(() => _searchQuery = q),
      ),
    );
  }

  Widget _emptyContent() {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24.w),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Gap(MediaQuery.of(context).size.height * 0.3),
            Text(
              'No contacts yet',
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            Gap(8.h),
            Text(
              'Find people by searching above, then add them from their profile.',
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Colors.white.withValues(alpha: 0.4),
          ),
          Gap(12.h),
          Text(
            'Failed to load contacts',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 16.sp,
            ),
          ),
          Gap(12.h),
          GestureDetector(
            onTap: () => ref.invalidate(contactsProvider),
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

  Widget _loadingContent() {
    return Center(
      child: SizedBox(
        width: 32.w,
        height: 32.w,
        child: CircularProgressIndicator(color: primaryColor, strokeWidth: 2.4),
      ),
    );
  }

  // ── Display + grouping helpers ──────────────────────────────────────────

  /// Best label for a contact: on-chain username, else alias, else null
  /// (null = wallet-address-only → "Unnamed" group).
  String? _displayName(UserProfile p) {
    final n = (p.username?.isNotEmpty == true) ? p.username : p.alias;
    return (n?.isNotEmpty == true) ? n : null;
  }

  String _rowLabel(UserProfile p) {
    final name = _displayName(p);
    if (name != null) return name;
    final w = p.walletAddress;
    if (w.length <= 8) return w;
    return '${w.substring(0, 4)}...${w.substring(w.length - 4)}';
  }

  String _avatarInitial(UserProfile p) {
    final name = _displayName(p);
    final src = name ?? p.walletAddress;
    return src.isEmpty ? '?' : src.substring(0, 1).toUpperCase();
  }

  /// Buckets contacts into letter groups, preserving the provider's
  /// named-first ordering. Wallet-only contacts collapse into one "Unnamed"
  /// group that sorts last.
  Map<String, List<UserProfile>> _groupContacts(List<UserProfile> contacts) {
    final groups = <String, List<UserProfile>>{};
    for (final c in contacts) {
      final name = _displayName(c);
      final key = name != null ? name.substring(0, 1).toUpperCase() : 'Unnamed';
      groups.putIfAbsent(key, () => []).add(c);
    }
    return groups;
  }

  Widget _buildContactsSliver(List<UserProfile> contacts) {
    final groups = _groupContacts(contacts);
    final letters = groups.keys.toList();
    return SliverPadding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 8.h,
      ),
      sliver: SliverList.builder(
        itemCount: letters.length,
        itemBuilder: (context, i) {
          final letter = letters[i];
          return Padding(
            padding: EdgeInsets.only(bottom: 12.h),
            child: _contactGroupWrap(letter, groups[letter]!),
          );
        },
      ),
    );
  }

  Widget _contactGroupWrap(String letter, List<UserProfile> contacts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Letter grouping - "Unnamed" section for wallet addresses only.
        Text(letter, style: Theme.of(context).textTheme.labelMedium),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16.r),
          ),
          padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 6.h),
          child: Column(children: [...contacts.map((c) => _contactWrap(c))]),
        ),
      ],
    );
  }

  String? expandedContact;
  Widget _contactWrap(UserProfile c) {
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              if (expandedContact == c.walletAddress) {
                expandedContact = null;
              } else {
                expandedContact = c.walletAddress;
              }
            });
          },
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.all(6.w),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20.w,

                    backgroundColor: primaryColor,
                    child: Text(
                      _avatarInitial(c),
                      style: const TextStyle(color: Colors.black),
                    ),
                  ),
                  Gap(16.w),
                  Text(
                    _rowLabel(c),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
        ),

        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: expandedContact == c.walletAddress
                ? _contactOptions(c)
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }

  Widget _contactOptions(UserProfile contact) {
    return Container(
      margin: EdgeInsets.only(top: 12.h, bottom: 6.h, left: 6.w, right: 6.w),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          // Open a normal wallet chat.
          _contactOption(
            onTap: () => _openChat(
              WalletChatId(contact.walletAddress, username: contact.username),
            ),
            assetPath: "assets/svg/contact_profile/alias_chat.svg",
            assetColor: Colors.white.withValues(alpha: 0.9),
          ),
          Gap(16.w),
          // Open the contact's profile.
          _contactOption(
            onTap: () => Navigator.of(context).push(
              _slideRoute(
                ContactProfileScreen(
                  contactWallet: contact.walletAddress,
                  contactUsername: contact.username,
                ),
              ),
            ),
            assetPath: "assets/svg/contact_profile/info.svg",
            assetColor: Colors.white.withValues(alpha: 0.9),
          ),
          Gap(16.w),
          // Send an alias-chat invitation.
          _contactOption(
            onTap: () => SealedDialog.show(
              context: context,
              dialog: AliasInvitationDialog(
                contactWallet: contact.walletAddress,
                contactUsername: contact.username,
              ),
            ),
            assetPath: "assets/svg/contact_profile/alias_chat.svg",
          ),
        ],
      ),
    );
  }

  Widget _contactOption({
    required Function onTap,
    required String assetPath,
    Color? assetColor,
  }) {
    return _ContactOptionButton(
      onTap: onTap,
      assetPath: assetPath,
      assetColor: assetColor,
    );
  }
}

/// A contact-action pill with press feedback (scale 0.95 / opacity 0.7 while
/// held). Stateful so each option tracks its own press independently.
class _ContactOptionButton extends StatefulWidget {
  const _ContactOptionButton({
    required this.onTap,
    required this.assetPath,
    this.assetColor,
  });

  final Function onTap;
  final String assetPath;
  final Color? assetColor;

  @override
  State<_ContactOptionButton> createState() => _ContactOptionButtonState();
}

class _ContactOptionButtonState extends State<_ContactOptionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isAlias =
        widget.assetPath == "assets/svg/contact_profile/alias_chat.svg" &&
        widget.assetColor == null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () => widget.onTap(),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.7 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            padding: EdgeInsets.all(8.w),
            decoration: BoxDecoration(
              color: !isAlias
                  ? Colors.white.withValues(alpha: 0.05)
                  : primaryColor.withValues(alpha: 0.1),
              shape: !isAlias ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: isAlias ? BorderRadius.circular(100.r) : null,
            ),
            child: Row(
              children: [
                SvgPicture.asset(
                  widget.assetPath,
                  width: 26.w,
                  colorFilter: widget.assetColor != null
                      ? ColorFilter.mode(widget.assetColor!, BlendMode.srcIn)
                      : null,
                ),
                isAlias
                    ? Container(
                        padding: EdgeInsets.symmetric(horizontal: 6.w),
                        child: Text(
                          "Alias Chat",
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall!.copyWith(color: primaryColor),
                        ),
                      )
                    : Center(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
