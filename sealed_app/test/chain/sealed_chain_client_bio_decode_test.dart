// UserState v2/v3 decode through the public getUserByWallet path.
//
// The contract migrates v2 boxes lazily, so the client must decode BOTH wire
// layouts: v2 (102B head, no bio) and v3 (104B head + trailing bio byte[]).
// Box bytes are hand-built here exactly as the ARC4 encoder lays them out and
// served through a fake Dio adapter (algod box endpoint).

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';

class _FakeWallet implements AlgorandWallet {
  @override
  final String? walletAddress;
  _FakeWallet(this.walletAddress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Serves a fixed box value for any algod box GET.
class _BoxAdapter implements HttpClientAdapter {
  _BoxAdapter(this.boxValue);
  final Uint8List boxValue;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    if (options.path.contains('/applications/') &&
        options.path.endsWith('/box')) {
      return ResponseBody.fromString(
        jsonEncode({'name': 'eA==', 'value': base64Encode(boxValue)}),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

Uint8List _u16(int v) => Uint8List.fromList([(v >> 8) & 0xff, v & 0xff]);

/// ARC4-encode a UserState. [bio] null → v2 layout (no bio slot), else v3.
Uint8List _encodeUserState({
  required List<int> username,
  List<int>? bio,
  int batchCount = 1,
}) {
  final v3 = bio != null;
  final headLen = v3 ? 104 : 102;
  final usernameOff = headLen;
  final batchesOff = usernameOff + 2 + username.length;
  final bioOff = batchesOff + 2 + batchCount * 16;

  final b = BytesBuilder();
  b.addByte(v3 ? 3 : 2); // version
  b.add(_u16(usernameOff));
  b.addByte(batchCount);
  b.add(_u16(batchesOff));
  b.add(Uint8List(32)..fillRange(0, 32, 0xaa)); // encryptionPubkey
  b.add(Uint8List(32)..fillRange(0, 32, 0xbb)); // scanPubkey
  b.add(Uint8List(32)..fillRange(0, 32, 0xcc)); // pqPubkeyHash
  if (v3) b.add(_u16(bioOff));
  // username
  b.add(_u16(username.length));
  b.add(username);
  // batches: count + count × (amount u64 BE, expiry u64 BE)
  b.add(_u16(batchCount));
  for (var i = 0; i < batchCount; i++) {
    b.add(Uint8List(8)..[7] = 5); // amount 5
    b.add(Uint8List(8)..[6] = 0xff); // far-future expiry
  }
  if (v3) {
    b.add(_u16(bio!.length));
    b.add(bio);
  }
  return b.toBytes();
}

SealedChainClient _client(Uint8List boxValue) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test-algod'));
  dio.httpClientAdapter = _BoxAdapter(boxValue);
  return SealedChainClient(
    sealedAppId: 1,
    algodUrl: 'http://test-algod',
    indexerUrl: 'http://test-indexer',
    wallet: _FakeWallet(null),
    escrow: TreasuryEscrowSigner(Uint8List.fromList([0x06])),
    dio: dio,
  );
}

const _wallet = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  group('getUserByWallet — UserState wire versions', () {
    test('v3 box: decodes username AND bio', () async {
      final box = _encodeUserState(
        username: utf8.encode('alice'),
        bio: utf8.encode('friendly and hardworking 👋'),
      );
      final profile = await _client(box).getUserByWallet(_wallet);
      expect(profile, isNotNull);
      expect(profile!.username, 'alice');
      expect(profile.bio, 'friendly and hardworking 👋');
    });

    test('v3 box with empty bio: bio is null', () async {
      final box = _encodeUserState(username: utf8.encode('alice'), bio: []);
      final profile = await _client(box).getUserByWallet(_wallet);
      expect(profile!.username, 'alice');
      expect(profile.bio, isNull);
    });

    test('v2 box (pre-bio layout): decodes with null bio', () async {
      final box = _encodeUserState(username: utf8.encode('bob'), bio: null);
      expect(box[0], 2);
      final profile = await _client(box).getUserByWallet(_wallet);
      expect(profile, isNotNull);
      expect(profile!.username, 'bob');
      expect(profile.bio, isNull);
    });

    test('unknown version byte throws FormatException', () async {
      final box = _encodeUserState(username: utf8.encode('bob'), bio: null);
      box[0] = 9;
      await expectLater(
        _client(box).getUserByWallet(_wallet),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
