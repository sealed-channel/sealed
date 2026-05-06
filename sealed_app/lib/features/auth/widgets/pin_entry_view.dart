/// PinEntryView — shared 6-digit PIN entry template.
///
/// One widget drives every PIN-entry surface in the app: lock screen,
/// onboarding setup, change-PIN flow, change-termination-code flow. The
/// caller owns the entry buffer and verification logic; this widget is
/// purely presentational.
///
/// Visual reference is the lock screen design — quantum-gif backdrop,
/// 6 progress dots, rounded numeric keypad with per-key press scaling,
/// optional logout / back affordances below the digits.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

/// Stateless template — drop into any screen and feed it state from above.
class PinEntryView extends StatelessWidget {
  const PinEntryView({
    super.key,
    required this.headline,
    required this.subhead,
    required this.filled,
    required this.onDigit,
    required this.onBackspace,
    this.errorText,
    this.onLogout,
    this.onBack,
    this.disabled = false,
    this.showQuantumBackdrop = true,
    this.loading = false,
  });

  final String headline;
  final String subhead;

  /// Number of dots filled (0..6).
  final int filled;

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  /// Optional one-line error rendered in red below the dots.
  final String? errorText;

  /// Show the "Log out" affordance below the keypad. Pass null to hide.
  final VoidCallback? onLogout;

  /// Show a back-arrow in the top-left. Pass null to hide.
  final VoidCallback? onBack;

  /// Disables every interactive element (typically while a verify call is
  /// in flight or after the entry has reached six digits).
  final bool disabled;

  /// The gif backdrop now appears on every PIN surface by default
  /// (lock, onboarding, change PIN, change termination). Pass false to
  /// disable for a specific screen if needed.
  final bool showQuantumBackdrop;

  /// Loading state — set to true while a verify/unlock call is in flight.
  /// Hides keypad/dots/header, ramps the quantum-gif opacity to full, and
  /// reverses the gif animation direction as a visual cue. The user is
  /// not asked to wait staring at frozen dots — the existing backdrop
  /// becomes the loading indicator.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    const fadeDuration = Duration(milliseconds: 350);
    return Stack(
      children: [
        if (showQuantumBackdrop) ...[
          const Positioned.fill(
            child: ColoredBox(color: Colors.black),
          ),
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: loading ? 1.0 : 0.55,
                duration: fadeDuration,
                curve: Curves.easeOut,
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.8,
                  width: double.infinity,
                  child: _PingPongGif(
                    asset: 'assets/quantum-animation.gif',
                    fit: BoxFit.cover,
                    reverse: loading,
                  ),
                ),
              ),
            ),
          ),
        ],
        SafeArea(
          child: AnimatedOpacity(
            opacity: loading ? 0.0 : 1.0,
            duration: fadeDuration,
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: loading,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    _Header(
                      onBack: onBack,
                      headline: headline,
                      subhead: subhead,
                    ),
                    const SizedBox(height: 48),
                    _Dots(filled: filled),
                    if (errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text(
                          errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    const Spacer(),
                    _Keypad(
                      hasEntry: filled > 0,
                      onDigit: onDigit,
                      onBackspace: onBackspace,
                      disabled: disabled,
                    ),
                    if (onLogout != null) ...[
                      const SizedBox(height: 12),
                      _LogoutButton(onTap: onLogout!),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.headline, required this.subhead, this.onBack});

  final String headline;
  final String subhead;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (onBack != null)
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: onBack,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Icon(
                  Icons.arrow_back_ios_new,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),
        Text(
          headline,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subhead,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 16,
            fontWeight: FontWeight.w500,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

// ─── Dots row ────────────────────────────────────────────────────────────────

class _Dots extends StatelessWidget {
  const _Dots({required this.filled});

  final int filled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final on = i < filled;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? primaryColor : Colors.white.withValues(alpha: 0.15),
          ),
        );
      }),
    );
  }
}

