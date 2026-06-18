import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/ui/shared/widgets/secure_screen.dart';

void main() {
  const channel = MethodChannel('sealed/screen_secure');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('mount acquires, unmount releases', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SecureScreen(child: Text('chat'))),
      ),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setSecure');
    expect(calls.single.arguments, isTrue);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: Text('list'))),
    );

    expect(calls, hasLength(2));
    expect(calls.last.arguments, isFalse);
  });

  testWidgets('stacked secure screens do not strobe the flag', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SecureScreen(child: SecureScreen(child: Text('stacked'))),
        ),
      ),
    );

    expect(calls, hasLength(1), reason: 'second acquire must not re-invoke');
    expect(calls.single.arguments, isTrue);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: Text('gone'))),
    );

    expect(calls, hasLength(2));
    expect(calls.last.arguments, isFalse);
  });
}
