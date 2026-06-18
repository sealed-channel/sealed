import 'package:flutter/material.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Plain centred spinner on black — used post-wallet-create while keys
/// derive and the user resolves. Distinct from the lock-screen pulsing
/// keypad so the create-account transition feels grounded.
class SpinnerScreen extends StatelessWidget {
  const SpinnerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: CircularProgressIndicator(color: primaryColor),
    );
  }
}

/// Bare black surface used by AppShell while wallet/keys/user resolve.
///
/// On the returning-user path this sits BEHIND the lock overlay
/// ([SessionLockGate]), which stays up — keypad pulsing — until content is
/// ready, so this backdrop is never actually seen; it only shows briefly on
/// the pre-lock bootstrapping frame. Kept black so nothing flashes through.
class LoadingBackdrop extends StatelessWidget {
  const LoadingBackdrop({super.key});

  // A Scaffold (not a bare ColoredBox) so the root ScaffoldMessenger always
  // has a registered Scaffold: AppShell's connectivity listener can fire
  // while the PIN gate is still withholding the shell, and showSnackBar
  // asserts if no Scaffold exists anywhere under the messenger.
  @override
  Widget build(BuildContext context) =>
      const Scaffold(backgroundColor: Colors.black, body: SizedBox.expand());
}

/// Wraps [child] in a continuous opacity + scale pulse.
///
/// Used for the lock-screen keypad during the "logging in" window: once the
/// PIN verifies, the keypad keeps pulsing while AppShell resolves the session
/// behind the lock overlay, so the keypad itself signals progress and there
/// is no separate loading screen between the lock screen and the app.
class PulsingKeypad extends StatefulWidget {
  const PulsingKeypad({super.key, required this.child});

  final Widget child;

  @override
  State<PulsingKeypad> createState() => _PulsingKeypadState();
}

class _PulsingKeypadState extends State<PulsingKeypad>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _scale = Tween<double>(begin: 1.00, end: 0.98).animate(curve);
    _opacity = Tween<double>(begin: 0.55, end: 0.9).animate(curve);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
