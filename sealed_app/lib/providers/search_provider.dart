// lib/providers/search_provider.dart
//
// Riverpod entry point for the two-stage search layer.
//
//   searchUsersProvider — StreamProvider.family.autoDispose<SearchResults>.
//                         Yields local hits immediately, then debounces
//                         250 ms and yields merged local + remote.
//
// The `searchServiceProvider` it depends on is defined in `app_providers.dart`
// (alongside other DI wiring). Keeping the family provider in its own file
// keeps imports for tests narrow.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/infra/chain/chain_address.dart';
import 'package:sealed_app/features/search/search_service.dart';

/// Debounce window between stage-1 (local) and stage-2 (remote) emissions.
const Duration kSearchDebounce = Duration(milliseconds: 250);

/// Defined in `app_providers.dart`. Re-declared here as a forward reference
/// so this file does not transitively pull in `IndexerService` and the rest
/// of the app wiring (and so that tests can `overrideWith` a fake).
final searchServiceProvider = FutureProvider<SearchService>((ref) {
  throw UnimplementedError(
    'searchServiceProvider must be overridden in app_providers.dart '
    'or via test overrides',
  );
});

/// Two-stage search keyed by raw user input.
///
/// Emits twice on non-empty input:
///   1. AsyncData(local-only)  — immediate, no debounce.
///   2. AsyncData(merged)      — after [kSearchDebounce] idle window.
///
/// Empty/whitespace input emits a single `AsyncData(SearchResults.empty)` and
/// never hits the network.
final searchUsersProvider = StreamProvider.family
    .autoDispose<SearchResults, String>((ref, query) async* {
      final trimmed = query.trim();
      if (trimmed.isEmpty) {
        yield SearchResults.empty(trimmed);
        return;
      }

      // Single cancellation flag covers every async hop: local repo read,
      // debounce delay, remote scope call, final yield. If the family entry is
      // disposed (autoDispose -> no listeners), the flag flips and we bail out
      // without emitting stale data.
      var cancelled = false;
      ref.onDispose(() => cancelled = true);

      final svc = await ref.watch(searchServiceProvider.future);
      if (cancelled) return;

      // Stage 1: local contacts, instant.
      final local = await svc.searchLocal(trimmed);
      if (cancelled) return;
      yield SearchResults(
        query: trimmed,
        count: local.length,
        hits: local,
        isRemotePending: true,
      );

      // Stage 2: debounce, then remote fuzzy merge.
      await Future<void>.delayed(kSearchDebounce);
      if (cancelled) return;

      try {
        final merged = await svc.searchRemote(trimmed, mergeWith: local);
        if (cancelled) return;
        yield _withWalletFallback(trimmed, merged);
      } catch (_) {
        // Remote scope failed — fall back to local-only results.
        if (cancelled) return;
        final fallback = SearchResults(
          query: trimmed,
          count: local.length,
          hits: local,
          isRemotePending: false,
        );
        yield _withWalletFallback(trimmed, fallback);
      }
    });

/// If [results] has no hits and [query] is a valid Algorand address,
/// returns a new [SearchResults] with a single [WalletAddressHit].
/// Otherwise returns [results] unchanged.
SearchResults _withWalletFallback(String query, SearchResults results) {
  if (results.hits.isNotEmpty) return results;
  if (!ChainAddress.isValid(query, 'algorand')) return results;
  final hit = WalletAddressHit(query);
  return SearchResults(query: query, count: 1, hits: [hit]);
}
