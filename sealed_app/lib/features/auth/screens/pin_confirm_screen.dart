/// PinConfirmScreen — full-screen PIN re-entry for sensitive actions
/// (currently: viewing the recovery phrase before logout).
///
/// Pops `true` on successful PIN verification, `false` on user-cancel
/// (back arrow). On 5th-strike, follows the same wipe-and-exit path as
/// [LockScreen]: silent-wipe, reset session, pop to root.
///
/// Shares the [PinAttemptTracker] budget with LockScreen by design — we
/// do not open a second 5-attempt budget here. See SPEC.md §4.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/auth/widgets/pin_entry_view.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/services/pin_attempt_tracker.dart';
import 'package:sealed_app/shared/widgets/styled_dialog.dart';

class PinConfirmScreen extends ConsumerStatefulWidget {
  const PinConfirmScreen({
    super.key,
    this.headline = 'Confirm PIN',
    this.subhead = 'Enter your PIN to continue',
  });

  final String headline;
  final String subhead;

  @override
  ConsumerState<PinConfirmScreen> createState() => _PinConfirmScreenState();
}

class _PinConfirmScreenState extends ConsumerState<PinConfirmScreen> {
  final StringBuffer _entry = StringBuffer();
  String? _error;
  bool _busy = false;

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

  Future<void> _submit() async {
    final code = _entry.toString();
    setState(() => _busy = true);
    try {
      final pin = ref.read(pinServiceProvider);
      try {
        await pin.verifyAndUnwrap(code);
        await ref.read(pinAttemptTrackerProvider).reset();
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (_) {
        await _onWrongPin();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onWrongPin() async {
    final tracker = ref.read(pinAttemptTrackerProvider);
    final count = await tracker.recordFailedAttempt();
    if (!mounted) return;

    if (count >= PinAttemptTracker.maxAttempts) {
      await _wipeAndExit();
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

  /// 5th-strike branch — silent wipe, reset session, pop to root.
  /// Disguise preserved ("Incorrect PIN") to mirror LockScreen behavior.
  Future<void> _wipeAndExit() async {
    if (!mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);

    setState(() {
      _entry.clear();
      _error = 'Incorrect PIN';
    });

    await wipeServiceFromContainer(container).silentWipe();
    if (!mounted) return;

    ref.read(pinSessionProvider.notifier).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PinEntryView(
        headline: widget.headline,
        subhead: widget.subhead,
        filled: _entry.length,
        onDigit: _appendDigit,
        onBackspace: _backspace,
        errorText: _error,
        disabled: _busy,
        loading: _busy,
        showQuantumBackdrop: true,
        onBack: () => Navigator.of(context).pop(false),
      ),
    );
  }
}
