// test/providers/search_provider_test.dart
//
// Tests `searchUsersProvider` by overriding `searchServiceProvider` with a
// hand-built `SearchService` over fake deps. The transitive providers
// (indexerServiceProvider, contactRepositoryProvider) are not loaded — they
// pull in unrelated app wiring not needed for the provider's own logic.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/search_provider.dart';
import 'package:sealed_app/features/search/search_scope.dart';
import 'package:sealed_app/features/search/search_service.dart';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeRepo implements ContactRepository {
  final List<UserProfile> profiles;
  _FakeRepo(this.profiles);

  @override
  Future<List<UserProfile>> searchContacts(String q, {int limit = 20}) async {
    final lower = q.toLowerCase();
    return profiles
        .where((p) => (p.username ?? '').toLowerCase().contains(lower))
        .take(limit)
        .toList();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScope implements SearchScope {
  int calls = 0;
  final Future<List<SearchHit>> Function(String q) handler;
  _FakeScope(this.handler);

  @override
  String get name => 'username';

  @override
  Future<List<SearchHit>> query(String q, {int limit = 20}) async {
    calls++;
    return handler(q);
  }
}

UserProfile _profile(String wallet, String username) => UserProfile(
  walletAddress: wallet,
  username: username,
  encryptionPubkey: Uint8List(32),
  scanPubkey: Uint8List(32),
  createdAt: DateTime(2024),
);

UsernameHit _remote(String name, String wallet) => UsernameHit(
  UsernameSearchHit(username: name, walletAddress: wallet),
  isLocal: false,
);

ProviderContainer _container(SearchService svc) {
  return ProviderContainer(
    overrides: [searchServiceProvider.overrideWith((_) async => svc)],
  );
}

void main() {
  group('searchUsersProvider', () {
    test('empty query: single AsyncData(empty), no scope call', () async {
      final scope = _FakeScope((_) async => [_remote('x', 'w')]);
      final svc = SearchService(
        contacts: _FakeRepo(const []),
        scopes: {scope.name: scope},
      );
      final c = _container(svc);
      addTearDown(c.dispose);

      final emissions = <SearchResults>[];
      final sub = c.listen<AsyncValue<SearchResults>>(
        searchUsersProvider(''),
        (_, next) => next.whenData(emissions.add),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      await Future.delayed(const Duration(milliseconds: 400));

      expect(emissions, hasLength(1));
      expect(emissions[0].hits, isEmpty);
      expect(scope.calls, 0);
    });

    test('non-empty: emits local first, then merged', () async {
      final scope = _FakeScope((q) async => [_remote('alan', 'w2')]);
      final svc = SearchService(
        contacts: _FakeRepo([_profile('w1', 'alice')]),
        scopes: {scope.name: scope},
      );
      final c = _container(svc);
      addTearDown(c.dispose);

      final emissions = <SearchResults>[];
      final sub = c.listen<AsyncValue<SearchResults>>(
        searchUsersProvider('al'),
        (prev, next) {
          next.whenData(emissions.add);
        },
        fireImmediately: true,
      );
      addTearDown(sub.close);

      // Wait past debounce + scope work.
      await Future.delayed(const Duration(milliseconds: 500));

      expect(emissions.length, greaterThanOrEqualTo(2));
      // Stage 1: local-only (1 hit, isLocal=true)
      expect(emissions.first.hits, hasLength(1));
      expect(emissions.first.hits.first.isLocal, isTrue);
      // Stage 2: merged (2 hits)
      expect(emissions.last.hits, hasLength(2));
      expect(scope.calls, 1);
    });

    test('disposal during debounce cancels stage-2', () async {
      final scope = _FakeScope((_) async => [_remote('x', 'w2')]);
      final svc = SearchService(
        contacts: _FakeRepo([_profile('w1', 'alice')]),
        scopes: {scope.name: scope},
      );
      final c = _container(svc);
      addTearDown(c.dispose);

      final sub = c.listen<AsyncValue<SearchResults>>(
        searchUsersProvider('al'),
        (_, _) {},
        fireImmediately: true,
      );

      // Close before debounce elapses (250ms).
      await Future.delayed(const Duration(milliseconds: 50));
      sub.close();

      // Wait past debounce.
      await Future.delayed(const Duration(milliseconds: 400));

      expect(scope.calls, 0);
    });

    test(
      'invalidating searchServiceProvider clears cache across queries',
      () async {
        // Simulates logout: container.invalidate(searchServiceProvider) → new
        // service instance → cache empty → fresh scope call required.
        var scopeBuilds = 0;
        _FakeScope makeScope() {
          scopeBuilds++;
          return _FakeScope((_) async => [_remote('a', 'w1')]);
        }

        final scopes = <_FakeScope>[];
        final c = ProviderContainer(
          overrides: [
            searchServiceProvider.overrideWith((_) async {
              final s = makeScope();
              scopes.add(s);
              return SearchService(
                contacts: _FakeRepo(const []),
                scopes: {s.name: s},
              );
            }),
          ],
        );
        addTearDown(c.dispose);

        // Run a search → caches result on service-instance #1.
        final sub1 = c.listen<AsyncValue<SearchResults>>(
          searchUsersProvider('al'),
          (_, _) {},
          fireImmediately: true,
        );
        await Future.delayed(const Duration(milliseconds: 400));
        sub1.close();
        expect(scopes[0].calls, 1);

        // Invalidate → next read builds service-instance #2 with empty cache.
        c.invalidate(searchServiceProvider);

        final sub2 = c.listen<AsyncValue<SearchResults>>(
          searchUsersProvider('al'),
          (_, _) {},
          fireImmediately: true,
        );
        await Future.delayed(const Duration(milliseconds: 400));
        sub2.close();

        expect(scopeBuilds, 2, reason: 'service rebuilt after invalidate');
        expect(
          scopes[1].calls,
          1,
          reason: 'fresh scope hit, cache did not leak',
        );
      },
    );

    test(
      'local stage is skipped when disposed before local future resolves',
      () async {
        // Stage-1 cancellation: if the container disposes the family entry
        // before searchLocal resolves, no emission happens.
        final scope = _FakeScope((_) async => [_remote('x', 'w2')]);
        final svc = SearchService(
          contacts: _FakeRepo([_profile('w1', 'alice')]),
          scopes: {scope.name: scope},
        );
        final c = _container(svc);
        addTearDown(c.dispose);

        final emissions = <SearchResults>[];
        final sub = c.listen<AsyncValue<SearchResults>>(
          searchUsersProvider('al'),
          (_, next) => next.whenData(emissions.add),
          fireImmediately: true,
        );

        // Close immediately. Microtask boundary: local future not yet awaited.
        sub.close();
        await Future.delayed(const Duration(milliseconds: 400));

        // No remote call should happen.
        expect(scope.calls, 0);
      },
    );
    test('stage-1 emission has isRemotePending=true', () async {
      final scope = _FakeScope((q) async => [_remote('alan', 'w2')]);
      final svc = SearchService(
        contacts: _FakeRepo([_profile('w1', 'alice')]),
        scopes: {scope.name: scope},
      );
      final c = _container(svc);
      addTearDown(c.dispose);

      final emissions = <SearchResults>[];
      final sub = c.listen<AsyncValue<SearchResults>>(
        searchUsersProvider('al'),
        (_, next) => next.whenData(emissions.add),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      await Future.delayed(const Duration(milliseconds: 500));

      expect(emissions.length, greaterThanOrEqualTo(2));
      expect(
        emissions.first.isRemotePending,
        isTrue,
        reason: 'Stage 1 should be marked pending',
      );
      expect(
        emissions.last.isRemotePending,
        isFalse,
        reason: 'Stage 2 should not be marked pending',
      );
    });

    test('empty query emission has isRemotePending=false', () async {
      final scope = _FakeScope((_) async => []);
      final svc = SearchService(
        contacts: _FakeRepo(const []),
        scopes: {scope.name: scope},
      );
      final c = _container(svc);
      addTearDown(c.dispose);

      final emissions = <SearchResults>[];
      final sub = c.listen<AsyncValue<SearchResults>>(
        searchUsersProvider(''),
        (_, next) => next.whenData(emissions.add),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      await Future.delayed(const Duration(milliseconds: 100));

      expect(emissions, hasLength(1));
      expect(emissions.first.isRemotePending, isFalse);
    });
  });
}
