import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/core/extensions.dart';
import 'package:sealed_app/features/search/search_service.dart';
import 'package:sealed_app/providers/search_provider.dart';
import 'package:sealed_app/ui/chat/widgets/alias_invitation.dart';
import 'package:sealed_app/ui/chats/screens/alias/oflline_connection.dart';
import 'package:sealed_app/ui/chats/widgets/search_hit_row.dart';
import 'package:sealed_app/ui/shared/widgets/action_tile.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

class NewMessageScreen extends ConsumerStatefulWidget {
  const NewMessageScreen({super.key});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final Debouncer _debouncer = Debouncer();

  String _searchQuery = '';
  bool _isSearching = false;

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {
      _isSearching = value.isNotEmpty;
      _debouncer.run(() {
        if (!mounted) return;
        setState(() => _searchQuery = value);
      });
    });
  }

  void _clearSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
    _searchFocusNode.unfocus();
  }

  // This screen starts an *alias* chat: tapping a recipient pitches an alias
  // invitation (popup) rather than opening a regular DM. The dialog handles
  // sending the invite envelope; on success we pop back to the chats tab.
  Future<void> _inviteToAliasChat(String wallet, String? username) async {
    final sent = await SealedDialog.show<bool>(
      context: context,
      dialog: AliasInvitationDialog(
        contactWallet: wallet,
        contactUsername: (username != null && username.isNotEmpty)
            ? username
            : null,
      ),
    );
    if (sent == true && mounted) Navigator.of(context).pop();
  }

  // ── Formatting helpers ───────────────────────────────────────────────────

  String _formatWallet(String addr) {
    if (addr.length <= 12) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 6)}';
  }

  String _avatarInitial(String? username, String wallet) {
    final src = (username != null && username.isNotEmpty)
        ? username
        : _formatWallet(wallet);
    if (src.isEmpty) return '?';
    return src.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      topBar: TopBar(label: "New Message"),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      expandedBody: _isSearching ? _buildSearchResults() : null,
      children: [
        _buildSearchBar(),

        // Offline-connection card hides as soon as a search is active.
        if (!_isSearching) ...[
          Gap(16.h),
          ActionTile(
            label: "Offline connection",
            subtitle: "Direct connection via QR code",
            assetPath: "assets/svg/chats/qr.svg",
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const OfflineConnectionScreen(),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Search bar (expanded pill, mirrors Chats screen) ─────────────────────

  Widget _buildSearchBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(9999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: const Color(0xFF2E2E2E), width: 1.2),
          ),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          child: Row(
            children: [
              Icon(CupertinoIcons.search, size: 16.w, color: mutedColor),
              Gap(8.w),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: _onSearchChanged,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w400,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8.h),
                    border: InputBorder.none,
                    hintText: 'Search Users',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
              if (_isSearching)
                GestureDetector(
                  onTap: _clearSearch,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(14.w, 12.h, 2.w, 12.h),
                    child: Icon(
                      CupertinoIcons.xmark,
                      size: 14.w,
                      color: neutralColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Search results ─────────────────────────────────────────────────────

  Widget _buildSearchResults() {
    final results = ref.watch(searchUsersProvider(_searchQuery));
    return results.when(
      loading: () => _loadingContent(),
      error: (_, _) => _noResultsContent(),
      data: (r) {
        if (r.hits.isEmpty) {
          return r.isRemotePending ? _loadingContent() : _noResultsContent();
        }
        return ListView.separated(
          padding: EdgeInsets.symmetric(vertical: 8.h),
          itemCount: r.hits.length,
          separatorBuilder: (_, _) => Gap(8.h),
          itemBuilder: (context, i) {
            final hit = r.hits[i];
            return switch (hit) {
              UsernameHit(
                :final username,
                :final walletAddress,
                :final isLocal,
              ) =>
                SearchHitRow(
                  primary: username.isNotEmpty
                      ? username
                      : _formatWallet(walletAddress),
                  secondary: walletAddress,
                  avatarInitial: _avatarInitial(username, walletAddress),
                  badge: isLocal ? 'Contact' : null,
                  onTap: () => _inviteToAliasChat(walletAddress, username),
                ),
              WalletAddressHit(:final walletAddress) => SearchHitRow(
                primary: _formatWallet(walletAddress),
                secondary: walletAddress,
                avatarInitial: '?',
                badge: 'Wallet',
                onTap: () => _inviteToAliasChat(walletAddress, null),
              ),
            };
          },
        );
      },
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

  Widget _noResultsContent() {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24.w),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Gap(MediaQuery.of(context).size.height * 0.2),
            Icon(
              Icons.search_off,
              size: 32.w,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            Gap(20.h),
            Text(
              "We couldn't find such a user.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 18.sp,
                fontWeight: FontWeight.w500,
              ),
            ),
            Gap(12.h),
            Text(
              'Please try a different search',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14.sp,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
