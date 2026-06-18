import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/background_wake_sync.dart';
import 'package:sealed_app/infra/local/wake_stage_store.dart';

StagedEnvelope env(String txid, {int round = 1}) => StagedEnvelope(
  round: round,
  txid: txid,
  senderAddress: 'S_$txid',
  senderEncryptionPubkey: Uint8List.fromList(List.filled(32, 9)),
  recipientTag: Uint8List.fromList(List.filled(32, 9)),
  ciphertext: Uint8List.fromList(List.filled(32, 9)),
);

class _FakeSource implements WakeEnvelopeSource {
  _FakeSource(this.items, {this.throwOnFetch = false});
  final List<StagedEnvelope> items;
  final bool throwOnFetch;
  @override
  Future<List<StagedEnvelope>> fetchSinceCursor() async {
    if (throwOnFetch) throw Exception('fetch boom');
    return items;
  }
}

class _FakeMatcher implements WakeMatcher {
  _FakeMatcher(this.matchTxids, {this.throwOn});
  final Set<String> matchTxids;
  final String? throwOn;
  @override
  Future<bool> matches(StagedEnvelope c) async {
    if (c.txid == throwOn) throw Exception('match boom');
    return matchTxids.contains(c.txid);
  }
}

void main() {
  late Directory tmp;
  late WakeStageStore store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bws_test');
    store = WakeStageStore(
      stagingKey: Uint8List.fromList(List.filled(32, 1)),
      filePathOverride: '${tmp.path}/s.bin',
    );
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('stages only matched envelopes', () async {
    final sync = BackgroundWakeSync(
      source: _FakeSource([env('a'), env('b'), env('c')]),
      matcher: _FakeMatcher({'a', 'c'}),
      store: store,
    );
    expect(await sync.run(), 2);
    final staged = (await store.readAll()).map((e) => e.txid).toList();
    expect(staged, ['a', 'c']);
  });

  test('no matches → nothing staged', () async {
    final sync = BackgroundWakeSync(
      source: _FakeSource([env('a'), env('b')]),
      matcher: _FakeMatcher({}),
      store: store,
    );
    expect(await sync.run(), 0);
    expect(await store.count(), 0);
  });

  test('fetch failure → 0 staged (loss-tolerant)', () async {
    final sync = BackgroundWakeSync(
      source: _FakeSource([], throwOnFetch: true),
      matcher: _FakeMatcher({'a'}),
      store: store,
    );
    expect(await sync.run(), 0);
  });

  test('one bad envelope does not stall the pass', () async {
    final sync = BackgroundWakeSync(
      source: _FakeSource([env('a'), env('bad'), env('c')]),
      matcher: _FakeMatcher({'a', 'c'}, throwOn: 'bad'),
      store: store,
    );
    expect(await sync.run(), 2);
    expect((await store.readAll()).map((e) => e.txid), ['a', 'c']);
  });

  test('honors the wall-clock cap (partial result)', () async {
    // Clock jumps past the deadline after the 2nd now() read in the loop, so
    // only the first candidate is processed.
    var t = DateTime(2026);
    final ticks = <DateTime>[
      t, // deadline base in ctor-time run() start
      t, // loop check #1 (before deadline)
      t.add(const Duration(seconds: 99)), // loop check #2 (past deadline)
    ];
    var i = 0;
    DateTime clock() =>
        i < ticks.length ? ticks[i++] : t.add(const Duration(seconds: 99));

    final sync = BackgroundWakeSync(
      source: _FakeSource([env('a'), env('b'), env('c')]),
      matcher: _FakeMatcher({'a', 'b', 'c'}),
      store: store,
      cap: const Duration(seconds: 20),
      clock: clock,
    );
    final staged = await sync.run();
    expect(staged, 1); // only 'a' before the cap tripped
    expect((await store.readAll()).map((e) => e.txid), ['a']);
  });
}
