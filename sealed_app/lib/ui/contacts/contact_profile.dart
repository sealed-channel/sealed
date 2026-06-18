import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/svg.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/ui/chat/widgets/alias_invitation.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart'
    show kPinErrorColor;
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

/// Contact's public on-chain bio. Chain read first (bio can change at any
/// time), cached contact row as offline fallback. Null/empty = hidden.
///
/// autoDispose + a refresh-counter watch so a peer's bio edit propagates without
/// an app restart: reopening the profile (or any post-sync bump) re-reads chain
/// instead of serving a value cached for the process lifetime.
final contactBioProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  wallet,
) async {
  ref.watch(messageRefreshCounterProvider);
  try {
    final chain = await ref.watch(sealedChainClientProvider.future);
    final profile = await chain.getUserByWallet(wallet);
    if (profile != null) return profile.bio;
  } catch (_) {
    // Offline / chain hiccup — fall through to the local cache.
  }
  final cached = await ref.watch(contactRepositoryProvider).getContact(wallet);
  return cached?.bio;
});

class ContactProfileScreen extends ConsumerWidget {
  const ContactProfileScreen({
    super.key,
    required this.contactWallet,
    this.contactUsername,
  });

  final String contactWallet;
  final String? contactUsername;

  Future<void> _startAliasChat(BuildContext context) {
    return SealedDialog.show(
      context: context,
      dialog: AliasInvitationDialog(
        contactWallet: contactWallet,
        contactUsername: contactUsername,
      ),
    );
  }

