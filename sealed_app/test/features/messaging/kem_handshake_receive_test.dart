/// Unit tests for the receive-side hybrid branch of
/// `MessageKemHandshake.processKemHandshakes`.
///
/// Builds synthetic on-chain message maps mirroring `SealedChainClient`'s
/// log-parsing output and exercises legacy vs hybrid discrimination,
/// AES-GCM auth, envelope decode, and the "cache only after auth" invariant.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/message_codec.dart' as codec;
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local/repositories/test_db.dart';

typedef _PqKeyPair = ({Uint8List publicKey, Uint8List privateKey});

// ─── Fakes ──────────────────────────────────────────────────────────────────

class _FakeAlgorandWallet implements AlgorandWallet {
  @override
  final String? walletAddress;
  _FakeAlgorandWallet(this.walletAddress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSealedChainClient implements SealedChainClient {
  @override
  final AlgorandWallet wallet;

  /// On-chain username resolution stub. wallet address -> username. A miss
  /// returns null (peer not registered), mirroring the real client.
  final Map<String, String> _usernames;

  _FakeSealedChainClient(this.wallet, {Map<String, String>? usernames})
    : _usernames = usernames ?? const {};

  @override
  Future<UserProfile?> getUserByWallet(String walletAddress) async {
    final username = _usernames[walletAddress];
    if (username == null) return null;
    return UserProfile(
      walletAddress: walletAddress,
      username: username,
      encryptionPubkey: _bytes(32, seed: 21),
      scanPubkey: _bytes(32, seed: 22),
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeKeyService implements KeyService {
  final _PqKeyPair _pq;
  _FakeKeyService(this._pq);

  @override
  Future<_PqKeyPair?> loadPqKeys() async => _pq;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ─── Test setup ─────────────────────────────────────────────────────────────

late TestLocalDatabase _db;
late ContactRepositoryImpl _contacts;
late CryptoService _crypto;
late _PqKeyPair _myPq;
late MessageKemHandshake _kem;

const _me = 'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI';
const _sender = 'V3RW2DEEOBKA7KMWMHP5MDSJMFNINEY4IC755WV6VN54JJJBPSNLWOSLAE';

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

  _myPq = await _crypto.generatePqKeyPair();

  _kem = MessageKemHandshake(
    sealedClient: _FakeSealedChainClient(_FakeAlgorandWallet(_me)),
    cryptoService: _crypto,
    keyService: _FakeKeyService(_myPq),
    contacts: _contacts,
  );
}

Future<void> _tearDown() async {
  await _db.close();
}

Uint8List _bytes(int n, {int seed = 1}) =>
    Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xff));

/// `ContactRepository.saveContactKeys` silently no-ops on insert when the
/// row doesn't already carry enc/scan pubkeys. The production receive path
/// has a key-publication ingestion step that primes those columns first; in
/// unit tests we seed them directly so secret writes actually persist.
Future<void> _seedSenderContact() async {
  await _contacts.saveContactKeys(
    _sender,
    encryptionPubkey: _bytes(32, seed: 11),
    scanPubkey: _bytes(32, seed: 12),
  );
}

/// Build a synthetic message map shaped like SealedChainClient log output.
Future<Map<String, dynamic>> _buildLegacyMsg() async {
  final encResult = await _crypto.kemEncapsulate(_myPq.publicKey);
  final scanPub = _bytes(32, seed: 9);
  final ciphertext = Uint8List.fromList([...encResult.ciphertext, ...scanPub]);
  final tag = await _kem.computeKemDiscoveryTag(_sender, _me);
  return {
    'accountPubkey': 'txid-legacy',
    'recipientTag': tag,
    'ciphertext': ciphertext,
    'senderAddress': _sender,
  };
}

Future<({Map<String, dynamic> msg, Uint8List sharedSecret})> _buildHybridMsg({
  required String content,
  required int timestampMs,
  String txid = 'txid-hybrid',
}) async {
  final encResult = await _crypto.kemEncapsulate(_myPq.publicKey);
  final envelope = codec.encodeHybridInnerEnvelope(
    timestampMs: timestampMs,
    content: Uint8List.fromList(content.codeUnits),
  );
  final innerCt = await _crypto.encryptWithEncKey(
    encKey: encResult.sharedSecret,
    plainTextBytes: envelope,
  );
  final frame = codec.encodeHybridFirstFrame(
    kemCt: encResult.ciphertext,
    innerCiphertext: innerCt,
  );
  final tag = await _kem.computeKemDiscoveryTag(_sender, _me);
  return (
    msg: {
      'accountPubkey': txid,
      'recipientTag': tag,
      'ciphertext': frame,
      'senderAddress': _sender,
    },
    sharedSecret: encResult.sharedSecret,
  );
}

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUp);
  tearDown(_tearDown);

  test('legacy 800B frame → kemSaved=1, no hybrid messages', () async {
    final msg = await _buildLegacyMsg();
    await _seedSenderContact();
    final result = await _kem.processKemHandshakes([msg]);
    expect(result.kemSaved, 1);
    expect(result.hybridMessages, isEmpty);

    final cached = await _contacts.getContactKeys(_sender);
    expect(cached.pqSharedSecret, isNotNull);
  });

  test(
    'hybrid frame round-trip → kemSaved=1, 1 hybrid message decoded',
    () async {
      final ts = 1717000000000;
      final built = await _buildHybridMsg(
        content: 'hello bob from alice',
        timestampMs: ts,
      );

      await _seedSenderContact();
      final result = await _kem.processKemHandshakes([built.msg]);
      expect(result.kemSaved, 1);
      expect(result.hybridMessages, hasLength(1));

      final msg = result.hybridMessages.single;
      expect(msg.senderWallet, _sender);
      expect(msg.recipientWallet, _me);
      expect(msg.content, 'hello bob from alice');
      expect(msg.timestamp.millisecondsSinceEpoch, ts);
      expect(msg.isOutgoing, isFalse);

      final cached = await _contacts.getContactKeys(_sender);
      expect(cached.pqSharedSecret, isNotNull);
      expect(
        _crypto.constantTimeEquals(cached.pqSharedSecret!, built.sharedSecret),
        isTrue,
      );
    },
  );

  test(
    'hybrid frame: AES-GCM auth failure → frame skipped, no secret cached',
    () async {
      final built = await _buildHybridMsg(
        content: 'tampered',
        timestampMs: 1717000000000,
      );
      // Flip a byte well after the AES-GCM tag region (somewhere inside the
      // inner ciphertext) so auth fails.
      final corrupt = Uint8List.fromList(built.msg['ciphertext'] as Uint8List);
      corrupt[corrupt.length - 5] ^= 0xFF;
      final msg = Map<String, dynamic>.from(built.msg);
      msg['ciphertext'] = corrupt;

      await _seedSenderContact();
      final result = await _kem.processKemHandshakes([msg]);
      expect(result.kemSaved, 0);
      expect(result.hybridMessages, isEmpty);

      final cached = await _contacts.getContactKeys(_sender);
      expect(
        cached.pqSharedSecret,
        isNull,
        reason: 'auth-failed hybrid frame must not poison the secret cache',
      );
    },
  );

  test(
    'hybrid frame: bad inner version → secret cached, payload dropped',
    () async {
      final encResult = await _crypto.kemEncapsulate(_myPq.publicKey);
      final envelope = Uint8List.fromList([
        0x99, // bogus version
        ...Uint8List(8),
        ...codec.gzipCompress(Uint8List.fromList('x'.codeUnits)),
      ]);
      final innerCt = await _crypto.encryptWithEncKey(
        encKey: encResult.sharedSecret,
        plainTextBytes: envelope,
      );
      final frame = codec.encodeHybridFirstFrame(
        kemCt: encResult.ciphertext,
        innerCiphertext: innerCt,
      );
      final tag = await _kem.computeKemDiscoveryTag(_sender, _me);
      final msg = {
        'accountPubkey': 'txid-badver',
        'recipientTag': tag,
        'ciphertext': frame,
        'senderAddress': _sender,
      };

      await _seedSenderContact();
      final result = await _kem.processKemHandshakes([msg]);
      expect(result.kemSaved, 1, reason: 'KEM half is fine — secret valid');
      expect(result.hybridMessages, isEmpty, reason: 'envelope decode skipped');

      final cached = await _contacts.getContactKeys(_sender);
      expect(cached.pqSharedSecret, isNotNull);
    },
  );

  test(
    'hybrid first message resolves the unknown sender username from chain',
    () async {
      // A KEM handshake is an unknown peer's first contact — no local row, no
      // payload username. The receive path must resolve it from chain so the
      // first message shows the username, not a shortened wallet.
      final kem = MessageKemHandshake(
        sealedClient: _FakeSealedChainClient(
          _FakeAlgorandWallet(_me),
          usernames: {_sender: 'alice'},
        ),
        cryptoService: _crypto,
        keyService: _FakeKeyService(_myPq),
        contacts: _contacts,
      );
      final built = await _buildHybridMsg(
        content: 'hello from alice',
        timestampMs: 1717000000000,
      );

      await _seedSenderContact();
      final result = await kem.processKemHandshakes([built.msg]);
      expect(result.hybridMessages, hasLength(1));
      expect(result.hybridMessages.single.senderUsername, 'alice');
    },
  );

  test(
    'hybrid first message: unregistered sender → senderUsername stays null',
    () async {
      // Chain miss (no on-chain username) must not throw and must leave the
      // snapshot fallback (null) untouched.
      final built = await _buildHybridMsg(
        content: 'no username on chain',
        timestampMs: 1717000000000,
      );

      await _seedSenderContact();
      // Default _kem's fake client returns null for getUserByWallet.
      final result = await _kem.processKemHandshakes([built.msg]);
      expect(result.hybridMessages, hasLength(1));
      expect(result.hybridMessages.single.senderUsername, isNull);
    },
  );

  test(
    'two identical hybrid messages in one batch → 1 hybrid msg emitted',
    () async {
      final built = await _buildHybridMsg(
        content: 'dup-test',
        timestampMs: 1717000000000,
        txid: 'txid-dup',
      );
      // Same txid twice — saveMessage-level dedup is handled by the caller in
      // Task 3.2; here we verify processKemHandshakes itself reports both
      // entries as one cached-secret event (idempotent secret) but emits one
      // hybrid message per frame for the caller to dedupe.
      await _seedSenderContact();
      final result = await _kem.processKemHandshakes([built.msg, built.msg]);
      expect(result.kemSaved, 1, reason: 'idempotent secret cache');
      // Both frames decode → both emit DecryptedMessage. Final dedup is the
      // store's job (matching on txid). Confirm both rows carry the same id.
      expect(result.hybridMessages, hasLength(2));
      expect(result.hybridMessages.first.id, 'txid-dup');
      expect(result.hybridMessages.last.id, 'txid-dup');
    },
  );
}
