/// ChangeTerminationFlow — three-step termination-code change reachable
/// from Settings.
///
///   1. Enter current termination code → verified via
///      `pinSecurityProvider.verifyTermination`. This path does NOT
///      trigger a wipe — wipe-on-entry only fires from the lock screen.
///   2. Enter new termination code
///   3. Confirm new termination code → `setTerminationCode` commits.
///
/// Termination is mandatory at onboarding; by the time this flow is
/// reachable from Settings the user already has a termination code
/// configured, so the gate step is always the existing termination
/// code (never the PIN).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_keypad_v2.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/success_sheet.dart';

class ChangeTerminationFlow extends ConsumerStatefulWidget {
  const ChangeTerminationFlow({super.key});

  @override
  ConsumerState<ChangeTerminationFlow> createState() =>
      _ChangeTerminationFlowState();
}

enum _Step { gate, enterNewCode, confirmNewCode }

class _ChangeTerminationFlowState extends ConsumerState<ChangeTerminationFlow> {
  static const _pinLength = 6;
  static const _busyHold = Duration(milliseconds: 350);
  static const _crossfade = Duration(milliseconds: 200);

  final List<int> _entered = [];
  _Step _step = _Step.gate;
  String _newCode = '';
  String? _error;
  bool _busy = false;

  String get _headline {
    switch (_step) {
      case _Step.gate:
        return 'Enter current termination code';
      case _Step.enterNewCode:
        return 'Change Termination Code';
      case _Step.confirmNewCode:
        return 'Confirm Termination Code';
    }
  }

  String get _subhead {
    switch (_step) {
      case _Step.gate:
        return 'Confirm your existing termination code. '
            'This will not wipe the device.';
      case _Step.enterNewCode:
        return 'Choose a different 6-digit code from your passcode.';
      case _Step.confirmNewCode:
        return 'Re-enter the new termination code.';
    }
  }

  void _onDigit(int d) {
    if (_busy) return;
    if (_entered.length >= _pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered.add(d);
      _error = null;
    });
    if (_entered.length == _pinLength) _onCodeComplete();
  }

  void _onBackspace() {
    if (_busy) return;
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _entered.removeLast());
  }

  Future<void> _onCodeComplete() async {
    final code = _entered.map((d) => d.toString()).join();

    switch (_step) {
      case _Step.gate:
        setState(() => _busy = true);
        try {
          final ok = await ref
              .read(pinSecurityProvider.notifier)
              .verifyTermination(code);
          if (!mounted) return;
          if (!ok) {
            setState(() {
              _entered.clear();
              _error = 'Incorrect termination code. Try again.';
              _busy = false;
            });
            return;
          }
          setState(() {
            _entered.clear();
            _step = _Step.enterNewCode;
            _busy = false;
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _entered.clear();
            _error = 'Something went wrong. Please try again.';
            _busy = false;
          });
        }
        return;

      case _Step.enterNewCode:
        setState(() {
          _newCode = code;
          _entered.clear();
          _step = _Step.confirmNewCode;
        });
        return;

      case _Step.confirmNewCode:
        if (code != _newCode) {
          setState(() {
            _entered.clear();
            _newCode = '';
            _error = "Codes don't match. Try again.";
            _step = _Step.enterNewCode;
          });
          return;
        }
        await _commit(code);
        return;
    }
  }

  Future<void> _commit(String code) async {
    setState(() => _busy = true);
    try {
      await ref.read(pinSecurityProvider.notifier).setTerminationCode(code);
      await Future<void>.delayed(_busyHold);
      if (!mounted) return;
      await showSuccessSheet(context, SuccessSheetKind.terminationCode);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _entered.clear();
        _error = 'Something went wrong. Please try again.';
        _busy = false;
      });
    }
  }

  void _onBackTap() {
    if (_busy) return;
    if (_step == _Step.gate) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _entered.clear();
      _error = null;
      if (_step == _Step.confirmNewCode) {
        _newCode = '';
      }
      _step = _Step.values[_step.index - 1];
    });
  }

  Future<bool> _onWillPop() async {
    if (_busy) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: SealedLayout(
        children: [
          SizedBox(
            height: 24.h,
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onBackTap,
                  child: Icon(
                    CupertinoIcons.chevron_back,
                    size: 24,
                    color: _busy
                        ? Colors.white.withValues(alpha: 0.3)
                        : Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          Gap(32.h),
          AnimatedSwitcher(
            duration: _crossfade,
            child: Column(
              key: ValueKey(_step),
              children: [
                Text(
                  _headline,
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                Gap(8.h),
                Text(
                  _subhead,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium!.copyWith(color: neutralColor),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const Spacer(),
          PinDotsRowV2(
            length: _pinLength,
            filled: _entered.length,
            values: _entered,
            showDigits: true,
            hasError: _error != null,
          ),
          Gap(16.h),
          SizedBox(
            child: Center(
              child: _error == null
                  ? const SizedBox.shrink()
                  : PinErrorLabel(text: _error!),
            ),
          ),
          const Spacer(),
          AnimatedOpacity(
            opacity: _busy ? 0.4 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: _busy,
              child: PinKeypadV2(onDigit: _onDigit, onBackspace: _onBackspace),
            ),
          ),
        ],
      ),
    );
  }
}
