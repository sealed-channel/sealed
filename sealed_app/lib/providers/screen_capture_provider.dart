import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infra/platform/screen_capture_guard.dart';

/// App-wide singleton guard over the native secure-screen flag.
/// Screens opt in by wrapping their subtree in `SecureScreen`.
final screenCaptureGuardProvider = Provider<ScreenCaptureGuard>((ref) {
  return ScreenCaptureGuard();
});
