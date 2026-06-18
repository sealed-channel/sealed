import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infra/platform/screen_capture_guard.dart';
import '../../../providers/screen_capture_provider.dart';

/// Wraps a screen's subtree: the window is capture-protected (black
/// screenshots/recordings, blank recents thumbnail) while this widget is
/// mounted. Backed by the refcounted [ScreenCaptureGuard], so stacking two
/// wrapped screens keeps the flag set across the transition.
class SecureScreen extends ConsumerStatefulWidget {
  const SecureScreen({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends ConsumerState<SecureScreen> {
  late final ScreenCaptureGuard _guard;

  @override
  void initState() {
    super.initState();
    _guard = ref.read(screenCaptureGuardProvider);
    _guard.acquire();
  }

  @override
  void dispose() {
    _guard.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