  /// Confirm, block the wallet, then unwind back to the chat list (popping
  /// both the profile and the now-blocked chat detail), so the user doesn't
  /// land in the conversation they just blocked. Cancel is a no-op.
  /// Reversible via "Unblock" (which stays a direct one-tap).
  Future<void> _confirmBlock(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(messagesNotifierProvider.notifier);
    final confirmed = await SealedDialog.show<bool>(
      context: context,
      dialog: const _BlockConfirmDialog(),
    );
    if (confirmed != true) return;
    await notifier.blockContact(contactWallet);
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Toggle the manual-contact flag. Add lazily creates the key-cache row for
  /// a never-messaged peer, which can fail offline — surfaced via snackbar.
  Future<void> _toggleContact(
    BuildContext context,
    WidgetRef ref, {
    required bool isContact,
  }) async {
    final notifier = ref.read(messagesNotifierProvider.notifier);
    try {
      if (isContact) {
        await notifier.removeFromContacts(contactWallet);
      } else {
        await notifier.addToContacts(contactWallet);
      }
    } catch (_) {
      if (context.mounted) {
        showInfoSnackBar(
          context,
          'Could not add contact — check your connection and try again',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked =
        ref.watch(contactBlockedProvider(contactWallet)).value ?? false;
    final isContact =
        ref.watch(contactIsContactProvider(contactWallet)).value ?? false;
    final bio = ref.watch(contactBioProvider(contactWallet)).value;
    return SealedLayout(
      scrollable: true,
      topBar: TopBar(label: "Profile"),
      children: [
        Container(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status pill: Blocked (red) wins over In-contacts; hidden for a
              // plain peer (not blocked, not manually added).
              if (blocked || isContact)
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          vertical: 8.h,
                          horizontal: 12.w,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(100),
                          color: blocked
                              ? kPinErrorColor.withValues(alpha: 0.1)
                              : primaryColor.withValues(alpha: 0.12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (blocked)
                              Icon(
                                Icons.close,
                                size: 16.w,
                                color: kPinErrorColor,
                              )
                            else
                              SvgPicture.asset(
                                "assets/svg/contact_profile/connected.svg",
                                width: 16.w,
                              ),
                            Gap(8.w),
                            Text(
                              blocked ? "Blocked" : "In contacts",
                              style: Theme.of(context).textTheme.bodySmall!
                                  .copyWith(
                                    color: blocked
                                        ? kPinErrorColor
                                        : primaryColor,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (bio != null && bio.isNotEmpty) ...[
                Gap(12.h),
                Text("Bio", style: Theme.of(context).textTheme.labelMedium),
                Gap(12.h),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16.w),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(16.r),
                  ),
                  child: Text(
                    bio,
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
              Gap(12.h),
              Text(
                "Wallet address",
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Gap(12.h),
              Container(
                padding: EdgeInsets.all(16.w),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(16.r),
                ),
                child: QRContainer(qrCode: contactWallet),
              ),
              Gap(24.h),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Contact",
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  Gap(12.h),
                  // Hidden while blocked — unblock first, then manage
                  // contact membership. Remove state styled red (Figma 6:7219).
                  if (!blocked) ...[
                    if (isContact)
                      OptionDialog(
                        iconAsset: "assets/svg/contact_profile/connected.svg",
                        iconColor: kPinErrorColor,
                        label: "Remove From Contacts",
                        labelColor: kPinErrorColor,
                        actionLabel: "Remove",
                        actionBackgroundColor: kPinErrorColor.withValues(
                          alpha: 0.08,
                        ),
                        actionTextColor: kPinErrorColor,
                        onActionTap: () =>
                            _toggleContact(context, ref, isContact: true),
                      )
                    else
                      OptionDialog(
                        iconAsset: "assets/svg/contact_profile/connected.svg",
                        iconColor: Colors.white.withValues(alpha: 0.9),
                        label: "Add To Contacts",
                        actionLabel: "Add",
                        actionBackgroundColor: Colors.white.withValues(
                          alpha: 0.1,
                        ),
                        onActionTap: () =>
                            _toggleContact(context, ref, isContact: false),
                      ),
                    Gap(12.h),
                  ],
                  OptionDialog(
                    iconAsset: blocked
                        ? "assets/svg/contact_profile/unlock.svg"
                        : "assets/svg/contact_profile/lock.svg",
                    iconColor: Colors.white.withValues(alpha: 0.9),
                    label: blocked ? "Unblock Wallet" : "Block Wallet",
                    actionLabel: blocked ? "Unblock" : "Block",
                    actionBackgroundColor: Colors.white.withValues(alpha: 0.1),
                    onActionTap: () async {
                      if (blocked) {
                        await ref
                            .read(messagesNotifierProvider.notifier)
                            .unblockContact(contactWallet);
                      } else {
                        await _confirmBlock(context, ref);
                      }
                    },
                  ),
                  Gap(12.h),
                  OptionDialog(
                    iconAsset: "assets/svg/contact_profile/alias_chat.svg",
                    iconColor: primaryColor,
                    label: "Create Alias Chat",
                    labelColor: primaryColor,
                    actionLabel: "Start Chat",
                    actionBackgroundColor: primaryColor.withValues(alpha: 0.2),
                    actionTextColor: primaryColor,
                    onActionTap: () => _startAliasChat(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class QRContainer extends StatelessWidget {
  QRContainer({super.key, required this.qrCode, this.copy = true});

  final String qrCode;
  bool copy;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // QR Code From contact's qrCode address.
        Container(
          padding: EdgeInsets.all(16.w),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(width: 1, color: primaryColor),
          ),
          child: ClipRRect(
            borderRadius: BorderRadiusGeometry.circular(8.r),
            child: QrImageView(
              data: qrCode,
              version: QrVersions.auto,
              size: 140.w,
              gapless: false,
              backgroundColor: Colors.white.withValues(alpha: 0.9),
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
        ),
        if (copy) ...[
          Gap(16.h),
          Container(
            padding: EdgeInsets.all(4.w),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
              color: const Color.fromRGBO(
                255,
                255,
                255,
                1,
              ).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8.r),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  flex: 4,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4.w),
                    child: Text(qrCode, style: TextStyle(fontSize: 10.sp)),
                  ),
                ),
                Flexible(
                  child: _CopyButton(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: qrCode));
                      showInfoSnackBar(context, 'Wallet address copied');
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _pressed = false;

  void _setPressed(bool value) => setState(() => _pressed = value);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedOpacity(
          opacity: _pressed ? 0.7 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              color: Colors.white.withValues(alpha: 0.1),
            ),
            padding: EdgeInsets.all(4.w),
            child: SvgPicture.asset("assets/icons/Copy.svg"),
          ),
        ),
      ),
    );
  }
}

/// Confirm blocking a wallet. Pops `true` on confirm, `false`/null on
/// cancel/close. Action is reversible via "Unblock".
class _BlockConfirmDialog extends StatelessWidget {
  const _BlockConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return SealedDialog(
      title: "Block Wallet",
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Block this wallet? Their messages move to Spam and won't "
            "trigger notifications.",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Gap(24.h),
          Row(
            children: [
              Expanded(
                child: SealedCircularButton(
                  label: "Cancel",
                  onTap: () => Navigator.of(context).pop(false),
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  textColor: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              Gap(12.w),
              Expanded(
                child: SealedCircularButton(
                  label: "Block",
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class OptionDialog extends StatelessWidget {
  const OptionDialog({
    super.key,
    required this.iconAsset,
    required this.label,
    required this.actionLabel,
    required this.actionBackgroundColor,
    required this.onActionTap,
    this.iconColor,
    this.labelColor,
    this.actionTextColor,
  });

  final String iconAsset;
  final Color? iconColor;
  final String label;
  final Color? labelColor;
  final String actionLabel;
  final Color actionBackgroundColor;
  final Color? actionTextColor;
  final VoidCallback onActionTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16.r),
        color: Colors.white.withValues(alpha: 0.04),
      ),
      padding: EdgeInsets.symmetric(vertical: 16.h, horizontal: 12.w),
      child: Row(
        children: [
          SvgPicture.asset(
            iconAsset,
            colorFilter: iconColor == null
                ? null
                : ColorFilter.mode(iconColor!, BlendMode.srcIn),
          ),
          Gap(8.w),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall!.copyWith(color: labelColor),
          ),
          const Spacer(),
          ActionButton(
            label: actionLabel,
            backgroundColor: actionBackgroundColor,
            textColor: actionTextColor,
            onActionTap: onActionTap,
          ),
        ],
      ),
    );
  }
}

class ActionButton extends StatefulWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.onActionTap,
    this.textColor,
  });

  final String label;
  final Color backgroundColor;
  final Color? textColor;
  final VoidCallback onActionTap;

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _pressed = false;

  void _setPressed(bool value) => setState(() => _pressed = value);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onActionTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedOpacity(
          opacity: _pressed ? 0.7 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(100),
              color: widget.backgroundColor,
            ),
            padding: EdgeInsets.symmetric(vertical: 8.h, horizontal: 12.w),
            child: Text(
              widget.label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium!.copyWith(color: widget.textColor),
            ),
          ),
        ),
      ),
    );
  }
}
