// lib/services/scopes/search_scope.dart
//
// Pluggable search scope abstraction. Each scope owns one source of hits
// (e.g. username via indexer, messages via local FTS, etc.). `SearchService`
// composes scopes; UI never depends on individual scope impls.

import 'package:sealed_app/models/search_hit.dart';

/// A single source of [SearchHit]s for a given query.
///
/// Implementations must:
///   * Treat empty/whitespace queries as a no-op (return `const []`).
///   * Clamp `limit` to a sane range internally if relevant.
///   * Be safe to call concurrently; instances are shared.
abstract class SearchScope {
  /// Stable identifier (e.g. `'username'`). Used as a cache-key prefix and
  /// for routing in `SearchService`.
  String get name;

  /// Run the scope's query. Returns hits with `isLocal` set per source.
  Future<List<SearchHit>> query(String q, {int limit});
}
