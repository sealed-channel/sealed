import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/ui/onboarding/widgets/legacy_migration_dialog.dart';

void main() {
  group('LegacyMigrationDialog', () {
    testWidgets('renders title, body, and Got it button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLegacyMigrationDialog(ctx),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Usernames have been reset'), findsOneWidget);
      expect(
        find.textContaining('migrated to a new on-chain contract'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('legacy_migration_dialog_got_it')),
        findsOneWidget,
      );
    });

    testWidgets('barrier tap does not dismiss the dialog', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLegacyMigrationDialog(ctx),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Tap outside the dialog content (top-left corner of the screen).
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(find.text('Usernames have been reset'), findsOneWidget);
    });

    testWidgets('Got it button dismisses the dialog and resolves the future', (
      tester,
    ) async {
      var resolved = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    await showLegacyMigrationDialog(ctx);
                    resolved = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('legacy_migration_dialog_got_it')));
      await tester.pumpAndSettle();

      expect(find.text('Usernames have been reset'), findsNothing);
      expect(resolved, isTrue);
    });
  });
}
