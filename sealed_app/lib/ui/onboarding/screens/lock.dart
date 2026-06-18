import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';
import 'package:sealed_app/ui/navigation/navigator_key.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/onboarding/widgets/termination_dialog.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_keypad_v2.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/loading_screens.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';

class LockScreenV2 extends ConsumerStatefulWidget {
  const LockScreenV2({
    super.key,
    this.reauth = false,
    this.title,
    this.subtitle,
  });

  /// Re-auth mode: pushed on top of an already-unlocked session to confirm
  /// the user before revealing a sensitive view (e.g. recovery phrase before
  /// logout). When true:
  ///  - PIN is verified via `PinService.verifyAndUnwrap` directly — wrong
  ///    attempts do NOT count against the wipe budget (settings-flow
  ///    convention; matches `changePin`).
  ///  - Termination duress check is skipped.
  ///  - "I forgot my passcode" affordance is hidden.
  ///  - A back-arrow is shown; success pops the route with `true`.
  final bool reauth;

  /// Override headline. Defaults to "Welcome back" (unlock) or
  /// "Enter Passcode" (reauth).
  final String? title;

  /// Override subheading. Defaults to "Log in to your account" (unlock) or
  /// "Confirm your passcode to continue." (reauth).
  final String? subtitle;

  @override
  ConsumerState<LockScreenV2> createState() => _LockScreenV2State();
}

class _LockScreenV2State extends ConsumerState<LockScreenV2> {
  static const _pinLength = 6;

  /// Re-auth (reveal-recovery-phrase / settings gate) attempt cap. Unlike the
  /// unlock path this does NOT share the duress/wipe budget — it never wipes.
  /// It is a self-contained in-memory session counter that simply refuses to
  /// run any more Argon2id derivations after [_reauthMaxAttempts] wrong codes,
  /// so an attacker holding the unlocked phone can't brute-force the seed via
  /// unlimited ~500ms offline guesses. Resets when the screen is rebuilt
  /// (i.e. a fresh re-auth prompt), which is the desired "per-session" scope.
  static const int _reauthMaxAttempts = 5;
  int _reauthFailures = 0;

  final List<int> _entered = [];
  String? _error;
  bool _busy = false;
  bool _terminating = false;

  // Built once and reused so per-keystroke setState (which only changes the
  // dots row) doesn't rebuild the 12 animated keys. Flutter skips a child
  // subtree when the widget instance is identical — keeps fast typing snappy
  // on old devices.
  late final Widget _keypad = PinKeypadV2(
    onDigit: _onDigit,
    onBackspace: _onBackspace,
  );

