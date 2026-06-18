import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Tappable row tile: leading SVG icon + label + subtitle.
/// Presses scale + fade for tactile feedback.
class ActionTile extends StatefulWidget {
  const ActionTile({
    super.key,
    required this.label,
    required this.subtitle,
    required this.assetPath,
    this.assetColor,
    this.onTap,
  });

  final String label;
  final String subtitle;
  final String assetPath;
  final Color? assetColor;
  final VoidCallback? onTap;

  @override
  State<ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<ActionTile> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.7 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 12.w),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.r),
              color: Colors.white.withValues(alpha: 0.08),
            ),
            child: Row(
              children: [
                SvgPicture.asset(
                  widget.assetPath,
                  width: 24.w,
                  height: 24.w,
                  colorFilter: widget.assetColor != null
                      ? ColorFilter.mode(widget.assetColor!, BlendMode.srcIn)
                      : null,
                ),
                Gap(12.w),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      widget.subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.displaySmall!.copyWith(color: neutralColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
