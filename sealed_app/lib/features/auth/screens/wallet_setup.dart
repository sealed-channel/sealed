import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/shared/widgets/theme.dart';
import 'package:sealed_app/shared/widgets/styled_dialog.dart';
import 'package:sealed_app/core/snackbars.dart';

/// Login / onboarding screen — create new account or restore an existing one.
class WalletSetupScreen extends StatefulWidget {
  const WalletSetupScreen({super.key});

  @override
  State<WalletSetupScreen> createState() => _WalletSetupScreenState();
}

class _WalletSetupScreenState extends State<WalletSetupScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _orbController;
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..forward();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _orbController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  Animation<double> _stagger(double begin, double end) {
    return CurvedAnimation(
      parent: _entranceController,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // Animated background: deep gradient + drifting blurred orbs.
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(gradient: sealedBackgroundGradient),
            ),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _orbController,
              builder: (_, _) => CustomPaint(
                painter: _FloatingOrbsPainter(
                  progress: _orbController.value,
                  primary: primaryColor,
                ),
              ),
            ),
          ),

          SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: size.height - 40),
              child: Column(
                children: [
                  SizedBox(height: size.height * 0.10),

                  // Logo with pulsing glow halo
                  _FadeSlideIn(
                    animation: _stagger(0.0, 0.5),
                    child: AnimatedBuilder(
                      animation: _pulseController,
                      builder: (_, child) {
                        final t = _pulseController.value;
                        return Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: primaryColor.withOpacity(
                                  0.25 + 0.25 * t,
                                ),
                                blurRadius: 60 + 40 * t,
                                spreadRadius: 4 + 6 * t,
                              ),
                            ],
                          ),
                          child: child,
                        );
                      },
                      child: Image.asset("assets/logo.png", width: 260),
                    ),
                  ),

                  const SizedBox(height: 28),

                  _FadeSlideIn(
                    animation: _stagger(0.15, 0.6),
                    child: ShaderMask(
                      shaderCallback: (rect) => LinearGradient(
                        colors: [Colors.white, Colors.white.withOpacity(0.75)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ).createShader(rect),
                      child: Text(
                        'Private messages.\nZero surveillance.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.displaySmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                            ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  _FadeSlideIn(
                    animation: _stagger(0.25, 0.7),
                    child: Text(
                      'End-to-end encrypted. No phone number,\nno email, no servers watching.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.white.withOpacity(0.65),
                        height: 1.5,
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Feature chips — auto-scrolling marquee (left → right)
                  const SizedBox(
                    height: 48,
                    child: _FeatureChipMarquee(
                      chips: [
                        _FeatureChip(
                          assetPath: 'assets/icons/onboarding/end-to-end.svg',
                          label: 'End-to-end',
                          title: 'End-to-end encrypted',
                          explanation:
                              'Every message is encrypted on your device before it leaves, and only the person you sent it to can unlock it. Not us, not the network, not anyone in between — just the two of you.',
                        ),
                        _FeatureChip(
                          assetPath: 'assets/icons/onboarding/hidden-ip.svg',
                          label: 'Hidden IP',
                          title: 'Hidden IP address',
                          explanation:
                              'Your IP address is never exposed to other users or stored on the blockchain. Messages are routed through the network without revealing your location or identity.',
                        ),
                        _FeatureChip(
                          assetPath: 'assets/icons/onboarding/quantum.svg',
                          label: 'Quantum-resistant',
                          title: 'Quantum-resistant encryption',
                          explanation:
                              'Built with post-quantum cryptography to protect your messages from future quantum computer attacks. Your conversations stay private, even decades from now.',
                        ),
                        _FeatureChip(
                          assetPath: 'assets/icons/onboarding/opensource.svg',
                          label: 'Open Source',
                          title: 'Open source & auditable',
                          explanation:
                              'Every line of code is public and independently auditable. No backdoors, no hidden tracking — just transparent, community-verified security.',
                        ),
                      ],
                    ),
                  ),

                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 18),
                    child: Column(
                      children: [
                        SizedBox(height: 44),

                        _FadeSlideIn(
                          animation: _stagger(0.45, 0.9),
                          child: const _CreatePrimaryButton(),
                        ),
                        const SizedBox(height: 14),
                        _FadeSlideIn(
                          animation: _stagger(0.55, 0.95),
                          child: const _RestoreSecondaryButton(),
                        ),

                        const SizedBox(height: 24),

                        _FadeSlideIn(
                          animation: _stagger(0.65, 1.0),
                          child: const _HowItWorksSection(),
                        ),

                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ENTRANCE ANIMATION HELPER
// ============================================================================

class _FadeSlideIn extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;
  const _FadeSlideIn({required this.animation, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, _) => Opacity(
        opacity: animation.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - animation.value) * 20),
          child: child,
        ),
      ),
    );
  }
}

// ============================================================================
// FLOATING BACKGROUND ORBS
// ============================================================================

class _FloatingOrbsPainter extends CustomPainter {
  final double progress;
  final Color primary;

  _FloatingOrbsPainter({required this.progress, required this.primary});

  @override
  void paint(Canvas canvas, Size size) {
    final orbs = [
      _Orb(0.2, 0.15, 180, primary.withOpacity(0.18)),
      _Orb(0.85, 0.3, 140, const Color(0xFF53FFE1).withOpacity(0.10)),
      _Orb(0.1, 0.75, 220, primary.withOpacity(0.12)),
      _Orb(0.9, 0.85, 160, const Color(0xFF00C6A5).withOpacity(0.10)),
    ];

    for (var i = 0; i < orbs.length; i++) {
      final o = orbs[i];
      final t = (progress + i * 0.25) * 2 * math.pi;
      final dx = math.sin(t) * 20;
      final dy = math.cos(t) * 24;
      final center = Offset(size.width * o.x + dx, size.height * o.y + dy);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [o.color, o.color.withOpacity(0)],
        ).createShader(Rect.fromCircle(center: center, radius: o.radius))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);
      canvas.drawCircle(center, o.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FloatingOrbsPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _Orb {
  final double x;
  final double y;
  final double radius;
  final Color color;
  _Orb(this.x, this.y, this.radius, this.color);
}

// ============================================================================
// FEATURE CHIP MARQUEE — auto-scrolls chips horizontally (left → right)
// ============================================================================

class _FeatureChipMarquee extends StatefulWidget {
  final List<_FeatureChip> chips;

  const _FeatureChipMarquee({required this.chips});

  /// Pixels per second the strip drifts.
  static const double _speed = 28;

  @override
  State<_FeatureChipMarquee> createState() => _FeatureChipMarqueeState();
}

class _FeatureChipMarqueeState extends State<_FeatureChipMarquee>
    with SingleTickerProviderStateMixin {
  final GlobalKey _stripKey = GlobalKey();
  Ticker? _ticker;
  Duration _last = Duration.zero;
  double _offset = 0;
  double _cycleWidth = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _measure() {
    final ctx = _stripKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // The Row contains the chips twice; one cycle = half the row width.
    final w = box.size.width / 2;
    if ((w - _cycleWidth).abs() > 0.5) _cycleWidth = w;
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 0.0
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _measure();
    if (_cycleWidth <= 0) return;
    setState(() {
      _offset = (_offset + _FeatureChipMarquee._speed * dt) % _cycleWidth;
    });
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Duplicate the chip list so wrapping is seamless.
    final doubled = [...widget.chips, ...widget.chips];
    return ClipRect(
      child: ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.06, 0.94, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          child: Transform.translate(
            // Negative offset → strip moves leftward visually. Flip the sign
            // so the strip drifts left → right as requested.
            offset: Offset(-_cycleWidth + _offset, 0),
            child: Row(
              key: _stripKey,
              mainAxisSize: MainAxisSize.min,
              children: doubled,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// FEATURE CHIP
// ============================================================================

class _FeatureChip extends StatelessWidget {
  final String assetPath;
  final String label;
  final String title;
  final String explanation;
  final double iconSize;
  const _FeatureChip({
    required this.assetPath,
    required this.label,
    required this.title,
    this.iconSize = 24,
    required this.explanation,
  });

  void _showExplanation(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _ChipExplanationSheet(
        assetPath: assetPath,
        title: title,
        explanation: explanation,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSvg = assetPath.endsWith('.svg');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showExplanation(context),
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

          child: Row(
            mainAxisSize: MainAxisSize.min,

            children: [
              SizedBox(
                width: iconSize,
                height: iconSize,
                child: isSvg
                    ? SvgPicture.asset(
                        assetPath,
                        width: iconSize,
                        height: iconSize,
                        colorFilter: ColorFilter.mode(
                          primaryColor,
                          BlendMode.srcIn,
                        ),
                      )
                    : Image.asset(
                        assetPath,
                        width: iconSize,
                        height: iconSize,
                        color: primaryColor,
                      ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipExplanationSheet extends StatelessWidget {
  final String assetPath;
  final String title;
  final String explanation;
  const _ChipExplanationSheet({
    required this.assetPath,
    required this.title,
    required this.explanation,
  });

  @override
  Widget build(BuildContext context) {
    final isSvg = assetPath.endsWith('.svg');

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
        decoration: BoxDecoration(
          color: const Color(0xFF101013),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: primaryColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: isSvg
                        ? SvgPicture.asset(
                            assetPath,
                            width: 22,
                            height: 22,
                            colorFilter: ColorFilter.mode(
                              primaryColor,
                              BlendMode.srcIn,
                            ),
                          )
                        : Image.asset(
                            assetPath,
                            width: 22,
                            height: 22,
                            color: primaryColor,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              explanation,
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Got it',
                  style: TextStyle(
                    color: primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// HOW IT WORKS — expandable explainer
// ============================================================================

class _HowItWorksSection extends StatefulWidget {
  const _HowItWorksSection();

  @override
  State<_HowItWorksSection> createState() => _HowItWorksSectionState();
}

class _HowItWorksSectionState extends State<_HowItWorksSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/icons/login/idea.png',
                      width: 18,
                      height: 18,
                      color: primaryColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'How it works?',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 200),
                      turns: _expanded ? 0.5 : 0,
                      child: Icon(
                        CupertinoIcons.chevron_down,
                        color: Colors.white.withOpacity(0.6),
                        size: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 250),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    _Step(
                      number: '1',
                      title: 'App creates or imports Algorand crypto wallet',
                    ),
                    SizedBox(height: 20),
                    _Step(
                      number: '2',
                      title:
                          'You can find other users by wallet address, their username',
                    ),
                    SizedBox(height: 20),
                    _Step(
                      number: '3',
                      title:
                          'Each message is a transaction published on blockchain, signed and encrypted by your wallet',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String title;

  const _Step({required this.number, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: primaryGradient,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: primaryColor.withOpacity(0.4), blurRadius: 8),
            ],
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// CREATE WALLET BUTTON
// ============================================================================

class _CreatePrimaryButton extends ConsumerStatefulWidget {
  const _CreatePrimaryButton();

  @override
  ConsumerState<_CreatePrimaryButton> createState() =>
      _CreatePrimaryButtonState();
}

class _CreatePrimaryButtonState extends ConsumerState<_CreatePrimaryButton>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  bool _isLoading = false;
  late final AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: _isLoading ? null : _handleCreate,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: _isPressed ? 0.97 : 1.0,
        child: Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            gradient: primaryGradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: _isPressed
                ? []
                : [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.15),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Shimmer sweep
                AnimatedBuilder(
                  animation: _shimmerController,
                  builder: (_, _) {
                    return Positioned.fill(
                      child: Transform.translate(
                        offset: Offset(
                          -200 + _shimmerController.value * 500,
                          0,
                        ),
                        child: Container(
                          width: 120,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                Colors.white.withValues(alpha: 0),
                                Colors.white.withValues(alpha: 0.18),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_isLoading)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Create account',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleCreate() async {
    setState(() => _isLoading = true);
    try {
      final seedPhrase = await ref
          .read(localWalletProvider.notifier)
          .createWallet();

      if (mounted) {
        // Show seed phrase backup dialog
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => SeedPhraseBackupDialog(seedPhrase: seedPhrase),
        );
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, 'Failed to create wallet: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}

// ============================================================================
// SECONDARY RESTORE BUTTON
// ============================================================================

class _RestoreSecondaryButton extends StatefulWidget {
  const _RestoreSecondaryButton();

  @override
  State<_RestoreSecondaryButton> createState() =>
      _RestoreSecondaryButtonState();
}

class _RestoreSecondaryButtonState extends State<_RestoreSecondaryButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: () => showRestoreWalletSheet(context),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: _isPressed ? 0.97 : 1.0,
        child: Container(
          width: double.infinity,
          height: 54,
          alignment: Alignment.center,

          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/icons/login/key.png',
                width: 16,
                height: 16,
                color: Colors.white.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 10),
              Text(
                'Login with existing wallet',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// SEED PHRASE BACKUP DIALOG
// ============================================================================

class SeedPhraseBackupDialog extends ConsumerStatefulWidget {
  final String seedPhrase;

  const SeedPhraseBackupDialog({super.key, required this.seedPhrase});

  @override
  ConsumerState<SeedPhraseBackupDialog> createState() =>
      _SeedPhraseBackupDialogState();
}

class _SeedPhraseBackupDialogState
    extends ConsumerState<SeedPhraseBackupDialog> {
  bool _hasConfirmed = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E1E2E), Color(0xFF16161E)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 30,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 24,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Backup Your Recovery Phrase',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Content
            Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This is your wallet recovery phrase. Write it down and store it safely. '
                    'If you lose this phrase, you will lose access to your wallet and messages forever.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: 20),
                  StyledSeedPhraseBox(
                    seedPhrase: widget.seedPhrase,
                    onCopy: () {
                      showInfoSnackBar(context, 'Copied to clipboard! ✅');
                    },
                  ),
                  SizedBox(height: 20),
                  StyledDialogCheckbox(
                    value: _hasConfirmed,
                    onChanged: (v) =>
                        setState(() => _hasConfirmed = v ?? false),
                    label: 'I have saved my recovery phrase safely',
                  ),
                ],
              ),
            ),
            // Actions
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _buildActionButton(
                    label: 'Continue',
                    onPressed: _hasConfirmed
                        ? () {
                            ref
                                .read(localWalletProvider.notifier)
                                .clearSeedPhraseFromState();
                            Navigator.pop(context);
                          }
                        : null,
                    isPrimary: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required VoidCallback? onPressed,
    bool isPrimary = false,
  }) {
    return AnimatedOpacity(
      duration: Duration(milliseconds: 200),
      opacity: onPressed == null ? 0.5 : 1.0,
      child: Container(
        decoration: isPrimary && onPressed != null
            ? BoxDecoration(
                gradient: primaryGradient,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              )
            : null,
        child: Material(
          color: isPrimary
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// RESTORE WALLET BOTTOM SHEET
// ============================================================================

/// Show the restore-wallet flow as a modal bottom sheet anchored to the
/// keyboard. Mirrors the existing `showChatTypePicker` pattern in
/// lib/features/qr/chat_type_picker_sheet.dart.
Future<void> showRestoreWalletSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const RestoreWalletSheet(),
  );
}

class RestoreWalletSheet extends ConsumerStatefulWidget {
  const RestoreWalletSheet({super.key});

  @override
  ConsumerState<RestoreWalletSheet> createState() => _RestoreWalletSheetState();
}

class _RestoreWalletSheetState extends ConsumerState<RestoreWalletSheet> {
  final _seedController = TextEditingController();
  // 24 = the primary recovery format used across most Sealed installs (BIP39).
  // 25 = the Algorand-native format (used by new wallets created on/after the
  // 25-word migration, and by Pera/Defly/MyAlgo exports).
  int _wordCount = 24;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _seedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.restore, color: primaryColor, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Restore Wallet',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Algorand recovery phrase',
                            style: TextStyle(
                              color: Color(0xFF9090A0),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // Word-count toggle (25 vs 24)
                SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: _wordCount,
                    thumbColor: primaryColor,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    children: const {
                      24: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          '24 words',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      25: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          '25 words (legacy)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    },
                    onValueChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _wordCount = value;
                        _error = null;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _wordCount == 24
                      ? 'Recovery phrase from your Sealed backup'
                      : 'Older Algorand-native phrase format with checksum word — use 24 if you\'re unsure',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 14),

                StyledDialogTextField(
                  controller: _seedController,
                  hintText: 'word1 word2 word3 …',
                  maxLines: 3,
                  errorText: _error,
                ),

                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _buildActionButton(
                      label: 'Cancel',
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 12),
                    _buildActionButton(
                      label: 'Restore',
                      onPressed: _isLoading ? null : _handleRestore,
                      isPrimary: true,
                      isLoading: _isLoading,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required VoidCallback? onPressed,
    bool isPrimary = false,
    bool isLoading = false,
  }) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: onPressed == null && !isLoading ? 0.5 : 1.0,
      child: Container(
        decoration: isPrimary
            ? BoxDecoration(
                gradient: primaryGradient,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              )
            : null,
        child: Material(
          color: isPrimary
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleRestore() async {
    final input = _seedController.text.trim();

    if (input.isEmpty) {
      setState(() => _error = 'Please enter your recovery phrase');
      return;
    }

    final words = input.toLowerCase().split(RegExp(r'\s+'));
    if (words.length != _wordCount) {
      setState(
        () => _error = 'Expected $_wordCount words, got ${words.length}',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Provider → AlgorandWallet.restoreWallet → dispatches by length
      // (25 = Algorand-native, 24 = legacy BIP39).
      await ref
          .read(localWalletProvider.notifier)
          .restoreFromMnemonic(input.toLowerCase());

      if (mounted) {
        Navigator.pop(context);
        showInfoSnackBar(context, 'Wallet restored successfully!');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}

// ============================================================================
// FUNDING REQUIRED SCREEN
// ============================================================================

class FundingRequiredScreen extends ConsumerStatefulWidget {
  const FundingRequiredScreen({super.key});

  @override
  ConsumerState<FundingRequiredScreen> createState() =>
      _FundingRequiredScreenState();
}

class _FundingRequiredScreenState extends ConsumerState<FundingRequiredScreen> {
  Timer? _pollingTimer;
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    // Poll every 3 seconds for balance changes
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkBalance();
    });
  }

  Future<void> _checkBalance() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);

    try {
      await ref.read(localWalletProvider.notifier).refreshBalance();
    } catch (e) {
      print('⚠️ FundingRequiredScreen: Failed to check balance: $e');
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final walletState = ref.watch(localWalletProvider);

    final address = walletState.value?.walletAddress ?? '';
    final balance = walletState.value?.balanceSol ?? 0.0;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: sealedBackgroundGradient),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: topPadding(context)),
            GestureDetector(
              behavior: HitTestBehavior.opaque,

              onTap: () => {
                ref.watch(localWalletProvider.notifier).deleteWallet(),
              },
              child: Container(
                padding: const EdgeInsets.all(8),

                child: const Icon(
                  CupertinoIcons.back,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HORIZONTAL_PADDING,
                ),

                child: Column(
                  children: [
                    // Icon
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        CupertinoIcons.arrow_down_circle_fill,
                        size: 64,
                        color: Colors.orange,
                      ),
                    ),

                    const SizedBox(height: 32),

                    Text(
                      'Fund Your Wallet',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),

                    const SizedBox(height: 12),

                    Text(
                      'Your wallet needs ALGO to register and send messages.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 16,
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Balance card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Current Balance',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${balance.toStringAsFixed(4)} ALGO',
                            style: TextStyle(
                              color: balance >= 0.1
                                  ? Colors.green
                                  : Colors.orange,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Minimum required: 0.001 ALGO',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Wallet address card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Send ALGO to this address:',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    address,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(text: address),
                                    );
                                    HapticFeedback.lightImpact();
                                    showInfoSnackBar(
                                      context,
                                      'Address copied! ✅',
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: primaryColor.withValues(
                                        alpha: 0.2,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      Icons.copy,
                                      color: primaryColor,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Instructions
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: primaryColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: primaryColor,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'How to fund',
                                style: TextStyle(
                                  color: primaryColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '1. Copy your wallet address above\n'
                            '2. Send ALGO from any wallet, or use the TestNet faucet: bank.testnet.algorand.network\n'
                            '3. Wait for the transaction to confirm\n'
                            '4. The app will automatically continue',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // Polling indicator
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Checking for incoming transactions...',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
