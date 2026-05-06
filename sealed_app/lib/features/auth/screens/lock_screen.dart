/// LockScreen — entered when the app is locked behind a PIN.
///
/// On 6-digit completion the screen tries the termination code first
/// (silent wipe + logout — duress safety) and otherwise falls back to PIN
/// verification.
///
/// Failure budget is hard-capped at [PinAttemptTracker.maxAttempts]:
///   attempts 1-3: free
///   attempt   4: in-line warning + final-attempt dialog
///   attempt   5: silent wipe + logout (5th-strike branch)
///
/// User-visible messaging on wipe paths:
///   * Duress branch (termination match) → "Terminating data…"
///   * 5th-strike branch (wrong PIN exhaustion) → "Incorrect PIN" (disguise
///     preserved so brute-force attacker cannot tell wipe is in progress).
///
/// SECURITY NOTE (SPEC.md §3): the duress-disguise property is partially
/// relaxed — termination match now reveals itself via the "Terminating
/// data…" string. This is a deliberate UX trade-off approved by the
/// product owner. The 5th-strike disguise is retained.
///
/// All visuals come from [PinEntryView] so the lock screen, onboarding
/// setup, change-PIN flow, and change-termination flow share one design.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/features/auth/widgets/pin_entry_view.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/services/pin_attempt_tracker.dart';
import 'package:sealed_app/shared/widgets/styled_dialog.dart';

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final StringBuffer _entry = StringBuffer();
  String? _error;
  bool _busy = false;

  // ─── Entry buffer ───────────────────────────────────────────────────────

  void _appendDigit(String d) {
    if (_busy) return;
    if (_entry.length >= 6) return;
    setState(() {
      _entry.write(d);
      _error = null;
    });
    if (_entry.length == 6) _submit();
  }

  void _backspace() {
    if (_entry.isEmpty) return;
    setState(() {
      final s = _entry.toString();
      _entry
        ..clear()
        ..write(s.substring(0, s.length - 1));
    });
  }

  // ─── Submission ─────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final code = _entry.toString();
    setState(() => _busy = true);
    final overall = Stopwatch()..start();
    try {
      // Termination code first — duress branch must wipe + logout before
      // we ever touch PinService (which would put the DEK in RAM).
      final term = ref.read(terminationServiceProvider);
      final termSw = Stopwatch()..start();
      final isTerm = await term.matches(code);
      debugPrint('[LockScreen] term.matches: ${termSw.elapsedMilliseconds}ms');
      if (isTerm) {
        await _wipeAndExit(isDuress: true);
        return;
      }

      final pin = ref.read(pinServiceProvider);
      try {
        final pinSw = Stopwatch()..start();
        final dek = await pin.verifyAndUnwrap(code);
        debugPrint(
          '[LockScreen] pin.verifyAndUnwrap: ${pinSw.elapsedMilliseconds}ms',
        );
        await ref.read(pinAttemptTrackerProvider).reset();
        final unlockSw = Stopwatch()..start();
        ref.read(pinSessionProvider.notifier).unlock(dek);
        debugPrint(
          '[LockScreen] session.unlock (sync): ${unlockSw.elapsedMicroseconds}us',
        );
      } catch (_) {
        await _onWrongPin();
      }
    } finally {
      debugPrint(
        '[LockScreen] _submit total: ${overall.elapsedMilliseconds}ms',
      );
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Records the wrong attempt and routes to one of three branches based
  /// on the new attempt count.
  Future<void> _onWrongPin() async {
    final tracker = ref.read(pinAttemptTrackerProvider);
    final count = await tracker.recordFailedAttempt();
    if (!mounted) return;

    if (count >= PinAttemptTracker.maxAttempts) {
      await _wipeAndExit(isDuress: false);
      return;
    }

    setState(() {
      _entry.clear();
      _error = count == PinAttemptTracker.maxAttempts - 1
          ? 'Incorrect PIN. 1 attempt left before this device is erased.'
          : 'Incorrect PIN';
    });

    if (count == PinAttemptTracker.maxAttempts - 1) {
      await _showFinalAttemptWarning();
    }
  }

  Future<void> _showFinalAttemptWarning() async {
    await StyledDialog.show<void>(
      context: context,
      icon: CupertinoIcons.exclamationmark_triangle_fill,
      iconColor: Colors.orange,
      title: 'Final attempt',
      content: const Text(
        'One more wrong PIN will permanently erase all messages, alias '
        'keys, and your wallet from this device. There is no recovery.',
        style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
      ),
      actions: [
        StyledDialogAction(
          label: 'Got it',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  /// Shared exit path for both the duress branch and the 5th-strike
  /// branch: silent-wipe everything, drop session, pop to root so the
  /// AppShell rebuilds onto the onboarding flow.
  ///
  /// [isDuress] controls user-visible messaging:
  ///   * true  (termination match) → "Terminating data…"
  ///   * false (5th-strike)        → "Incorrect PIN" (disguise preserved)
  Future<void> _wipeAndExit({required bool isDuress}) async {
    if (!mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);

    setState(() {
      _entry.clear();
      _error = isDuress ? 'Terminating data…' : 'Incorrect PIN';
    });

    await wipeServiceFromContainer(container).silentWipe();
    if (!mounted) return;

    ref.read(pinSessionProvider.notifier).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PinEntryView(
        headline: 'Welcome back!',
        subhead: 'Please enter your PIN to continue',
        filled: _entry.length,
        onDigit: _appendDigit,
        onBackspace: _backspace,
        errorText: _error,
        disabled: _busy,
        loading: _busy,
        showQuantumBackdrop: true,
      ),
    );
  }
}
