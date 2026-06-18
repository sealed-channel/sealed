// Tests for SealedChainClient.waitForConfirmation.
//
// Strategy: inject a Dio with a custom HttpClientAdapter that yields canned
// JSON responses for `GET /v2/transactions/pending/{txid}`. Avoids depending
// on http_mock_adapter (not a project dep).

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';
import 'package:sealed_app/core/errors.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> responses;
  int callCount = 0;
  _ScriptedAdapter(this.responses);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final idx = callCount < responses.length ? callCount : responses.length - 1;
    callCount += 1;
    final body = responses[idx];
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

// Empty 1-byte program is enough — we never actually submit a txn in these
// tests; we only exercise the algod-polling path.
final _emptyEscrow = TreasuryEscrowSigner(Uint8List.fromList([0x01]));

SealedChainClient _client(_ScriptedAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return SealedChainClient(
    sealedAppId: 1,
    algodUrl: 'http://localhost:4001',
    indexerUrl: 'http://localhost:8980',
    wallet: AlgorandWallet(const FlutterSecureStorage()),
    escrow: _emptyEscrow,
    dio: dio,
  );
}

void main() {
  group('SealedChainClient.waitForConfirmation', () {
    test('returns confirmed round immediately', () async {
      final adapter = _ScriptedAdapter([
        {'confirmed-round': 42},
      ]);
      final client = _client(adapter);
      final round = await client.waitForConfirmation(
        'TX1',
        timeout: const Duration(seconds: 1),
        interval: const Duration(milliseconds: 10),
      );
      expect(round, 42);
      expect(adapter.callCount, 1);
    });

    test('polls until confirmed', () async {
      final adapter = _ScriptedAdapter([
        {'confirmed-round': 0},
        {'confirmed-round': 0},
        {'confirmed-round': 7},
      ]);
      final client = _client(adapter);
      final round = await client.waitForConfirmation(
        'TX2',
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 10),
      );
      expect(round, 7);
      expect(adapter.callCount, 3);
    });

    test('throws ConfirmationTimeoutError when never confirms', () async {
      final adapter = _ScriptedAdapter([
        {'confirmed-round': 0},
      ]);
      final client = _client(adapter);
      await expectLater(
        client.waitForConfirmation(
          'TX3',
          timeout: const Duration(milliseconds: 300),
          interval: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<ConfirmationTimeoutError>().having((e) => e.txId, 'txId', 'TX3'),
        ),
      );
    });

    test('throws GenericSealedException on non-empty pool-error', () async {
      final adapter = _ScriptedAdapter([
        {'confirmed-round': 0, 'pool-error': 'TransactionPool.Remember: boom'},
      ]);
      final client = _client(adapter);
      await expectLater(
        client.waitForConfirmation(
          'TX4',
          timeout: const Duration(seconds: 1),
          interval: const Duration(milliseconds: 10),
        ),
        throwsA(isA<GenericSealedException>()),
      );
    });
  });
}
