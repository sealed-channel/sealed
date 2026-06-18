import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Single row in the search-results list. Used for both username hits and
/// wallet-address fallback hits.
class SearchHitRow extends StatefulWidget {
  const SearchHitRow({
    super.key,
    required this.primary,
    required this.secondary,
    required this.avatarInitial,
    required this.onTap,
    this.badge,
  });

  final String primary;
  final String secondary;
  final String avatarInitial;
  final String? badge;
  final VoidCallback onTap;

  @override
  State<SearchHitRow> createState() => _SearchHitRowState();
}

class _SearchHitRowState extends State<SearchHitRow> {
  bool isPressed = false;
  @override
  Widget build(BuildContext context) {
    return Container(
      child: GestureDetector(
        onTapDown: (_) {
          setState(() {
            isPressed = true;
          });
        },
        onTapUp: (_) {
          setState(() {
            isPressed = false;
          });
        },
        onTapCancel: () {
          setState(() {
            isPressed = false;
          });
        },
        onTap: widget.onTap,
        child: Material(
          color: Colors.transparent,
          child: AnimatedOpacity(
            opacity: isPressed ? 0.7 : 1,
              duration: Duration(milliseconds: 100),
            child: AnimatedScale(
              scale: isPressed ? 0.97 : 1,
              duration: Duration(milliseconds: 100),
              child: Container(
                padding: EdgeInsets.all(12.w),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20.w,
                      backgroundColor: const Color(0xFF191D1D),
                      child: Text(
                        widget.avatarInitial,
                        style: TextStyle(
                          color: primaryColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Gap(16.w),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.primary,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 14.sp,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (widget.badge != null) ...[
                                Gap(6.w),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 6.w,
                                    vertical: 2.h,
                                  ),
                                  decoration: BoxDecoration(
                                    color: primaryColor.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    widget.badge!,
                                    style: TextStyle(
                                      color: primaryColor,
                                      fontSize: 10.sp,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          SizedBox(height: 2.h),
                          Text(
                            widget.secondary,
                            style: TextStyle(
                              color: primaryColor,
                              fontSize: 12.sp,
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
