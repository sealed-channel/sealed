/// Unit tests for `MessageSender.sendMessage` branch selection.
///
/// Three branches:
///   A — cached PQ secret → 1 sendMessage call (legacy path).
///   B — no cache + short content + fits → 1 sendMessage call (hybrid).
///   C — no cache + long content / doesn't fit → 2 sendMessage calls
///       (legacy KEM handshake + legacy payload).
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/identity/user_service.dart';
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/messaging/message_sender.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local/repositories/test_db.dart';

// ─── Fakes ──────────────────────────────────────────────────────────────────

class _ChainSendRecorder {
  final List<({Uint8List recipientTag, Uint8List senderEph, Uint8List ct})>
  calls = [];

  Future<String> call({
    required Uint8List recipientTag,
    required Uint8List senderEphemeralPubkey,
    required Uint8List ciphertext,
  }) async {
    calls.add((
      recipientTag: recipientTag,
      senderEph: senderEphemeralPubkey,
      ct: ciphertext,
    ));
    return 'tx-${calls.length}';
  }
}

class _FakeSealedChainClient implements SealedChainClient {
  final _ChainSendRecorder rec;
  _FakeSealedChainClient(this.rec);

  @override
  Future<String> sendMessage({
    required Uint8List recipientTag,
    required Uint8List senderEphemeralPubkey,
    required Uint8List ciphertext,
  }) => rec.call(
    recipientTag: recipientTag,
    senderEphemeralPubkey: senderEphemeralPubkey,
    ciphertext: ciphertext,
  );

  @override
  Future<UserProfile?> getUserByWallet(String walletAddress) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeKeyService implements KeyService {
  final SealedKeys keys;
  _FakeKeyService(this.keys);

  @override
  Future<SealedKeys?> loadKeys() async => keys;

  @override
  Future<Uint8List> deriveKemEncapsNonce(Uint8List peerPqPubkey) async =>
      Uint8List(32);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUserService implements UserService {
  @override
  String? get displayName => 'alice';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ─── Setup ──────────────────────────────────────────────────────────────────

late TestLocalDatabase _db;
late ContactRepositoryImpl _contacts;
late MessageRepositoryImpl _messageCache;
late CryptoService _crypto;
late SealedKeys _senderKeys;
late Uint8List _recipientEnc;
late Uint8List _recipientScan;
late Uint8List _recipientPq;

// Valid Algorand addresses (58-char base32 with 4-byte checksum).
const _sender = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _recipient = 'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI';

Future<void> _setUp({Uint8List? cachedSharedSecret}) async {
  sqfliteFfiInit();
  _db = await TestLocalDatabase.open();
  _contacts = ContactRepositoryImpl(_db);
  _messageCache = MessageRepositoryImpl(localDatabase: _db);
  _crypto = CryptoService(
    x25519: X25519(),
    hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
    aesGcm: AesGcm.with256bits(),
    hmac: Hmac.sha256(),
  );

  // Sender keys (real X25519 + a fresh PQ pair we won't use for send).
  final senderEncKp = await X25519().newKeyPair();
  final senderScanKp = await X25519().newKeyPair();
  final senderEncPub = await senderEncKp.extractPublicKey();
  final senderScanPub = await senderScanKp.extractPublicKey();
  final pq = await _crypto.generatePqKeyPair();
  _senderKeys = SealedKeys(
    encryptionKeyPair: senderEncKp,
    scanKeyPair: senderScanKp,
    walletAddress: _sender,
    scanPubkey: Uint8List.fromList(senderScanPub.bytes),
    encryptionPubkey: Uint8List.fromList(senderEncPub.bytes),
    encryptionPrivateKey: Uint8List(32),
    viewPrivateKey: Uint8List(32),
    pqPublicKey: pq.publicKey,
    pqPrivateKey: pq.privateKey,
  );

  // Recipient's published keys.
  final recipientEncKp = await X25519().newKeyPair();
  final recipientScanKp = await X25519().newKeyPair();
  final recipientEncPub = await recipientEncKp.extractPublicKey();
  final recipientScanPub = await recipientScanKp.extractPublicKey();
  _recipientEnc = Uint8List.fromList(recipientEncPub.bytes);
  _recipientScan = Uint8List.fromList(recipientScanPub.bytes);
  final recipientPq = await _crypto.generatePqKeyPair();
  _recipientPq = recipientPq.publicKey;

  await _contacts.saveContactKeys(
    _recipient,
    encryptionPubkey: _recipientEnc,
    scanPubkey: _recipientScan,
    pqPublicKey: _recipientPq,
    pqSharedSecret: cachedSharedSecret,
  );
}

Future<void> _tearDown() async {
  await _db.close();
}

MessageSender _makeSender(_ChainSendRecorder rec) {
  final fakeChain = _FakeSealedChainClient(rec);
  final kem = MessageKemHandshake(
    sealedClient: fakeChain,
    cryptoService: _crypto,
    keyService: _FakeKeyService(_senderKeys),
    contacts: _contacts,
  );
  return MessageSender(
    sealedClient: fakeChain,
    cryptoService: _crypto,
    keyService: _FakeKeyService(_senderKeys),
    userService: _FakeUserService(),
    contacts: _contacts,
    messageCache: _messageCache,
    kem: kem,
  );
}

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  tearDown(_tearDown);

  test('Branch A: cached secret → exactly 1 sendMessage call', () async {
    await _setUp(cachedSharedSecret: Uint8List(32));
    final rec = _ChainSendRecorder();
    final sender = _makeSender(rec);

    await sender.sendMessage(
      recipientWallet: _recipient,
      plaintext: 'hi',
      senderWallet: _sender,
    );

    expect(rec.calls, hasLength(1));
    // Legacy padded payload — not a KEM handshake frame (which is 800B).
    expect(rec.calls.single.ct.length, isNot(800));
  });

  test(
    'Branch B: no cache + short content → exactly 1 sendMessage call',
    () async {
      await _setUp();
      final rec = _ChainSendRecorder();
      final sender = _makeSender(rec);

      await sender.sendMessage(
        recipientWallet: _recipient,
        plaintext: 'one credit short hybrid message',
        senderWallet: _sender,
      );

      expect(rec.calls, hasLength(1));
      // Hybrid frame > 800B and <= 992B.
      expect(rec.calls.single.ct.length, greaterThan(800));
      expect(rec.calls.single.ct.length, lessThanOrEqualTo(992));
    },
  );

  test(
    'Branch C: no cache + long content → exactly 2 sendMessage calls',
    () async {
      await _setUp();
      final rec = _ChainSendRecorder();
      final sender = _makeSender(rec);

      // 400 chars — over the 280-char threshold → branch C.
      final long = 'a' * 400;

      await sender.sendMessage(
        recipientWallet: _recipient,
        plaintext: long,
        senderWallet: _sender,
      );

      expect(rec.calls, hasLength(2));
      // First call: legacy KEM handshake = 800B.
      expect(rec.calls[0].ct.length, 800);
      // Second call: padded encrypted payload, not 800.
      expect(rec.calls[1].ct.length, isNot(800));
    },
  );
}
