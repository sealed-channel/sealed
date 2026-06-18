import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_keypad_v2.dart';
import 'package:sealed_app/ui/onboarding/widgets/termination_dialog.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/loading_screens.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';

enum PinSetupMode { pin, termination }

enum _Step { create, confirm }

class PinSetupScreenV2 extends ConsumerStatefulWidget {
  const PinSetupScreenV2({
    super.key,
    this.mode = PinSetupMode.pin,
    this.mandatory = true,
    this.referencePin,
  });

  final PinSetupMode mode;
  final bool mandatory;
  final String? referencePin;

  @override
  ConsumerState<PinSetupScreenV2> createState() => _PinSetupScreenV2State();
}

class _PinSetupScreenV2State extends ConsumerState<PinSetupScreenV2> {
  static const _pinLength = 6;
  static const _crossfade = Duration(milliseconds: 200);

  final List<int> _entered = [];
  _Step _step = _Step.create;
  String _firstCode = '';
  String? _error;
  bool _busy = false;

  // Built once and reused so per-keystroke setState (which only changes the
  // dots row) doesn't rebuild the 12 animated keys. Flutter skips a child
  // subtree when the widget instance is identical — keeps fast typing snappy
  // on old devices.
  late final Widget _keypad = PinKeypadV2(
    onDigit: _onDigit,
    onBackspace: _onBackspace,
  );