  // Bumped on every digit/backspace so only the dots+status region rebuilds —
  // the Scaffold, headline and keypad stay put. Keeps fast typing from
  // queueing behind a full-screen rebuild per keystroke on old devices.
  final ValueNotifier<int> _entryTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _entryTick.dispose();
    super.dispose();
  }

  void _onDigit(int d) {
    if (_busy) return;
    if (_entered.length >= _pinLength) return;
    HapticFeedback.selectionClick();
    _entered.add(d);
    _error = null;
    _entryTick.value++; // rebuilds only the dots+status region
    if (_entered.length == _pinLength) _submit();
  }

  void _onBackspace() {
    if (_busy) return;
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    _entered.removeLast();
    _entryTick.value++; // rebuilds only the dots+status region
  }

  Future<void> _submit() async {
    final code = _entered.map((d) => d.toString()).join();
    setState(() => _busy = true);
    // Let the busy-state frame paint (pulsing keypad + spinner) before we run
    // PBKDF2/scrypt on the main isolate, which blocks repaints for ~hundreds
    // of ms and would otherwise make the UI appear frozen.
    await WidgetsBinding.instance.endOfFrame;

    if (widget.reauth) {
      try {
        await _submitReauth(code);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    // On a successful unlock we deliberately KEEP _busy=true: the session is
    // now unlocked but AppShell still has to resolve wallet/keys/user.
    // SessionLockGate holds this lock overlay above the loading AppShell until
    // content is ready, and the keypad keeps pulsing the whole time. Clearing
    // _busy would make the keypad look idle/interactive during that window.
    var keepBusy = false;
    try {
      final notifier = ref.read(pinSecurityProvider.notifier);

      final isTerm = await notifier.verifyTermination(code);
      if (isTerm) {
        await _wipeAndExit(isDuress: true);
        return;
      }

      final ok = await notifier.confirmAndUnlock(code);
      if (ok) {
        keepBusy = true;
        return;
      }
      await _onWrongPin();
    } finally {
      if (mounted && !keepBusy) setState(() => _busy = false);
    }
  }

  Future<void> _submitReauth(String code) async {
    // Hard cap before we even derive: once the per-session budget is spent we
    // stop running the KDF entirely, so the reveal-recovery-phrase gate can't
    // be brute-forced offline. No wipe — this is a non-destructive lockout.
    if (_reauthFailures >= _reauthMaxAttempts) {
      if (!mounted) return;
      setState(() {
        _entered.clear();
        _error = 'Too many attempts. Close and try again later.';
      });
      return;
    }
    try {
      await ref.read(pinServiceProvider).verifyAndUnwrap(code);
      if (!mounted) return;
      _reauthFailures = 0;
      Navigator.of(context).pop(true);
    } on PinIncorrectException {
      _reauthFailures++;
      Log.d('reauth: wrong passcode ($_reauthFailures/$_reauthMaxAttempts)');
      if (!mounted) return;
      final spent = _reauthFailures >= _reauthMaxAttempts;
      setState(() {
        _entered.clear();
        _error = spent
            ? 'Too many attempts. Close and try again later.'
            : 'Incorrect passcode';
      });
    } catch (_) {
      // Infrastructure fault (KDF blowup) — not a guess, so don't burn budget.
      if (!mounted) return;
      setState(() {
        _entered.clear();
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  Future<void> _onWrongPin() async {
    final state = ref.read(pinSecurityProvider).value;
    final count = state?.attemptCount ?? 0;
    if (!mounted) return;

    if (count >= PinAttemptTracker.maxAttempts) {
      await _wipeAndExit(isDuress: false, alreadyWiped: true);
      return;
    }

    setState(() {
      _entered.clear();
      _error = 'Incorrect passcode';
    });

    if (count == PinAttemptTracker.maxAttempts - 1) {
      await _showFinalAttemptWarning();
    }
  }

  Future<void> _showFinalAttemptWarning() async {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => PinDialog.warning(
        title: 'Final attempt',
        body:
            'One more wrong passcode will permanently erase all messages, alias '
            'keys, and your wallet from this device. There is no recovery.',
        buttonText: 'Got it',
        danger: true,
        onPressed: () => Navigator.of(dialogCtx).pop(),
      ),
    );
  }

  Future<void> _wipeAndExit({
    required bool isDuress,
    bool alreadyWiped = false,
  }) async {
    if (!mounted) return;
    setState(() {
      _entered.clear();
      if (isDuress) {
        // Duress: no red error border; show "Terminating app…" note under the
        // spinner instead. Keep _error null so PinDotsRowV2.hasError stays
        // false.
        _terminating = true;
        _error = null;
      } else {
        _error = 'Incorrect passcode';
      }
    });
    if (!alreadyWiped) {
      await ref.read(pinSecurityProvider.notifier).wipeNow();
    }
    if (!mounted) return;
    // Pop the ROOT navigator explicitly: in the locked state this screen is
    // mounted inside SessionLockGate's own Navigator ABOVE the root one, so
    // Navigator.of(context) would only act on the lock layer and leave stale
    // routes (e.g. an open chat) on the real stack after the wipe.
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
  }

  Future<void> _onForgotPasscode() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => PinDialog.warning(
        title: 'No passcode recovery',
        body:
            'Your passcode cannot be recovered. To regain access you must erase '
            'this device and restore from your 24-word recovery phrase. All local '
            'messages, alias keys, and the wallet on this device will be wiped.',
        buttonText: 'Log Out',
        danger: true,
        onPressed: () => Navigator.of(ctx).pop(true),
        cancelText: 'Cancel',
        onCancel: () => Navigator.of(ctx).pop(false),
      ),
    );
    if (confirmed != true) return;
    await _wipeAndExit(isDuress: false);
  }

  @override
  Widget build(BuildContext context) {
    final reauth = widget.reauth;
    final title = widget.title ?? (reauth ? 'Enter Passcode' : 'Welcome back');
    final subtitle =
        widget.subtitle ??
        (reauth
            ? 'Confirm your passcode to continue.'
            : 'Log in to your account');
    return SealedLayout(
      children: [
        if (reauth)
          SizedBox(
            height: 40.h,
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _busy ? null : () => Navigator.of(context).pop(false),
                  child: SizedBox(
                    width: 40.w,
                    height: 40.h,
                    child: Icon(
                      CupertinoIcons.chevron_back,
                      size: 24,
                      color: _busy
                          ? Colors.white.withValues(alpha: 0.3)
                          : Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          Gap(40.h),
          Container(
            width: 40.w,
            height: 40.w,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
            ),
            alignment: Alignment.center,
            child: Icon(
              CupertinoIcons.person_fill,
              size: 20.sp,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ],
        Gap(24.h),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        Gap(8.h),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(color: neutralColor),
        ),
        Gap(24.h),
        // Only this region reacts to keystrokes (via _entryTick); error/
        // terminating transitions still go through setState and rebuild it too.
        ValueListenableBuilder<int>(
          valueListenable: _entryTick,
          builder: (_, _, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PinDotsRowV2(
                length: _pinLength,
                filled: _entered.length,
                showDigits: false,
                hasError: _error != null,
                loading: _busy && _error == null,
              ),
              Container(
                margin: EdgeInsets.only(top: 24.h),
                child: Center(
                  child: _terminating
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18.w,
                              height: 18.w,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                            Gap(8.h),
                            Text(
                              'Terminating app…',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 12.sp,
                                height: 20 / 12,
                                letterSpacing: 0.336,
                              ),
                            ),
                          ],
                        )
                      : _error == null
                      ? const SizedBox.shrink()
                      : PinErrorLabel(text: _error!),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        IgnorePointer(
          ignoring: _busy,
          // While verifying/loading the keypad pulses (opacity + scale) as the
          // progress indicator; idle it sits at full opacity. The pulse keeps
          // running after a successful unlock — _busy stays true until this
          // screen unmounts — so the keypad animates over the loading AppShell
          // instead of cutting to a separate loading screen. See _submit.
          child: _busy ? PulsingKeypad(child: _keypad) : _keypad,
        ),
        if (!reauth)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onForgotPasscode,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Text(
                'I forgot my passcode',
                style: TextStyle(
                  color: _busy
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.9),
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.32,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
