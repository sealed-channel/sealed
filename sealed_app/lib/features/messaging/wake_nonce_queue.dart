// lib/services/wake_nonce_queue.dart
//
// Persists FCM/APNs wake nonces across isolate and app-restart boundaries so
// that messages received while the app is backgrounded or locked are not lost.
//
// Two queues:
//
//   [kKeyNormal]         — for wakes received when the DEK is unlocked.
//                          Cap 16 entries; entries older than [kNormalTtl] are
//                          dropped on drain. Drained on AppLifecycleState.resumed
//                          when PinPhase.unlocked.
//
//   [kKeyPendingUnlock]  — for wakes received while the DEK is locked (PIN not
//                          yet entered). No TTL; entries survive until the user
//                          unlocks. Cap 64 entries (oldest evicted on overflow).
//                          Drained on PinPhase locked→unlocked transition.
//
// Both queues are written by the background isolate (onBackgroundMessage) and
// read/drained by the main isolate. shared_preferences writes are atomic on
// Android (commit via apply()); a rare concurrent-write race may lose one entry
// — the next push will resupply the signal, so lossy behavior is acceptable.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A single entry stored in the wake-nonce queue.
class WakeNonceEntry {
  final String? nonce;
  final DateTime receivedAt;

  const WakeNonceEntry({required this.nonce, required this.receivedAt});

  Map<String, dynamic> toJson() => {
    'nonce': nonce,
    'receivedAt': receivedAt.millisecondsSinceEpoch,
  };

  factory WakeNonceEntry.fromJson(Map<String, dynamic> json) {
    return WakeNonceEntry(
      nonce: json['nonce'] as String?,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        json['receivedAt'] as int,
      ),
    );
  }
}

class WakeNonceQueue {
  static const String kKeyNormal = 'sealed/wake_nonces';
  static const String kKeyPendingUnlock = 'sealed/wake_nonces_pending_unlock';

  static const int kNormalCap = 16;
  static const int kPendingUnlockCap = 64;
  static const Duration kNormalTtl = Duration(minutes: 5);

  final SharedPreferences _prefs;

  WakeNonceQueue(this._prefs);

  // ---------------------------------------------------------------------------
  // Normal queue (DEK unlocked)
  // ---------------------------------------------------------------------------

  /// Append a nonce to the normal queue. Evicts oldest if cap exceeded.
  Future<void> enqueue(String? nonce, DateTime receivedAt) async {
    final entries = _readList(kKeyNormal);
    entries.add(WakeNonceEntry(nonce: nonce, receivedAt: receivedAt));
    if (entries.length > kNormalCap) {
      entries.removeRange(0, entries.length - kNormalCap);
    }
    await _writeList(kKeyNormal, entries);
  }

  /// Return all non-expired entries and clear the normal queue.
  Future<List<WakeNonceEntry>> drain(DateTime now) async {
    final entries = _readList(kKeyNormal);
    await _prefs.remove(kKeyNormal);
    final cutoff = now.subtract(kNormalTtl);
    return entries.where((e) => e.receivedAt.isAfter(cutoff)).toList();
  }

  // ---------------------------------------------------------------------------
  // Pending-unlock queue (DEK locked)
  // ---------------------------------------------------------------------------

  /// Append a nonce to the pending-unlock queue. Evicts oldest if cap exceeded.
  Future<void> enqueuePendingUnlock(String? nonce, DateTime receivedAt) async {
    final entries = _readList(kKeyPendingUnlock);
    entries.add(WakeNonceEntry(nonce: nonce, receivedAt: receivedAt));
    if (entries.length > kPendingUnlockCap) {
      entries.removeRange(0, entries.length - kPendingUnlockCap);
    }
    await _writeList(kKeyPendingUnlock, entries);
  }

  /// Return all entries from the pending-unlock queue and clear it.
  /// No TTL — entries survive until unlock.
  Future<List<WakeNonceEntry>> drainPendingUnlock() async {
    final entries = _readList(kKeyPendingUnlock);
    await _prefs.remove(kKeyPendingUnlock);
    return entries;
  }

  /// Move all current normal-queue entries into the pending-unlock queue.
  /// Called when a wake arrives (or resume fires) while the DEK is locked.
  Future<void> moveNormalToPending() async {
    final normal = _readList(kKeyNormal);
    if (normal.isEmpty) return;
    await _prefs.remove(kKeyNormal);
    for (final e in normal) {
      await enqueuePendingUnlock(e.nonce, e.receivedAt);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<WakeNonceEntry> _readList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => WakeNonceEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeList(String key, List<WakeNonceEntry> entries) async {
    await _prefs.setString(
      key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
