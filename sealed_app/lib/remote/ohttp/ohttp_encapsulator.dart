import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sealed_app/remote/ohttp/binary_http.dart';
import 'package:sealed_app/remote/ohttp/ohttp_config.dart';

String _hex(List<int> b, [int max = 64]) {
  final n = b.length > max ? max : b.length;
  final s = b
      .take(n)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  return b.length > max ? '$s...(${b.length})' : s;
}

/// OHTTP request/response encapsulation per RFC 9458.
///
/// Implements HPKE (RFC 9180) in Base mode with:
/// - DHKEM(X25519, HKDF-SHA256) (KEM ID: 0x0020)
/// - HKDF-SHA256 (KDF ID: 0x0001)
/// - AES-128-GCM (AEAD ID: 0x0001)
class OhttpEncapsulator {
  final OhttpConfig config;

  OhttpEncapsulator(this.config);

  /// Encapsulate an HTTP request for OHTTP transmission.
  Future<OhttpEncapsulatedRequest> encapsulateRequest({
    required String method,
    required Uri targetUri,
    Map<String, String> headers = const {},
    Uint8List? body,
  }) async {
    // 1. Encode request as Binary HTTP
    final binaryRequest = BinaryHttp.encodeRequest(
      method: method,
      uri: targetUri,
      headers: headers,
      body: body,
    );

    // 2. HPKE Encap: generate ephemeral key, compute shared secret
    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();
    final enc = Uint8List.fromList(ephemeralPubKey.bytes); // 32 bytes

    // DH(skE, pkR)
    final gatewayPubKey = SimplePublicKey(
      config.publicKey.toList(),
      type: KeyPairType.x25519,
    );
    final dhResult = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: gatewayPubKey,
    );
    final dh = Uint8List.fromList(await dhResult.extractBytes());

    // 3. DHKEM ExtractAndExpand
    final kemContext = Uint8List.fromList([...enc, ...config.publicKey]);
    final sharedSecret = await _extractAndExpand(dh, kemContext);

    // 4. HPKE KeySchedule (Base mode)
    // Per RFC 9458: info = "message/bhttp request" || 0x00 || hdr
    final hdr = _ohttpKeyInfoHeader();
    final hpkeInfo = [...'message/bhttp request'.codeUnits, 0x00, ...hdr];

    final (key, baseNonce, exporterSecret) = await _keySchedule(
      sharedSecret,
      hpkeInfo,
    );

    // 5. Encrypt with EMPTY AAD (hdr is bound via HPKE info, not AEAD AAD)
    final aesGcm = AesGcm.with128bits();

    final secretBox = await aesGcm.encrypt(
      binaryRequest,
      secretKey: SecretKey(key),
      nonce: baseNonce,
      aad: Uint8List(0), // Empty AAD per reference implementation
    );

    // 6. Build encapsulated request:
    //    hdr (7 bytes) || enc (32 bytes) || ct || tag (16 bytes)
    final encapsulated = BytesBuilder();
    encapsulated.add(hdr);
    encapsulated.add(enc); // 32 bytes ephemeral public key
    encapsulated.add(secretBox.cipherText);
    encapsulated.add(secretBox.mac.bytes);

    // 7. Compute HPKE export for response decapsulation
    // export(exporter_secret, "message/bhttp response", Nk=16)
    // = LabeledExpand(exporter_secret, "sec", export_context, L)
    final exportContext = 'message/bhttp response'.codeUnits;
    final hpkeSuiteId = [
      ...'HPKE'.codeUnits,
      0x00, 0x20, // KEM
      0x00, 0x01, // KDF
      0x00, 0x01, // AEAD
    ];
    final secret = await _labeledExpandWithSuiteId(
      exporterSecret,
      'sec'.codeUnits,
      Uint8List.fromList(exportContext),
      16, // aeadKeySize for AES-128-GCM
      hpkeSuiteId,
    );

    if (kDebugMode) {
      print('[HPKE-ENC] enc=${_hex(enc)}');
      print('[HPKE-ENC] dh=${_hex(dh)}');
      print('[HPKE-ENC] sharedSecret=${_hex(sharedSecret)}');
      print('[HPKE-ENC] hpkeInfo=${_hex(hpkeInfo)}');
      print('[HPKE-ENC] aeadKey=${_hex(key)}');
      print('[HPKE-ENC] baseNonce=${_hex(baseNonce)}');
      print('[HPKE-ENC] exporterSecret=${_hex(exporterSecret)}');
      print('[HPKE-ENC] responseSecret=${_hex(secret)}');
    }

