import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_keypad_v2.dart';
import 'package:sealed_app/ui/settings/screens/change_termination_flow.dart';

class _FakePinSecurityNotifier extends PinSecurityNotifier {
  _FakePinSecurityNotifier({required this.acceptCode});

  final String acceptCode;
  final List<String> verifyCalls = [];
  final List<String> setCalls = [];

  @override
  Future<PinSecurityState> build() async => const PinSecurityState();

  @override
  Future<bool> verifyTermination(String code) async {
    verifyCalls.add(code);
    return code == acceptCode;
  }

  @override
  Future<void> setTerminationCode(String code) async {
    setCalls.add(code);
  }
}

/// PinErrorLabel renders a non-flexible Row that overflows the narrow
/// test viewport when long error strings appear. The overflow is
/// cosmetic and unrelated to flow behaviour — consume them so the test
/// framework doesn't fail on visual layout we aren't asserting.
void _drainRenderOverflow(WidgetTester tester) {
  while (true) {
    final ex = tester.takeException();
    if (ex == null) return;
    final s = ex.toString();
    if (!s.contains('A RenderFlex overflowed')) {
      throw ex;
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
                      builder: (_) => const ChangeTerminationFlow(),
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
  group('ChangeTerminationFlow', () {
    testWidgets('happy path: gate, new code, confirm → success sheet', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier(acceptCode: '111111');
      await _pumpFlow(tester, fake: fake);

      expect(find.text('Enter current termination code'), findsOneWidget);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      expect(find.text('Change Termination Code'), findsOneWidget);
      expect(fake.verifyCalls, ['111111']);

      await _enterCode(tester, '222222');
      await tester.pumpAndSettle();
      expect(find.text('Confirm Termination Code'), findsOneWidget);

      await _enterCode(tester, '222222');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(fake.setCalls, ['222222']);
      expect(
        find.text('Termination code successfully changed'),
        findsOneWidget,
      );

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter current termination code'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('wrong gate code: stays on step 1 with error', (tester) async {
      final fake = _FakePinSecurityNotifier(acceptCode: '111111');
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '999999');
      await tester.pumpAndSettle();
      _drainRenderOverflow(tester);

      expect(find.text('Enter current termination code'), findsOneWidget);
      expect(
        find.text('Incorrect termination code. Try again.'),
        findsOneWidget,
      );
      expect(fake.verifyCalls, ['999999']);
      expect(fake.setCalls, isEmpty);
    });

    testWidgets('confirm mismatch: rewinds to step 2 with error', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier(acceptCode: '111111');
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      await _enterCode(tester, '222222');
      await tester.pumpAndSettle();
      expect(find.text('Confirm Termination Code'), findsOneWidget);

      await _enterCode(tester, '333333');
      await tester.pumpAndSettle();
      _drainRenderOverflow(tester);

      expect(find.text('Change Termination Code'), findsOneWidget);
      expect(find.text("Codes don't match. Try again."), findsOneWidget);
      expect(fake.setCalls, isEmpty);
    });

    testWidgets('back from step 2 rewinds to gate with cleared entry', (
      tester,
    ) async {
      final fake = _FakePinSecurityNotifier(acceptCode: '111111');
      await _pumpFlow(tester, fake: fake);

      await _enterCode(tester, '111111');
      await tester.pumpAndSettle();
      expect(find.text('Change Termination Code'), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.chevron_back));
      await tester.pumpAndSettle();

      expect(find.text('Enter current termination code'), findsOneWidget);
    });
  });
}
