/// PinSetupScreen — multi-step PIN onboarding flow.
///
/// Steps:
///   1. Enter new PIN (6 digits)
///   2. Confirm PIN
///   3. (Optional) Set termination code
///
/// All PIN-entry steps render through [PinEntryView] so the visuals
/// match the lock screen and the in-settings change flows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/features/auth/widgets/pin_entry_view.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

class PinSetupScreen extends ConsumerStatefulWidget {
  /// If `true`, this screen blocks the user from proceeding to the app
  /// without setting up a PIN. Used for the post-onboarding mandatory step.
  final bool mandatory;

  const PinSetupScreen({super.key, this.mandatory = true});

  @override
  ConsumerState<PinSetupScreen> createState() => _PinSetupScreenState();
}

enum _Step { enterPin, confirmPin, termOptIn, termEnter, termConfirm }

class _PinSetupScreenState extends ConsumerState<PinSetupScreen> {
  _Step _step = _Step.enterPin;
  String _firstPin = '';
  String _firstTerm = '';
  final StringBuffer _entry = StringBuffer();
  String? _error;
  bool _busy = false;

  bool get _isCodeStep =>
      _step == _Step.enterPin ||
      _step == _Step.confirmPin ||
      _step == _Step.termEnter ||
      _step == _Step.termConfirm;

  String get _headline {
    switch (_step) {
      case _Step.enterPin:
        return 'Create a PIN';
      case _Step.confirmPin:
        return 'Confirm your PIN';
      case _Step.termOptIn:
        return 'Termination Code';
      case _Step.termEnter:
        return 'Set termination code';
      case _Step.termConfirm:
        return 'Confirm termination code';
    }
  }

  String get _subhead {
    switch (_step) {
      case _Step.enterPin:
        return '6 digits. You\'ll need this every time you open Sealed.';
      case _Step.confirmPin:
        return 'Re-enter the same PIN.';
      case _Step.termOptIn:
        return 'Optional. Entering this code on the lock screen will erase '
            'all messages, alias keys, and your wallet from this device.';
      case _Step.termEnter:
        return 'Choose a different 6-digit code from your PIN.';
      case _Step.termConfirm:
        return 'Re-enter the termination code.';
    }
  }

  // ─── Entry buffer ───────────────────────────────────────────────────────

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

  // ─── Step machine ───────────────────────────────────────────────────────

  Future<void> _onCodeComplete() async {
    final code = _entry.toString();
    setState(() => _busy = true);
    try {
      switch (_step) {
        case _Step.enterPin:
          _firstPin = code;
          _entry.clear();
          setState(() => _step = _Step.confirmPin);
          break;
        case _Step.confirmPin:
          if (code != _firstPin) {
            setState(() {
              _entry.clear();
              _error = 'PINs don\'t match. Try again.';
              _step = _Step.enterPin;
              _firstPin = '';
            });
            return;
          }
          await ref.read(pinServiceProvider).setPin(code);
          // Get the freshly-wrapped DEK so we can hand it to the session.
          final dek = await ref.read(pinServiceProvider).verifyAndUnwrap(code);
          ref.read(pinSessionProvider.notifier).onPinSetCompleted(dek);
          _entry.clear();
          setState(() => _step = _Step.termOptIn);
          break;
        case _Step.termEnter:
          if (code == _firstPin) {
            setState(() {
              _entry.clear();
              _error = 'Termination code must differ from your PIN.';
            });
            return;
          }
          _firstTerm = code;
          _entry.clear();
          setState(() => _step = _Step.termConfirm);
          break;
        case _Step.termConfirm:
          if (code != _firstTerm) {
            setState(() {
              _entry.clear();
              _error = 'Termination codes don\'t match.';
              _step = _Step.termEnter;
              _firstTerm = '';
            });
            return;
          }
          await ref.read(terminationServiceProvider).setCode(code);
          _entry.clear();
          _finish();
          break;
        default:
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

  void _skipTerm() => _finish();
  void _setTerm() => setState(() {
    _entry.clear();
    _error = null;
    _step = _Step.termEnter;
  });

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => !widget.mandatory,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: BoxDecoration(gradient: sealedBackgroundGradient),
          child: _isCodeStep
              ? PinEntryView(
                  headline: _headline,
                  subhead: _subhead,
                  filled: _entry.length,
                  onDigit: _onDigit,
                  onBackspace: _onBackspace,
                  errorText: _error,
                  disabled: _busy,
                )
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        Text(
                          _headline,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _subhead,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            height: 1.4,
                          ),
                        ),
                        const Spacer(),
                        if (_step == _Step.termOptIn) ...[
                          _BigButton(
                            label: 'Set termination code',
                            onTap: _setTerm,
                          ),
                          const SizedBox(height: 12),
                          _BigButton(
                            label: 'Skip for now',
                            outlined: true,
                            onTap: _skipTerm,
                          ),
                        ],
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool outlined;

  const _BigButton({
    required this.label,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: outlined
          ? OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: Text(label),
            )
          : ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: Text(label),
            ),
    );
  }
}
