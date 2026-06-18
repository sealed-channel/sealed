// lib/remote/root_cache.dart
//
// Local cache of the indexer's roots registry (SPEC-snark-redeem-B §6).
//
// The indexer exposes `GET /roots` over OHTTP. The response is a list of
// records each containing:
//
//   - `root`         : 64-char lowercase-hex (32-byte Fr element, BN254)
//   - `denomination` : note denomination in cs base units
//   - `postedRound`  : Algorand round the root was posted on
//   - `leaves`       : ordered list of 64-char lowercase-hex leaves
//
// Callers need to find which root (if any) contains a freshly-derived leaf,
// in order to assemble a Merkle authentication path for the redeem circuit.
// Going to the indexer on every redeem would (a) hammer the OHTTP path and
// (b) leak the timing pattern of redeem attempts. Hence the local cache.
//
// SECURITY PROPERTIES (preserved by both implementations here):
//
//   1. **Encrypted at rest** — the only persistent implementation is
//      [EncryptedRootCache] which AES-GCM encrypts the entire serialized
//      catalog under a caller-supplied key. Roots/leaves are public on-chain
//      data; we still encrypt to avoid leaking *which* roots a user is
//      tracking (i.e. their denomination interest) to anyone with disk
//      access. The in-memory implementation does not persist.
//
//   2. **Logout-clears** — `clear()` zeroes RAM and (for encrypted) deletes
//      the persisted blob. `IndexerClient.clearRootCache()` invokes this.
//
//   3. **No PII logged** — `toString()` is intentionally not overridden to
//      avoid accidental dumps. Helpers below truncate hex prefixes.
//
// ─────────────────────────────────────────────────────────────────────────
// Fr-decimal / hex parsing helpers
// ─────────────────────────────────────────────────────────────────────────
//
// Leaves and roots in the redeem circuit are BN254 Fr elements. Two textual
// encodings appear in practice:
//
//   - **Hex** (what the indexer hands us)        : 64 lowercase hex chars.
//   - **Decimal** (what the SNARK witness uses)  : the same Fr printed in
//                                                  base-10 (no fixed width).
//
// [frFromHex] / [frToHex] / [frFromDecimal] are the only conversion
// utilities; do not roll your own.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;

/// BN254 scalar field modulus (mirrors `lib/zk/poseidon.dart`'s `frModulus`).
/// Duplicated here so this file has no dependency on the zk layer — keeps
/// the remote/ module standalone-testable.
final BigInt frModulus = BigInt.parse(
  '21888242871839275222246405745257275088548364400416034343698204186575808495617',
);

/// Parse a 64-char lowercase-hex string into a BN254 Fr element.
///
/// Throws [FormatException] on bad length or non-hex chars. Reduces mod p.
BigInt frFromHex(String hex) {
  if (hex.length != 64) {
    throw FormatException('Fr hex must be 64 chars, got ${hex.length}');
  }
  if (!_hex64Regex.hasMatch(hex)) {
    throw FormatException('Fr hex must be lowercase 0-9a-f');
  }
  final v = BigInt.parse(hex, radix: 16);
  return v % frModulus;
}

/// Render an Fr element as 64-char lowercase hex (pad-left with '0').
String frToHex(BigInt fr) {
  final reduced = fr % frModulus;
  final raw = reduced.toRadixString(16);
  if (raw.length > 64) {
    throw StateError('frToHex: reduced value exceeds 64 hex chars (bug)');
  }
  return raw.padLeft(64, '0');
}

/// Parse a base-10 Fr string as produced by snarkjs witness JSON.
///
/// Accepts an optional leading sign (rejected) — any non-digit throws.
BigInt frFromDecimal(String dec) {
  if (dec.isEmpty || !_decRegex.hasMatch(dec)) {
    throw FormatException('Fr decimal must be a non-empty digit string');
  }
  return BigInt.parse(dec) % frModulus;
}

final RegExp _hex64Regex = RegExp(r'^[0-9a-f]{64}$');
final RegExp _decRegex = RegExp(r'^[0-9]+$');

// ─────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────

/// A single row from `GET /roots`.
class RootRecord {
  /// 64-char lowercase hex of the 32-byte Merkle root.
  final String root;

