// lib/services/scopes/username_scope.dart
//
// Username scope: wraps a [UsernameSearcher] (typically [IndexerService] in
// production) which forwards to `GET /username/search` on the indexer (FTS5
// trigram fuzzy match server-side).
//
// Returns hits with `isLocal: false`. The local-contact stage lives in
// `SearchService` and is merged upstream of this scope.
//
// The scope depends on a narrow [UsernameSearcher] interface rather than
// `IndexerService` directly so tests can substitute a fake without dragging in
// the full service surface.

import 'package:sealed_app/models/search_hit.dart';
import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/features/search/search_scope.dart';

/// Narrow interface for the one method this scope needs.
///
/// `IndexerService.searchUsers` satisfies this structurally; declare it
/// `implements UsernameSearcher` (or pass an adapter) when wiring DI.
abstract class UsernameSearcher {
  Future<IndexerResult<UsernameSearchResult>> searchUsers(
    String query, {
    int limit,
  });
}

class UsernameSearchScope implements SearchScope {
  final UsernameSearcher _searcher;

  const UsernameSearchScope(this._searcher);

  @override
  String get name => 'username';

  @override
  Future<List<SearchHit>> query(String q, {int limit = 20}) async {
    final trimmed = q.trim();
    if (trimmed.isEmpty) return const [];

    final clamped = limit.clamp(1, 50);
    final result = await _searcher.searchUsers(trimmed, limit: clamped);
    Log.d(result);
    return switch (result) {
      IndexerSuccess<UsernameSearchResult>(:final data) => [
        for (final hit in data.users) UsernameHit(hit, isLocal: false),
      ],
      IndexerFailure<UsernameSearchResult>() => throw result,
    };
  }
}
