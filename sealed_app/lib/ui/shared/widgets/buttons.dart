import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/shared/theme.dart';

class SealedBackButton extends StatefulWidget {
  const SealedBackButton({super.key, required this.onTap});

  /// Nullable so callers can disable the button (e.g. while a logout/wipe is
  /// in flight) by passing null. GestureDetector treats a null onTap as
  /// disabled. Previously callers force-unwrapped a nullable into this
  /// non-null slot, which threw "Null check operator used on a null value"
  /// and painted a full-screen red error during logout.
  final VoidCallback? onTap;

  @override
  State<SealedBackButton> createState() => _SealedBackButtonState();
}

class _SealedBackButtonState extends State<SealedBackButton> {
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
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.all(8.w),
              child: SvgPicture.asset("assets/svg/back.svg", width: 20.w),
            ),
          ),
        ),
      ),
    );
  }
}

class SealedCircularButton extends StatefulWidget {
  SealedCircularButton({
    super.key,
    required this.label,
    required this.onTap,
    this.backgroundColor,
    this.textColor,
    this.enableGlassBlur = false,
    this.fullWidth = true,
    this.loading = false,
    this.padding = const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
    this.textStyle = const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      fontFamily: 'DexaPro',
      height: 1.66,
    ),
  });

  final String label;
  final VoidCallback onTap;
  final Color? backgroundColor;
  final bool fullWidth;
  final Color? textColor;
  TextStyle textStyle;
  EdgeInsets padding;

  /// When true, shows an in-button spinner and ignores taps.
  final bool loading;

  /// When true, renders a liquid-glass background blur behind the button
  /// (translucent fill + backdrop blur). Defaults to false.
  final bool enableGlassBlur;

  @override
  State<SealedCircularButton> createState() => _SealedCircularButtonState();
}

class _SealedCircularButtonState extends State<SealedCircularButton> {
  bool _isPressed = false;

  void _setPressed(bool value) => setState(() => _isPressed = value);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) {
        _setPressed(false);
        if (!widget.loading) widget.onTap();
      },
      onTapCancel: () => _setPressed(false),
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedOpacity(
          opacity: _isPressed ? 0.8 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: _buildButton(context),
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context) {
    final borderRadius = BorderRadius.circular(100);

    if (!widget.enableGlassBlur) {
      return Container(
        width: widget.fullWidth ? double.infinity : null,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? primaryColor,
          borderRadius: borderRadius,
        ),
        child: _buildLabel(context),
      );
    }

    // Liquid-glass: backdrop blur behind a translucent fill.
    final baseColor = widget.backgroundColor ?? primaryColor;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          width: widget.fullWidth ? double.infinity : null,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: baseColor.withValues(alpha: 0.08),
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: _buildLabel(context),
        ),
      ),
    );
  }

  Widget _buildLabel(BuildContext context) {
    final color = widget.textColor ?? Colors.black;
    if (widget.loading) {
      return Center(
        child: SizedBox(
          width: 20.w,
          height: 20.w,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
      );
    }
    return Center(
      child: Text(widget.label, style: widget.textStyle.copyWith(color: color)),
    );
  }
}
