import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/shared/theme.dart';

class PinDialog extends StatelessWidget {
  const PinDialog.request({super.key, VoidCallback? onSetCode})
    : onPressed = onSetCode,
      _variant = _Variant.request,
      _customBanner = null,
      _customTitle = null,
      _customBody = null,
      _customButtonText = null,
      _cancelText = null,
      _onCancel = null,
      _danger = false,
      _neutral = false;

  /// Success variant. Copy defaults to the PIN-setup strings; pass
  /// [bannerText]/[title]/[body]/[buttonText] to reuse the same chrome for
  /// other success moments (e.g. code redeem).
  const PinDialog.success({
    super.key,
    this.onPressed,
    String? bannerText,
    String? title,
    String? body,
    String? buttonText,
  }) : _variant = _Variant.success,
       _customBanner = bannerText,
       _customTitle = title,
       _customBody = body,
       _customButtonText = buttonText,
       _cancelText = null,
       _onCancel = null,
       _danger = false,
       _neutral = false;

  /// Generic warning variant: reuses the dialog chrome with custom copy and
  /// the non-success hero. No success banner is shown.
  ///
  /// Pass [cancelText]/[onCancel] to add a secondary button on the left; the
  /// action button then sits on the right. Set [danger] to paint the action
  /// button with [kPinErrorColor] (white label) for destructive actions.
  /// Set [neutral] for informational confirmations (e.g. "costs 1 credit"):
  /// title and hero icon render white instead of the red alert tint.
  const PinDialog.warning({
    super.key,
    required String title,
    required String body,
    required String buttonText,
    this.onPressed,
    String? cancelText,
    VoidCallback? onCancel,
    bool danger = false,
    bool neutral = false,
  }) : _variant = _Variant.warning,
       _customBanner = null,
       _customTitle = title,
       _customBody = body,
       _customButtonText = buttonText,
       _cancelText = cancelText,
       _onCancel = onCancel,
       _danger = danger,
       _neutral = neutral;

  final VoidCallback? onPressed;
  final _Variant _variant;

  // Custom copy for the warning/success variants; null = built-in strings.
  final String? _customBanner;
  final String? _customTitle;
  final String? _customBody;
  final String? _customButtonText;

  // Optional secondary (cancel) button + destructive styling, warning only.
  final String? _cancelText;
  final VoidCallback? _onCancel;
  final bool _danger;
  final bool _neutral;

  bool get _isSuccess => _variant == _Variant.success;
  bool get _isWarning => _variant == _Variant.warning;

  String get _bannerText {
    if (_customBanner != null) return _customBanner;
    return _isSuccess
        ? 'Termination code has been successfully set'
        : 'Your passcode has been successfully set';
  }

  String get _title {
    if (_isWarning) return _customTitle!;
    if (_customTitle != null) return _customTitle;
    return _isSuccess ? 'All set' : 'Termination Code';
  }

  String get _body {
    if (_isWarning) return _customBody!;
    if (_customBody != null) return _customBody;
    return _isSuccess
        ? 'You can now use secure communication'
        : 'Now you need to create a termination code, which allows you to '
              'instantly reset the app, erase local data, and protect your '
              'account in case of emergency or unauthorized access.';
  }

  String get _buttonText {
    if (_isWarning) return _customButtonText!;
    if (_customButtonText != null) return _customButtonText;
    return _isSuccess ? 'Continue' : 'Set Code';
  }

  bool get _hasCancel => _cancelText != null;

