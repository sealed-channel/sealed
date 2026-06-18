import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/features/search/search_service.dart';
import 'package:sealed_app/providers/chat_controller.dart'
    show ChatIdentity, WalletChatId;
import 'package:sealed_app/providers/search_provider.dart';
import 'package:sealed_app/ui/chats/widgets/search_hit_row.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/search_top_bar.dart'
    show kSearchTapGroup;

/// Renders user-search results as a sliver. Watches [searchUsersProvider] for
/// [query] and reports a tapped hit via [onOpenChat]. Feature-blind: the parent
/// decides what opening a chat means.
class UserSearchSliver extends ConsumerWidget {
  const UserSearchSliver({
    super.key,
    required this.query,
    required this.onOpenChat,
  });

  final String query;
  final void Function(ChatIdentity identity) onOpenChat;

  static String _formatWallet(String addr) {
    if (addr.length <= 12) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 6)}';
  }

  static String _avatarInitial(String? username, String wallet) {
    final src = (username != null && username.isNotEmpty)
        ? username
        : _formatWallet(wallet);
    if (src.isEmpty) return '?';
    return src.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchUsersProvider(query));
    return results.when(
      loading: () =>
          SliverFillRemaining(hasScrollBody: false, child: _loadingContent(context)),
      error: (_, _) => SliverFillRemaining(
        hasScrollBody: false,
        child: _noResultsContent(context),
      ),
      data: (r) {
        if (r.hits.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: r.isRemotePending
                ? _loadingContent(context)
                : _noResultsContent(context),
          );
        }
        return SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 8.h,
          ),
          sliver: SliverList.separated(
            itemCount: r.hits.length,
            separatorBuilder: (_, _) => Gap(8.h),
            itemBuilder: (context, i) {
              final hit = r.hits[i];
              // Membership in the search tap group: a row tap is "inside" the
              // bar's TapRegion, so it navigates rather than collapsing search.
              return TapRegion(
                groupId: kSearchTapGroup,
                child: switch (hit) {
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
                      onTap: () => onOpenChat(
                        WalletChatId(walletAddress, username: username),
                      ),
                    ),
                  WalletAddressHit(:final walletAddress) => SearchHitRow(
                    primary: _formatWallet(walletAddress),
                    secondary: walletAddress,
                    avatarInitial: '?',
                    badge: 'Wallet',
                    onTap: () =>
                        onOpenChat(WalletChatId(walletAddress, username: '')),
                  ),
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _loadingContent(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        Gap(MediaQuery.of(context).size.height * 0.3),
        Center(
          child: SizedBox(
            width: 32.w,
            height: 32.w,
            child: CircularProgressIndicator(
              color: primaryColor,
              strokeWidth: 2.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _noResultsContent(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24.w),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Gap(MediaQuery.of(context).size.height * 0.3),

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
