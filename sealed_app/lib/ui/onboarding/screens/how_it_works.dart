import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/onboarding/screens/wallet_setup.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:video_player/video_player.dart';

/// One onboarding step: a looping video, a title, feature tags and a blurb.
class _Step {
  const _Step({
    required this.asset,
    required this.title,
    required this.tags,
    required this.body,
  });

  final String asset;
  final String title;
  final List<String> tags;

  /// Rich body so individual words can be highlighted (frame 3).
  final List<TextSpan> body;
}

final List<_Step> _steps = [
  _Step(
    asset: 'assets/animations/account_loop.mp4',
    title: 'Create Wallet-Based Account',
    tags: ['Anonymous Conversation', 'Decentralized'],
    body: [
      TextSpan(
        text:
            'Create an account directly from your blockchain wallet. '
            'No phone number, email, or personal data required.',
      ),
    ],
  ),
  _Step(
    asset: 'assets/animations/coins_loop.mp4',
    title: 'Add Network Credits',
    tags: ['Blockchain Based', 'No Data Collected'],
    body: [
      TextSpan(
        text:
            'Fund your account and pay only for message delivery. '
            'No intermediary servers, no access to your conversations.',
      ),
    ],
  ),
  _Step(
    asset: 'assets/animations/msg_loop.mp4',
    title: 'Send Secure Messages',
    tags: ['Encrypted', 'Direct Communication'],
    body: [
      TextSpan(text: 'Top up your account and start messaging instantly. '),
      TextSpan(text: 'Communicate through a '),
      TextSpan(
        text: 'privacy-first',
        style: TextStyle(color: primaryColor),
      ),
      TextSpan(text: ' '),
      TextSpan(
        text: 'decentralized network.',
        style: TextStyle(color: primaryColor),
      ),
    ],
  ),
  _Step(
    asset: 'assets/animations/opensource_loop.mp4',
    title: "Don't Trust, Verify",
    tags: ['Open Source Verified', 'Transparent by Design'],
    body: [
      TextSpan(
        text:
            'Our protocol is fully open source and publicly auditable. '
            'Review the code, verify the architecture, and validate our '
            'privacy claims yourself.',
      ),
    ],
  ),
];

class HowItWorksFlow extends StatefulWidget {
  const HowItWorksFlow({super.key});

  @override
  State<HowItWorksFlow> createState() => _HowItWorksFlowState();
}

class _HowItWorksFlowState extends State<HowItWorksFlow> {
  final PageController _controller = PageController();
  int _index = 0;

  bool get _isLast => _index == _steps.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_isLast) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (context) => WalletSetup()));
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            "How it works?",
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall!.copyWith(color: neutralColor),
          ),
        ),
        Gap(32.h),
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: _steps.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) =>
                _StepView(step: _steps[i], isActive: i == _index),
          ),
        ),
        Gap(24.h),
        SealedCircularButton(
          label: _isLast ? "Create account" : "Next",
          onTap: _next,
        ),
        Gap(12.h),
        _Dots(count: _steps.length, index: _index),
      ],
    );
  }
}

/// A single page: looping video card plus its text. Owns its own video
/// controller and only plays while it is the active page.
class _StepView extends StatefulWidget {
  const _StepView({required this.step, required this.isActive});

  final _Step step;
  final bool isActive;

  @override
  State<_StepView> createState() => _StepViewState();
}

class _StepViewState extends State<_StepView> {
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    // Assets are pre-rendered boomerangs (forward + reversed concat), so the
    // last frame equals the first — plain looping plays back and forth with no
    // visible seam.
    final c = VideoPlayerController.asset(widget.step.asset);
    _video = c;
    c
      ..setLooping(true)
      ..setVolume(0)
      ..initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
            if (widget.isActive) c.play();
          })
          .catchError((Object e, StackTrace st) {
            // Most likely a missing/unbundled asset (added files need a full app
            // rebuild, not hot reload). Surface it instead of failing silently.
            debugPrint(
              '[HowItWorks] video init failed for ${widget.step.asset}: $e',
            );
          });
  }

  @override
  void didUpdateWidget(covariant _StepView old) {
    super.didUpdateWidget(old);
    if (widget.isActive == old.isActive) return;
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    widget.isActive ? v.play() : v.pause();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    final ready = v != null && v.value.isInitialized;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              // Inset the video inside the border so the rounded teal frame —
              // corners included — stays fully visible. BoxFit.cover on the
              // bare Container painted over the border at the corners.
              padding: EdgeInsets.all(8.w),
              decoration: BoxDecoration(
                border: Border.all(color: primaryColor, width: 1),
                borderRadius: BorderRadius.circular(32.r),
              ),
              child: ready
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(24.r),
                      child: FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: v.value.size.width,
                          height: v.value.size.height,
                          child: VideoPlayer(v),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Gap(32.h),
          Text(
            widget.step.title,
            style: Theme.of(context).textTheme.headlineSmall!,
          ),
          Gap(12.h),
          Row(
            children: [
              for (final tag in widget.step.tags) ...[_Tag(tag), Gap(8.w)],
            ],
          ),
          Gap(12.h),
          Text.rich(
            TextSpan(
              style: Theme.of(
                context,
              ).textTheme.bodyMedium!.copyWith(color: neutralColor),
              children: widget.step.body,
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(4.w),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall!.copyWith(color: primaryColor),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++) ...[
          Container(
            width: 12.w,
            height: 12.w,
            decoration: BoxDecoration(
              color: i == index ? primaryColor : Colors.transparent,
              border: i == index
                  ? null
                  : Border.all(color: Colors.white, width: 1),
              shape: BoxShape.circle,
            ),
          ),
          if (i < count - 1) Gap(8.w),
        ],
      ],
    );
  }
}
