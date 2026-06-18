import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:sealed_app/features/auth/wipe.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';
import 'package:sealed_app/providers/app_settings_provider.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/indexer_provider.dart';
import 'package:sealed_app/ui/contacts/contact_profile.dart'
    show contactBioProvider;
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/onboarding/screens/lock.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/onboarding/widgets/termination_dialog.dart';
import 'package:sealed_app/ui/settings/screens/change_pin_flow.dart';
import 'package:sealed_app/ui/settings/screens/change_termination_flow.dart';
import 'package:sealed_app/ui/settings/screens/logout_screen.dart';
import 'package:sealed_app/ui/settings/widgets/redeem_code.dart';
import 'package:sealed_app/ui/shared/widgets/dialogs.dart';

import 'package:sealed_app/ui/settings/widgets/bio_change.dart';
import 'package:sealed_app/ui/settings/widgets/username_change.dart';
import 'package:sealed_app/ui/settings/widgets/wallet_address.dart';
import 'package:sealed_app/ui/shared/screens/option_toggle.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/shimmer_loading.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

/// Figma-aligned Settings screen, wired to the same functionality the legacy
/// `SettingsScreen_old` carried. Push (and, when re-enabled, spam) toggles route
/// through the generic [OptionToggleScreen]; "Delete alias chats" gates a bulk
/// alias wipe behind a [PinDialog] warning + [LockScreenV2] re-auth.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _isResyncing = false;

  // ─── My Account ────────────────────────────────────────────────────────────

  /// First claim is gated behind a 1-credit cost warning; once a username
  /// exists the dialog opens directly (no persisted flag — derived from the
  /// profile).
  Future<void> _openUsernameDialog() async {
    final username = ref.read(userProvider).value?.profile?.username;
    if (username == null || username.isEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => PinDialog.warning(
          title: 'Username costs 1 credit',
          body: 'Claiming a username is an on-chain action and costs 1 credit.',
          buttonText: 'Continue',
          neutral: true,
          cancelText: 'Cancel',
          onCancel: () => Navigator.of(ctx).pop(false),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      );
      if (proceed != true || !mounted) return;
    }
    await SealedDialog.show<void>(
      context: context,
      dialog: const ChangeUsernameDialog(),
    );
  }

  /// First set is gated behind a 1-credit cost warning, mirroring
  /// [_openUsernameDialog]; once a bio exists the dialog opens directly.
  Future<void> _openBioDialog() async {
    final bio = ref.read(userProvider).value?.profile?.bio;
    if (bio == null || bio.isEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => PinDialog.warning(
          title: 'Bio costs 1 credit',
          body:
              'Setting a bio is an on-chain action and costs 1 credit. '
              'Your bio is publicly visible.',
          buttonText: 'Continue',
          neutral: true,
          cancelText: 'Cancel',
          onCancel: () => Navigator.of(ctx).pop(false),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      );
      if (proceed != true || !mounted) return;
    }
    await SealedDialog.show<void>(
      context: context,
      dialog: const ChangeBioDialog(),
    );
  }

  Future<void> _openWalletDialog() async {
    await SealedDialog.show<void>(
      context: context,
      dialog: const WalletAddressDialog(),
    );
  }

  // ─── Push notifications ──────────────────────────────────────────────────────

  void _openPushToggle(bool currentValue) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OptionToggleScreen(
          label: "Push notification",
          description:
              "Get notified when a new message arrives. The Sealed relay learns "
              "when you receive a message (never the contents, sender, or your "
              "IP). Apple/Google see one wake per message.",
          initialValue: currentValue,
          onChanged: _onPushToggle,
        ),
      ),
    );
  }

  /// Returns the value the switch should settle on. Mirrors the legacy
  /// `_onTargetedPushToggle` exactly — the enable path is gated on the
  /// dual-disclosure consent + OS permission + indexer registration, and the
  /// disable path tears registrations down in the load-bearing order
  /// (alias view keys → push token → clear alias flags → persist off) so a
  /// network failure can't orphan indexer rows. Any failure leaves push OFF.
  Future<bool> _onPushToggle(bool requested) async {
    if (requested) {
      // OS permission first (Android POST_NOTIFICATIONS + FCM token), before we
      // promise the indexer we can deliver.
      final granted = await NotificationService()
          .requestPermissionAndGetToken();
      if (!granted) {
        if (mounted) {
          showWarningSnackBar(context, 'Notification permission denied');
        }
        return false;
      }

      // Indexer registration is OHTTP-wrapped — typically a few seconds.
      final indexer = await ref.read(indexerServiceProvider.future);
      final ok = await indexer.registerTargetedPush();
      if (!ok) {
        if (mounted) {
          showErrorSnackBar(context, 'Push Notifications registration failed');
        }
        return false;
      }

      await ref.read(appSettingsProvider.notifier).setTargetedPushEnabled(true);
      return true;
    } else {
      final indexer = await ref.read(indexerServiceProvider.future);
      // Unregister first; clear flags after, so a network failure doesn't leave
      // dangling indexer rows. Alias push shares the main enc_token, so every
      // alias row must come down with the global toggle.
      await indexer.unregisterAllAliasViewKeys();
      await indexer.unregisterTargetedPush();
      final settingsNotifier = ref.read(appSettingsProvider.notifier);
      await settingsNotifier.clearAllAliasPushFlags();
      await settingsNotifier.setTargetedPushEnabled(false);
      return false;
    }
  }

  // ─── Security ────────────────────────────────────────────────────────────────

  Future<void> _changePin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChangePinFlow(),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _manageTermination() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChangeTerminationFlow(),
        fullscreenDialog: true,
      ),
    );
  }

  // ─── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _forceResync() async {
    final confirmed = await _confirm(
      title: 'Reload Conversations?',
      body:
          'This will clear your message cache and re-download all messages '
          'from the blockchain. This may take a while.',
      confirmLabel: 'Reload',
    );
    if (!confirmed) return;

    setState(() => _isResyncing = true);
    try {
      await ref.read(messagesNotifierProvider.notifier).forceResync();
      if (!mounted) return;
      showInfoSnackBar(context, 'Resync complete ');
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'Resync failed: $e');
    } finally {
      if (mounted) setState(() => _isResyncing = false);
    }
  }

  /// Delete every alias chat on this device. Flow: warning dialog ([PinDialog])
  /// → PIN re-auth ([LockScreenV2]) → bulk delete → confirmation. Cancelling at
  /// any step aborts with no deletion.
  Future<void> _deleteAliasChats() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => PinDialog.warning(
        title: 'Delete Alias Chats',
        body:
            'This permanently deletes every alias chat on this device — their '
            'messages, keys, and on-chain data. This cannot be undone. You will '
            'be asked for your passcode to confirm.',
        buttonText: 'Continue',
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    );
    if (confirmed != true || !mounted) return;

    final reauthed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            const LockScreenV2(reauth: true, title: 'Delete Alias Chats'),
      ),
    );
    if (reauthed != true || !mounted) return;

    try {
      final result = await ref
          .read(messagesNotifierProvider.notifier)
          .deleteAllAliasChats();
      if (!mounted) return;
      if (result.failed == 0) {
        showInfoSnackBar(
          context,
          'Deleted ${result.deleted} alias chat'
          '${result.deleted == 1 ? '' : 's'}',
        );
      } else {
        showWarningSnackBar(
          context,
          'Deleted ${result.deleted}, ${result.failed} failed',
        );
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'Delete failed: $e');
    }
  }

  Future<void> _logout() async {
    final seedPhrase = await ref
        .read(walletProvider.notifier)
        .getSeedPhraseForBackup();

    if (seedPhrase == null) {
      // No mnemonic — simple confirm + wipe.
      final confirmed = await _confirm(
        title: 'Log Out?',
        body: 'Are you sure you want to log out?',
        confirmLabel: 'Log Out',
      );
      if (!confirmed) return;
      await _performLogoutAndPop();
      return;
    }

    if (!mounted) return;
    // Mnemonic exists — full-screen logout flow owns reveal → PIN gate → wipe.
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LogoutScreen(seedPhrase: seedPhrase)),
    );
  }

  Future<void> _performLogoutAndPop() async {
    final container = ProviderScope.containerOf(context);
    if (mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    try {
      await performLogout(container);
    } catch (e) {
      debugPrint('⚠️ Logout error: $e');
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  /// Shared two-button confirm dialog in the new [SealedDialog] chrome.
  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final result = await SealedDialog.show<bool>(
      context: context,
      dialog: SealedDialog(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              body,
              style: Theme.of(
                context,
              ).textTheme.bodySmall!.copyWith(color: Colors.white),
            ),
            Gap(24.h),
            Builder(
              builder: (ctx) => Row(
                children: [
                  Expanded(
                    child: SealedCircularButton(
                      label: 'Cancel',
                      onTap: () => Navigator.of(ctx).pop(false),
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      textColor: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  Gap(12.w),
                  Expanded(
                    child: SealedCircularButton(
                      label: confirmLabel,
                      onTap: () => Navigator.of(ctx).pop(true),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  String _truncateAddress(String address) {
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)} .... ${address.substring(address.length - 4)}';
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final walletAddress = ref.watch(walletProvider).asData?.value.walletAddress;
    final pushEnabled = ref
        .watch(appSettingsProvider)
        .maybeWhen(data: (s) => s.targetedPushEnabled, orElse: () => false);
    final credits = ref.watch(creditsBalanceProvider);
    final creditsLabel = credits.when(
      data: (value) => '$value',
      loading: () => '…',
      error: (_, _) => '—',
    );

    // Own bio: prefer the cached value (set instantly on edit), but fall back to
    // the authoritative chain read so it survives a restart even when the local
    // cache row was missed. contactBioProvider is chain-first with a cache
    // fallback, so it works offline too.
    final ownBio = currentUser?.bio;
    final bioAsync = walletAddress != null
        ? ref.watch(contactBioProvider(walletAddress))
        : const AsyncValue<String?>.data(null);
    // Show a shimmer skeleton while the chain bio is still resolving and there's
    // no cached value to display yet.
    final bioLoading = !(ownBio?.isNotEmpty ?? false) && bioAsync.isLoading;
    final bioText = (ownBio?.isNotEmpty ?? false) ? ownBio : bioAsync.value;

    return SealedLayout(
      scrollable: true,
      crossAxisAlignment: CrossAxisAlignment.start,
      topBar: TopBar(label: "Settings", back: false),
      children: [
        SettingsSection(
          label: "My Account",
          children: [
            SettingsRow(
              assetName: 'username',
              onTap: _openUsernameDialog,
              subtitle: Text(
                currentUser?.username != null
                    ? "@${currentUser!.username}"
                    : "Not set",
                style: Theme.of(
                  context,
                ).textTheme.displaySmall!.copyWith(color: neutralColor),
              ),
              label: "username",
            ),
            SettingsRow(
              assetName: 'description',
              onTap: _openBioDialog,
              subtitle: bioLoading
                  ? ShimmerLoading(
                      child: Container(
                        width: 140.w,
                        height: 12.h,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4.r),
                        ),
                      ),
                    )
                  : Text(
                      (bioText?.isNotEmpty ?? false)
                          ? bioText!.replaceAll('\n', ' ')
                          : "Add a bio",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      softWrap: true,
                      style: Theme.of(
                        context,
                      ).textTheme.displaySmall!.copyWith(color: neutralColor),
                    ),
              label: "Bio Description",
            ),
            SettingsRow(
              assetName: "wallet",
              label: "wallet",
              subtitle: Text(
                walletAddress != null
                    ? _truncateAddress(walletAddress)
                    : "Not connected",
                style: Theme.of(
                  context,
                ).textTheme.displaySmall!.copyWith(color: neutralColor),
              ),
              action: SealedCircularButton(
                label: "Show wallet",
                fullWidth: false,
                textStyle: Theme.of(context).textTheme.labelSmall!,
                padding: EdgeInsets.symmetric(vertical: 8.h, horizontal: 12.w),
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                textColor: Colors.white.withValues(alpha: 0.9),
                onTap: walletAddress == null ? () {} : _openWalletDialog,
              ),
            ),
          ],
        ),

        Gap(12.h),
        SettingsSection(
          label: "App Credits",
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          "Sealed Credits",
                          style: Theme.of(context).textTheme.displaySmall!
                              .copyWith(fontWeight: FontWeight.w500),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => SealedDialog.show<void>(
                            context: context,
                            dialog: const CreditsDialog(),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.w,
                              vertical: 4.h,
                            ),
                            child: SvgPicture.asset(
                              "assets/svg/settings/info.svg",
                              width: 14.w,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Gap(2.h),
                    Row(
                      children: [
                        Text(
                          "enough to send",
                          style: Theme.of(context).textTheme.displaySmall!
                              .copyWith(color: neutralColor),
                        ),
                        Gap(4.w),
                        Text(
                          creditsLabel,
                          style: Theme.of(context).textTheme.displaySmall!
                              .copyWith(
                                color: Colors.white.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        Gap(4.w),
                        Text(
                          "messages",
                          style: Theme.of(context).textTheme.displaySmall!
                              .copyWith(color: neutralColor),
                        ),
                      ],
                    ),
                  ],
                ),
                Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    creditsLabel,
                    style: TextStyle(color: primaryColor),
                  ),
                ),
              ],
            ),
            Gap(12.h),
            Container(
              width: double.infinity,
              height: 1.5.h,
              color: Colors.white.withValues(alpha: 0.12),
            ),
            Gap(8.h),
            SettingsRow(
              label: "Redeem Code",
              onTap: () => RedeemCodeDialog.show(context),
              assetName: 'star',
              subtitle: Text(
                "Enter the code and claim your credits",
                style: Theme.of(
                  context,
                ).textTheme.displaySmall!.copyWith(color: neutralColor),
              ),
            ),
            Gap(8.h),
            Container(
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: SettingsRow(
                assetName: 'redeem',
                label: "Top up Wallet",
                labelColor: primaryColor,
                onTap: openTopUpSite,
                subtitle: Text(
                  "Purchase credits for your account",
                  style: Theme.of(
                    context,
                  ).textTheme.displaySmall!.copyWith(color: neutralColor),
                ),
                padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 8.h),
              ),
            ),
          ],
        ),

        Gap(12.h),
        SettingsSection(
          label: "Notification",
          children: [
            SettingsRow(
              label: "Push notification",
              assetName: 'bell',
              padding: EdgeInsets.symmetric(vertical: 8.h),
              onTap: () => _openPushToggle(pushEnabled),
              action: Text(
                pushEnabled ? "Enabled" : "Disabled",
                style: Theme.of(context).textTheme.displaySmall!.copyWith(
                  color: pushEnabled ? primaryColor : neutralColor,
                ),
              ),
            ),
          ],
        ),
        Gap(12.h),
        SettingsSection(
          label: "Action",
          children: [
            Text(
              "Passwords",
              style: Theme.of(
                context,
              ).textTheme.labelSmall!.copyWith(color: primaryColor),
            ),
            Gap(8.h),
            SettingsRow(
              label: "Change passcode",
              assetName: "passcode",
              padding: EdgeInsets.symmetric(vertical: 8.h),
              onTap: _changePin,
            ),
            Gap(8.h),
            SettingsRow(
              label: "Change termination code",
              assetName: "file_termination",
              padding: EdgeInsets.symmetric(vertical: 8.h),
              onTap: _manageTermination,
            ),
            Gap(16.h),
            Text(
              "Preferences",
              style: Theme.of(
                context,
              ).textTheme.labelSmall!.copyWith(color: primaryColor),
            ),
            Gap(8.h),
            SettingsRow(
              padding: EdgeInsets.symmetric(vertical: 8.h),
              label: "Re-sync messages",
              assetName: "resync",
              onTap: _isResyncing ? null : _forceResync,
              action: _isResyncing
                  ? SizedBox(
                      width: 16.w,
                      height: 16.w,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Row(
                      children: [
                        Text(
                          "Synced",
                          style: Theme.of(context).textTheme.displaySmall!
                              .copyWith(color: primaryColor),
                        ),
                        Gap(6.w),
                        Icon(
                          Icons.check_circle_outline,
                          size: 16.w,
                          color: primaryColor,
                        ),
                      ],
                    ),
            ),
            // Spam filter is disabled app-wide for now. When re-enabled it
            // routes through OptionToggleScreen exactly like Push above.
            // SettingsRow(
            //   label: "Spam filter",
            //   assetName: 'filter',
            //   padding: EdgeInsets.symmetric(vertical: 8.h),
            //   action: Text("Disabled", ...),
            // ),
            Gap(16.h),
            SettingsRow(
              label: "Delete Alias Chats",
              assetName: 'delete',
              assetColor: kPinErrorColor!.withValues(alpha: 0.8),
              labelColor: kPinErrorColor!.withValues(alpha: 0.9),
              onTap: _deleteAliasChats,
            ),
            Gap(8.h),
            SettingsRow(
              label: "Log out & delete your data",
              assetName: "logout",
              onTap: _logout,
            ),
          ],
        ),
        Gap(12.h),
        VersionInfo(),
        Gap(24.h),
      ],
    );
  }
}

class VersionInfo extends StatelessWidget {
  const VersionInfo({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              children: [
                Text(
                  "Sealed",
                  style: Theme.of(
                    context,
                  ).textTheme.displaySmall!.copyWith(color: primaryColor),
                ),
                Gap(4.w),
                Text(
                  Platform.isIOS ? "iOS" : "Android",
                  style: Theme.of(
                    context,
                  ).textTheme.displaySmall!.copyWith(color: primaryColor),
                ),
              ],
            ),
            Text(
              "Version 2.0.0",
              style: Theme.of(
                context,
              ).textTheme.displaySmall!.copyWith(color: neutralColor),
            ),
          ],
        ),
      ],
    );
  }
}

