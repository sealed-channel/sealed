import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';

Uint8List _rand(Random rng, int len) {
  final out = Uint8List(len);
  for (int i = 0; i < len; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void main() {
  group('OfflineHandshakeCodec.encode/decode', () {
    test('round-trips 865B payload (invite envelope size)', () async {
      final bytes = _rand(Random(1), 865);
      final frames = await OfflineHandshakeCodec.encode(bytes);
      // Handshake envelopes fit a single static frame at the default chunk.
      expect(frames.length, 1);

      final acc = OfflineHandshakeCodec.decoder();
      Uint8List? out;
      for (final f in frames) {
        out = acc.feed(f);
      }
      expect(out, isNotNull);
      expect(out, equals(bytes));
    });

    test('round-trips 841B payload (accept envelope size)', () async {
      final bytes = _rand(Random(2), 841);
      final frames = await OfflineHandshakeCodec.encode(bytes);
      expect(frames.length, 1);
      final acc = OfflineHandshakeCodec.decoder();
      Uint8List? out;
      for (final f in frames) {
        out = acc.feed(f);
      }
      expect(out, equals(bytes));
    });

    test('round-trips 32B payload', () async {
      final bytes = _rand(Random(3), 32);
      final frames = await OfflineHandshakeCodec.encode(bytes);
      expect(frames.length, 1);
      final acc = OfflineHandshakeCodec.decoder();
      expect(acc.feed(frames.single), equals(bytes));
    });

    test('round-trips 1B payload', () async {
      final bytes = Uint8List.fromList([0x42]);
      final frames = await OfflineHandshakeCodec.encode(bytes);
      expect(frames.length, 1);
      final acc = OfflineHandshakeCodec.decoder();
      expect(acc.feed(frames.single), equals(bytes));
    });

    test('out-of-order frames reassemble', () async {
      final bytes = _rand(Random(4), 1500);
      final frames = await OfflineHandshakeCodec.encode(bytes, chunkSize: 380);
      expect(frames.length, greaterThan(2));

      final shuffled = [...frames]..shuffle(Random(99));
      final acc = OfflineHandshakeCodec.decoder();
      Uint8List? out;
      for (final f in shuffled) {
        out = acc.feed(f);
      }
      expect(out, equals(bytes));
    });

    test('duplicate seq frames discarded', () async {
      final bytes = _rand(Random(5), 900);
      final frames = await OfflineHandshakeCodec.encode(bytes, chunkSize: 380);
      final acc = OfflineHandshakeCodec.decoder();

      // Feed first frame several times.
      expect(acc.feed(frames.first), isNull);
      expect(acc.feed(frames.first), isNull);
      expect(acc.feed(frames.first), isNull);

      Uint8List? out;
      for (int i = 1; i < frames.length; i++) {
        out = acc.feed(frames[i]);
      }
      expect(out, equals(bytes));
    });

    test('wrong magic frame rejected (returns null)', () {
      final acc = OfflineHandshakeCodec.decoder();
      // Build a bogus frame with magic=0x00.
      final junk = Uint8List.fromList([0x00, 0, 1, 0, 0, 0xAB, 0xCD]);
      final s = _b64(junk);
      expect(acc.feed(s), isNull);
    });

    test('malformed base64 returns null', () {
      final acc = OfflineHandshakeCodec.decoder();
      expect(acc.feed('!!!not-base64!!!'), isNull);
    });

    test('total=0 frame rejected', () {
      final acc = OfflineHandshakeCodec.decoder();
      final junk = Uint8List.fromList([0xA1, 0, 0, 1, 2, 0xAA]);
      expect(acc.feed(_b64(junk)), isNull);
    });

    test('seq >= total rejected', () {
      final acc = OfflineHandshakeCodec.decoder();
      final junk = Uint8List.fromList([0xA1, 5, 2, 1, 2, 0xAA]);
      expect(acc.feed(_b64(junk)), isNull);
    });

    test('payloadId mismatch resets accumulator to new payload', () async {
      final a = _rand(Random(10), 900);
      final b = _rand(Random(11), 900);
      final framesA = await OfflineHandshakeCodec.encode(a, chunkSize: 380);
      final framesB = await OfflineHandshakeCodec.encode(b, chunkSize: 380);

      final acc = OfflineHandshakeCodec.decoder();
      // Half of A, then full B.
      acc.feed(framesA.first);

      Uint8List? out;
      for (final f in framesB) {
        out = acc.feed(f);
      }
      expect(out, equals(b));
    });

    test('reset clears accumulator state', () async {
      final bytes = _rand(Random(12), 900);
      final frames = await OfflineHandshakeCodec.encode(bytes, chunkSize: 380);
      final acc = OfflineHandshakeCodec.decoder();
      acc.feed(frames.first);
      acc.reset();

      Uint8List? out;
      for (final f in frames) {
        out = acc.feed(f);
      }
      expect(out, equals(bytes));
    });

    test('returns null on encode of empty bytes', () async {
      expect(
        () => OfflineHandshakeCodec.encode(Uint8List(0)),
        throwsArgumentError,
      );
    });

    test(
      'property: 100 random payloads of length 1..2000 round-trip',
      () async {
        final rng = Random(424242);
        for (int i = 0; i < 100; i++) {
          final len = 1 + rng.nextInt(2000);
          final bytes = _rand(rng, len);
          final frames = await OfflineHandshakeCodec.encode(bytes);
          final acc = OfflineHandshakeCodec.decoder();
          Uint8List? out;
          for (final f in frames) {
            out = acc.feed(f);
          }
          expect(
            out,
            equals(bytes),
            reason: 'failed for length=$len (iter $i)',
          );
        }
      },
    );
  });
}

String _b64(Uint8List b) {
  return base64.encode(b);
}
