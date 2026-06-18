// Tests for WakeNonceQueue.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sealed_app/features/messaging/wake_nonce_queue.dart';

void main() {
  late SharedPreferences prefs;
  late WakeNonceQueue q;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    q = WakeNonceQueue(prefs);
  });

  final t0 = DateTime(2025, 1, 1, 12, 0, 0);

  group('Normal queue (enqueue / drain)', () {
    test('enqueue then drain returns entry', () async {
      await q.enqueue('abc', t0);
      final drained = await q.drain(t0);
      expect(drained, hasLength(1));
      expect(drained.first.nonce, 'abc');
    });

    test('drain clears the queue', () async {
      await q.enqueue('x', t0);
      await q.drain(t0);
      final second = await q.drain(t0);
      expect(second, isEmpty);
    });

    test('drain with null nonce is preserved', () async {
      await q.enqueue(null, t0);
      final drained = await q.drain(t0);
      expect(drained.first.nonce, isNull);
    });

    test('drain drops entries older than TTL', () async {
      final stale = t0.subtract(
        WakeNonceQueue.kNormalTtl + const Duration(seconds: 1),
      );
      final fresh = t0.subtract(const Duration(seconds: 30));
      await q.enqueue('stale', stale);
      await q.enqueue('fresh', fresh);
      final drained = await q.drain(t0);
      expect(drained, hasLength(1));
      expect(drained.first.nonce, 'fresh');
    });

    test('evicts oldest when cap exceeded', () async {
      for (var i = 0; i < WakeNonceQueue.kNormalCap + 3; i++) {
        await q.enqueue('n$i', t0);
      }
      final drained = await q.drain(t0);
      expect(drained, hasLength(WakeNonceQueue.kNormalCap));
      // oldest (n0, n1, n2) evicted; last kNormalCap remain
      expect(drained.first.nonce, 'n3');
      expect(drained.last.nonce, 'n${WakeNonceQueue.kNormalCap + 2}');
    });

    test('empty drain returns empty list', () async {
      final drained = await q.drain(t0);
      expect(drained, isEmpty);
    });
  });

  group('Pending-unlock queue', () {
    test('enqueuePendingUnlock / drainPendingUnlock round-trip', () async {
      await q.enqueuePendingUnlock('pu1', t0);
      await q.enqueuePendingUnlock('pu2', t0);
      final drained = await q.drainPendingUnlock();
      expect(drained, hasLength(2));
      expect(drained.map((e) => e.nonce), containsAll(['pu1', 'pu2']));
    });

    test('drainPendingUnlock clears queue', () async {
      await q.enqueuePendingUnlock('x', t0);
      await q.drainPendingUnlock();
      final second = await q.drainPendingUnlock();
      expect(second, isEmpty);
    });

    test('no TTL — entries survive past 5 minutes', () async {
      final ancient = t0.subtract(const Duration(hours: 12));
      await q.enqueuePendingUnlock('old', ancient);
      // drain does not apply TTL
      final drained = await q.drainPendingUnlock();
      expect(drained, hasLength(1));
      expect(drained.first.nonce, 'old');
    });

    test('evicts oldest when cap exceeded', () async {
      for (var i = 0; i < WakeNonceQueue.kPendingUnlockCap + 2; i++) {
        await q.enqueuePendingUnlock('p$i', t0);
      }
      final drained = await q.drainPendingUnlock();
      expect(drained, hasLength(WakeNonceQueue.kPendingUnlockCap));
      expect(drained.first.nonce, 'p2');
    });
  });

  group('moveNormalToPending', () {
    test('moves all normal entries into pending queue', () async {
      await q.enqueue('a', t0);
      await q.enqueue('b', t0);
      await q.moveNormalToPending();

      final normal = await q.drain(t0);
      final pending = await q.drainPendingUnlock();

      expect(normal, isEmpty);
      expect(pending, hasLength(2));
      expect(pending.map((e) => e.nonce), containsAll(['a', 'b']));
    });

    test('no-op when normal queue empty', () async {
      await q.moveNormalToPending(); // should not throw
      final pending = await q.drainPendingUnlock();
      expect(pending, isEmpty);
    });

    test('move respects pending cap', () async {
      // Fill pending to near cap first
      for (var i = 0; i < WakeNonceQueue.kPendingUnlockCap - 1; i++) {
        await q.enqueuePendingUnlock('existing$i', t0);
      }
      // Add 3 to normal — only 1 slot left before cap hit
      await q.enqueue('n0', t0);
      await q.enqueue('n1', t0);
      await q.enqueue('n2', t0);
      await q.moveNormalToPending();

      final pending = await q.drainPendingUnlock();
      expect(pending.length, WakeNonceQueue.kPendingUnlockCap);
    });
  });

  group('Persistence across instances', () {
    test('entries survive queue reconstruction (same prefs)', () async {
      await q.enqueue('persist', t0);
      // Reconstruct from same prefs (simulates foreground isolate reading what
      // background isolate wrote).
      final q2 = WakeNonceQueue(prefs);
      final drained = await q2.drain(t0);
      expect(drained.first.nonce, 'persist');
    });
  });
}
