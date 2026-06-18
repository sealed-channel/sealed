// test/services/scopes/username_scope_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/models/search_hit.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/features/search/username_scope.dart';

/// Narrow fake implementing only [UsernameSearcher].
class _FakeUsernameSearcher implements UsernameSearcher {
  int calls = 0;
  String? lastQuery;
  int? lastLimit;
  final IndexerResult<UsernameSearchResult> Function(String q, int limit)
  handler;

  _FakeUsernameSearcher(this.handler);

  @override
  Future<IndexerResult<UsernameSearchResult>> searchUsers(
    String query, {
    int limit = 20,
  }) async {
    calls++;
    lastQuery = query;
    lastLimit = limit;
    return handler(query, limit);
  }
}

UsernameSearchResult _ok(String q, List<(String, String)> hits) =>
    UsernameSearchResult(
      query: q,
      count: hits.length,
      users: [
        for (final (u, w) in hits)
          UsernameSearchHit(username: u, walletAddress: w),
      ],
    );

void main() {
  group('UsernameSearchScope', () {
    test('name is "username"', () {
      final scope = UsernameSearchScope(
        _FakeUsernameSearcher((_, _) => IndexerSuccess(_ok('', []))),
      );
      expect(scope.name, 'username');
    });

    test('empty query short-circuits, no searcher call', () async {
      final fake = _FakeUsernameSearcher((_, _) => IndexerSuccess(_ok('', [])));
      final scope = UsernameSearchScope(fake);

      final hits = await scope.query('   ');

      expect(hits, isEmpty);
      expect(fake.calls, 0);
    });

    test('valid query: returns mapped hits with isLocal=false', () async {
      final fake = _FakeUsernameSearcher(
        (_, _) => IndexerSuccess(_ok('al', [('alice', 'w1'), ('alan', 'w2')])),
      );
      final scope = UsernameSearchScope(fake);

      final hits = await scope.query('al');

      expect(hits, hasLength(2));
      expect(hits.every((h) => !h.isLocal), isTrue);
      expect(hits.whereType<UsernameHit>().map((h) => h.username), [
        'alice',
        'alan',
      ]);
      expect(fake.calls, 1);
      expect(fake.lastQuery, 'al');
    });

    test('trims query before forwarding', () async {
      final fake = _FakeUsernameSearcher(
        (_, _) => IndexerSuccess(_ok('alice', [('alice', 'w1')])),
      );
      final scope = UsernameSearchScope(fake);

      await scope.query('  alice  ');

      expect(fake.lastQuery, 'alice');
    });

    test('limit clamped to [1, 50]', () async {
      final fake = _FakeUsernameSearcher(
        (_, _) => IndexerSuccess(_ok('a', [])),
      );
      final scope = UsernameSearchScope(fake);

      await scope.query('a', limit: 0);
      expect(fake.lastLimit, 1);

      await scope.query('a', limit: 9999);
      expect(fake.lastLimit, 50);

      await scope.query('a', limit: 25);
      expect(fake.lastLimit, 25);
    });

    test('IndexerFailure rethrows', () async {
      final fake = _FakeUsernameSearcher(
        (_, _) =>
            const IndexerFailure<UsernameSearchResult>('boom', statusCode: 500),
      );
      final scope = UsernameSearchScope(fake);

      expect(
        () => scope.query('al'),
        throwsA(
          isA<IndexerFailure<UsernameSearchResult>>()
              .having((f) => f.error, 'error', 'boom')
              .having((f) => f.statusCode, 'statusCode', 500),
        ),
      );
    });
  });
}
