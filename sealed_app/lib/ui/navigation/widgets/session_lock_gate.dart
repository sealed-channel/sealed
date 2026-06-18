import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/ui/onboarding/screens/lock.dart';

/// App-level lock layer, mounted ABOVE the root [Navigator] via
/// [MaterialApp.builder] (see `SealedApp`).
///
/// The overlay must sit above the Navigator, not inside the `home:` route:
/// the home route's subtree paints BELOW every pushed route, so a lock that
/// fires while ChatScreen (or any pushed route/dialog/sheet) is open would
/// stay hidden underneath it — chat content remained visible while the
/// session was locked, and the lock screen only surfaced after popping back.
/// Mounted here it covers all routes, dialogs and bottom sheets
/// unconditionally.
class SessionLockGate extends ConsumerWidget {
  const SessionLockGate({super.key, required this.child});

  /// The root Navigator subtree handed to [MaterialApp.builder].
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(pinSessionProvider.select((s) => s.phase));
    final needsPinSetup = ref.watch(
      pinSessionProvider.select((s) => s.needsPinSetup),
    );
    final appReady = ref.watch(appContentReadyProvider);

    // Keep the lock overlay up not only while `locked`, but also through the
    // FIRST post-unlock window — phase has flipped to `unlocked` but AppShell
    // has not yet rendered MainShell (appContentReady=false). This lets the
    // lock screen's keypad keep pulsing over the loading AppShell instead of
    // cutting to a separate loading screen. Excludes the post-create flow
    // (`needsPinSetup`), which has no lock screen and shows its own spinner.
    final showLock =
        phase == PinPhase.locked ||
        (phase == PinPhase.unlocked && !needsPinSetup && !appReady);

    // Kill focus when locking, otherwise the soft keyboard (an OS surface,
    // drawn above any app widget) stays open over the lock screen and feeds
    // keystrokes into the hidden text field beneath it.
    //
    // `unfocus()` alone only clears the Flutter focus node; it does NOT
    // reliably close the platform IME. The lock fires from a background
    // inactivity timer (see AppShell._maybeLockNow), so the soft keyboard is
    // dismissed while the app is paused — Android then RESTORES the open IME
    // on resume, leaving it stacked over the PIN keypad with the user frozen.
    // Force the platform input surface shut as well so it cannot be restored.
    ref.listen(pinSessionProvider.select((s) => s.phase), (_, next) {
      if (next == PinPhase.locked) {
        FocusManager.instance.primaryFocus?.unfocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
    });
    return SessionLockOverlay(isLocked: showLock, child: child);
  }
}

/// Composition half of [SessionLockGate], split out so widget tests can
/// drive `isLocked` directly without the pin-session provider plumbing.
class SessionLockOverlay extends StatelessWidget {
  const SessionLockOverlay({
    super.key,
    required this.isLocked,
    required this.child,
  });

  final bool isLocked;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLocked)
          // Own Navigator: this layer sits above the root one, so
          // LockScreenV2's dialogs (final-attempt warning, forgot-passcode)
          // need a local Navigator ancestor to mount into. Wipe flows that
          // must clear the real route stack go through the global
          // navigatorKey instead (see LockScreenV2._wipeAndExit).
          // HeroControllerScope.none: the root HeroController must not
          // observe a second Navigator (asserts otherwise); no heroes here.
          Positioned.fill(
            child: HeroControllerScope.none(
              child: Navigator(
                onGenerateRoute: (_) =>
                    MaterialPageRoute(builder: (_) => const LockScreenV2()),
              ),
            ),
          ),
      ],
    );
  }
}
