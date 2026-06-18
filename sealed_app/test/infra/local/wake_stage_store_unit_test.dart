import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/wake_stage_store.dart';

void main() {
  late Directory tmp;
  String path() => '${tmp.path}/wake_stage.bin';
  Uint8List key(int b) => Uint8List.fromList(List.filled(32, b));
  StagedEnvelope env(String txid, {int round = 1, int fill = 7}) =>
      StagedEnvelope(
        round: round,
        txid: txid,
        senderAddress: 'SENDER_$txid',
        senderEncryptionPubkey: Uint8List.fromList(List.filled(32, fill)),
        recipientTag: Uint8List.fromList(List.filled(32, fill)),
        ciphertext: Uint8List.fromList(List.filled(64, fill)),
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wake_stage_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  WakeStageStore store(Uint8List k) =>
      WakeStageStore(stagingKey: k, filePathOverride: path());

  test('round-trips a staged envelope', () async {
    final s = store(key(1));
    await s.append(env('tx1', round: 42));
    final all = await s.readAll();
    expect(all, hasLength(1));
    expect(all.first.txid, 'tx1');
    expect(all.first.round, 42);
    expect(all.first.senderAddress, 'SENDER_tx1');
    expect(all.first.ciphertext, hasLength(64));
    expect(all.first.recipientTag, hasLength(32));
  });

  test('dedupe by txid — appending same txid is a no-op', () async {
    final s = store(key(1));
    await s.append(env('tx1'));
    await s.append(env('tx1'));
    expect(await s.count(), 1);
  });

  test('FIFO eviction past cap', () async {
    final s = store(key(1));
    for (var i = 0; i < WakeStageStore.cap + 5; i++) {
      await s.append(env('tx$i'));
    }
    final all = await s.readAll();
    expect(all, hasLength(WakeStageStore.cap));
    // Oldest 5 evicted; newest retained.
    expect(all.first.txid, 'tx5');
    expect(all.last.txid, 'tx${WakeStageStore.cap + 4}');
  });

  test('wrong key fails closed (empty), never throws', () async {
    await store(key(1)).append(env('tx1'));
    final wrong = store(key(2));
    expect(await wrong.readAll(), isEmpty);
    expect(await wrong.count(), 0);
  });

  test('drain returns all and clears the store', () async {
    final s = store(key(1));
    await s.append(env('tx1'));
    await s.append(env('tx2'));
    final drained = await s.drain();
    expect(drained.map((e) => e.txid), ['tx1', 'tx2']);
    expect(await s.count(), 0);
    expect(await File(path()).exists(), isFalse);
  });
}
