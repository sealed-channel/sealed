// Tests for SealedChainClient.publishKeysIfStale.
//
// Strategy:
//   - The full method is awkward to mock against the concrete client (private
//     algod helpers, escrow signer, etc.). The freshness decision lives in the
//     pure static `SealedChainClient.isKeyPublicationFresh` — most cases are
//     unit-tested against that.
//   - One smaller integration-style test exercises the full method's "no
//     UserState box" early-return path through a fake Dio adapter (algod box
//     read → 404). That validates the wiring.
//   - The wallet-null StateError path is also exercised end-to-end.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';

Uint8List _bytes(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xff));

Uint8List _sha256(Uint8List b) =>
    Uint8List.fromList(pkg_crypto.sha256.convert(b).bytes);

// ─── Fake wallet (signature surface only) ───────────────────────────────────

class _FakeWallet implements AlgorandWallet {
  @override
  final String? walletAddress;
  _FakeWallet(this.walletAddress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ─── Fake Dio adapter: route algod box GET → 404 (no box) ───────────────────

class _NoBoxAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    // Algod box endpoint returns 404 when box missing.
    if (options.path.contains('/applications/') &&
        options.path.endsWith('/box')) {
      return ResponseBody.fromString(
        jsonEncode({'message': 'box not found'}),
        404,
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

void main() {
  group('isKeyPublicationFresh (pure decision logic)', () {
    final enc = _bytes(1, 32);
    final scan = _bytes(2, 32);
    final pq = _bytes(3, 800);
    final pqHash = _sha256(pq);

    test('returns true when all three match', () {
      expect(
        SealedChainClient.isKeyPublicationFresh(
          onChainPqPubkeyHash: pqHash,
          onChainEncryptionPubkey: enc,
          onChainScanPubkey: scan,
          newPqPubkeyHash: pqHash,
          newEncryptionPubkey: enc,
          newScanPubkey: scan,
        ),
        isTrue,
      );
    });

    test('returns false when on-chain pqPubkeyHash is null', () {
      expect(
        SealedChainClient.isKeyPublicationFresh(
          onChainPqPubkeyHash: null,
          onChainEncryptionPubkey: enc,
          onChainScanPubkey: scan,
          newPqPubkeyHash: pqHash,
          newEncryptionPubkey: enc,
          newScanPubkey: scan,
        ),
        isFalse,
      );
    });

    test('returns false when pq hash differs', () {
      final otherHash = _sha256(_bytes(99, 800));
      expect(
        SealedChainClient.isKeyPublicationFresh(
          onChainPqPubkeyHash: otherHash,
          onChainEncryptionPubkey: enc,
          onChainScanPubkey: scan,
          newPqPubkeyHash: pqHash,
          newEncryptionPubkey: enc,
          newScanPubkey: scan,
        ),
        isFalse,
      );
    });

    test('returns false when encryptionPubkey differs', () {
      expect(
        SealedChainClient.isKeyPublicationFresh(
          onChainPqPubkeyHash: pqHash,
          onChainEncryptionPubkey: _bytes(77, 32),
          onChainScanPubkey: scan,
          newPqPubkeyHash: pqHash,
          newEncryptionPubkey: enc,
          newScanPubkey: scan,
        ),
        isFalse,
      );
    });

    test('returns false when scanPubkey differs', () {
      expect(
        SealedChainClient.isKeyPublicationFresh(
          onChainPqPubkeyHash: pqHash,
          onChainEncryptionPubkey: enc,
          onChainScanPubkey: _bytes(88, 32),
          newPqPubkeyHash: pqHash,
          newEncryptionPubkey: enc,
          newScanPubkey: scan,
        ),
        isFalse,
      );
    });
  });

  group('publishKeysIfStale (integration-style)', () {
    late SealedChainClient client;

    SealedChainClient build({String? walletAddress}) {
      final dio = Dio(BaseOptions(baseUrl: 'http://test-algod'));
      dio.httpClientAdapter = _NoBoxAdapter();
      return SealedChainClient(
        sealedAppId: 1,
        algodUrl: 'http://test-algod',
        indexerUrl: 'http://test-indexer',
        wallet: _FakeWallet(walletAddress),
        // Escrow signer is not exercised on the no-box / wallet-null paths.
        escrow: TreasuryEscrowSigner(Uint8List.fromList([0x06])),
        dio: dio,
      );
    }

    test('throws StateError when wallet not loaded', () async {
      client = build(walletAddress: null);
      await expectLater(
        client.publishKeysIfStale(
          encryptionPubkey: _bytes(1, 32),
          scanPubkey: _bytes(2, 32),
          pqPubkey: _bytes(3, 800),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'returns null when getUserByWallet returns null (no UserState box)',
      () async {
        client = build(
          // Any valid-shape 58-char base32 string is fine; only the box-name
          // base64 echoed in the algod URL is exercised, and the adapter
          // returns 404 unconditionally.
          walletAddress:
              'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        );
        final result = await client.publishKeysIfStale(
          encryptionPubkey: _bytes(1, 32),
          scanPubkey: _bytes(2, 32),
          pqPubkey: _bytes(3, 800),
        );
        expect(result, isNull);
      },
    );
  });
}
