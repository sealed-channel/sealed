import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/features/qr/chat_type_picker_sheet.dart';

void main() {
  group('ChatTypePickerSheet', () {
    testWidgets('shows both options and pops with normal', (tester) async {
      ChatType? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showChatTypePicker(ctx, address: 'A' * 58);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Normal chat'), findsOneWidget);
      expect(find.text('Alias chat'), findsOneWidget);
      expect(find.text('Start a conversation'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-type-normal')));
      await tester.pumpAndSettle();

      expect(result, ChatType.normal);
    });

    testWidgets('pops with alias when alias row tapped', (tester) async {
      ChatType? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showChatTypePicker(ctx, address: 'A' * 58);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('chat-type-alias')));
      await tester.pumpAndSettle();

      expect(result, ChatType.alias);
    });

    testWidgets('truncates long address in subtitle', (tester) async {
      const addr =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEFGHIJKLMNOPQRSTUVWXYZ2';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showChatTypePicker(ctx, address: addr),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ABCDEF'), findsOneWidget);
      expect(find.textContaining('XYZ2'), findsOneWidget);
      // Full untruncated address should not appear in the visible body.
      expect(find.text('with $addr'), findsNothing);
    });
  });
}