  // Bumped on every digit/backspace so only the dots+error region rebuilds —
  // the Scaffold, headline and keypad stay put. Keeps fast typing from
  // queueing behind a full-screen rebuild per keystroke on old devices.
  final ValueNotifier<int> _entryTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _entryTick.dispose();
    super.dispose();
  }

  String get _headline {
    switch (widget.mode) {
      case PinSetupMode.pin:
        return _step == _Step.create ? 'Create Passcode' : 'Confirm Passcode';
      case PinSetupMode.termination:
        return _step == _Step.create
            ? 'Create Termination Code'
            : 'Confirm Termination Code';
    }
  }

  String get _subhead {
    switch (widget.mode) {
      case PinSetupMode.pin:
        return _step == _Step.create
            ? 'Create a secure 6-digit passcode to protect your account.'
            : 'Re-enter the same passcode.';
      case PinSetupMode.termination:
        return _step == _Step.create
            ? 'Choose a different 6-digit code from your passcode.'
            : 'Re-enter the termination code.';
    }
  }

  bool get _showBack {
    if (_step == _Step.confirm) return true;
    // Create step: termination is always mandatory, hide chevron.
    if (widget.mode == PinSetupMode.termination) return false;
    // Mandatory PIN setup sits on top of the live app shell — there is
    // nowhere to go back to, so popping would drop the user into the app
    // with no passcode set. Hide the chevron.
    return !widget.mandatory;
  }

  // ─── Entry buffer ────────────────────────────────────────────────────────

  void _onDigit(int d) {
    if (_busy) return;
    if (_entered.length >= _pinLength) return;
    HapticFeedback.selectionClick();
    _entered.add(d);
    _error = null;
    _entryTick.value++; // rebuilds only the dots+error region
    if (_entered.length == _pinLength) {
      _onCodeComplete();
    }
  }

  void _onBackspace() {
    if (_busy) return;
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    _entered.removeLast();
    _entryTick.value++; // rebuilds only the dots+error region
  }

  // ─── Step machine ────────────────────────────────────────────────────────

  Future<void> _onCodeComplete() async {
    final code = _entered.map((d) => d.toString()).join();

    if (_step == _Step.create) {
      if (widget.mode == PinSetupMode.termination &&
          code == widget.referencePin) {
        setState(() {
          _entered.clear();
          _error = 'Termination code must differ from your passcode.';
        });
        return;
      }
      // Pulse + gate the keypad across the crossfade so overflow taps from
      // fast typing don't bleed into the now-empty Confirm buffer (worse on
      // slow devices where the crossfade widens the window).
      setState(() {
        _firstCode = code;
        _entered.clear();
        _step = _Step.confirm;
        _busy = true;
      });
      await Future<void>.delayed(_crossfade);
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }

    // _Step.confirm
    if (code != _firstCode) {
      setState(() {
        _entered.clear();
        _firstCode = '';
        _step = _Step.create;
        _error = widget.mode == PinSetupMode.pin
            ? "Passcodes don't match. Try again."
            : "Termination codes don't match.";
      });
      return;
    }

    // Match. Persist.
    setState(() => _busy = true);
    // Let the pulsing-keypad frame paint before PBKDF2/scrypt runs on the main
    // isolate and blocks repaints for hundreds of ms (else the UI looks frozen
    // on old devices).
    await WidgetsBinding.instance.endOfFrame;
    try {
      if (widget.mode == PinSetupMode.pin) {
        await ref.read(pinSecurityProvider.notifier).setPin(code);
        if (!mounted) return;
        setState(() => _busy = false);
        await _runTerminationFlow();
      } else {
        await ref.read(pinSecurityProvider.notifier).setTerminationCode(code);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (!mounted) return;
      // Termination is mandatory — never exit on error. Reset to create and
      // surface a generic error.
      setState(() {
        _entered.clear();
        _firstCode = '';
        _step = _Step.create;
        _error = 'Something went wrong. Please try again.';
        _busy = false;
      });
    }
  }

  Future<void> _runTerminationFlow() async {
    // 1. Mandatory request dialog — only Set Code exits.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => WillPopScope(
        onWillPop: () async => false,
        child: PinDialog.request(
          onSetCode: () => Navigator.of(dialogCtx).pop(),
        ),
      ),
    );

    if (!mounted) return;
    // 2. Mandatory termination screen — only successful set pops.
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PinSetupScreenV2(
          mode: PinSetupMode.termination,
          mandatory: true,
          referencePin: _firstCode,
        ),
      ),
    );
    _firstCode = '';

    if (!mounted) return;
    // 3. Mandatory success dialog.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => WillPopScope(
        onWillPop: () async => false,
        child: PinDialog.success(
          onPressed: () => Navigator.of(dialogCtx).pop(),
        ),
      ),
    );

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ─── Back-arrow rules ────────────────────────────────────────────────────

  void _onBackTap() {
    if (_busy) return;
    if (_step == _Step.confirm) {
      setState(() {
        _entered.clear();
        _firstCode = '';
        _step = _Step.create;
        _error = null;
      });
      return;
    }
    // Create step: only PIN-mode non-mandatory reaches here (termination
    // hides the chevron via _showBack).
    if (widget.mode == PinSetupMode.termination) return;
    // Defense in depth: never pop a mandatory setup off the live app shell,
    // even if the chevron is somehow rendered. Mirrors _onWillPop.
    if (widget.mandatory) return;
    Navigator.of(context).pop();
  }

  Future<bool> _onWillPop() async {
    if (_busy) return false;
    if (_step == _Step.confirm) {
      setState(() {
        _entered.clear();
        _firstCode = '';
        _step = _Step.create;
        _error = null;
      });
      return false;
    }
    // Create step.
    if (widget.mode == PinSetupMode.termination) return false;
    if (widget.mandatory) return false;
    return true;
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: SealedLayout(
        children: [
          SizedBox(
            height: 24.h,
            child: _showBack
                ? Row(
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
                  )
                : null,
          ),
          Gap(32.h),
          AnimatedSwitcher(
            duration: _crossfade,
            child: Column(
              key: ValueKey('${widget.mode}-$_step'),
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
          Spacer(),
          // Only this region reacts to keystrokes (via _entryTick); step/error
          // transitions still go through setState and rebuild it too.
          ValueListenableBuilder<int>(
            valueListenable: _entryTick,
            builder: (_, _, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
              ],
            ),
          ),
          Spacer(),
          IgnorePointer(
            ignoring: _busy,
            // While busy the keypad pulses (opacity + scale) instead of
            // dimming abruptly — same affordance as the lock screen unlock,
            // and it animates over both the create→confirm flip and the
            // PBKDF2/scrypt persist (which blocks repaints on old devices).
            child: _busy ? PulsingKeypad(child: _keypad) : _keypad,
          ),
        ],
      ),
    );
  }
}
