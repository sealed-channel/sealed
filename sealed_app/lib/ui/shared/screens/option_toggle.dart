import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

/// Generic on/off option screen.
///
/// Controlled + async: the caller owns the toggle's meaning. [initialValue]
/// seeds the displayed state, and [onChanged] runs the (possibly multi-second)
/// side effect. While [onChanged] is in flight the switch shows a busy
/// indicator and ignores interaction; once it resolves, the switch settles on
/// the value [onChanged] returns. If that returned value equals the value the
/// switch was already at (op declined / failed), the switch visually reverts.
///
/// No push / notification / permission logic lives here — the caller supplies
/// it through [onChanged], so this screen can host any boolean preference.
class OptionToggleScreen extends StatelessWidget {
  const OptionToggleScreen({
    super.key,
    required this.label,
    required this.description,
    required this.initialValue,
    required this.onChanged,
  });

  final String label;
  final String description;

  /// Current persisted value of the option.
  final bool initialValue;

  /// Runs the side effect for a requested change and returns the value the
  /// switch should end up displaying. Returning the same value the switch was
  /// already at signals a decline/failure and the switch reverts.
  final Future<bool> Function(bool requested) onChanged;

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      horizontalPadding: horizontalPadding,
      topBar: TopBar(label: label),
      children: [
        Gap(12.h),
        Row(
          children: [
            SvgPicture.asset(
              "assets/svg/contact_profile/unlock.svg",
              colorFilter: ColorFilter.mode(Colors.white.withValues(alpha: 0.9), BlendMode.srcIn),
            ),
            Gap(16.w),
            Text(
              "Enable $label",
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Spacer(),
            SealedSwitch(value: initialValue, onChanged: onChanged),
          ],
        ),
        Gap(12.h),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall!.copyWith(color: primaryColor),
        ),
        Gap(12.h),
        Text(description),
      ],
    );
  }
}

/// Controlled, async toggle switch.
///
/// [value] is the externally-owned current value. On a tap the switch
/// optimistically shows the requested value, disables itself, and awaits
/// [onChanged]; the resolved value becomes the new displayed value (reverting
/// the optimistic flip if [onChanged] returns the prior value or throws).
class SealedSwitch extends StatefulWidget {
  const SealedSwitch({super.key, required this.value, required this.onChanged});

  final bool value;

  /// Returns the value to settle on. See [OptionToggleScreen.onChanged].
  final Future<bool> Function(bool requested) onChanged;

  @override
  State<SealedSwitch> createState() => _SealedSwitchState();
}

class _SealedSwitchState extends State<SealedSwitch> {
  late bool _displayed = widget.value;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant SealedSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync to externally-driven changes only while idle; an in-flight request
    // owns the displayed value until it resolves.
    if (!_busy && widget.value != oldWidget.value) {
      _displayed = widget.value;
    }
  }

  Future<void> _handleChange(bool requested) async {
    if (_busy) return;
    final previous = _displayed;
    setState(() {
      _busy = true;
      _displayed = requested; // optimistic
    });

    bool settled = previous; // default to revert on throw
    try {
      settled = await widget.onChanged(requested);
    } catch (_) {
      settled = previous;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _displayed = settled;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Both states render inside the Switch's footprint (60x48 incl. tap
    // target) so swapping in the busy spinner never shifts the row layout.
    return SizedBox(
      width: 60,
      height: 48,
      child: Center(
        child: _busy
            ? SizedBox(
                width: 24.w,
                height: 24.w,
                child: CircularProgressIndicator(
                  strokeWidth: 2.r,
                  valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                ),
              )
            : Switch(
                value: _displayed,
                onChanged: _handleChange,
                activeTrackColor: primaryColor.withValues(alpha: 0.3),
                activeThumbColor: primaryColor,
                trackOutlineWidth: WidgetStateProperty.all(1.5),
              ),
      ),
    );
  }
}
