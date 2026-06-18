// Tests for the roots-registry surface added to IndexerClient:
//   - findRootContaining (cache hit / cache miss → refresh / still-miss)
//   - refreshRoots       (populates cache from GET /roots, OHTTP envelope)
//   - clearRootCache     (logout-clears semantics; persisted blob deleted)
//   - EncryptedRootCache (restart-survives via in-memory persisted blob)
//
// Strategy: inject a Dio with a custom HttpClientAdapter that serves canned
// JSON for `GET /roots`. The real OHTTP interceptor is verified separately
// (test/remote/ohttp/) — here we assert that the IndexerClient surface
// uses the same Dio (and therefore the same interceptor chain) by spying
// on the request URI/method that reaches the adapter when no interceptor
// short-circuits it. The OHTTP envelope is asserted via interceptor wiring.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/network/ohttp/ohttp_interceptor.dart';

// ─────────────────────────────────────────────────────────────────────────
// Test doubles
// ─────────────────────────────────────────────────────────────────────────

class _ScriptedAdapter implements HttpClientAdapter {
  /// One canned response per call. Out-of-range index reuses the last.
  final List<Map<String, dynamic>> responses;
  int statusCode;
  final List<RequestOptions> seen = [];

  _ScriptedAdapter(this.responses, {this.statusCode = 200});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final idx = seen.length - 1 < responses.length
        ? seen.length - 1
        : responses.length - 1;
    final body = responses[idx];
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

/// Pretend persisted-blob storage shared between two `EncryptedRootCache`
/// instances — proves "restart-survives".
class _MemBlobStore {
  Uint8List? blob;
  Future<Uint8List?> read() async => blob;
  Future<void> write(Uint8List? v) async {
    blob = v;
  }
}

IndexerClient _client(
  _ScriptedAdapter adapter, {
  RootCache? cache,
  List<Interceptor> interceptors = const [],
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  for (final i in interceptors) {
    dio.interceptors.add(i);
  }
  return IndexerClient(
    baseUrl: 'https://example.invalid',
    dioClient: dio,
    rootCache: cache,
  );
}

// Canonical canned `GET /roots` response — two roots, second contains
// `_targetLeaf` at index 2.
const String _targetLeaf =
    '00000000000000000000000000000000000000000000000000000000000000aa';
List<Map<String, dynamic>> _twoRoots() => [
  {
    'root': '1111111111111111111111111111111111111111111111111111111111111111',
    'denomination': 100000,
    'postedRound': 100,
    'leaves': [
      '00000000000000000000000000000000000000000000000000000000000000bb',
    ],
  },
  {
    'root': '2222222222222222222222222222222222222222222222222222222222222222',
    'denomination': 100000,
    'postedRound': 200,
    'leaves': [
      '0000000000000000000000000000000000000000000000000000000000000001',
      '0000000000000000000000000000000000000000000000000000000000000002',
      _targetLeaf,
    ],
  },
];

void main() {
  group('IndexerClient — roots registry', () {
    test('refreshRoots populates cache from GET /roots', () async {
      final adapter = _ScriptedAdapter([
        {} /* unused — body is a List, not a Map; override below */,
      ]);
      // Use a List body — emulate the actual indexer wire shape.
      final dio = Dio()..httpClientAdapter = _ListBodyAdapter(_twoRoots());
      final cache = InMemoryRootCache();
      final client = IndexerClient(
        baseUrl: 'https://example.invalid',
        dioClient: dio,
        rootCache: cache,
      );

      final ok = await client.refreshRoots();
      expect(ok, isTrue);
      final snap = await cache.snapshot();
      expect(snap.length, 2);
      expect(snap[1].leaves[2], _targetLeaf);
      // We do not assert adapter calls here because the ListBodyAdapter
      // counts elsewhere — see next test.
      adapter.seen.length; // silence unused warning
    });

    test(
      'findRootContaining returns hit when leaf already in cache (no network)',
      () async {
        final cache = InMemoryRootCache();
        await cache.replaceAll(_twoRoots().map(RootRecord.fromJson).toList());

        final adapter = _ListBodyAdapter(const []);
        final client = IndexerClient(
          baseUrl: 'https://example.invalid',
          dioClient: Dio()..httpClientAdapter = adapter,
          rootCache: cache,
        );

        final hit = await client.findRootContaining(_targetLeaf);
        expect(hit, isNotNull);
        expect(hit!.leafIndex, 2);
        expect(hit.record.postedRound, 200);
        expect(
          adapter.seen,
          isEmpty,
          reason: 'cache hit must not hit the network',
        );
      },
    );

    test('findRootContaining refreshes on miss and finds the leaf', () async {
      final cache = InMemoryRootCache(); // empty
      final adapter = _ListBodyAdapter(_twoRoots());
      final client = IndexerClient(
        baseUrl: 'https://example.invalid',
        dioClient: Dio()..httpClientAdapter = adapter,
        rootCache: cache,
      );

      final hit = await client.findRootContaining(_targetLeaf);
      expect(hit, isNotNull);
      expect(hit!.leafIndex, 2);
      expect(adapter.seen, hasLength(1));
      expect(adapter.seen.single.path, '/roots');
      expect(adapter.seen.single.method, 'GET');
    });

    test(
      'findRootContaining returns null when leaf absent after refresh',
      () async {
        final cache = InMemoryRootCache();
        final adapter = _ListBodyAdapter(_twoRoots());
        final client = IndexerClient(
          baseUrl: 'https://example.invalid',
          dioClient: Dio()..httpClientAdapter = adapter,
          rootCache: cache,
        );

        const stranger =
            '00000000000000000000000000000000000000000000000000000000deadbeef';
        // Pad to 64 — `stranger` above is only 60 hex chars. Use a clean one:
        final hit = await client.findRootContaining(
          '00000000000000000000000000000000000000000000000000000000deadbeef'
              .padLeft(64, '0'),
        );
        expect(hit, isNull);
        expect(stranger, isNotNull); // keep variable used
      },
    );

    test('clearRootCache empties the cache', () async {
      final cache = InMemoryRootCache();
      await cache.replaceAll(_twoRoots().map(RootRecord.fromJson).toList());

      final client = IndexerClient(
        baseUrl: 'https://example.invalid',
        dioClient: Dio()..httpClientAdapter = _ListBodyAdapter(const []),
        rootCache: cache,
      );

      expect((await cache.snapshot()).length, 2);
      await client.clearRootCache();
      expect(await cache.snapshot(), isEmpty);
    });

    test(
      'OHTTP envelope: the configured Dio interceptor sees the /roots request',
      () async {
        // We don't run real OHTTP here (gateway config + relay are remote).
        // Instead we assert that *if* a caller attached
        // IndexerOhttpInterceptor, refreshRoots() funnels through it like
        // every other IndexerClient call.
        final spy = _SpyInterceptor();
        final adapter = _ListBodyAdapter(_twoRoots());
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(spy);
        final client = IndexerClient(
          baseUrl: 'https://example.invalid',
          dioClient: dio,
          rootCache: InMemoryRootCache(),
        );
        await client.refreshRoots();
        expect(spy.observed, hasLength(1));
        expect(spy.observed.single.path, '/roots');
        // Sanity: the real interceptor type exists and is constructible —
        // catches accidental import breakage.
        expect(OhttpInterceptor.indexer, isNotNull);
      },
    );
  });

  group('EncryptedRootCache', () {
    final key = c.SecretKey(List<int>.filled(32, 7));

    test('restart-survives via persisted blob', () async {
      final store = _MemBlobStore();
      final first = EncryptedRootCache(
        read: store.read,
        write: store.write,
        key: key,
      );
      await first.replaceAll(_twoRoots().map(RootRecord.fromJson).toList());
      expect(store.blob, isNotNull);

      // Simulate process restart: fresh instance, same key + blob.
      final second = EncryptedRootCache(
        read: store.read,
        write: store.write,
        key: key,
      );
      final hit = await second.findRootContaining(_targetLeaf);
      expect(hit, isNotNull);
      expect(hit!.leafIndex, 2);
    });

    test('clear deletes the persisted blob (logout-clears)', () async {
      final store = _MemBlobStore();
      final cache = EncryptedRootCache(
        read: store.read,
        write: store.write,
        key: key,
      );
      await cache.replaceAll(_twoRoots().map(RootRecord.fromJson).toList());
      expect(store.blob, isNotNull);

      await cache.clear();
      expect(store.blob, isNull);

      // A fresh instance must see no leaves.
      final fresh = EncryptedRootCache(
        read: store.read,
        write: store.write,
        key: key,
      );
      expect(await fresh.findRootContaining(_targetLeaf), isNull);
    });

    test('wrong key → fail-closed empty (no plaintext leak)', () async {
      final store = _MemBlobStore();
      await EncryptedRootCache(
        read: store.read,
        write: store.write,
        key: key,
      ).replaceAll(_twoRoots().map(RootRecord.fromJson).toList());

      final wrong = EncryptedRootCache(
        read: store.read,
        write: store.write,
        key: c.SecretKey(List<int>.filled(32, 8)),
      );
      expect(await wrong.snapshot(), isEmpty);
      expect(await wrong.findRootContaining(_targetLeaf), isNull);
    });
  });

  group('Fr helpers', () {
    test('frFromHex / frToHex round-trip', () {
      const h =
          '0a0b0c0d0e0f0102030405060708090a0b0c0d0e0f010203040506070809abcd';
      expect(frToHex(frFromHex(h)), h);
    });

    test('frFromDecimal matches frFromHex on a small value', () {
      final a = frFromDecimal('255');
      final b = frFromHex(
        '00000000000000000000000000000000000000000000000000000000000000ff',
      );
      expect(a, b);
    });

    test('frFromHex rejects bad length', () {
      expect(() => frFromHex('ab'), throwsFormatException);
    });
  });
}

/// Adapter that returns a JSON *List* body — matches `GET /roots` wire shape.
class _ListBodyAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> body;
  int statusCode;
  final List<RequestOptions> seen = [];

  _ListBodyAdapter(this.body, {this.statusCode = 200});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _SpyInterceptor extends Interceptor {
  final List<RequestOptions> observed = [];
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    observed.add(options);
    handler.next(options);
  }
}
