/// Unit tests for the send-side branch of `MessageKemHandshake.performKemHandshake`.
///
/// Stubs `sealedClient.sendMessage` through the injectable [ChainSendMessageFn]
/// seam and uses a real `CryptoService` so the KEM + AES-GCM round-trip is
/// exercised end-to-end. `ContactRepository` runs against an in-memory SQLite
/// via `TestLocalDatabase`.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/message_codec.dart' as codec;
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local/repositories/test_db.dart';

// ─── Fakes ──────────────────────────────────────────────────────────────────

class _FakeSealedChainClient implements SealedChainClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeKeyService implements KeyService {
  @override
  Future<Uint8List> deriveKemEncapsNonce(Uint8List peerPqPubkey) async =>
      Uint8List(32); // deterministic stub; frame-shape tests don't depend on it

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Recorder {
  final List<({Uint8List recipientTag, Uint8List senderEph, Uint8List ct})>
  calls = [];
  bool failNext = false;

  ChainSendMessageFn get fn =>
      ({
        required Uint8List recipientTag,
        required Uint8List senderEphemeralPubkey,
        required Uint8List ciphertext,
      }) async {
        calls.add((
          recipientTag: recipientTag,
          senderEph: senderEphemeralPubkey,
          ct: ciphertext,
        ));
        if (failNext) {
          throw Exception('forced send failure');
        }
        return 'tx-${calls.length}';
      };
}

// ─── Test setup ─────────────────────────────────────────────────────────────

late TestLocalDatabase _db;
late ContactRepositoryImpl _contacts;
late CryptoService _crypto;

Future<void> _setUp() async {
  sqfliteFfiInit();
  _db = await TestLocalDatabase.open();
  _contacts = ContactRepositoryImpl(_db);
  _crypto = CryptoService(
    x25519: X25519(),
    hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
    aesGcm: AesGcm.with256bits(),
    hmac: Hmac.sha256(),
  );
}

Future<void> _tearDown() async {
  await _db.close();
}

MessageKemHandshake _makeKem(_Recorder rec) => MessageKemHandshake(
  sealedClient: _FakeSealedChainClient(),
  cryptoService: _crypto,
  keyService: _FakeKeyService(),
  contacts: _contacts,
  sendMessageFn: rec.fn,
);

Future<Uint8List> _newRecipientPqPubkey() async =>
    (await _crypto.generatePqKeyPair()).publicKey;

/// Pre-populate the contact row so `saveContactKeys(pqSharedSecret: ...)`
/// can update — production code always invokes the handshake on a recipient
/// whose enc/scan pubkeys are already cached.
Future<void> _seedRecipientContact(Uint8List pqPub) async {
  await _contacts.saveContactKeys(
    _recipient,
    encryptionPubkey: _bytes(32, seed: 5),
    scanPubkey: _bytes(32, seed: 6),
    pqPublicKey: pqPub,
  );
}

Uint8List _bytes(int n, {int seed = 1}) =>
    Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xff));

const _sender = 'SENDERWALLETADDRESSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _recipient = 'RECIPIENTWALLETADDRESSBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUp);
  tearDown(_tearDown);

  group('performKemHandshake', () {
    test(
      'null firstPayloadContent → legacy 800B frame, hybridIncluded=false',
      () async {
        final rec = _Recorder();
        final kem = _makeKem(rec);
        final recipientPq = await _newRecipientPqPubkey();
        final scanPub = _bytes(32, seed: 99);
        await _seedRecipientContact(recipientPq);

        final result = await kem.performKemHandshake(
          senderWallet: _sender,
          senderScanPubkey: scanPub,
          recipientWallet: _recipient,
          recipientPqPubkey: recipientPq,
        );

        expect(rec.calls, hasLength(1));
        expect(rec.calls.single.ct.length, codec.kLegacyKemFrameLen);
        expect(result.hybridIncluded, isFalse);
        expect(result.sendTxid, 'tx-1');
        expect(result.sharedSecret.length, 32);

        final cached = await _contacts.getContactKeys(_recipient);
        expect(cached.pqSharedSecret, isNotNull);
      },
    );

    test(
      'short firstPayloadContent → hybrid frame > 800B, hybridIncluded=true',
      () async {
        final rec = _Recorder();
        final kem = _makeKem(rec);
        final recipientPq = await _newRecipientPqPubkey();
        final scanPub = _bytes(32, seed: 99);
        await _seedRecipientContact(recipientPq);
        final content = Uint8List.fromList('hello world from alice'.codeUnits);

        final result = await kem.performKemHandshake(
          senderWallet: _sender,
          senderScanPubkey: scanPub,
          recipientWallet: _recipient,
          recipientPqPubkey: recipientPq,
          firstPayloadContent: content,
          firstPayloadTimestampMs: 1717000000000,
        );

        expect(rec.calls, hasLength(1));
        expect(
          rec.calls.single.ct.length,
          greaterThan(codec.kLegacyKemFrameLen),
        );
        expect(
          rec.calls.single.ct.length,
          lessThanOrEqualTo(codec.kHybridFrameMaxBytes),
        );
        expect(result.hybridIncluded, isTrue);

        final cached = await _contacts.getContactKeys(_recipient);
        expect(cached.pqSharedSecret, isNotNull);
      },
    );

    test(
      'long firstPayloadContent over predicate budget → legacy 800B frame, hybridIncluded=false',
      () async {
        final rec = _Recorder();
        final kem = _makeKem(rec);
        final recipientPq = await _newRecipientPqPubkey();
        final scanPub = _bytes(32, seed: 99);
        await _seedRecipientContact(recipientPq);
        // Random bytes don't compress — guaranteed to bust the predicate.
        final content = _bytes(2048, seed: 17);

        final result = await kem.performKemHandshake(
          senderWallet: _sender,
          senderScanPubkey: scanPub,
          recipientWallet: _recipient,
          recipientPqPubkey: recipientPq,
          firstPayloadContent: content,
        );

        expect(rec.calls, hasLength(1));
        expect(rec.calls.single.ct.length, codec.kLegacyKemFrameLen);
        expect(result.hybridIncluded, isFalse);
        expect(result.sharedSecret.length, 32);
      },
    );

    test(
      'hybrid path: tx submit failure → no cached shared secret (no half-state)',
      () async {
        final rec = _Recorder()..failNext = true;
        final kem = _makeKem(rec);
        final recipientPq = await _newRecipientPqPubkey();
        final scanPub = _bytes(32, seed: 99);
        await _seedRecipientContact(recipientPq);
        final content = Uint8List.fromList('one credit text'.codeUnits);

        await expectLater(
          () => kem.performKemHandshake(
            senderWallet: _sender,
            senderScanPubkey: scanPub,
            recipientWallet: _recipient,
            recipientPqPubkey: recipientPq,
            firstPayloadContent: content,
          ),
          throwsException,
        );

        final cached = await _contacts.getContactKeys(_recipient);
        expect(
          cached.pqSharedSecret,
          isNull,
          reason: 'hybrid send failure must not leave a cached secret',
        );
      },
    );
  });
}
