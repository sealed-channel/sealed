import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/shared/theme.dart';

class AliasInvitation extends StatefulWidget {
  const AliasInvitation({
    super.key,
    required this.fromLabel,
    required this.timeLabel,
    required this.onTap,
  });

  /// Who the invite is from (sender wallet or resolved username).
  final String fromLabel;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  State<AliasInvitation> createState() => _AliasInvitationState();
}

class _AliasInvitationState extends State<AliasInvitation> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 100),
        opacity: _pressed ? 0.6 : 1.0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 100),
          scale: _pressed ? 0.98 : 1.0,
          child: Material(
            child: Container(
              margin: EdgeInsets.symmetric(),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16.r),
                color: primaryColor.withValues(alpha: 0.1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 20.w,
                    backgroundColor: primaryColor,
                    child: SvgPicture.asset(
                      "assets/svg/chats/alias_invitation.svg",
                      width: 24.w,
                    ),
                  ),
                  Gap(16.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Alias Chat invitation",
                          style: TextStyle(
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w500,
                            height: 1.1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2.h),

                        Text(
                          "from ${widget.fromLabel}",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.center,

                    children: [
                      Text(
                        widget.timeLabel,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall!.copyWith(color: primaryColor),
                      ),
                      Gap(6.w),
                      SvgPicture.asset("assets/svg/chats/clock.svg"),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
