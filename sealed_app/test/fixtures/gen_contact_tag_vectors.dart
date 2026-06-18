/// Generator for `contact_tag_vectors.json`.
///
/// Run from `sealed_app/` with:
///   dart run test/fixtures/gen_contact_tag_vectors.dart > test/fixtures/contact_tag_vectors.json
///
/// Produces 5 deterministic vectors covering:
///   - contactRecipientTag(sharedSecret)
///   - contactMessageKey(sharedSecret)
///   - deriveContactSharedSecret(x25519Shared, mlkemShared, tagSalt)
///
/// All inputs are deterministic byte patterns so a regen always matches the
/// committed file (drift means a real KDF change — review carefully).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';

CryptoService _newService() => CryptoService(
  x25519: X25519(),
  hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
  aesGcm: AesGcm.with256bits(),
  hmac: Hmac.sha256(),
);

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List _pattern(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed * 31) & 0xff));

Future<void> main() async {
  final svc = _newService();

  // 5 KDF-only vectors.
  final kdfVectors = <Map<String, dynamic>>[];
  for (var i = 0; i < 5; i++) {
    final ss = _pattern(i + 1);
    final tag = await svc.contactRecipientTag(ss);
    final mk = await svc.contactMessageKey(ss);
    kdfVectors.add({
      'shared_secret_hex': _hex(ss),
      'recipient_tag_hex': _hex(tag),
      'msg_key_hex': _hex(mk),
    });
  }

  // 3 handshake vectors (X25519 + ML-KEM + tag_salt → shared_secret).
  final handshakeVectors = <Map<String, dynamic>>[];
  for (var i = 0; i < 3; i++) {
    final x = _pattern(100 + i);
    final m = _pattern(200 + i);
    final salt = _pattern(300 + i);
    final ss = await svc.deriveContactSharedSecret(
      x25519Shared: x,
      mlkemShared: m,
      tagSalt: salt,
    );
    final tag = await svc.contactRecipientTag(ss);
    final mk = await svc.contactMessageKey(ss);
    handshakeVectors.add({
      'x25519_shared_hex': _hex(x),
      'mlkem_shared_hex': _hex(m),
      'tag_salt_hex': _hex(salt),
      'shared_secret_hex': _hex(ss),
      'recipient_tag_hex': _hex(tag),
      'msg_key_hex': _hex(mk),
    });
  }

  final out = {
    'version': 1,
    'tag_info': 'sealed-tag-v1',
    'msg_key_info': 'sealed-msg-v1',
    'handshake_info': 'sealed-contact-secret-v1',
    'kdf_vectors': kdfVectors,
    'handshake_vectors': handshakeVectors,
  };

  print(const JsonEncoder.withIndent('  ').convert(out));
}
