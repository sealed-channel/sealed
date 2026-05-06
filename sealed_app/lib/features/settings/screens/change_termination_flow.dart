/// ChangeTerminationFlow — three-step termination-code change reachable
/// from Settings.
///
///   1. Gate step:
///        • If a termination code is already configured → enter the
///          existing termination code (verified via
///          `TerminationService.matches`; this path does NOT trigger a
///          wipe — wipe-on-entry only fires from the lock screen).
///        • If no termination code is configured yet → enter the PIN
///          (verified via `PinService.verifyAndUnwrap`).
///   2. Enter new termination code (must differ from the PIN)
///   3. Confirm new code      → `TerminationService.setCode` commits
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:sealed_app/features/auth/widgets/pin_entry_view.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/services/pin_service.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

class ChangeTerminationFlow extends ConsumerStatefulWidget {
  /// When true, a termination code is already configured and the gate step
  /// requires the *existing termination code*. When false, the gate step
  /// requires the PIN (used for the initial setup path).
  final bool terminationAlreadySet;

  const ChangeTerminationFlow({super.key, required this.terminationAlreadySet});

  @override
  ConsumerState<ChangeTerminationFlow> createState() =>
      _ChangeTerminationFlowState();
}

enum _Step { gate, enterNewCode, confirmNewCode }

class _ChangeTerminationFlowState extends ConsumerState<ChangeTerminationFlow> {
  _Step _step = _Step.gate;
  // The PIN value, captured at the gate step when no termination code is
  // configured yet. When the gate is the existing termination code, we
  // verify the PIN separately at confirm time so we still enforce the
  // "new code must differ from PIN" rule.
  String? _pin;
  String _newCode = '';
  final StringBuffer _entry = StringBuffer();
  String? _error;
  bool _busy = false;

  bool get _gateIsTerminationCode => widget.terminationAlreadySet;

  String get _headline {
    switch (_step) {
      case _Step.gate:
        return _gateIsTerminationCode
            ? 'Enter current termination code'
            : 'Enter your PIN';
      case _Step.enterNewCode:
        return 'Set termination code';
      case _Step.confirmNewCode:
        return 'Confirm termination code';
    }
  }

  String get _subhead {
    switch (_step) {
      case _Step.gate:
        return _gateIsTerminationCode
            ? 'Confirm your existing termination code before '
                  'changing it. This will not wipe the device.'
            : 'Confirm your PIN before setting the termination code.';
      case _Step.enterNewCode:
        return 'Choose a different 6-digit code from your PIN. '
            'Entering it on the lock screen erases this device.';
      case _Step.confirmNewCode:
        return 'Re-enter the termination code.';
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
        case _Step.gate:
          if (_gateIsTerminationCode) {
            final ok = await ref
                .read(terminationServiceProvider)
                .matches(code);
            if (!ok) {
              setState(() {
                _entry.clear();
                _error = 'Incorrect termination code. Try again.';
              });
              return;
            }
            // Gate passed via existing termination code. We do not learn
            // the PIN here; we'll verify the "new ≠ PIN" rule at commit.
            _pin = null;
          } else {
            try {
              await ref.read(pinServiceProvider).verifyAndUnwrap(code);
            } on PinIncorrectException {
              setState(() {
                _entry.clear();
                _error = 'Incorrect PIN. Try again.';
              });
              return;
            }
            _pin = code;
          }
          _entry.clear();
          setState(() => _step = _Step.enterNewCode);
          break;

        case _Step.enterNewCode:
          // Only enforce "differs from PIN" when we actually captured the
          // PIN at the gate step. If the gate was the termination code, we
          // skip this client-side check (the user's PIN is not in memory).
          if (_pin != null && code == _pin) {
            setState(() {
              _entry.clear();
              _error = 'Termination code must differ from your PIN.';
            });
            return;
          }
          _newCode = code;
          _entry.clear();
          setState(() => _step = _Step.confirmNewCode);
          break;

        case _Step.confirmNewCode:
          if (code != _newCode) {
            setState(() {
              _entry.clear();
              _error = 'Codes don\'t match. Try again.';
              _step = _Step.enterNewCode;
              _newCode = '';
            });
            return;
          }
          await ref.read(terminationServiceProvider).setCode(code);
          if (!mounted) return;
          Navigator.of(context).pop();
          showInfoSnackBar(context, 'Termination code updated');
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
    if (_step == _Step.gate) {
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
