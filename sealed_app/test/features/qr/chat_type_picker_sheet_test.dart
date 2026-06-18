import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/ui/qr/widgets/chat_type_picker_sheet.dart';

void main() {
  // Disable the Material ink ripple: its `ink_sparkle.frag` shader asset is not
  // bundled in the widget-test environment and throws on first ripple.
  Widget host(void Function(BuildContext) onOpen) => MaterialApp(
    theme: ThemeData(splashFactory: NoSplash.splashFactory),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => onOpen(ctx),
          child: const Text('open'),
        ),
      ),
    ),
  );

  group('ChatTypePickerSheet', () {
    testWidgets('shows only normal (on-chain + offline alias hidden)', (
      tester,
    ) async {
      ChatType? result;
      await tester.pumpWidget(
        host((ctx) async {
          result = await showChatTypePicker(ctx, address: 'A' * 58);
        }),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Normal chat'), findsOneWidget);
      expect(find.text('Alias chat'), findsNothing);
      expect(find.text('Alias chat (offline)'), findsNothing);
      expect(find.text('Start a conversation'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-type-normal')));
      await tester.pumpAndSettle();
      expect(result, ChatType.normal);
    });

    testWidgets('truncates long address in subtitle', (tester) async {
      const addr =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEFGHIJKLMNOPQRSTUVWXYZ2';
      await tester.pumpWidget(
        host((ctx) => showChatTypePicker(ctx, address: addr)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ABCDEF'), findsOneWidget);
      expect(find.textContaining('XYZ2'), findsOneWidget);
      expect(find.text('with $addr'), findsNothing);
    });
  });
}
