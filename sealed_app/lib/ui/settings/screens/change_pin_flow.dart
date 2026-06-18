/// ChangePinFlow — three-step PIN change reachable from Settings.
///
///   1. Enter current passcode → captured locally; not verified yet
///   2. Change passcode        → enforces new != current client-side
///   3. Confirm new passcode   → `pinSecurityProvider.changePin` commits.
///                               A wrong current PIN surfaces here as
///                               [PinIncorrectException] and we rewind to
///                               step 1 with an inline error.
///
/// Wrong-current-PIN attempts in this flow do **not** count against
/// [PinAttemptTracker.maxAttempts] (the wipe budget) — the underlying
/// `PinService.changePin` does not touch the tracker. Only lock-screen
/// attempts count toward the wipe budget.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_keypad_v2.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/success_sheet.dart';

class ChangePinFlow extends ConsumerStatefulWidget {
  const ChangePinFlow({super.key});

  @override
  ConsumerState<ChangePinFlow> createState() => _ChangePinFlowState();
}

enum _Step { enterCurrent, enterNew, confirmNew }

class _ChangePinFlowState extends ConsumerState<ChangePinFlow> {
  static const _pinLength = 6;
  static const _busyHold = Duration(milliseconds: 350);
  static const _crossfade = Duration(milliseconds: 200);

  final List<int> _entered = [];
  _Step _step = _Step.enterCurrent;
  String _currentPin = '';
  String _newPin = '';
  String? _error;
  bool _busy = false;

  String get _headline {
    switch (_step) {
      case _Step.enterCurrent:
        return 'Enter Passcode';
      case _Step.enterNew:
        return 'Change Passcode';
      case _Step.confirmNew:
        return 'Confirm New Passcode';
    }
  }

  String get _subhead {
    switch (_step) {
      case _Step.enterCurrent:
        return "Verify it's you before we change anything.";
      case _Step.enterNew:
        return 'Choose a new 6-digit passcode.';
      case _Step.confirmNew:
        return 'Re-enter the new passcode to confirm.';
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
      case _Step.enterCurrent:
        // Capture only — no verify here. A wrong current PIN surfaces at
        // commit time via PinIncorrectException from changePin(), at
        // which point we rewind to this step. Keeping verify off the
        // step-1 path removes the need for a non-tracking PIN-check call
        // site outside the unified notifier.
        setState(() {
          _currentPin = code;
          _entered.clear();
          _step = _Step.enterNew;
        });
        return;

      case _Step.enterNew:
        if (code == _currentPin) {
          setState(() {
            _entered.clear();
            _error = 'New passcode must differ from your current passcode.';
          });
          return;
        }
        // Reject if the new PIN collides with the termination code —
        // entering it at the lock screen would otherwise wipe the device
        // instead of unlocking.
        setState(() => _busy = true);
        try {
          final matchesTermination = await ref
              .read(pinSecurityProvider.notifier)
              .verifyTermination(code);
          if (!mounted) return;
          if (matchesTermination) {
            setState(() {
              _entered.clear();
              _error = 'New passcode must differ from your termination code.';
              _busy = false;
            });
            return;
          }
          setState(() {
            _newPin = code;
            _entered.clear();
            _step = _Step.confirmNew;
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

      case _Step.confirmNew:
        if (code != _newPin) {
          setState(() {
            _entered.clear();
            _newPin = '';
            _error = "Passcodes don't match. Try again.";
            _step = _Step.enterNew;
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
      await ref.read(pinSecurityProvider.notifier).changePin(_currentPin, code);
      await Future<void>.delayed(_busyHold);
      if (!mounted) return;
      await showSuccessSheet(context, SuccessSheetKind.passcode);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on PinIncorrectException {
      if (!mounted) return;
      setState(() {
        _entered.clear();
        _currentPin = '';
        _newPin = '';
        _error = 'Incorrect current passcode. Start again.';
        _step = _Step.enterCurrent;
        _busy = false;
      });
    } catch (e) {
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
    if (_step == _Step.enterCurrent) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _entered.clear();
      _error = null;
      if (_step == _Step.confirmNew) {
        _newPin = '';
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