    return OhttpEncapsulatedRequest(
      encapsulatedMessage: Uint8List.fromList(encapsulated.toBytes()),
      enc: enc,
      secret: Uint8List.fromList(secret),
    );
  }

  /// Decapsulate an OHTTP response.
  ///
  /// Per RFC 9458 §4.4 and ohttp-js reference:
  /// Response format: responseNonce (max(Nk,Nn) bytes) || encrypted_response
  /// Key derivation: salt = enc || responseNonce
  ///                 prk = Extract(salt, secret)
  ///                 key = Expand(prk, "key", Nk)
  ///                 nonce = Expand(prk, "nonce", Nn)
  Future<BinaryHttpResponse> decapsulateResponse({
    required Uint8List encryptedResponse,
    required Uint8List enc,
    required Uint8List secret,
  }) async {
    // responseNonce length = max(Nk, Nn) = max(16, 12) = 16
    final responseNonceLen = max(16, 12); // max(aeadKeySize, aeadNonceSize)

    if (encryptedResponse.length < responseNonceLen + 16) {
      throw const FormatException('OHTTP response too short');
    }

    final responseNonce = encryptedResponse.sublist(0, responseNonceLen);
    final encResponse = encryptedResponse.sublist(responseNonceLen);

    // salt = enc || responseNonce
    final salt = Uint8List.fromList([...enc, ...responseNonce]);

    // prk = Extract(salt, secret)
    final hmac = Hmac.sha256();
    final prk = await hmac.calculateMac(
      secret,
      secretKey: SecretKey(salt.toList()),
    );

    // key = Expand(prk, "key", Nk=16)
    final aeadKey = await _hkdfExpand(
      prk.bytes,
      Uint8List.fromList('key'.codeUnits),
      16,
    );

    // nonce = Expand(prk, "nonce", Nn=12)
    final aeadNonce = await _hkdfExpand(
      prk.bytes,
      Uint8List.fromList('nonce'.codeUnits),
      12,
    );

    if (kDebugMode) {
      print('[HPKE-DEC] enc=${_hex(enc)}');
      print('[HPKE-DEC] secret(input)=${_hex(secret)}');
      print('[HPKE-DEC] responseNonce=${_hex(responseNonce)}');
      print('[HPKE-DEC] salt=${_hex(salt)}');
      print('[HPKE-DEC] prk=${_hex(prk.bytes)}');
      print('[HPKE-DEC] aeadKey=${_hex(aeadKey)}');
      print('[HPKE-DEC] aeadNonce=${_hex(aeadNonce)}');
      print(
        '[HPKE-DEC] encResponse(${encResponse.length}B) '
        'head=${_hex(encResponse.sublist(0, encResponse.length > 32 ? 32 : encResponse.length))} '
        'tail16=${_hex(encResponse.sublist(encResponse.length - 16))}',
      );
    }

    // Decrypt
    if (encResponse.length < 16) {
      throw const FormatException('OHTTP response ciphertext too short');
    }

    final tagStart = encResponse.length - 16;
    final cipherText = encResponse.sublist(0, tagStart);
    final tag = encResponse.sublist(tagStart);

    final aesGcm = AesGcm.with128bits();
    final secretBox = SecretBox(cipherText, nonce: aeadNonce, mac: Mac(tag));

    final plaintext = await aesGcm.decrypt(
      secretBox,
      secretKey: SecretKey(aeadKey),
      aad: Uint8List(
        0,
      ), // Empty AAD per reference: new TextEncoder().encode("")
    );

    return BinaryHttp.decodeResponse(Uint8List.fromList(plaintext));
  }

  // ===========================================================================
  // HPKE internals (RFC 9180)
  // ===========================================================================

  /// DHKEM ExtractAndExpand (RFC 9180 §4.1)
  Future<List<int>> _extractAndExpand(
    Uint8List dh,
    Uint8List kemContext,
  ) async {
    final suiteId = [...'KEM'.codeUnits, 0x00, 0x20];

    final labeledIkm = Uint8List.fromList([
      ...'HPKE-v1'.codeUnits,
      ...suiteId,
      ...'eae_prk'.codeUnits,
      ...dh,
    ]);

    final hmac = Hmac.sha256();
    final prk = await hmac.calculateMac(
      labeledIkm,
      secretKey: SecretKey(Uint8List(32).toList()), // empty salt → zero key
    );

    return _labeledExpandWithSuiteId(
      prk.bytes,
      'shared_secret'.codeUnits,
      kemContext,
      32,
      suiteId,
    );
  }

  /// HPKE KeySchedule in Base mode (RFC 9180 §5.1)
  Future<(List<int>, List<int>, List<int>)> _keySchedule(
    List<int> sharedSecret,
    List<int> info,
  ) async {
    final suiteId = [
      ...'HPKE'.codeUnits,
      0x00, 0x20, // KEM
      0x00, 0x01, // KDF
      0x00, 0x01, // AEAD
    ];

    // psk_id_hash = LabeledExtract("", "psk_id_hash", "")
    final pskIdHash = await _labeledExtractWithSuiteId(
      Uint8List(0),
      'psk_id_hash'.codeUnits,
      Uint8List(0),
      suiteId,
    );

    // info_hash = LabeledExtract("", "info_hash", info)
    final infoHash = await _labeledExtractWithSuiteId(
      Uint8List(0),
      'info_hash'.codeUnits,
      Uint8List.fromList(info),
      suiteId,
    );

    // ks_context = mode || psk_id_hash || info_hash
    final ksContext = Uint8List.fromList([0x00, ...pskIdHash, ...infoHash]);

    // secret = LabeledExtract(shared_secret, "secret", psk="")
    final secret = await _labeledExtractWithSuiteId(
      Uint8List.fromList(sharedSecret),
      'secret'.codeUnits,
      Uint8List(0),
      suiteId,
    );

    // key = LabeledExpand(secret, "key", ks_context, Nk=16)
    final key = await _labeledExpandWithSuiteId(
      secret,
      'key'.codeUnits,
      ksContext,
      16,
      suiteId,
    );

    // base_nonce = LabeledExpand(secret, "base_nonce", ks_context, Nn=12)
    final baseNonce = await _labeledExpandWithSuiteId(
      secret,
      'base_nonce'.codeUnits,
      ksContext,
      12,
      suiteId,
    );

    // exp = LabeledExpand(secret, "exp", ks_context, Nh=32)
    final exporterSecret = await _labeledExpandWithSuiteId(
      secret,
      'exp'.codeUnits,
      ksContext,
      32,
      suiteId,
    );

    return (key, baseNonce, exporterSecret);
  }

  /// LabeledExtract (RFC 9180 §4)
  Future<List<int>> _labeledExtractWithSuiteId(
    Uint8List salt,
    List<int> label,
    Uint8List ikm,
    List<int> suiteId,
  ) async {
    final labeledIkm = Uint8List.fromList([
      ...'HPKE-v1'.codeUnits,
      ...suiteId,
      ...label,
      ...ikm,
    ]);

    final hmac = Hmac.sha256();
    final effectiveSalt = salt.isEmpty ? Uint8List(32) : salt;
    final mac = await hmac.calculateMac(
      labeledIkm,
      secretKey: SecretKey(effectiveSalt.toList()),
    );
    return mac.bytes;
  }

  /// LabeledExpand (RFC 9180 §4)
  Future<List<int>> _labeledExpandWithSuiteId(
    List<int> prk,
    List<int> label,
    Uint8List info,
    int length,
    List<int> suiteId,
  ) async {
    final labeledInfo = Uint8List.fromList([
      (length >> 8) & 0xFF,
      length & 0xFF,
      ...'HPKE-v1'.codeUnits,
      ...suiteId,
      ...label,
      ...info,
    ]);

    return _hkdfExpand(prk, labeledInfo, length);
  }

  /// HKDF-Expand (RFC 5869)
  Future<List<int>> _hkdfExpand(
    List<int> prk,
    Uint8List info,
    int length,
  ) async {
    final hmac = Hmac.sha256();
    final hashLen = 32;
    final n = (length + hashLen - 1) ~/ hashLen;
    final result = <int>[];
    var t = <int>[];

    for (int i = 1; i <= n; i++) {
      final input = [...t, ...info, i];
      final mac = await hmac.calculateMac(input, secretKey: SecretKey(prk));
      t = mac.bytes;
      result.addAll(t);
    }

    return result.sublist(0, length);
  }

  // ===========================================================================
  // OHTTP-specific helpers
  // ===========================================================================

  /// OHTTP key info header = keyId(1) || kemId(2) || kdfId(2) || aeadId(2)
  List<int> _ohttpKeyInfoHeader() {
    return [
      config.keyId,
      (config.kemId >> 8) & 0xFF,
      config.kemId & 0xFF,
      (config.kdfId >> 8) & 0xFF,
      config.kdfId & 0xFF,
      (config.aeadId >> 8) & 0xFF,
      config.aeadId & 0xFF,
    ];
  }
}

/// Result of OHTTP request encapsulation.
class OhttpEncapsulatedRequest {
  final Uint8List encapsulatedMessage;
  final Uint8List
  enc; // ephemeral public key, needed for response decapsulation
  final Uint8List
  secret; // HPKE export secret, needed for response decapsulation

  OhttpEncapsulatedRequest({
    required this.encapsulatedMessage,
    required this.enc,
    required this.secret,
  });
}
