// Tests for indexer pagination in SealedChainClient (_fetchTxnPages):
// the client must follow the indexer's `next-token` across pages instead of
// silently capping results at a single `limit`-sized page.

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

class _FakeEscrow implements TreasuryEscrowSigner {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records each `/v2/transactions` request and serves a scripted sequence of
/// pages. A page with a non-empty `next-token` must trigger a follow-up
/// request carrying that token as `next`.
class _PagingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> pages;
  final List<String?> seenNextParams = [];
  int _i = 0;

  _PagingAdapter(this.pages);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    seenNextParams.add(options.queryParameters['next'] as String?);
    final page = pages[_i.clamp(0, pages.length - 1)];
    _i++;
    return ResponseBody.fromString(
      jsonEncode(page),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

SealedChainClient _client(_PagingAdapter adapter) {
  final dio = Dio(BaseOptions(responseType: ResponseType.json));
  dio.httpClientAdapter = adapter;
  return SealedChainClient(
    sealedAppId: 1234,
    algodUrl: 'https://algod.test',
    indexerUrl: 'https://indexer.test',
    wallet: _FakeWallet(
      'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI',
    ),
    escrow: _FakeEscrow(),
    dio: dio,
  );
}

// A minimal appl txn that does NOT match the sendMessage selector — kept simple
// because these tests assert pagination control flow, not message parsing.
Map<String, dynamic> _txn(String id) => {
  'id': id,
  'sender': 'SENDER',
  'round-time': 1,
  'application-transaction': {
    'application-args': [base64Encode(Uint8List(4))],
  },
};

void main() {
  test('follows next-token across multiple pages', () async {
    final adapter = _PagingAdapter([
      {
        'transactions': [_txn('a'), _txn('b')],
        'next-token': 'TKN_2',
      },
      {
        'transactions': [_txn('c')],
        'next-token': 'TKN_3',
      },
      {
        'transactions': <dynamic>[], // empty page terminates
        'next-token': 'TKN_4',
      },
    ]);

    await _client(adapter).fetchAllAppMessages();

    expect(adapter.seenNextParams.length, 3, reason: '3 requests expected');
    expect(
      adapter.seenNextParams[0],
      isNull,
      reason: 'first page has no token',
    );
    expect(adapter.seenNextParams[1], 'TKN_2');
    expect(adapter.seenNextParams[2], 'TKN_3');
  });

  test('stops after a single page when no next-token is returned', () async {
    final adapter = _PagingAdapter([
      {
        'transactions': [_txn('a')],
        // no next-token
      },
    ]);

    await _client(adapter).fetchAllAppMessages();

    expect(adapter.seenNextParams.length, 1);
  });

  test('a failing request propagates instead of returning empty', () async {
    final adapter = _FailingAdapter();
    expect(
      () => _client2(adapter).fetchAllAppMessages(),
      throwsA(isA<DioException>()),
    );
  });
}

class _FailingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async => throw DioException(requestOptions: options, error: 'boom');
}

SealedChainClient _client2(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(responseType: ResponseType.json));
  dio.httpClientAdapter = adapter;
  return SealedChainClient(
    sealedAppId: 1234,
    algodUrl: 'https://algod.test',
    indexerUrl: 'https://indexer.test',
    wallet: _FakeWallet(
      'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI',
    ),
    escrow: _FakeEscrow(),
    dio: dio,
  );
}
