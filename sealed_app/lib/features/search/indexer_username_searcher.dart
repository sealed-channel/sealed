import 'package:sealed_app/features/search/username_scope.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';

/// Adapter: bridge IndexerService → narrow UsernameSearcher interface.
/// Typed `dynamic` to avoid analysis-time coupling to the rest of
/// IndexerService while it has unrelated compile errors on this branch.
class IndexerUsernameSearcher implements UsernameSearcher {
  final dynamic _indexer;
  const IndexerUsernameSearcher(this._indexer);

  @override
  Future<IndexerResult<UsernameSearchResult>> searchUsers(
    String query, {
    int limit = 20,
  }) {
    return _indexer.searchUsers(query, limit: limit)
        as Future<IndexerResult<UsernameSearchResult>>;
  }
}