  Widget _actionButton(BuildContext context) {
    final danger = _isWarning && _danger;
    return _PressableButton(
      onTap: onPressed ?? () => Navigator.of(context).pop(),
      verticalPadding: _isSuccess ? 12.h : 8.h,
      horizontalPadding: _isSuccess ? 20.w : 16.w,
      backgroundColor: danger ? kPinErrorColor : primaryColor,
      label: _buttonText,
      labelStyle: TextStyle(
        color: danger ? Colors.white : const Color(0xFF050A0A),
        fontFamily: 'DexaPro',
        fontSize: _isSuccess ? 16.sp : 14.sp,
        height: 24 / (_isSuccess ? 16 : 14),
        letterSpacing: _isSuccess ? 0.32 : 0.336,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _cancelButton(BuildContext context) {
    return _PressableButton(
      onTap: _onCancel ?? () => Navigator.of(context).pop(),
      verticalPadding: 8.h,
      horizontalPadding: 16.w,
      backgroundColor: Colors.transparent,
      border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      label: _cancelText!,
      labelStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.9),
        fontFamily: 'DexaPro',
        fontSize: 14.sp,
        height: 24 / 14,
        letterSpacing: 0.336,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0D1110),
      insetPadding: EdgeInsets.symmetric(horizontal: 24.w),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24.r)),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 16.h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!_isWarning) _SuccessBanner(text: _bannerText),
            Padding(
              padding: EdgeInsets.symmetric(vertical: 32.h, horizontal: 24.w),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Neutral warnings (e.g. "costs 1 credit") drop the hero
                  // icon entirely — it carries no meaning there.
                  if (!(_isWarning && _neutral)) ...[
                    _HeroIcon(
                      isSuccess: _isSuccess,
                      isWarning: _isWarning && !_neutral,
                    ),
                    Gap(20.h),
                  ],
                  Text(
                    _title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _isWarning && !_neutral
                          ? kPinErrorColor.withValues(alpha: 0.9)
                          : Colors.white.withValues(alpha: 0.9),
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
              padding: EdgeInsets.symmetric(
                horizontal: _isSuccess ? 16.w : 20.w,
              ),
              child: _hasCancel
                  ? Row(
                      children: [
                        Expanded(child: _cancelButton(context)),
                        Gap(12.w),
                        Expanded(child: _actionButton(context)),
                      ],
                    )
                  : _actionButton(context),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Variant { request, success, warning }

class _PressableButton extends StatefulWidget {
  const _PressableButton({
    required this.onTap,
    required this.verticalPadding,
    required this.horizontalPadding,
    required this.label,
    required this.labelStyle,
    this.backgroundColor,
    this.border,
  });

  final VoidCallback onTap;
  final double verticalPadding;
  final double horizontalPadding;
  final String label;
  final TextStyle labelStyle;
  final Color? backgroundColor;
  final BoxBorder? border;

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
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
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedOpacity(
          opacity: _pressed ? 0.7 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              vertical: widget.verticalPadding,
              horizontal: widget.horizontalPadding,
            ),
            decoration: BoxDecoration(
              color: widget.backgroundColor ?? primaryColor,
              border: widget.border,
              borderRadius: BorderRadius.circular(9999),
            ),
            alignment: Alignment.center,
            child: Text(
              widget.label,
              textAlign: TextAlign.center,
              style: widget.labelStyle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Tappable inline text/link with the same press feedback as
/// [_PressableButton] (scale + opacity), but no pill chrome — used for
/// text-only actions like "I understand".
class _PressableLink extends StatefulWidget {
  const _PressableLink({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PressableLink> createState() => _PressableLinkState();
}

class _PressableLinkState extends State<_PressableLink> {
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
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedOpacity(
          opacity: _pressed ? 0.6 : 1.0,
          duration: const Duration(milliseconds: 100),
          // Pad the hit target beyond the bare text so the link meets the
          // 44pt-ish touch-area expectation without changing layout much.
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8.h, horizontal: 8.w),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _HeroIcon extends StatelessWidget {
  const _HeroIcon({required this.isSuccess, required this.isWarning});

  final bool isSuccess;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    if (isSuccess) {
      return Container(
        width: 32.w,
        height: 32.w,
        decoration: BoxDecoration(color: primaryColor, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(Icons.check, size: 20.w, color: const Color(0xFF050A0A)),
      );
    }
    return SvgPicture.asset(
      'assets/svg/file_close.svg',
      width: 32.w,
      height: 32.w,
      colorFilter: isWarning
          ? ColorFilter.mode(
              kPinErrorColor.withValues(alpha: 0.9),
              BlendMode.srcIn,
            )
          : null,
    );
  }
}

class _SuccessBanner extends StatelessWidget {
  const _SuccessBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(32.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, size: 20.w, color: primaryColor),
          Gap(8.w),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: primaryColor,
                fontFamily: 'DexaPro',
                fontSize: 12.sp,
                height: 20 / 12,
                letterSpacing: 0.336,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
