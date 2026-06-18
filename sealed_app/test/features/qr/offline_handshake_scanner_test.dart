import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';
import 'package:sealed_app/ui/qr/widgets/offline_handshake_scanner.dart';

Uint8List _rand(Random rng, int len) {
  final out = Uint8List(len);
  for (int i = 0; i < len; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void main() {
  test('emits assembled bytes exactly once per payload', () async {
    final ctrl = StreamController<String>();
    final scanner = OfflineHandshakeScanner(ctrl.stream);

    final emitted = <Uint8List>[];
    final sub = scanner.payloads.listen(emitted.add);

    final payload = _rand(Random(1), 1500);
    final frames = await OfflineHandshakeCodec.encode(payload);
    for (final f in frames) {
      ctrl.add(f);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(emitted.length, 1);
    expect(emitted.first, equals(payload));

    await sub.cancel();
    scanner.dispose();
    await ctrl.close();
  });

  test('ignores wrong-magic and malformed frames between valid ones', () async {
    final ctrl = StreamController<String>();
    final scanner = OfflineHandshakeScanner(ctrl.stream);

    final emitted = <Uint8List>[];
    final sub = scanner.payloads.listen(emitted.add);

    final payload = _rand(Random(2), 900);
    final frames = await OfflineHandshakeCodec.encode(payload);

    // Interleave garbage.
    ctrl.add('!!!garbage!!!');
    ctrl.add(frames[0]);
    ctrl.add('moregarbage====');
    if (frames.length > 1) ctrl.add(frames[1]);
    ctrl.add('AAAA'); // valid base64, wrong magic
    for (int i = 2; i < frames.length; i++) {
      ctrl.add(frames[i]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(emitted.length, 1);
    expect(emitted.first, equals(payload));

    await sub.cancel();
    scanner.dispose();
    await ctrl.close();
  });

  test(
    'switches accumulator when a new payloadId arrives mid-stream',
    () async {
      final ctrl = StreamController<String>();
      final scanner = OfflineHandshakeScanner(ctrl.stream);

      final emitted = <Uint8List>[];
      final sub = scanner.payloads.listen(emitted.add);

      final a = _rand(Random(10), 1500);
      final b = _rand(Random(11), 1500);
      final framesA = await OfflineHandshakeCodec.encode(a);
      final framesB = await OfflineHandshakeCodec.encode(b);

      // Half of A, then all of B.
      ctrl.add(framesA.first);
      for (final f in framesB) {
        ctrl.add(f);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(emitted.length, 1);
      expect(emitted.first, equals(b));

      await sub.cancel();
      scanner.dispose();
      await ctrl.close();
    },
  );

  test('idempotent dispose; no emissions after dispose', () async {
    final ctrl = StreamController<String>();
    final scanner = OfflineHandshakeScanner(ctrl.stream);

    final emitted = <Uint8List>[];
    final sub = scanner.payloads.listen(emitted.add);

    scanner.dispose();
    scanner.dispose(); // second call must not throw

    final payload = _rand(Random(3), 900);
    final frames = await OfflineHandshakeCodec.encode(payload);
    for (final f in frames) {
      ctrl.add(f);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(emitted, isEmpty);

    await sub.cancel();
    await ctrl.close();
  });

  test(
    'emits twice across two complete payloads on the same scanner',
    () async {
      final ctrl = StreamController<String>();
      final scanner = OfflineHandshakeScanner(ctrl.stream);

      final emitted = <Uint8List>[];
      final sub = scanner.payloads.listen(emitted.add);

      final a = _rand(Random(30), 900);
      final b = _rand(Random(31), 900);
      final framesA = await OfflineHandshakeCodec.encode(a);
      final framesB = await OfflineHandshakeCodec.encode(b);

      for (final f in framesA) {
        ctrl.add(f);
      }
      for (final f in framesB) {
        ctrl.add(f);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(emitted.length, 2);
      expect(emitted[0], equals(a));
      expect(emitted[1], equals(b));

      await sub.cancel();
      scanner.dispose();
      await ctrl.close();
    },
  );
}
