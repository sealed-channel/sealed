import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/platform/screen_capture_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sealed/screen_secure');
  late List<MethodCall> calls;

  void mockChannel({Object? Function(MethodCall call)? handler}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler?.call(call);
        });
  }

  setUp(() {
    calls = [];
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('first acquire invokes setSecure(true) once', () async {
    final guard = ScreenCaptureGuard();
    await guard.acquire();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setSecure');
    expect(calls.single.arguments, isTrue);
    expect(guard.refCount, 1);
  });

  test('nested acquire does not re-invoke the channel', () async {
    final guard = ScreenCaptureGuard();
    await guard.acquire();
    await guard.acquire();

    expect(calls, hasLength(1));
    expect(guard.refCount, 2);
  });

  test('release to zero invokes setSecure(false)', () async {
    final guard = ScreenCaptureGuard();
    await guard.acquire();
    await guard.acquire();
    await guard.release();

    expect(calls, hasLength(1), reason: 'inner release must not toggle');

    await guard.release();

    expect(calls, hasLength(2));
    expect(calls.last.method, 'setSecure');
    expect(calls.last.arguments, isFalse);
    expect(guard.refCount, 0);
  });

  test('missing native handler is fail-open (no throw)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    final guard = ScreenCaptureGuard();
    await expectLater(guard.acquire(), completes);
    await expectLater(guard.release(), completes);
  });

  test('native PlatformException is fail-open (no throw)', () async {
    mockChannel(handler: (_) => throw PlatformException(code: 'no_window'));

    final guard = ScreenCaptureGuard();
    await expectLater(guard.acquire(), completes);
    expect(guard.refCount, 1);
  });
}
