/// Golden vectors + round-trip + handshake-symmetry tests for the per-contact
/// stable tag KDFs (Spec H §3).
///
/// Fixture: `test/fixtures/contact_tag_vectors.json` (regen via
/// `test/fixtures/gen_contact_tag_vectors.dart`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';

Uint8List _fromHex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  late CryptoService svc;

  setUp(() {
    svc = CryptoService(
      x25519: X25519(),
      hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
      aesGcm: AesGcm.with256bits(),
      hmac: Hmac.sha256(),
    );
  });

  group('Spec H contact KDFs — golden vectors', () {
    late Map<String, dynamic> fixture;

    setUpAll(() {
      final file = File('test/fixtures/contact_tag_vectors.json');
      fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    test('fixture metadata matches CryptoService constants', () {
      expect(fixture['tag_info'], 'sealed-tag-v1');
      expect(fixture['msg_key_info'], 'sealed-msg-v1');
      expect(fixture['handshake_info'], 'sealed-contact-secret-v1');
    });

    test('≥5 KDF vectors committed', () {
      final v = fixture['kdf_vectors'] as List;
      expect(v.length, greaterThanOrEqualTo(5));
    });

    test(
      'contactRecipientTag + contactMessageKey reproduce golden bytes',
      () async {
        for (final raw in fixture['kdf_vectors'] as List) {
          final v = raw as Map<String, dynamic>;
          final ss = _fromHex(v['shared_secret_hex'] as String);
          final tag = await svc.contactRecipientTag(ss);
          final mk = await svc.contactMessageKey(ss);
          expect(
            tag,
            _fromHex(v['recipient_tag_hex'] as String),
            reason: 'tag drift for ss=${v['shared_secret_hex']}',
          );
          expect(
            mk,
            _fromHex(v['msg_key_hex'] as String),
            reason: 'msg_key drift for ss=${v['shared_secret_hex']}',
          );
          expect(tag.length, 32);
          expect(mk.length, 32);
        }
      },
    );

    test('deriveContactSharedSecret reproduces golden bytes', () async {
      for (final raw in fixture['handshake_vectors'] as List) {
        final v = raw as Map<String, dynamic>;
        final ss = await svc.deriveContactSharedSecret(
          x25519Shared: _fromHex(v['x25519_shared_hex'] as String),
          mlkemShared: _fromHex(v['mlkem_shared_hex'] as String),
          tagSalt: _fromHex(v['tag_salt_hex'] as String),
        );
        expect(ss, _fromHex(v['shared_secret_hex'] as String));
      }
    });
  });

  group('Spec H — AES-GCM round-trip with msg_key', () {
    test(
      'encryptWithEncKey → decryptWithEncKey recovers padded plaintext',
      () async {
        final ss = Uint8List.fromList(
          List.generate(32, (i) => (i * 13) & 0xff),
        );
        final msgKey = await svc.contactMessageKey(ss);

        // padTo1KB stores pad-length in a single byte → plaintext must be
        // ≥ 1024-255 = 769 bytes for the round-trip to recover correctly.
        final plain = Uint8List.fromList(
          List.generate(900, (i) => (i * 11) & 0xff),
        );
        final padded = svc.padTo1KB(plain);
        expect(padded.length, 1024);

        final ct = await svc.encryptWithEncKey(
          encKey: msgKey,
          plainTextBytes: padded,
        );

        // layout: 12B nonce + ct + 16B mac
        expect(ct.length, 12 + 1024 + 16);

        final recovered = await svc.decryptWithEncKey(
          encKey: msgKey,
          cipherText: ct,
        );
        expect(recovered, padded);
        expect(svc.unpadFrom1KB(recovered), plain);
      },
    );

    test('two encrypts under same msg_key use distinct nonces', () async {
      final ss = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final msgKey = await svc.contactMessageKey(ss);
      final p = svc.padTo1KB(
        Uint8List.fromList(List.generate(900, (i) => i & 0xff)),
      );
      final a = await svc.encryptWithEncKey(encKey: msgKey, plainTextBytes: p);
      final b = await svc.encryptWithEncKey(encKey: msgKey, plainTextBytes: p);
      expect(a.sublist(0, 12), isNot(b.sublist(0, 12)));
    });
  });

  group('Spec H — handshake symmetry', () {
    test('both sides of an X25519+ML-KEM handshake derive identical '
        'shared_secret / recipient_tag / msg_key', () async {
      // Simulate a completed hybrid handshake: both parties end up with the
      // same X25519 shared, the same ML-KEM shared, and the same tag_salt
      // (out-of-band). Then deriveContactSharedSecret MUST agree byte-for-byte.
      final rng = Random.secure();
      final x = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      final m = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      final salt = Uint8List.fromList(
        List.generate(32, (_) => rng.nextInt(256)),
      );

      final ssA = await svc.deriveContactSharedSecret(
        x25519Shared: x,
        mlkemShared: m,
        tagSalt: salt,
      );
      final ssB = await svc.deriveContactSharedSecret(
        x25519Shared: x,
        mlkemShared: m,
        tagSalt: salt,
      );
      expect(ssA, ssB);

      final tagA = await svc.contactRecipientTag(ssA);
      final tagB = await svc.contactRecipientTag(ssB);
      expect(tagA, tagB);

      final mkA = await svc.contactMessageKey(ssA);
      final mkB = await svc.contactMessageKey(ssB);
      expect(mkA, mkB);
    });

    test('different tag_salt → different shared_secret + tag', () async {
      final x = Uint8List.fromList(List.generate(32, (i) => i));
      final m = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final salt1 = Uint8List.fromList(List.generate(32, (i) => 1));
      final salt2 = Uint8List.fromList(List.generate(32, (i) => 2));

      final ss1 = await svc.deriveContactSharedSecret(
        x25519Shared: x,
        mlkemShared: m,
        tagSalt: salt1,
      );
      final ss2 = await svc.deriveContactSharedSecret(
        x25519Shared: x,
        mlkemShared: m,
        tagSalt: salt2,
      );
      expect(ss1, isNot(ss2));
      expect(
        await svc.contactRecipientTag(ss1),
        isNot(await svc.contactRecipientTag(ss2)),
      );
    });
  });

  group('Spec H — validation', () {
    test('non-32B shared_secret rejected', () async {
      expect(
        () => svc.contactRecipientTag(Uint8List(31)),
        throwsA(isA<CryptoValidationException>()),
      );
      expect(
        () => svc.contactMessageKey(Uint8List(33)),
        throwsA(isA<CryptoValidationException>()),
      );
    });

    test('non-32B handshake inputs rejected', () async {
      expect(
        () => svc.deriveContactSharedSecret(
          x25519Shared: Uint8List(31),
          mlkemShared: Uint8List(32),
          tagSalt: Uint8List(32),
        ),
        throwsA(isA<CryptoValidationException>()),
      );
    });
  });
}
