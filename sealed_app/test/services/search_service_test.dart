// test/services/search_service_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/features/search/search_scope.dart';
import 'package:sealed_app/features/search/search_service.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeContactRepository implements ContactRepository {
  final List<UserProfile> profiles;
  int searchCalls = 0;

  _FakeContactRepository(this.profiles);

  @override
  Future<List<UserProfile>> searchContacts(
    String query, {
    int limit = 20,
  }) async {
    searchCalls++;
    final q = query.toLowerCase();
    return profiles
        .where(
          (p) =>
              (p.username?.toLowerCase().contains(q) ?? false) ||
              p.walletAddress.toLowerCase().contains(q),
        )
        .take(limit)
        .toList();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScope implements SearchScope {
  final String _name;
  int calls = 0;
  String? lastQuery;
  Future<List<SearchHit>> Function(String q, int limit) handler;

  _FakeScope(this._name, this.handler);

  @override
  String get name => _name;

  @override
  Future<List<SearchHit>> query(String q, {int limit = 20}) async {
    calls++;
    lastQuery = q;
    return handler(q, limit);
  }
}

UserProfile _profile(String wallet, String? username) => UserProfile(
  walletAddress: wallet,
  username: username,
  encryptionPubkey: Uint8List(32),
  scanPubkey: Uint8List(32),
  createdAt: DateTime(2024),
);

UsernameHit _remoteHit(String name, String wallet) => UsernameHit(
  UsernameSearchHit(username: name, walletAddress: wallet),
  isLocal: false,
);

// Algorand addresses generated from Ed25519 seeds 0x42 and 0x01 via ChainAddress.encode.
const _algoAddr1 = 'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI';
const _algoAddr2 = 'RKEOHXLUBHYZL7KS3MWTZOS5OLFGOCN7DWKBEG7TOSEADNAPN5OOTUNSLE';

void main() {
  group('SearchService self-exclusion', () {
    test('searchLocal excludes self wallet', () async {
      final repo = _FakeContactRepository([
        _profile('self-wallet', 'me'),
        _profile('w2', 'melody'),
      ]);
      final svc = SearchService(
        contacts: repo,
        scopes: const {},
        selfWalletGetter: () => 'self-wallet',
      );

      final out = await svc.searchLocal('me');

      expect(out, hasLength(1));
      expect((out.first as UsernameHit).walletAddress, 'w2');
    });

    test(
      'searchLocal includes all hits when selfWalletGetter is null',
      () async {
        final repo = _FakeContactRepository([
          _profile('w1', 'me'),
          _profile('w2', 'alice'),
        ]);
        final svc = SearchService(contacts: repo, scopes: const {});

        final out = await svc.searchLocal('e');

        expect(out, hasLength(2));
      },
    );

    test('_merge excludes self wallet from local hits', () async {
      final scope = _FakeScope(
        'username',
        (_, _) async => [_remoteHit('alice', 'w2')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
        selfWalletGetter: () => 'self-wallet',
      );
      final local = [
        UsernameHit(
          const UsernameSearchHit(username: 'me', walletAddress: 'self-wallet'),
          isLocal: true,
        ),
        UsernameHit(
          const UsernameSearchHit(username: 'bob', walletAddress: 'w3'),
          isLocal: true,
        ),
      ];

      final r = await svc.searchRemote('e', mergeWith: local);

      expect(r.hits, hasLength(2));
      expect(
        r.hits.whereType<UsernameHit>().map((h) => h.walletAddress),
        isNot(contains('self-wallet')),
      );
    });

    test('_merge excludes self wallet from remote hits', () async {
      final scope = _FakeScope(
        'username',
        (_, _) async => [
          _remoteHit('me', 'self-wallet'),
          _remoteHit('alice', 'w2'),
        ],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
        selfWalletGetter: () => 'self-wallet',
      );

      final r = await svc.searchRemote('me');

      expect(r.hits, hasLength(1));
      expect((r.hits.first as UsernameHit).walletAddress, 'w2');
    });

    test('self-exclusion: null self wallet excludes nothing', () async {
      final scope = _FakeScope(
        'username',
        (_, _) async => [_remoteHit('me', 'w1'), _remoteHit('alice', 'w2')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
        selfWalletGetter: () => null,
      );

      final r = await svc.searchRemote('me');

      expect(r.hits, hasLength(2));
    });
  });

  group('SearchService.searchLocal', () {
    test('empty query: no repo call, empty result', () async {
      final repo = _FakeContactRepository([_profile('w1', 'alice')]);
      final svc = SearchService(contacts: repo, scopes: const {});

      final out = await svc.searchLocal('   ');

      expect(out, isEmpty);
      expect(repo.searchCalls, 0);
    });

    test('returns local UsernameHits with isLocal=true', () async {
      final repo = _FakeContactRepository([
        _profile('w1', 'alice'),
        _profile('w2', 'alan'),
        _profile('w3', null), // no username, filtered out
      ]);
      final svc = SearchService(contacts: repo, scopes: const {});

      final out = await svc.searchLocal('al');

      expect(out, hasLength(2));
      expect(out.every((h) => h.isLocal), isTrue);
      expect(out.whereType<UsernameHit>().map((h) => h.username), [
        'alice',
        'alan',
      ]);
    });
  });

  group('SearchService.searchRemote', () {
    test('empty query: empty result, no scope call', () async {
      final scope = _FakeScope(
        'username',
        (q, _) async => [_remoteHit('x', 'w')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
      );

      final r = await svc.searchRemote('');
      expect(r.hits, isEmpty);
      expect(r.count, 0);
      expect(scope.calls, 0);
    });

    test('unknown scope throws', () async {
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: const {},
      );
      expect(() => svc.searchRemote('a'), throwsArgumentError);
    });

    test('returns scope hits when no local merge', () async {
      final scope = _FakeScope(
        'username',
        (_, _) async => [_remoteHit('alice', 'w1'), _remoteHit('alan', 'w2')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
      );

      final r = await svc.searchRemote('al');

      expect(r.query, 'al');
      expect(r.count, 2);
      expect(r.hits.whereType<UsernameHit>().map((h) => h.username), [
        'alice',
        'alan',
      ]);
      expect(scope.calls, 1);
    });

    test(
      'de-dupe by wallet: local wins, order = local-first then remote-only',
      () async {
        final scope = _FakeScope(
          'username',
          (_, _) async => [
            _remoteHit('aliceRemote', 'w1'), // collides with local
            _remoteHit('alan', 'w2'), // remote-only
          ],
        );
        final svc = SearchService(
          contacts: _FakeContactRepository(const []),
          scopes: {scope.name: scope},
        );

        final local = [
          UsernameHit(
            const UsernameSearchHit(
              username: 'aliceLocal',
              walletAddress: 'w1',
            ),
            isLocal: true,
          ),
        ];

        final r = await svc.searchRemote('a', mergeWith: local);

        expect(r.hits, hasLength(2));
        final first = r.hits[0] as UsernameHit;
        final second = r.hits[1] as UsernameHit;
        expect(first.username, 'aliceLocal');
        expect(first.isLocal, isTrue);
        expect(second.username, 'alan');
        expect(second.isLocal, isFalse);
      },
    );

    test('cache hit within TTL: second call skips scope', () async {
      var nowMs = 1000;
      final scope = _FakeScope(
        'username',
        (_, _) async => [_remoteHit('a', 'w1')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      );

      await svc.searchRemote('al');
      nowMs += 5000; // 5s later
      final r2 = await svc.searchRemote('al');

      expect(scope.calls, 1);
      expect(r2.hits, hasLength(1));
    });

    test('cache miss after TTL: scope called again', () async {
      var nowMs = 1000;
      final scope = _FakeScope(
        'username',
        (_, _) async => [_remoteHit('a', 'w1')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
        ttl: const Duration(seconds: 30),
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      );

      await svc.searchRemote('al');
      nowMs += 31000; // past TTL
      await svc.searchRemote('al');

      expect(scope.calls, 2);
    });

    test('LRU evicts oldest at capacity + 1', () async {
      final scope = _FakeScope(
        'username',
        (q, _) async => [_remoteHit(q, 'w-$q')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
        capacity: 3,
      );

      await svc.searchRemote('a');
      await svc.searchRemote('b');
      await svc.searchRemote('c');
      expect(svc.cacheSize, 3);

      await svc.searchRemote('d'); // evicts 'a'
      expect(svc.cacheSize, 3);

      // 'a' re-fetches, scope called again
      await svc.searchRemote('a');
      expect(scope.calls, 5);
    });

    test('clearCache wipes all entries', () async {
      final scope = _FakeScope(
        'username',
        (_, _) async => [_remoteHit('a', 'w1')],
      );
      final svc = SearchService(
        contacts: _FakeContactRepository(const []),
        scopes: {scope.name: scope},
      );

      await svc.searchRemote('al');
      expect(svc.cacheSize, 1);
      svc.clearCache();
      expect(svc.cacheSize, 0);

      await svc.searchRemote('al');
      expect(scope.calls, 2);
    });
  });

  group('WalletAddressHit synthetic emission', () {
    test(
      'valid address with no contact → empty searchLocal (wallet tile injected by provider)',
      () async {
        final repo = _FakeContactRepository(const []);
        final svc = SearchService(contacts: repo, scopes: const {});

        final out = await svc.searchLocal(_algoAddr1);

        // SearchService no longer injects WalletAddressHit — that's the provider's job.
        expect(out, isEmpty);
        expect(out.whereType<WalletAddressHit>(), isEmpty);
      },
    );

    test(
      'valid address matching existing contact → UsernameHit returned',
      () async {
        final repo = _FakeContactRepository([_profile(_algoAddr1, 'alice')]);
        final svc = SearchService(contacts: repo, scopes: const {});

        final out = await svc.searchLocal(_algoAddr1);

        expect(out, hasLength(1));
        expect(out.first, isA<UsernameHit>());
      },
    );

    test('own wallet address → 0 hits in searchLocal', () async {
      final repo = _FakeContactRepository(const []);
      final svc = SearchService(
        contacts: repo,
        scopes: const {},
        selfWalletGetter: () => _algoAddr1,
      );

      final out = await svc.searchLocal(_algoAddr1);

      expect(out, isEmpty);
    });

    test('invalid string → no synthetic hit in searchLocal', () async {
      final repo = _FakeContactRepository(const []);
      final svc = SearchService(contacts: repo, scopes: const {});

      final out = await svc.searchLocal('notanaddress');

      expect(out.whereType<WalletAddressHit>(), isEmpty);
    });

    test(
      'valid address with no remote hits → empty searchRemote (wallet tile injected by provider)',
      () async {
        final scope = _FakeScope('username', (_, _) async => []);
        final svc = SearchService(
          contacts: _FakeContactRepository(const []),
          scopes: {scope.name: scope},
        );

        final r = await svc.searchRemote(_algoAddr1);

        // SearchService returns empty — provider layer adds WalletAddressHit.
        expect(r.hits, isEmpty);
      },
    );

    test(
      'valid address already in remote hits → UsernameHit returned, no duplicate',
      () async {
        final scope = _FakeScope(
          'username',
          (_, _) async => [_remoteHit('alice', _algoAddr1)],
        );
        final svc = SearchService(
          contacts: _FakeContactRepository(const []),
          scopes: {scope.name: scope},
        );

        final r = await svc.searchRemote(_algoAddr1);

        expect(r.hits, hasLength(1));
        expect(r.hits.first, isA<UsernameHit>());
      },
    );
  });
}