  /// Denomination posted alongside the root, in cs base units.
  final int denomination;

  /// Algorand round the `postRoot` event landed on.
  final int postedRound;

  /// Lowercase-hex leaves, in upload-order. Empty when admin has not
  /// uploaded leaves for this root yet.
  final List<String> leaves;

  const RootRecord({
    required this.root,
    required this.denomination,
    required this.postedRound,
    required this.leaves,
  });

  factory RootRecord.fromJson(Map<String, dynamic> j) {
    final root = j['root'] as String;
    if (!_hex64Regex.hasMatch(root)) {
      throw FormatException('RootRecord.root not 64-hex: $root');
    }
    final rawLeaves = (j['leaves'] as List<dynamic>? ?? const [])
        .cast<String>();
    for (final l in rawLeaves) {
      if (!_hex64Regex.hasMatch(l)) {
        throw FormatException('RootRecord.leaves contains non-hex entry');
      }
    }
    return RootRecord(
      root: root,
      denomination: (j['denomination'] as num).toInt(),
      postedRound: (j['postedRound'] as num).toInt(),
      leaves: List<String>.unmodifiable(rawLeaves),
    );
  }

  Map<String, dynamic> toJson() => {
    'root': root,
    'denomination': denomination,
    'postedRound': postedRound,
    'leaves': leaves,
  };

  /// Index of [leafHex] in [leaves], or -1 if absent.
  int indexOfLeaf(String leafHex) {
    // Linear scan — leaf lists are bounded by tree size (2^16). For larger
    // trees swap in a Set built at load-time.
    for (var i = 0; i < leaves.length; i++) {
      if (leaves[i] == leafHex) return i;
    }
    return -1;
  }
}

/// Result of [RootCache.findRootContaining] / `IndexerClient.findRootContaining`.
class RootHit {
  final RootRecord record;
  final int leafIndex;
  const RootHit({required this.record, required this.leafIndex});
}

/// Linear scan of [records] for [leafHex]. Returns `null` on miss or on
/// invalid (non-64-hex) input. Shared by both [RootCache] implementations.
RootHit? _scan(Iterable<RootRecord> records, String leafHex) {
  if (!_hex64Regex.hasMatch(leafHex)) return null;
  for (final r in records) {
    final i = r.indexOfLeaf(leafHex);
    if (i >= 0) return RootHit(record: r, leafIndex: i);
  }
  return null;
}

/// Like [_scan] but returns EVERY matching root, not just the first. The
/// `/roots` table is cumulative across every app the indexer has watched, and
/// historical batches can reuse a preimage → the same leaf hash appears under
/// roots posted to different apps. The redeem flow disambiguates by checking
/// which candidate's `r:<root>` box exists on the *configured* app.
List<RootHit> _scanAll(Iterable<RootRecord> records, String leafHex) {
  if (!_hex64Regex.hasMatch(leafHex)) return const [];
  final hits = <RootHit>[];
  for (final r in records) {
    final i = r.indexOfLeaf(leafHex);
    if (i >= 0) hits.add(RootHit(record: r, leafIndex: i));
  }
  return hits;
}

// ─────────────────────────────────────────────────────────────────────────
// Cache abstraction
// ─────────────────────────────────────────────────────────────────────────

/// Local catalog of roots and leaves the redeem flow can authenticate against.
///
/// Implementations:
///   - [InMemoryRootCache]   : volatile, for tests and ephemeral installs.
///   - [EncryptedRootCache]  : AES-GCM at rest, for production.
abstract class RootCache {
  /// Replace the cached catalog wholesale with [records].
  Future<void> replaceAll(List<RootRecord> records);

  /// Snapshot the current catalog (deep-immutable).
  Future<List<RootRecord>> snapshot();

  /// Look up the first record whose `leaves` contains [leafHex].
  /// Returns `null` on miss.
  Future<RootHit?> findRootContaining(String leafHex);

  /// Look up EVERY record whose `leaves` contains [leafHex]. Empty on miss.
  /// Callers disambiguate cross-app collisions by on-chain box existence.
  Future<List<RootHit>> findAllRootsContaining(String leafHex);

  /// Drop everything (RAM + any persisted blob). Idempotent.
  Future<void> clear();
}

