import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/identity/username_validator.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/ui/settings/widgets/username_change.dart';

/// Proves [ChangeUsernameDialog] renders a rule-specific message per
/// [UsernameErrorCode] instead of the old generic 'Invalid username'.

/// Same overflow-drain + bounded-settle pattern as
/// username_change_credits_gate_test.dart.
void _drainRenderOverflow(WidgetTester tester) {
  while (true) {
    final ex = tester.takeException();
    if (ex == null) return;
    if (!ex.toString().contains('A RenderFlex overflowed')) {
      throw ex;
    }
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  _drainRenderOverflow(tester);
}

class _FakeUsernameController extends UsernameController {
  _FakeUsernameController(this.result, this.input);

  final AvailabilityResult result;
  final String input;

  @override
  Future<UsernameCheckState> build() async => UsernameCheckState(
    input: input,
    isChecking: false,
    availabilityResult: result,
  );

  @override
  void onInputChanged(String raw) {}
}

Future<void> _pumpDialog(
  WidgetTester tester,
  AvailabilityResult result, {
  String input = 'x',
}) async {
  tester.view.physicalSize = const Size(360, 752);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        usernameControllerProvider.overrideWith(
          () => _FakeUsernameController(result, input),
        ),
      ],
      child: ScreenUtilInit(
        designSize: const Size(360, 752),
        builder: (context, _) =>
            const MaterialApp(home: Scaffold(body: ChangeUsernameDialog())),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  group('ChangeUsernameDialog error text', () {
    const cases = <UsernameErrorCode, String>{
      UsernameErrorCode.badLen: '3–20 characters',
      UsernameErrorCode.badChar: 'Only a–z, 0–9 and _',
      UsernameErrorCode.notAscii: 'Only a–z, 0–9 and _',
      UsernameErrorCode.leadingUnderscore: "Can't start with _",
      UsernameErrorCode.trailingUnderscore: "Can't end with _",
      UsernameErrorCode.reserved: 'This name is reserved',
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key} → "${entry.value}"', (tester) async {
        await _pumpDialog(tester, NameInvalid(entry.key));
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('Invalid username'), findsNothing);
      });
    }

    testWidgets('empty code shows no error', (tester) async {
      await _pumpDialog(tester, const NameInvalid(UsernameErrorCode.empty));
      expect(find.text('Invalid username'), findsNothing);
      expect(find.textContaining("Can't"), findsNothing);
    });

    testWidgets('taken name keeps the taken message', (tester) async {
      await _pumpDialog(tester, const NameTaken(), input: 'igor');
      expect(find.text('@igor is taken'), findsOneWidget);
    });
  });
}
