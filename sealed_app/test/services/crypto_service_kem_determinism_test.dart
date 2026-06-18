/// Deterministic ML-KEM encapsulation (initiator-secret recovery).
///
/// With a caller-supplied 32B nonce, encapsulation must be reproducible so the
/// initiator can re-derive its shared secret after a logout/cache wipe — while
/// still interoperating with a normal decapsulation by the recipient.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';

CryptoService _svc() => CryptoService(
  x25519: X25519(),
  hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
  aesGcm: AesGcm.with256bits(),
  hmac: Hmac.sha256(),
);

Uint8List _nonce(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) & 0xff));

void main() {
  late CryptoService svc;
  setUp(() => svc = _svc());

  test('same nonce → identical (ciphertext, sharedSecret)', () async {
    final kp = await svc.generatePqKeyPair();
    final n = _nonce(1);
    final a = await svc.kemEncapsulate(kp.publicKey, nonce: n);
    final b = await svc.kemEncapsulate(kp.publicKey, nonce: n);
    expect(a.ciphertext, b.ciphertext);
    expect(a.sharedSecret, b.sharedSecret);
    expect(a.sharedSecret.length, 32);
  });

  test(
    'derandomized encaps interops with normal decaps (cross-party)',
    () async {
      final bob = await svc.generatePqKeyPair();
      final n = _nonce(7);
      // Alice encapsulates to Bob with a deterministic nonce.
      final enc = await svc.kemEncapsulate(bob.publicKey, nonce: n);
      // Bob decapsulates with his private key → must recover the same secret.
      final bobSecret = await svc.kemDecapsulate(
        enc.ciphertext,
        bob.privateKey,
      );
      expect(bobSecret, enc.sharedSecret);
    },
  );

  test(
    'different recipient key → different shared secret (same nonce)',
    () async {
      final k1 = await svc.generatePqKeyPair();
      final k2 = await svc.generatePqKeyPair();
      final n = _nonce(3);
      final s1 = (await svc.kemEncapsulate(
        k1.publicKey,
        nonce: n,
      )).sharedSecret;
      final s2 = (await svc.kemEncapsulate(
        k2.publicKey,
        nonce: n,
      )).sharedSecret;
      expect(s1, isNot(s2));
    },
  );

  test('default (no nonce) is random → differs across calls', () async {
    final kp = await svc.generatePqKeyPair();
    final a = await svc.kemEncapsulate(kp.publicKey);
    final b = await svc.kemEncapsulate(kp.publicKey);
    expect(a.sharedSecret, isNot(b.sharedSecret));
  });

  test('rejects a wrong-length nonce', () async {
    final kp = await svc.generatePqKeyPair();
    expect(
      () => svc.kemEncapsulate(kp.publicKey, nonce: Uint8List(31)),
      throwsA(isA<Exception>()),
    );
  });
}
