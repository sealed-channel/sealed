/// SuccessSheet — Figma 1:18285 modal bottom sheet shown after a
/// settings-side credential change (passcode or termination code)
/// commits successfully. Copy is selected by [SuccessSheetKind]; visual
/// is identical across variants.
library;

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/shared/theme.dart';

enum SuccessSheetKind { passcode, terminationCode }

/// Show the success sheet and return a future that resolves when it is
/// dismissed (Continue tap, swipe-down, or tap-outside).
Future<void> showSuccessSheet(BuildContext context, SuccessSheetKind kind) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => SuccessSheet(kind: kind),
  );
}

class SuccessSheet extends StatelessWidget {
  const SuccessSheet({super.key, required this.kind});

  final SuccessSheetKind kind;

  String get _title {
    switch (kind) {
      case SuccessSheetKind.passcode:
        return 'Passcode';
      case SuccessSheetKind.terminationCode:
        return 'Termination code';
    }
  }

  String get _body {
    switch (kind) {
      case SuccessSheetKind.passcode:
        return 'Passcode successfully changed';
      case SuccessSheetKind.terminationCode:
        return 'Termination code successfully changed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.w),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF0D1110),
            borderRadius: BorderRadius.circular(24.r),
          ),
          padding: EdgeInsets.symmetric(vertical: 16.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 32.h, horizontal: 24.w),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 32.w,
                      height: 32.w,
                      decoration: BoxDecoration(
                        color: primaryColor,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.check,
                        size: 20.w,
                        color: const Color(0xFF050A0A),
                      ),
                    ),
                    Gap(20.h),
                    Text(
                      _title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontFamily: 'DexaPro',
                        fontSize: 20.sp,
                        height: 24 / 20,
                        letterSpacing: 0.28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Gap(8.h),
                    Text(
                      _body,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: const Color(0xFFD5D9D4),
                        fontFamily: 'DexaPro',
                        fontSize: 14.sp,
                        height: 24 / 14,
                        letterSpacing: 0.336,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 32.w),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _ContinueButton(
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueButton extends StatefulWidget {
  const _ContinueButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedOpacity(
        opacity: _pressed ? 0.7 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12.h),
          child: Text(
            'Continue',
            style: TextStyle(
              color: primaryColor,
              fontFamily: 'DexaPro',
              fontSize: 16.sp,
              height: 24 / 16,
              letterSpacing: 0.32,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