class MessageCredits extends ConsumerWidget {
  const MessageCredits({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final credits = ref
        .watch(creditsBalanceProvider)
        .maybeWhen(data: (c) => c, orElse: () => 0);
    return Row(
      children: [
        Text(
          "$credits",
          style: Theme.of(context).textTheme.displaySmall!.copyWith(
            fontWeight: FontWeight.w600,
            color: primaryColor,
          ),
        ),
      ],
    );
  }
}

class SettingsRow extends StatefulWidget {
  SettingsRow({
    super.key,
    this.action,
    this.subtitle,
    required this.label,
    this.assetName,
    this.assetColor,
    this.onTap,
    this.labelColor,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });
  String label;
  Color? labelColor;
  Widget? subtitle;
  Color? assetColor;
  String? assetName;
  EdgeInsets padding;

  /// Tap handler for the whole row. When null the row is inert (no press
  /// feedback).
  final VoidCallback? onTap;

  Widget? action;

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    // The leading icon + label + subtitle animate together as the row's
    // press target; the trailing [action] (its own button) is left untouched.
    final content = AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 100),
      child: AnimatedOpacity(
        opacity: _pressed ? 0.7 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.assetName != null
                ? Container(
                    margin: EdgeInsets.only(left: 4.w),
                    child: SvgPicture.asset(
                      "assets/svg/settings/${widget.assetName}.svg",
                      width: 20.w,
                      colorFilter: widget.assetColor != null
                          ? ColorFilter.mode(
                              widget.assetColor!,
                              BlendMode.srcIn,
                            )
                          : null,
                    ),
                  )
                : Center(),
            Gap(8.w),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label.substring(0, 1).toUpperCase() +
                        widget.label.substring(1),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall!.copyWith(color: widget.labelColor),
                  ),
                  Gap(2.h),
                  ?widget.subtitle,
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final row = Container(
      padding: widget.padding,
      child: Row(children: [content, Spacer(), ?widget.action]),
    );

    if (widget.onTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: row,
    );
  }
}

class SettingsSection extends StatelessWidget {
  SettingsSection({super.key, required this.children, required this.label});

  List<Widget> children;
  String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium!.copyWith()),
        Gap(8.h),
        Container(
          padding: EdgeInsets.all(12.w),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16.r),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [...children],
          ),
        ),
      ],
    );
  }
}
