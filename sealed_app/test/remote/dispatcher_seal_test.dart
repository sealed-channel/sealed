import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/remote/seal_dispatcher.dart';

/// Minimal Dart-side decryptor mirroring the Node server's
/// `createDispatcherDecryptor` so we can verify round-trip without invoking
/// the actual server. If this round-trips, the Node server (which uses the
/// same primitives over the same byte layout) will too.
Future<String> _testDecrypt({
  required Uint8List envelope,
  required SimpleKeyPair dispatcherKeyPair,
  required Uint8List dispatcherPubKey,
}) async {
  expect(envelope.length, DispatcherSeal.envelopeSize);
  final ephPub = envelope.sublist(0, DispatcherSeal.ephPubSize);
  final ct = envelope.sublist(
    DispatcherSeal.ephPubSize,
    DispatcherSeal.ephPubSize + DispatcherSeal.ciphertextSize,
  );
  final mac = envelope.sublist(
    DispatcherSeal.ephPubSize + DispatcherSeal.ciphertextSize,
  );

  final x25519 = X25519();
  final shared = await x25519.sharedSecretKey(
    keyPair: dispatcherKeyPair,
    remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519),
  );
  final sharedBytes = await shared.extractBytes();

  final salt = Uint8List(DispatcherSeal.ephPubSize * 2)
    ..setRange(0, DispatcherSeal.ephPubSize, ephPub)
    ..setRange(
      DispatcherSeal.ephPubSize,
      DispatcherSeal.ephPubSize * 2,
      dispatcherPubKey,
    );

  final nonceHash = await Blake2b().hash(salt);
  final nonce = Uint8List.fromList(
    nonceHash.bytes.sublist(0, DispatcherSeal.nonceSize),
  );

  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: DispatcherSeal.keySize);
  final aesKey = await hkdf.deriveKey(
    secretKey: SecretKey(sharedBytes),
    nonce: salt,
    info: 'sealed-push-token-v1'.codeUnits,
  );

  final aesGcm = AesGcm.with256bits();
  final plain = await aesGcm.decrypt(
    SecretBox(ct, nonce: nonce, mac: Mac(mac)),
    secretKey: aesKey,
  );
  expect(plain.length, DispatcherSeal.paddedTokenSize);
  final tokenLen = (plain[0] << 8) | plain[1];
  return String.fromCharCodes(plain.sublist(2, 2 + tokenLen));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DispatcherSeal.sealToken', () {
    late SimpleKeyPair dispatcherKeyPair;
    late Uint8List dispatcherPubKey;

    setUp(() async {
      dispatcherKeyPair = await X25519().newKeyPair();
      final pub = await dispatcherKeyPair.extractPublicKey();
      dispatcherPubKey = Uint8List.fromList(pub.bytes);
    });

    test('produces a 304-byte envelope', () async {
      final seal = DispatcherSeal();
      final env = await seal.sealToken('hello', dispatcherPubKey);
      expect(env.length, 304);
    });

    test('round-trips through the dispatcher decryptor', () async {
      final seal = DispatcherSeal();
      const tok = 'a-typical-fcm-token:APA91bABCDEF1234567890';
      final env = await seal.sealToken(tok, dispatcherPubKey);
      final got = await _testDecrypt(
        envelope: env,
        dispatcherKeyPair: dispatcherKeyPair,
        dispatcherPubKey: dispatcherPubKey,
      );
      expect(got, tok);
    });

    test('round-trips a 254-byte token (max length)', () async {
      final seal = DispatcherSeal();
      final tok = 'x' * DispatcherSeal.maxTokenBytes;
      final env = await seal.sealToken(tok, dispatcherPubKey);
      final got = await _testDecrypt(
        envelope: env,
        dispatcherKeyPair: dispatcherKeyPair,
        dispatcherPubKey: dispatcherPubKey,
      );
      expect(got, tok);
    });

    test('rejects empty token', () async {
      final seal = DispatcherSeal();
      expect(() => seal.sealToken('', dispatcherPubKey), throwsArgumentError);
    });

    test('rejects oversized token', () async {
      final seal = DispatcherSeal();
      final tok = 'x' * (DispatcherSeal.maxTokenBytes + 1);
      expect(() => seal.sealToken(tok, dispatcherPubKey), throwsArgumentError);
    });

    test('rejects wrong-size dispatcher pubkey', () async {
      final seal = DispatcherSeal();
      expect(() => seal.sealToken('x', Uint8List(31)), throwsArgumentError);
    });

    test('produces fresh ephemeral key for each call', () async {
      final seal = DispatcherSeal();
      final env1 = await seal.sealToken('x', dispatcherPubKey);
      final env2 = await seal.sealToken('x', dispatcherPubKey);
      expect(env1.sublist(0, 32), isNot(env2.sublist(0, 32)));
    });
  });
}
