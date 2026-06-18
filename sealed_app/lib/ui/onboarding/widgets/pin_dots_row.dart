import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Brand error red — Figma `--error-color` / `#D31737`. Shared between
/// [PinDotsRowV2] cell borders and [PinErrorLabel].
const Color kPinErrorColor = Color(0xFFD31737);

class PinDotsRowV2 extends StatefulWidget {
  const PinDotsRowV2({
    super.key,
    required this.length,
    required this.filled,
    this.values,
    this.showDigits = true,
    this.hasError = false,
    this.loading = false,
  });

  final int length;
  final int filled;
  final List<int>? values;
  final bool showDigits;

  /// When true, every cell renders a 1px [kPinErrorColor] border — matches
  /// Figma node 1:18249 (invalid passcode state).
  final bool hasError;

  /// When true a brightness/scale pulse travels left→right across the dots on
  /// repeat — the "wave" loading state. Overrides [filled]: every cell shows a
  /// dot so the wave reads across the whole row. Pair with a busy/verifying
  /// flag (see lock screen `_busy`).
  final bool loading;

  @override
  State<PinDotsRowV2> createState() => _PinDotsRowV2State();
}

class _PinDotsRowV2State extends State<PinDotsRowV2>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.loading) _wave.repeat();
  }

  @override
  void didUpdateWidget(PinDotsRowV2 old) {
    super.didUpdateWidget(old);
    if (widget.loading && !_wave.isAnimating) {
      _wave.repeat();
    } else if (!widget.loading && _wave.isAnimating) {
      _wave
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  /// Bell-shaped pulse for dot [i] at wave phase [t] (0..1). The crest sweeps
  /// across indices; each dot peaks as the crest passes it, then decays.
  double _pulse(int i, double t) {
    // Crest position spans slightly past both ends so edge dots fully animate.
    final crest = t * (widget.length + 1) - 0.5;
    final d = (i - crest).abs();
    // Cosine lobe, zero outside one cell of the crest.
    if (d >= 1.0) return 0;
    return (math.cos(d * math.pi) + 1) / 2;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(widget.length, (i) {
        final isFilled = widget.loading || i < widget.filled;
        return Container(
          height: 48.h,
          width: 48.h,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withValues(alpha: 0.08),
            border: widget.hasError
                ? Border.all(color: kPinErrorColor)
                : null,
          ),
          child: !isFilled
              ? null
              : widget.loading
              ? AnimatedBuilder(
                  animation: _wave,
                  builder: (context, _) {
                    final p = _pulse(i, _wave.value);
                    return Transform.scale(
                      scale: 0.8 + 0.4 * p,
                      child: Container(
                        width: 12.w,
                        height: 12.w,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(
                            alpha: 0.3 + 0.6 * p,
                          ),
                        ),
                      ),
                    );
                  },
                )
              : widget.showDigits &&
                    widget.values != null &&
                    i < widget.values!.length
              ? Text(
                  '${widget.values![i]}',
                  style: Theme.of(
                    context,
                  ).textTheme.headlineSmall?.copyWith(color: Colors.white),
                )
              : Container(
                  width: 12.w,
                  height: 12.w,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
        );
      }),
    );
  }
}

/// Inline invalid-code message — alert icon + red text. Figma node 1:18262.
class PinErrorLabel extends StatelessWidget {
  const PinErrorLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SvgPicture.asset(
          "assets/svg/alert.svg",
          colorFilter: ColorFilter.mode(kPinErrorColor, BlendMode.srcIn),
        ),
        SizedBox(width: 8.w),
        Text(
          text,
          style: TextStyle(
            color: kPinErrorColor,
            fontSize: 12.sp,
            height: 20 / 12,
            letterSpacing: 0.336,
          ),
        ),
      ],
    );
  }
}
