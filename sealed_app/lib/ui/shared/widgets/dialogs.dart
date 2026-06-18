import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/svg.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens the Sealed top-up page in the external browser.
Future<void> openTopUpSite() {
  return launchUrl(
    Uri.parse(SEALED_TOPUP_URL),
    mode: LaunchMode.externalApplication,
  );
}

/// Shown whenever a credit-spending action (message send, alias invitation,
/// nickname change) fails for lack of Sealed Credits. The "Top Up Credits"
/// link closes the dialog and opens [SEALED_TOPUP_URL] externally.
class CreditsRequiredDialog extends StatelessWidget {
  const CreditsRequiredDialog({super.key});

  static Future<void> show(BuildContext context) {
    return SealedDialog.show<void>(
      context: context,
      dialog: const CreditsRequiredDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SealedDialog(
      title: "Credits Required",
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SvgPicture.asset("assets/svg/alert.svg", width: 24.w),
              Gap(16.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "You don't have enough Sealed Credits to complete this action. Sending messages, alias invitations, and nickname changes each cost credits.",
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall!.copyWith(color: Colors.white),
                    ),
                    Gap(12.h),
                    Text(
                      "Top up your wallet on the Sealed website and redeem a code from Settings.",
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall!.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Gap(24.h),
          _TopUpLink(
            onTap: () {
              Navigator.of(context).pop();
              openTopUpSite();
            },
          ),
        ],
      ),
    );
  }
}

/// "Top Up Credits" link with the house 80 ms scale + opacity press feedback
/// (mirrors [SealedBackButton]).
class _TopUpLink extends StatefulWidget {
  const _TopUpLink({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_TopUpLink> createState() => _TopUpLinkState();
}

class _TopUpLinkState extends State<_TopUpLink> {
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
          child: Text(
            "Top Up Credits",
            style: Theme.of(context).textTheme.labelMedium!.copyWith(
              color: primaryColor,
              decoration: TextDecoration.underline,
              decorationColor: primaryColor,
            ),
          ),
        ),
      ),
    );
  }
}

class CreditsDialog extends StatelessWidget {
  const CreditsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return SealedDialog(
      title: "Sealed Credits",
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Action",
                style: Theme.of(
                  context,
                ).textTheme.labelSmall!.copyWith(color: Colors.white),
              ),
              Text(
                "Cost",
                style: Theme.of(
                  context,
                ).textTheme.labelSmall!.copyWith(color: Colors.white),
              ),
            ],
          ),
          Container(
            margin: EdgeInsets.symmetric(vertical: 12.h),
            width: double.infinity,
            height: 1.5.h,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          Row(
            children: [
              Text(
                "1 Normal Chat message",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(12.r),
                    topLeft: Radius.circular(12.r),
                  ),
                ),
                child: Text("1 credit", style: TextStyle(color: primaryColor)),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                "1 Alias Chat message",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.1),
                ),
                child: Text("1 credit", style: TextStyle(color: primaryColor)),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                "Nickname change",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.1),
                ),
                child: Text("1 credit", style: TextStyle(color: primaryColor)),
              ),
            ],
          ),
          Row(
            children: [
              Text("Bio change", style: Theme.of(context).textTheme.bodyMedium),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(12.r),
                    bottomRight: Radius.circular(12.r),
                  ),
                ),
                child: Text("1 credit", style: TextStyle(color: primaryColor)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
