import 'package:flutter/services.dart';

/// Refcounted gate over the native secure-screen flag.
///
/// While at least one holder has [acquire]d, the platform side blanks the
/// window from capture:
/// - Android: `FLAG_SECURE` — screenshots blocked, recordings and the recents
///   thumbnail render black.
/// - iOS: secure-`UITextField` layer trick — screenshots and recordings of
///   the window come out black.
///
/// The channel is only invoked on 0↔1 refcount transitions, so stacked
/// secure screens (chat → alias handshake) never strobe the flag during
/// route transitions.
///
/// Fail-open: if the channel is missing (tests, unsupported platform) or the
/// native side errors, the call is a no-op — capture protection is never
/// allowed to block messaging.
class ScreenCaptureGuard {
  ScreenCaptureGuard({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('sealed/screen_secure');

  final MethodChannel _channel;
  int _refs = 0;

  /// Number of active holders. Exposed for tests.
  int get refCount => _refs;

  /// Mark one more screen as requiring capture protection.
  Future<void> acquire() async {
    _refs++;
    if (_refs == 1) await _set(true);
  }

  /// Release one holder; protection is dropped when the last one releases.
  Future<void> release() async {
    assert(_refs > 0, 'release() without matching acquire()');
    if (_refs == 0) return;
    _refs--;
    if (_refs == 0) await _set(false);
  }

  Future<void> _set(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', secure);
    } on MissingPluginException {
      // Tests / platforms without the native handler — fail-open.
    } on PlatformException {
      // Native-side failure — fail-open, never block chat on the guard.
    }
  }
}
