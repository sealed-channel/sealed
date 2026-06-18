import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/dialogs.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// Invitation pitch + Send. Shown via [showDialog]; sends an alias invite
/// envelope to [contactWallet] (reusing the canonical onboarding path), with an
/// in-button spinner while sending. Pops true on success.
class AliasInvitationDialog extends ConsumerStatefulWidget {
  const AliasInvitationDialog({
    super.key,
    required this.contactWallet,
    this.contactUsername,
  });

  final String contactWallet;
  final String? contactUsername;

  @override
  ConsumerState<AliasInvitationDialog> createState() =>
      _AliasInvitationDialogState();
}

class _AliasInvitationDialogState extends ConsumerState<AliasInvitationDialog> {
  bool _sending = false;

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final onboarding = await ref.read(aliasOnboardingServiceProvider.future);
      final messages = ref.read(messagesNotifierProvider.notifier);
      final alias = widget.contactUsername ?? 'Alias Chat';

      // Canonical envelope path: no on-chain write; single DM carries key material.
      final result = await onboarding.createInvitationEnvelope(alias: alias);
      await messages.sendMessageBytes(
        recipientWallet: widget.contactWallet,
        plaintextBytes: result.envelopeBytes,
      );
      await messages.refresh();
      // refresh() reloads conversations but does NOT bump the refresh counter
      // that creatorPendingInvitesProvider watches — bump it so the creator
      // "waiting for acceptance" row appears immediately, not after next sync.
      messages.bumpRefresh();

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      final err = SendMessageException.fromError(e);
      if (err.kind == SendMessageErrorKind.insufficientBalance) {
        await CreditsRequiredDialog.show(context);
      } else {
        showErrorSnackBar(context, 'Failed to send invitation');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SealedDialog(
      title: "Alias Chat invitation",
      closeEnabled: !_sending,
      onClose: () => Navigator.of(context).pop(false),
      bodyPadding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 16.h,
      ),
      child: Column(
        children: [
          Text(
            "Chat Alias allows you to create a private alias for this conversation. Your identity remains hidden while you communicate securely.",
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
          Gap(24.h),
          FeatureRow(
            iconAsset: 'assets/svg/contact_profile/shield.svg',
            title: "Protect your identity",
            subtitle: "wallet address and personal identity hidden",
          ),
          Gap(12.h),
          FeatureRow(
            iconAsset: 'assets/svg/contact_profile/eye.svg',
            title: "Communicate privately",
            subtitle: "exchange messages without exposing",
          ),
          Gap(12.h),
          FeatureRow(
            iconAsset: 'assets/svg/contact_profile/close.svg',
            title: "Alias can be revoked forever",
            subtitle: "full control by removing the connection",
          ),
          Gap(24.h),
          Row(
            children: [
              Expanded(
                child: SealedCircularButton(
                  label: "Cancel",
                  onTap: _sending
                      ? () {}
                      : () => Navigator.of(context).pop(false),
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  textColor: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              Gap(12.w),
              Expanded(
                child: SealedCircularButton(
                  label: "Send Invitation",
                  loading: _sending,
                  onTap: _send,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class FeatureRow extends StatelessWidget {
  const FeatureRow({
    required this.iconAsset,
    required this.title,
    required this.subtitle,
  });

  final String iconAsset;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SvgPicture.asset(iconAsset, width: 20.w),
        Gap(16.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.labelMedium),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
