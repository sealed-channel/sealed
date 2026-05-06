/// ChangePinFlow — three-step PIN change reachable from Settings.
///
///   1. Enter current PIN     → `PinService.verifyAndUnwrap` gates entry
///   2. Enter new PIN
///   3. Confirm new PIN       → `PinService.changePin` commits
///
/// Wrong-current-PIN attempts in this flow do **not** count against
/// [PinAttemptTracker.maxAttempts] (the wipe budget) — only lock-screen
/// attempts do. The user just sees an inline error and retries.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:sealed_app/features/auth/widgets/pin_entry_view.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/services/pin_service.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

class ChangePinFlow extends ConsumerStatefulWidget {
  const ChangePinFlow({super.key});

  @override
  ConsumerState<ChangePinFlow> createState() => _ChangePinFlowState();
}

enum _Step { enterCurrent, enterNew, confirmNew }

class _ChangePinFlowState extends ConsumerState<ChangePinFlow> {
  _Step _step = _Step.enterCurrent;
  String _currentPin = '';
  String _newPin = '';
  final StringBuffer _entry = StringBuffer();
  String? _error;
  bool _busy = false;

  String get _headline {
    switch (_step) {
      case _Step.enterCurrent:
        return 'Enter current PIN';
      case _Step.enterNew:
        return 'Choose a new PIN';
      case _Step.confirmNew:
        return 'Confirm new PIN';
    }
  }

  String get _subhead {
    switch (_step) {
      case _Step.enterCurrent:
        return 'Verify it\'s you before we change anything.';
      case _Step.enterNew:
        return 'Pick a 6-digit code you can remember.';
      case _Step.confirmNew:
        return 'Re-enter the new PIN to confirm.';
    }
  }

  void _onDigit(String d) {
    if (_busy || _entry.length >= 6) return;
    setState(() {
      _entry.write(d);
      _error = null;
    });
    if (_entry.length == 6) _onCodeComplete();
  }

  void _onBackspace() {
    if (_entry.isEmpty) return;
    setState(() {
      final s = _entry.toString();
      _entry
        ..clear()
        ..write(s.substring(0, s.length - 1));
    });
  }

  Future<void> _onCodeComplete() async {
    final code = _entry.toString();
    setState(() => _busy = true);
    try {
      switch (_step) {
        case _Step.enterCurrent:
          // Verify by attempting an unwrap. Don't touch PinAttemptTracker.
          try {
            await ref.read(pinServiceProvider).verifyAndUnwrap(code);
          } on PinIncorrectException {
            setState(() {
              _entry.clear();
              _error = 'Incorrect PIN. Try again.';
            });
            return;
          }
          _currentPin = code;
          _entry.clear();
          setState(() => _step = _Step.enterNew);
          break;

        case _Step.enterNew:
          if (code == _currentPin) {
            setState(() {
              _entry.clear();
              _error = 'New PIN must differ from your current PIN.';
            });
            return;
          }
          _newPin = code;
          _entry.clear();
          setState(() => _step = _Step.confirmNew);
          break;

        case _Step.confirmNew:
          if (code != _newPin) {
            setState(() {
              _entry.clear();
              _error = 'PINs don\'t match. Try again.';
              _step = _Step.enterNew;
              _newPin = '';
            });
            return;
          }
          await ref.read(pinServiceProvider).changePin(_currentPin, code);
          if (!mounted) return;
          Navigator.of(context).pop();
          showInfoSnackBar(context, 'PIN updated');
          break;
      }
    } catch (e) {
      setState(() {
        _entry.clear();
        _error = 'Something went wrong: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onBack() {
    if (_step == _Step.enterCurrent) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _entry.clear();
      _error = null;
      _step = _Step.values[_step.index - 1];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(gradient: sealedBackgroundGradient),
        child: PinEntryView(
          headline: _headline,
          subhead: _subhead,
          filled: _entry.length,
          onDigit: _onDigit,
          onBackspace: _onBackspace,
          errorText: _error,
          onBack: _onBack,
          disabled: _busy,
        ),
      ),
    );
  }
}
