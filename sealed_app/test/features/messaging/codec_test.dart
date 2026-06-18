import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/message_codec.dart';

Uint8List _bytes(int len, {int seed = 7}) {
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    out[i] = (seed + i * 31) & 0xFF;
  }
  return out;
}

void main() {
  group('encodeHybridFirstFrame / decodeHybridFirstFrame', () {
    test('round-trips for varied inner-ciphertext lengths', () {
      final kemCt = _bytes(kKemCtLen, seed: 1);
      // Must produce frame.length > kLegacyKemFrameLen (>800) so receivers
      // discriminate hybrid from legacy. Min innerLen = 31.
      // Must also stay ≤ kHybridFrameMaxBytes (992 → innerLen ≤ 222).
      for (final innerLen in const [31, 50, 100, 200, 222]) {
        final inner = _bytes(innerLen, seed: innerLen + 1);
        final frame = encodeHybridFirstFrame(
          kemCt: kemCt,
          innerCiphertext: inner,
        );
        expect(frame.length, kKemCtLen + 2 + innerLen);
        expect(frame.length, greaterThan(kLegacyKemFrameLen));

        final decoded = decodeHybridFirstFrame(frame);
        expect(decoded, isNotNull);
        expect(decoded!.kemCt, kemCt);
        expect(decoded.innerCiphertext, inner);
      }
    });

    test('encode refuses inner lengths that collide with the legacy range', () {
      final kemCt = _bytes(kKemCtLen);
      for (final tooShort in const [0, 1, 10, 30]) {
        expect(
          () => encodeHybridFirstFrame(
            kemCt: kemCt,
            innerCiphertext: _bytes(tooShort),
          ),
          throwsArgumentError,
          reason: 'innerLen=$tooShort should fail (frame too short)',
        );
      }
    });

    test('encode rejects wrong kemCt length', () {
      expect(
        () => encodeHybridFirstFrame(
          kemCt: _bytes(kKemCtLen - 1),
          innerCiphertext: _bytes(10),
        ),
        throwsArgumentError,
      );
    });

    test('encode throws MessageTooLargeError when total exceeds cap', () {
      final kemCt = _bytes(kKemCtLen);
      // Max inner = 992 - 768 - 2 = 222 bytes. 223 should bust.
      final tooBig = _bytes(223);
      expect(
        () => encodeHybridFirstFrame(kemCt: kemCt, innerCiphertext: tooBig),
        throwsA(isA<MessageTooLargeError>()),
      );
    });

    test('encode succeeds at the exact cap (inner=222 → frame=992)', () {
      // Boundary check matching the AVM log budget: 32B sender_eph framing +
      // 992B hybrid frame = 1024B logged. One byte more should reject.
      final kemCt = _bytes(kKemCtLen);
      final maxInner = _bytes(222);
      final frame = encodeHybridFirstFrame(
        kemCt: kemCt,
        innerCiphertext: maxInner,
      );
      expect(frame.length, kHybridFrameMaxBytes);
    });

    test(
      'decode returns null for legacy 800B frame (caller falls through)',
      () {
        final legacy = _bytes(kLegacyKemFrameLen);
        expect(decodeHybridFirstFrame(legacy), isNull);
      },
    );

    test('decode returns null for any frame <= legacy length', () {
      expect(decodeHybridFirstFrame(_bytes(100)), isNull);
      expect(decodeHybridFirstFrame(_bytes(kLegacyKemFrameLen)), isNull);
    });

    test('decode throws on oversized frame', () {
      final huge = _bytes(kHybridFrameMaxBytes + 1);
      expect(
        () => decodeHybridFirstFrame(huge),
        throwsA(isA<MessageTooLargeError>()),
      );
    });

    test('decode throws FormatException on inner length mismatch', () {
      final kemCt = _bytes(kKemCtLen, seed: 1);
      final inner = _bytes(50);
      final frame = encodeHybridFirstFrame(
        kemCt: kemCt,
        innerCiphertext: inner,
      );
      // Corrupt the length prefix to claim more bytes than present.
      final corrupt = Uint8List.fromList(frame);
      corrupt[kKemCtLen] = 0xFF;
      corrupt[kKemCtLen + 1] = 0xFF;
      expect(
        () => decodeHybridFirstFrame(corrupt),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('encodeHybridInnerEnvelope / decodeHybridInnerEnvelope', () {
    test('round-trips content + timestamp', () {
      const ts = 1717000000123;
      for (final n in const [1, 32, 200, 280]) {
        final content = _bytes(n, seed: n);
        final env = encodeHybridInnerEnvelope(
          timestampMs: ts,
          content: content,
        );
        // header is 1B version + 8B ts.
        expect(env[0], kHybridInnerVersion);

        final out = decodeHybridInnerEnvelope(env);
        expect(out.timestampMs, ts);
        expect(out.content, content);
      }
    });

    test('decode rejects unsupported version byte', () {
      final content = _bytes(20);
      final env = encodeHybridInnerEnvelope(timestampMs: 1, content: content);
      env[0] = 0x99;
      expect(
        () => decodeHybridInnerEnvelope(env),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('unsupported hybrid inner version'),
          ),
        ),
      );
    });

    test('decode rejects envelope shorter than header', () {
      expect(
        () => decodeHybridInnerEnvelope(_bytes(5)),
        throwsA(isA<FormatException>()),
      );
    });

    test('encode rejects negative timestamp', () {
      expect(
        () => encodeHybridInnerEnvelope(timestampMs: -1, content: _bytes(10)),
        throwsArgumentError,
      );
    });
  });

  group('hybridFrameFits', () {
    test('rejects negative input', () {
      expect(() => hybridFrameFits(-1), throwsArgumentError);
    });

    test('boundary values around the cap', () {
      // Max gzippedLen such that 768+2+9+gzipped+28 <= 992
      //   => gzipped <= 992 - 807 = 185
      expect(hybridFrameFits(0), isTrue);
      expect(hybridFrameFits(100), isTrue);
      expect(hybridFrameFits(185), isTrue);
      expect(hybridFrameFits(186), isFalse);
      expect(hybridFrameFits(500), isFalse);
    });

    test('predicate-true implies encode succeeds (property)', () {
      // For every n in [0..220], if predicate accepts then a synthetic
      // innerCiphertext of length (n + AES-GCM overhead) must encode
      // without MessageTooLargeError.
      final kemCt = _bytes(kKemCtLen);
      for (var n = 0; n <= 220; n++) {
        if (!hybridFrameFits(n)) continue;
        final innerCt = _bytes(kHybridInnerHeaderLen + n + kAesGcmOverheadLen);
        // The collision guard rejects below 31B inner — those n values
        // also fail the property by design.
        if (innerCt.length < kHybridFrameMaxBytes - kKemCtLen - 2 + 1 &&
            kKemCtLen + 2 + innerCt.length > kLegacyKemFrameLen) {
          expect(
            () =>
                encodeHybridFirstFrame(kemCt: kemCt, innerCiphertext: innerCt),
            returnsNormally,
            reason: 'predicate accepted n=$n but encode rejected',
          );
        }
      }
    });
  });
}
