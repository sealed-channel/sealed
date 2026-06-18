import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';

class TopBar extends StatelessWidget {
  TopBar({super.key, this.back = true, this.onBackTap, required this.label});

  String label;
  bool back;
  Function? onBackTap;

  @override
  Widget build(BuildContext context) {
    return Container(
   
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: back ? 6.w : horizontalPadding.w,
              vertical: 6.h
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                back
                    ? Row(
                        children: [
                          SealedBackButton(
                            onTap: () {
                              if (onBackTap != null) {
                                onBackTap!();
                              } else {
                                Navigator.of(context).pop();
                              }
                            },
                          ),
                          Gap(16.w),
                        ],
                      )
                    : Center(),
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.headlineSmall!.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
          Gap(12.h),
          Container(
            width: double.infinity,
            height: 1.h,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}
