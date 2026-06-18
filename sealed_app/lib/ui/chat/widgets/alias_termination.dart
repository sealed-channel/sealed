import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart'
    show kPinErrorColor;
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';

/// Confirm permanent deletion of an alias chat. Shown via [showDialog]; pops
/// true on "Delete", false/null on Cancel/close.
class AliasTerminationDialog extends StatelessWidget {
  const AliasTerminationDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return SealedDialog(
      title: "Alias Chat Termination",
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        children: [
          Row(
            children: [
              SvgPicture.asset(
                'assets/svg/alert.svg',
                colorFilter: ColorFilter.mode(kPinErrorColor, BlendMode.srcIn),
                width: 20.w,
              ),
              Gap(12.w),
              Text(
                "You can’t undo this action",
                style: Theme.of(
                  context,
                ).textTheme.labelMedium!.copyWith(color: kPinErrorColor),
              ),
            ],
          ),
          Gap(8.h),
          Text("This chat cannot be restored after this deletion."),
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
                  label: "Delete",
                  backgroundColor: kPinErrorColor,
                  textColor: Colors.white.withValues(alpha: 0.9),
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
