import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class PinKeypadV2 extends StatelessWidget {
  const PinKeypadV2({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.onDot,
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onDot;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 224.w, maxWidth: 304.w),
      child: Padding(
        padding: EdgeInsets.only(top: 8.h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // No Gap() between rows: the 8.h vertical spacing is folded into each
          // key's hit area instead (see _KeyBase vertical padding). Row pitch is
          // unchanged so digits don't move — only the tappable region grows.
          children: [
            _row([_digit(1), _digit(2), _digit(3)]),
            _row([_digit(4), _digit(5), _digit(6)]),
            _row([_digit(7), _digit(8), _digit(9)]),
            _row([
              _Dot(onTap: onDot),
              _digit(0),
              _BackspaceKey(onTap: onBackspace),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _digit(int value) =>
      _DigitKey(value: value, onTap: () => onDigit(value));

  Widget _row(List<Widget> children) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: children,
  );
}

class _KeyBase extends StatefulWidget {
  const _KeyBase({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_KeyBase> createState() => _KeyBaseState();
}

class _KeyBaseState extends State<_KeyBase> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      // Transparent vertical padding replaces the old inter-row Gap(8.h): it
      // enlarges the tappable region (opaque GestureDetector) without moving
      // the glyph, which stays centered in the unchanged 64x64 visual box.
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 4.h),
        child: AnimatedOpacity(
          duration: Duration(milliseconds: 90),
          opacity: _pressed ? 0.7 : 1,
          child: AnimatedScale(
            scale: _pressed ? 0.92 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
              width: 64.w,
              height: 64.w,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.transparent,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({required this.value, required this.onTap});

  final int value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _KeyBase(
      onTap: onTap,
      child: Text(
        '$value',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.9),
          fontSize: 24.sp,
          fontWeight: FontWeight.w500,
          height: 1.0,
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _KeyBase(
      onTap: onTap,
      child: Container(
        width: 8.w,
        height: 8.w,
        decoration:  BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.0),
        ),
      ),
    );
  }
}

class _BackspaceKey extends StatelessWidget {
  const _BackspaceKey({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _KeyBase(
      onTap: onTap,
      child: Icon(Icons.backspace_outlined, color: Colors.white.withValues(alpha: 0.9), size: 24.sp),
    );
  }
}
