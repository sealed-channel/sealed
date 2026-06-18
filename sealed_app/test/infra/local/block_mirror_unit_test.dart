import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/block_mirror.dart';

void main() {
  late Directory tmp;
  String path() => '${tmp.path}/bm.bin';
  Uint8List key(int b) => Uint8List.fromList(List.filled(32, b));
  BlockMirror mirror(Uint8List k) =>
      BlockMirror(mirrorKey: k, filePathOverride: path());

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('block_mirror_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('add → contains; remove → not contains', () async {
    final m = mirror(key(1));
    expect(await m.contains('WALLET_A'), isFalse);
    await m.add('WALLET_A');
    expect(await m.contains('WALLET_A'), isTrue);
    expect(await m.contains('WALLET_B'), isFalse);
    await m.remove('WALLET_A');
    expect(await m.contains('WALLET_A'), isFalse);
  });

  test('reconcile rebuilds to exactly the given set (idempotent)', () async {
    final m = mirror(key(1));
    await m.add('OLD');
    await m.reconcile(['X', 'Y']);
    expect(await m.contains('X'), isTrue);
    expect(await m.contains('Y'), isTrue);
    expect(await m.contains('OLD'), isFalse);
    // Idempotent: same set again → unchanged.
    await m.reconcile(['X', 'Y']);
    expect(await m.contains('X'), isTrue);
  });

  test('wrong key → empty (fail-closed, never throws)', () async {
    await mirror(key(1)).add('WALLET_A');
    final wrong = mirror(key(2));
    expect(await wrong.contains('WALLET_A'), isFalse);
  });

  test('at rest holds no plaintext wallet address', () async {
    final m = mirror(key(1));
    await m.add('SECRET_WALLET_XYZ');
    final bytes = await File(path()).readAsBytes();
    final asText = String.fromCharCodes(bytes);
    expect(asText.contains('SECRET_WALLET_XYZ'), isFalse);
  });
}