// ─── Keypad ──────────────────────────────────────────────────────────────────

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.hasEntry,
    required this.onDigit,
    required this.onBackspace,
    required this.disabled,
  });

  final bool hasEntry;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            children: row
                .map(
                  (d) => _KeypadKey(
                    disabled: disabled,
                    onTap: () => onDigit(d),
                    child: Text(
                      d,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        Row(
          children: [
            const Spacer(),
            _KeypadKey(
              disabled: disabled,
              onTap: () => onDigit('0'),
              child: const Text(
                '0',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (hasEntry)
              _KeypadKey(
                disabled: disabled,
                onTap: onBackspace,
                child: const Icon(
                  Icons.backspace_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              )
            else
              const Spacer(),
          ],
        ),
      ],
    );
  }
}

/// Single keypad key with its own press-scale animation so each key
/// animates independently of the others.
class _KeypadKey extends StatefulWidget {
  const _KeypadKey({
    required this.child,
    required this.onTap,
    required this.disabled,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool disabled;

  @override
  State<_KeypadKey> createState() => _KeypadKeyState();
}

class _KeypadKeyState extends State<_KeypadKey> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.disabled && widget.onTap != null;
    return Expanded(
      child: GestureDetector(
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                widget.onTap!();
              }
            : null,
        child: AspectRatio(
          aspectRatio: 1,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: AnimatedOpacity(
              opacity: _pressed ? 0.8 : 1.0,
              duration: const Duration(milliseconds: 100),
              child: AnimatedScale(
                scale: _pressed ? 0.9 : 1.0,
                duration: const Duration(milliseconds: 100),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Container(
                      decoration: BoxDecoration(
                        // Soft white tint over the blurred backdrop so the
                        // key reads as a frosted-glass surface, not just a
                        // blurry hole.
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withOpacity(0.08),
                            Colors.white.withOpacity(0.04),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                       
                      ),
                      child: Center(child: widget.child),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Logout button ───────────────────────────────────────────────────────────

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Log out',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.logout, color: Colors.white, size: 16),
          ],
        ),
      ),
    );
  }
}

// ─── Quantum-animation backdrop ──────────────────────────────────────────────

/// Plays an animated GIF forwards then backwards on repeat (ping-pong).
///
/// Decodes every frame upfront via `dart:ui` so we can drive the index
/// manually with an [AnimationController] — `Image.asset` only loops forward.
///
/// When [reverse] is true, frame order is mirrored — useful as a visual
/// cue during loading transitions (e.g. unlock in progress).
class _PingPongGif extends StatefulWidget {
  const _PingPongGif({
    required this.asset,
    this.fit = BoxFit.cover,
    this.reverse = false,
  });

  final String asset;
  final BoxFit fit;
  final bool reverse;

  static const Duration _frameDuration = Duration(milliseconds: 50);

  @override
  State<_PingPongGif> createState() => _PingPongGifState();
}

class _PingPongGifState extends State<_PingPongGif>
    with SingleTickerProviderStateMixin {
  final List<ui.Image> _frames = [];
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final data = await rootBundle.load(widget.asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame();
      _frames.add(frame.image);
    }
    if (!mounted || _frames.isEmpty) return;
    final total = _PingPongGif._frameDuration * (_frames.length * 2);
    _controller = AnimationController(
      vsync: this,
      duration: total - const Duration(milliseconds: 2000),
    )..repeat();
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    for (final f in _frames) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || _frames.isEmpty) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = widget.reverse
            ? 1.0 - controller.value
            : controller.value;
        // Ping-pong: 0..0.5 → forward, 0.5..1 → reverse.
        final phase = t < 0.5 ? t * 2 : (1 - t) * 2;
        final idx = (phase * (_frames.length - 1)).round().clamp(
          0,
          _frames.length - 1,
        );
        return RawImage(image: _frames[idx], fit: widget.fit);
      },
    );
  }
}
