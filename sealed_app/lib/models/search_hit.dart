// lib/models/search/search_hit.dart
//
// Shared result types for the client-side search layer.
//
// `SearchHit` is a sealed union: future scopes (messages, contacts,
// transactions) extend it with new variants. UI switches on the variant to
// render scope-specific tiles.
//
// `isLocal` distinguishes hits sourced from on-device storage (e.g. local
// contact repository) from hits returned by the remote indexer. UI may show a
// badge for local hits to communicate that the result is from a saved contact.

/// Discriminated union of all search result variants.
///
/// Add a new scope by adding a new subclass and updating switch sites.
sealed class SearchHit {
  /// True when sourced from on-device storage; false when sourced from the
  /// remote indexer.
  final bool isLocal;

  const SearchHit({required this.isLocal});
}

/// Skinny search hit from GET /username/search.
class UsernameSearchHit {
  final String username;
  final String walletAddress;

  const UsernameSearchHit({
    required this.username,
    required this.walletAddress,
  });

  factory UsernameSearchHit.fromJson(Map<String, dynamic> json) {
    return UsernameSearchHit(
      username: json['username'] as String,
      walletAddress: json['wallet'] as String,
    );
  }
}

/// A username/wallet hit. Currently produced by [UsernameSearchScope].
final class UsernameHit extends SearchHit {
  final UsernameSearchHit hit;

  const UsernameHit(this.hit, {required super.isLocal});

  String get username => hit.username;
  String get walletAddress => hit.walletAddress;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsernameHit &&
          isLocal == other.isLocal &&
          hit.username == other.hit.username &&
          hit.walletAddress == other.hit.walletAddress;

  @override
  int get hashCode => Object.hash(isLocal, hit.username, hit.walletAddress);

  @override
  String toString() =>
      'UsernameHit(${hit.username}, ${hit.walletAddress}, local: $isLocal)';
}

/// A raw Algorand wallet-address hit — synthetic, no username, no I/O.
///
/// Emitted by [SearchService] when the query parses as a valid Algorand address
/// and no existing contact/username hit covers the same wallet.
final class WalletAddressHit extends SearchHit {
  final String walletAddress;

  const WalletAddressHit(this.walletAddress) : super(isLocal: false);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WalletAddressHit && walletAddress == other.walletAddress;

  @override
  int get hashCode => walletAddress.hashCode;

  @override
  String toString() => 'WalletAddressHit($walletAddress)';
}

/// Immutable wrapper around an ordered list of hits for a given query.
///
/// Used by the search provider to emit results to the UI. `query` is the
/// trimmed query the results were produced for; `count` mirrors `hits.length`
/// for convenience and parity with the indexer response shape.
class SearchResults {
  final String query;
  final int count;
  final List<SearchHit> hits;

  /// True while Stage 2 (remote) is in-flight; false once merged result arrives.
  final bool isRemotePending;

  const SearchResults({
    required this.query,
    required this.count,
    required this.hits,
    this.isRemotePending = false,
  });

  /// Empty result for a given query. No hits, count = 0, not pending.
  const SearchResults.empty(this.query)
    : count = 0,
      hits = const [],
      isRemotePending = false;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SearchResults) return false;
    if (query != other.query || count != other.count) return false;
    if (isRemotePending != other.isRemotePending) return false;
    if (hits.length != other.hits.length) return false;
    for (var i = 0; i < hits.length; i++) {
      if (hits[i] != other.hits[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(query, count, isRemotePending, Object.hashAll(hits));

  @override
  String toString() =>
      'SearchResults(query: "$query", count: $count, hits: ${hits.length}, pending: $isRemotePending)';
}
