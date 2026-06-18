// lib/services/search_service.dart
//
// Two-stage search composer:
//
//   Stage 1: local contact LIKE-match (sync, instant)  — via ContactRepository.
//   Stage 2: pluggable remote SearchScope (e.g. indexer fuzzy trigram).
//
// `searchLocal` is cheap and never cached.
// `searchRemote` runs the named scope and merges its hits with the supplied
// local hits, de-duping by `walletAddress` (local wins to preserve user-set
// names). Merged results are cached (LRU 32 entries, 30s TTL) keyed by
// (scope, trimmed query, limit).
//
// `clearCache()` wipes the cache (call on logout). The service instance itself
// owns the cache, so dropping/rebuilding the service via Riverpod
// `ref.invalidate` is also a valid invalidation strategy.

import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/search_hit.dart';
import 'package:sealed_app/features/search/search_scope.dart';

export 'package:sealed_app/models/search_hit.dart';

typedef ClockFn = DateTime Function();
typedef SelfWalletGetter = String? Function();

class _CacheEntry {
  final SearchResults results;
  final DateTime storedAt;
  const _CacheEntry(this.results, this.storedAt);
}

class SearchService {
  static const int defaultCacheCapacity = 32;
  static const Duration defaultCacheTtl = Duration(seconds: 30);

  final ContactRepository _contacts;
  final Map<String, SearchScope> _scopes;
  final int _capacity;
  final Duration _ttl;
  final ClockFn _now;
  final SelfWalletGetter? _selfWalletGetter;

  /// Insertion-ordered map → cheap LRU via remove+reinsert on access.
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  SearchService({
    required ContactRepository contacts,
    required Map<String, SearchScope> scopes,
    int capacity = defaultCacheCapacity,
    Duration ttl = defaultCacheTtl,
    ClockFn? clock,
    SelfWalletGetter? selfWalletGetter,
  }) : _contacts = contacts,
       _scopes = Map.unmodifiable(scopes),
       _capacity = capacity,
       _ttl = ttl,
       _now = clock ?? DateTime.now,
       _selfWalletGetter = selfWalletGetter;

  // ---------------------------------------------------------------------------
  // Stage 1: local contacts
  // ---------------------------------------------------------------------------

  /// Local contact LIKE-match. Returns hits with `isLocal: true`.
  /// Empty/whitespace query short-circuits to `[]`, no repo call.
  /// Self wallet (if provided via [selfWalletGetter]) is excluded.
  Future<List<SearchHit>> searchLocal(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final self = _selfWalletGetter?.call();
    final profiles = await _contacts.searchContacts(trimmed, limit: limit);
    return [
      for (final p in profiles)
        if (p.username != null && p.username!.isNotEmpty)
          if (self == null || p.walletAddress != self)
            UsernameHit(
              UsernameSearchHit(
                username: p.username!,
                walletAddress: p.walletAddress,
              ),
              isLocal: true,
            ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Stage 2: remote scope + merge + cache
  // ---------------------------------------------------------------------------

  /// Run the named scope, merge with [mergeWith] (typically the stage-1 local
  /// hits), and return cached-or-fresh [SearchResults].
  ///
  /// Cache key: `(scopeName, trimmedQuery, limit)`. Cache stores merged result;
  /// `mergeWith` is part of the key shape only via wallet de-dup outcome —
  /// callers should pass the same `mergeWith` for cache reuse to be correct.
  /// In practice, local hits are stable within a session so this is fine.
  Future<SearchResults> searchRemote(
    String query, {
    String scope = 'username',
    int limit = 20,
    List<SearchHit> mergeWith = const [],
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchResults.empty(trimmed);
    }

    final key = _cacheKey(scope, trimmed, limit);

    // Cache the REMOTE hits only, never the merged result: a local contact must
    // always override its indexer twin (same wallet → keep the labelled
    // 'Contact' hit), so we re-merge the caller's current `mergeWith` on top of
    // the cached remote hits every call instead of serving a stale merge.
    List<SearchHit> remoteHits;
    final cachedRemote = _readCache(key);
    if (cachedRemote != null) {
      remoteHits = cachedRemote.hits;
    } else {
      final impl = _scopes[scope];
      if (impl == null) {
        throw ArgumentError.value(scope, 'scope', 'unknown search scope');
      }
      remoteHits = await impl.query(trimmed, limit: limit);
      _writeCache(
        key,
        SearchResults(
          query: trimmed,
          count: remoteHits.length,
          hits: remoteHits,
        ),
      );
    }

    return _merge(query: trimmed, local: mergeWith, remote: remoteHits);
  }

  /// Drop all cached results. Call on logout / user switch.
  void clearCache() => _cache.clear();

  /// Visible for tests/inspection.
  int get cacheSize => _cache.length;

  // ---------------------------------------------------------------------------
  // Merge
  // ---------------------------------------------------------------------------

  SearchResults _merge({
    required String query,
    required List<SearchHit> local,
    required List<SearchHit> remote,
  }) {
    final self = _selfWalletGetter?.call();
    final seen = <String>{};
    final out = <SearchHit>[];

    for (final h in local) {
      final w = _walletOf(h);
      if (w == null) continue;
      if (self != null && w == self) continue;
      if (seen.add(w)) out.add(h);
    }
    for (final h in remote) {
      final w = _walletOf(h);
      if (w == null) {
        out.add(h);
        continue;
      }
      if (self != null && w == self) continue;
      if (seen.add(w)) out.add(h);
    }

    return SearchResults(query: query, count: out.length, hits: out);
  }

  String? _walletOf(SearchHit h) => switch (h) {
    UsernameHit(:final walletAddress) => walletAddress,
    WalletAddressHit(:final walletAddress) => walletAddress,
  };

  // ---------------------------------------------------------------------------
  // Cache helpers (LRU + TTL)
  // ---------------------------------------------------------------------------

  String _cacheKey(String scope, String q, int limit) => '$scope|$q|$limit';

  SearchResults? _readCache(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (_now().difference(entry.storedAt) > _ttl) return null;
    // Reinsert at MRU end.
    _cache[key] = entry;
    return entry.results;
  }

  void _writeCache(String key, SearchResults results) {
    _cache.remove(key);
    _cache[key] = _CacheEntry(results, _now());
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first);
    }
  }
}