// ─────────────────────────────────────────────────────────────────────────
// InMemoryRootCache
// ─────────────────────────────────────────────────────────────────────────

class InMemoryRootCache implements RootCache {
  List<RootRecord> _records = const [];

  @override
  Future<void> replaceAll(List<RootRecord> records) async {
    _records = List<RootRecord>.unmodifiable(records);
  }

  @override
  Future<List<RootRecord>> snapshot() async => _records;

  @override
  Future<RootHit?> findRootContaining(String leafHex) async =>
      _scan(_records, leafHex);

  @override
  Future<List<RootHit>> findAllRootsContaining(String leafHex) async =>
      _scanAll(_records, leafHex);

  @override
  Future<void> clear() async {
    _records = const [];
  }
}

// ─────────────────────────────────────────────────────────────────────────
// EncryptedRootCache
// ─────────────────────────────────────────────────────────────────────────

/// Read/write callbacks decoupling this cache from any concrete storage
/// backend (file, secure-storage, sqflite blob, ...). The cache module owns
/// no I/O — callers wire it up in `app_providers.dart`.
typedef RootCacheReader = Future<Uint8List?> Function();
typedef RootCacheWriter = Future<void> Function(Uint8List? bytes);

/// AES-GCM-at-rest cache.
///
/// Wire-format of the persisted blob:
///
///   bytes[0..12)        : 12-byte random nonce
///   bytes[12..len-16)   : AES-GCM ciphertext (utf8 JSON of List<RootRecord>)
///   bytes[len-16..len)  : 16-byte GCM tag
///
/// A `null` write deletes the blob. Decryption errors → cache treated as
/// empty (we never silently surface stale plaintext after a key rotation).
class EncryptedRootCache implements RootCache {
  final RootCacheReader _read;
  final RootCacheWriter _write;
  final c.SecretKey _key;
  final c.AesGcm _aead = c.AesGcm.with256bits();
  final Random _rng;

  List<RootRecord>? _ram;

  EncryptedRootCache({
    required RootCacheReader read,
    required RootCacheWriter write,
    required c.SecretKey key,
    Random? rng,
  }) : _read = read,
       _write = write,
       _key = key,
       _rng = rng ?? Random.secure();

  Future<List<RootRecord>> _ensureLoaded() async {
    final cached = _ram;
    if (cached != null) return cached;
    final bytes = await _read();
    if (bytes == null || bytes.length < 12 + 16) {
      _ram = const [];
      return _ram!;
    }
    try {
      final nonce = bytes.sublist(0, 12);
      final mac = c.Mac(bytes.sublist(bytes.length - 16));
      final ct = bytes.sublist(12, bytes.length - 16);
      final clear = await _aead.decrypt(
        c.SecretBox(ct, nonce: nonce, mac: mac),
        secretKey: _key,
      );
      final parsed = (jsonDecode(utf8.decode(clear)) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(RootRecord.fromJson)
          .toList(growable: false);
      _ram = List<RootRecord>.unmodifiable(parsed);
      return _ram!;
    } catch (_) {
      // Decrypt or parse failure → fail-closed empty. Never throw, since the
      // redeem flow can always re-fetch from the indexer.
      _ram = const [];
      return _ram!;
    }
  }

  @override
  Future<void> replaceAll(List<RootRecord> records) async {
    _ram = List<RootRecord>.unmodifiable(records);
    final json = jsonEncode(records.map((r) => r.toJson()).toList());
    final plain = Uint8List.fromList(utf8.encode(json));
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => _rng.nextInt(256)),
    );
    final box = await _aead.encrypt(plain, secretKey: _key, nonce: nonce);
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    await _write(Uint8List.fromList(out.toBytes()));
  }

  @override
  Future<List<RootRecord>> snapshot() => _ensureLoaded();

  @override
  Future<RootHit?> findRootContaining(String leafHex) async =>
      _scan(await _ensureLoaded(), leafHex);

  @override
  Future<List<RootHit>> findAllRootsContaining(String leafHex) async =>
      _scanAll(await _ensureLoaded(), leafHex);

  @override
  Future<void> clear() async {
    _ram = const [];
    await _write(null);
  }
}
