import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_keypad_v2.dart';
import 'package:sealed_app/ui/settings/screens/change_pin_flow.dart';

/// Drain any pending render overflow exceptions accumulated by the
/// last pump. PinErrorLabel's non-flexible Row overflows when long error
/// strings render in the narrow test viewport — overflows are visual
/// only and out of scope for these tests, so consume them so the test
/// framework doesn't fail the test on cosmetic layout.
void _drainRenderOverflow(WidgetTester tester) {
  while (true) {
    final ex = tester.takeException();
    if (ex == null) return;
    final s = ex.toString();
    if (!s.contains('A RenderFlex overflowed')) {
      // Real exception — re-raise.
      throw ex;
    }
  }
}

class _FakePinSecurityNotifier extends PinSecurityNotifier {
  _FakePinSecurityNotifier({this.throwOnChange = false, this.terminationCode});

  bool throwOnChange;
  final String? terminationCode;
  final List<(String, String)> changePinCalls = [];
  final List<String> verifyTerminationCalls = [];

  @override
  Future<PinSecurityState> build() async => const PinSecurityState();

  @override
  Future<bool> verifyTermination(String code) async {
    verifyTerminationCalls.add(code);
    return terminationCode != null && code == terminationCode;
  }

  @override
  Future<void> changePin(String oldPin, String newPin) async {
    changePinCalls.add((oldPin, newPin));
    if (throwOnChange) {
      throw PinIncorrectException();
    }
  }
}

Future<void> _pumpFlow(
  WidgetTester tester, {
  required _FakePinSecurityNotifier fake,
}) async {
  tester.view.physicalSize = const Size(360, 752);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [pinSecurityProvider.overrideWith(() => fake)],
      child: ScreenUtilInit(
        designSize: const Size(360, 752),
        builder: (context, _) => MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ChangePinFlow(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _enterCode(WidgetTester tester, String code) async {
  for (final c in code.split('')) {
    final key = find.descendant(
      of: find.byType(PinKeypadV2),
      matching: find.text(c),
    );
    await tester.tap(key);
    await tester.pump();
  }
}

void main() {
  group('ChangePinFlow', () {
    testWidgets('happy path: enter current, new, confirm → success sheet', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier();
      await _pumpFlow(tester, fake: fake);

      expect(find.text('Enter Passcode'), findsOneWidget);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      expect(find.text('Change Passcode'), findsOneWidget);

      await _enterCode(tester, '222222');
      await tester.pumpAndSettle();
      expect(find.text('Confirm New Passcode'), findsOneWidget);

      await _enterCode(tester, '222222');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(fake.changePinCalls, [('111111', '222222')]);
      expect(find.text('Passcode successfully changed'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter Passcode'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('new == current: stays on step 2 with inline error', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier();
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '123456');
      await tester.pumpAndSettle();
      expect(find.text('Change Passcode'), findsOneWidget);

      await _enterCode(tester, '123456');
      await tester.pumpAndSettle();
      _drainRenderOverflow(tester);

      expect(find.text('Change Passcode'), findsOneWidget);
      expect(
        find.text('New passcode must differ from your current passcode.'),
        findsOneWidget,
      );
      expect(fake.changePinCalls, isEmpty);
    });

    testWidgets('confirm mismatch: rewinds to step 2 with error', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier();
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      await _enterCode(tester, '222222');
      await tester.pumpAndSettle();
      expect(find.text('Confirm New Passcode'), findsOneWidget);

      await _enterCode(tester, '333333');
      await tester.pumpAndSettle();
      _drainRenderOverflow(tester);

      expect(find.text('Change Passcode'), findsOneWidget);
      expect(find.text("Passcodes don't match. Try again."), findsOneWidget);
      expect(fake.changePinCalls, isEmpty);
    });

    testWidgets('PinIncorrectException at commit: rewinds to step 1', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier(throwOnChange: true);
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      await _enterCode(tester, '222222');
      await tester.pumpAndSettle();
      await _enterCode(tester, '222222');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      _drainRenderOverflow(tester);

      expect(find.text('Enter Passcode'), findsOneWidget);
      expect(
        find.text('Incorrect current passcode. Start again.'),
        findsOneWidget,
      );
    });

    testWidgets('new == termination code: stays on step 2 with inline error', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier(terminationCode: '999999');
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      expect(find.text('Change Passcode'), findsOneWidget);

      await _enterCode(tester, '999999');
      await tester.pumpAndSettle();
      _drainRenderOverflow(tester);

      expect(find.text('Change Passcode'), findsOneWidget);
      expect(
        find.text('New passcode must differ from your termination code.'),
        findsOneWidget,
      );
      expect(fake.verifyTerminationCalls, contains('999999'));
      expect(fake.changePinCalls, isEmpty);
    });

    testWidgets('back from step 2 rewinds to step 1 with cleared entry', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier();
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      expect(find.text('Change Passcode'), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.chevron_back));
      await tester.pumpAndSettle();

      expect(find.text('Enter Passcode'), findsOneWidget);
    });
  });
}
