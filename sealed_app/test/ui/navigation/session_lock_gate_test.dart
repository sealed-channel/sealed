import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/ui/navigation/widgets/session_lock_gate.dart';
import 'package:sealed_app/ui/onboarding/screens/lock.dart';

/// Regression guard for "lock screen only appears after pressing back".
///
/// Root cause: the lock overlay lived inside AppShell, the `home:` route of
/// the root Navigator. Any pushed route (ChatScreen, settings, …) painted on
/// top of it, so a lock that fired while such a route was open stayed hidden
/// underneath — chat content remained visible while the session was locked,
/// and the lock screen only surfaced once the user popped back to home.
///
/// Fix: SessionLockGate/SessionLockOverlay mounted ABOVE the root Navigator
/// via MaterialApp.builder (see app.dart), covering every route. These tests
/// pump that exact composition: a route pushed over home must be covered and
/// non-interactive while locked, and still on top after unlock.
void main() {
  Future<GlobalKey<NavigatorState>> pumpLockableApp(
    WidgetTester tester,
    ValueNotifier<bool> locked,
    VoidCallback onChatTap,
  ) async {
    // Phone-sized surface matching the Figma design frame — the default
    // 800x600 test window overflows the lock screen's keypad column.
    tester.view.physicalSize = const Size(360 * 3, 752 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        child: ScreenUtilInit(
          designSize: const Size(360, 752),
          minTextAdapt: true,
          builder: (context, child) => MaterialApp(
            navigatorKey: navKey,
            home: child,
            // Same wiring as SealedApp: overlay above the root Navigator.
            builder: (context, navigator) => ValueListenableBuilder<bool>(
              valueListenable: locked,
              builder: (_, isLocked, _) =>
                  SessionLockOverlay(isLocked: isLocked, child: navigator!),
            ),
          ),
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: onChatTap,
              child: const Text('chat content'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navKey;
  }

  testWidgets('lock fired while a route is pushed covers that route', (
    tester,
  ) async {
    final locked = ValueNotifier<bool>(false);
    var tapsReachedChat = 0;
    await pumpLockableApp(tester, locked, () => tapsReachedChat++);

    expect(find.text('chat content'), findsOneWidget);
    expect(find.byType(LockScreenV2), findsNothing);

    locked.value = true;
    await tester.pumpAndSettle();

    // Lock screen mounted above the pushed route — visible immediately,
    // without popping back.
    expect(find.byType(LockScreenV2), findsOneWidget);

    // The chat underneath must not be hittable through the lock layer.
    await tester.tap(find.text('chat content'), warnIfMissed: false);
    await tester.pump();
    expect(tapsReachedChat, 0);
  });

  testWidgets('unlock removes the overlay and keeps the pushed route on top', (
    tester,
  ) async {
    final locked = ValueNotifier<bool>(true);
    var tapsReachedChat = 0;
    await pumpLockableApp(tester, locked, () => tapsReachedChat++);

    expect(find.byType(LockScreenV2), findsOneWidget);

    locked.value = false;
    await tester.pumpAndSettle();

    // Overlay gone; navigation state preserved — the user is back in the
    // chat they had open, and it is interactive again.
    expect(find.byType(LockScreenV2), findsNothing);
    expect(find.text('chat content'), findsOneWidget);
    await tester.tap(find.text('chat content'));
    await tester.pump();
    expect(tapsReachedChat, 1);
  });
}
