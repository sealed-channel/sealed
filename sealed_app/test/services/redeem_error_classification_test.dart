// Unit tests for [isBadCodeRejection] — the redeem-path error classifier used
// by [SealedChainClient.redeemAndPublish].
//
// Background: redeem is a PAID action (10 ALGO / 500-credit code). The catch
// block must convert an error into [BadRedeemCodeError] ("code invalid or
// already used") ONLY when the failure is a genuine TEAL logic-eval rejection
// (contract assert `BAD_CODE` / `BAD_PREIMAGE`). Everything else — pool errors,
// the credit-batch limit, HTTP 5xx relay failures, responseless transport
// errors — leaves the code unspent and MUST propagate unchanged so we never
// burn-flag a valid paid code.
//
// These are pure unit tests: no network, no chain client construction. They
// pin the classifier directly.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';

DioException _dioWithResponse(int status, Object? body) {
  final opts = RequestOptions(path: '/v2/transactions');
  return DioException(
    requestOptions: opts,
    response: Response<dynamic>(
      requestOptions: opts,
      statusCode: status,
      data: body,
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  group('isBadCodeRejection (unit)', () {
    test('credit batch-limit GenericSealedException is NOT converted', () {
      // Mirrors the literal thrown by the chain client for TOO_MANY_BATCHES.
      final e = const GenericSealedException(
        'Credit batch limit (12) reached.',
      );
      expect(isBadCodeRejection(e), isFalse);
    });

    test('TOO_MANY_BATCHES in details is NOT converted', () {
      final e = const GenericSealedException(
        'algod rejected group (HTTP 400): logic eval error: assert',
        details: 'TOO_MANY_BATCHES',
      );
      // Even though the message contains eval markers, the batch-limit marker
      // wins (code is not bad — the box is just full).
      expect(isBadCodeRejection(e), isFalse);
    });

    test('pool-error GenericSealedException is NOT converted', () {
      final e = const GenericSealedException(
        'pool-error: txn dead: fee too small',
        details: 'txn dead: fee too small',
      );
      expect(isBadCodeRejection(e), isFalse);
    });

    test('pool-error that also mentions assert is NOT converted', () {
      final e = const GenericSealedException(
        'pool-error: TransactionPool.Remember: assert failed',
        details: 'TransactionPool.Remember: assert failed',
      );
      expect(isBadCodeRejection(e), isFalse);
    });

    test('HTTP 5xx GenericSealedException is NOT converted', () {
      final e = const GenericSealedException(
        'algod rejected group (HTTP 503): logic eval error: assert',
        details: 'logic eval error: assert',
      );
      expect(isBadCodeRejection(e), isFalse);
    });

    test('logic-eval BAD_CODE GenericSealedException IS converted', () {
      final e = const GenericSealedException(
        'algod rejected group (HTTP 400): logic eval error',
        details:
            'logic eval error: assert failed pc=123. Details: app=..., '
            'opcode=assert, BAD_CODE',
      );
      expect(isBadCodeRejection(e), isTrue);
    });

    test('logic-eval BAD_PREIMAGE GenericSealedException IS converted', () {
      final e = const GenericSealedException(
        'algod rejected group (HTTP 400)',
        details: 'rejected by logic error: BAD_PREIMAGE',
      );
      expect(isBadCodeRejection(e), isTrue);
    });

    test('GenericSealedException with no eval marker is NOT converted', () {
      final e = const GenericSealedException(
        'On-chain state inconsistency.',
        details: 'BAD_STATE',
      );
      expect(isBadCodeRejection(e), isFalse);
    });

    test('responseless DioException (timeout) is NOT converted', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v2/transactions'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(isBadCodeRejection(e), isFalse);
    });

    test('DioException 4xx with eval marker IS converted', () {
      final e = _dioWithResponse(
        400,
        '{"message":"logic eval error: assert failed BAD_CODE"}',
      );
      expect(isBadCodeRejection(e), isTrue);
    });

    test('DioException 4xx without eval marker is NOT converted', () {
      final e = _dioWithResponse(404, '{"message":"not found"}');
      expect(isBadCodeRejection(e), isFalse);
    });

    test('DioException 5xx with eval marker is NOT converted', () {
      // 5xx is a server failure, never a code rejection — even if the body
      // happens to echo eval wording.
      final e = _dioWithResponse(500, '{"message":"logic eval error: assert"}');
      expect(isBadCodeRejection(e), isFalse);
    });

    test('unrelated error type is NOT converted', () {
      expect(isBadCodeRejection(StateError('boom')), isFalse);
      expect(isBadCodeRejection(ArgumentError('nope')), isFalse);
    });
  });
}
