import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sealed_app/ui/qr/widgets/offline_handshake_qr_view.dart';

Uint8List _rand(Random rng, int len) {
  final out = Uint8List(len);
  for (int i = 0; i < len; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

Future<void> _settleEncode(WidgetTester tester) async {
  // The widget encodes asynchronously in initState; pump the microtask queue
  // and one frame so the first QR is mounted.
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  testWidgets('renders single-frame for 1B payload', (tester) async {
    final payload = Uint8List.fromList([0x42]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfflineHandshakeQrView(payload: payload, size: 200),
        ),
      ),
    );
    await _settleEncode(tester);

    expect(find.byType(QrImageView), findsOneWidget);
    // Single frame — counter overlay hidden.
    expect(find.text('1/1'), findsNothing);
  });

  testWidgets('renders multi-frame for 2000B payload', (tester) async {
    final payload = _rand(Random(7), 2000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfflineHandshakeQrView(payload: payload, size: 200),
        ),
      ),
    );
    await _settleEncode(tester);

    expect(find.byType(QrImageView), findsOneWidget);
    // 2000 / 1000 = ceil 2 → '1/2' visible at start.
    expect(find.textContaining('/2'), findsOneWidget);
  });

  testWidgets('cycles through every frame within total * 500ms', (
    tester,
  ) async {
    final payload = _rand(Random(8), 3500);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfflineHandshakeQrView(payload: payload, size: 200),
        ),
      ),
    );
    await _settleEncode(tester);

    // 3500 / 1000 = ceil 4.
    expect(find.text('1/4'), findsOneWidget);

    // Advance through the cycle; collect counter text after each tick.
    final seen = <String>{'1/4'};
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      for (final s in ['1/4', '2/4', '3/4', '4/4']) {
        if (find.text(s).evaluate().isNotEmpty) {
          seen.add(s);
          break;
        }
      }
    }
    expect(seen, containsAll(['1/4', '2/4', '3/4', '4/4']));
  });

  testWidgets('disposes timer cleanly (no leak after unmount)', (tester) async {
    final payload = _rand(Random(9), 1500);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfflineHandshakeQrView(payload: payload, size: 200),
        ),
      ),
    );
    await _settleEncode(tester);

    // Unmount.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    // If the timer leaked, pumping a frame interval would throw "A Timer is
    // still pending" via the test framework's leak detector. We pump several.
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('payload swap re-encodes and resets counter', (tester) async {
    final a = _rand(Random(20), 3500);
    final b = _rand(Random(21), 2500);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OfflineHandshakeQrView(payload: a, size: 200)),
      ),
    );
    await _settleEncode(tester);
    expect(find.text('1/4'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OfflineHandshakeQrView(payload: b, size: 200)),
      ),
    );
    await _settleEncode(tester);
    // 2500 / 1000 = ceil 3.
    expect(find.text('1/3'), findsOneWidget);
  });
}
