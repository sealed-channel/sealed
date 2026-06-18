import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/ui/shared/widgets/success_sheet.dart';

Widget _wrap({required Widget child}) {
  return ScreenUtilInit(
    designSize: const Size(360, 752),
    builder: (context, _) => MaterialApp(home: child),
  );
}

void main() {
  group('SuccessSheet', () {
    testWidgets('passcode kind renders passcode copy', (tester) async {
      await tester.pumpWidget(
        _wrap(child: const SuccessSheet(kind: SuccessSheetKind.passcode)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Passcode'), findsOneWidget);
      expect(find.text('Passcode successfully changed'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('terminationCode kind renders termination copy', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          child: const SuccessSheet(kind: SuccessSheetKind.terminationCode),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Termination code'), findsOneWidget);
      expect(
        find.text('Termination code successfully changed'),
        findsOneWidget,
      );
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('Continue tap completes the showSuccessSheet future', (
      tester,
    ) async {
      bool completed = false;

      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(360, 752),
          builder: (context, _) => MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      await showSuccessSheet(ctx, SuccessSheetKind.passcode);
                      completed = true;
                    },
                    child: const Text('open'),
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

      expect(find.text('Passcode successfully changed'), findsOneWidget);
      expect(completed, isFalse);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Passcode successfully changed'), findsNothing);
      expect(completed, isTrue);
    });
  });
}
