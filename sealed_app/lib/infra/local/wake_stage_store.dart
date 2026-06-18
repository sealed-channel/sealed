// Append-only, device-secret-encrypted store of push-prefetched message
// envelopes (push pre-sync foundation, internal/docs/plan-push-prefetch-sync.md).
//
// The FCM background isolate can fetch + tag-check public on-chain envelopes
// with the PIN-free keys, but it MUST NOT open the PIN-gated DEK DB. So it
// stages matched envelopes here — a small AES-GCM blob keyed by the device
// secret (PIN-free, first_unlock) — and the main isolate drains + decrypts them
// into the real DB on unlock, with zero network. Never holds plaintext message
// content; envelope bytes are public chain data, encrypted at rest only to hide
// receipt-timing metadata.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:path_provider/path_provider.dart';

/// One staged on-chain message — exactly the fields the background isolate
/// needs to (a) MATCH recipiency (tag-check, PIN-free) and (b) let the main
/// isolate RE-DECRYPT it on drain (it carries the full raw envelope). [txid]
/// dedupes against DB rows on drain. All bytes are public chain data.
class StagedEnvelope {
  const StagedEnvelope({
    required this.round,
    required this.txid,
    required this.senderAddress,
    required this.senderEncryptionPubkey,
    required this.recipientTag,
    required this.ciphertext,
  });

  final int round;
  final String txid;
  final String senderAddress;
  final Uint8List senderEncryptionPubkey;
  final Uint8List recipientTag;
  final Uint8List ciphertext;

  Map<String, dynamic> toJson() => {
    'round': round,
    'txid': txid,
    'sa': senderAddress,
    'sep': base64.encode(senderEncryptionPubkey),
    'rt': base64.encode(recipientTag),
    'ct': base64.encode(ciphertext),
  };

  static StagedEnvelope fromJson(Map<String, dynamic> j) => StagedEnvelope(
    round: j['round'] as int,
    txid: j['txid'] as String,
    senderAddress: j['sa'] as String,
    senderEncryptionPubkey: base64.decode(j['sep'] as String),
    recipientTag: base64.decode(j['rt'] as String),
    ciphertext: base64.decode(j['ct'] as String),
  );

  /// Reconstruct the raw on-chain message map the sync/decrypt path expects.
  Map<String, dynamic> toRawMessage() => {
    'accountPubkey': txid,
    'senderAddress': senderAddress,
    'senderEncryptionPubkey': senderEncryptionPubkey,
    'recipientTag': recipientTag,
    'ciphertext': ciphertext,
    'timestamp': round,
  };
}

/// Append-only staged-envelope store. FIFO-capped, dedupe-by-txid, drained on
/// unlock. Lives in the app-support dir, never inside the DEK DB. Wrong-key /
/// corrupt reads fail closed (empty), never throw — staging is loss-tolerant.
class WakeStageStore {
  WakeStageStore({required Uint8List stagingKey, String? filePathOverride})
    : _key = stagingKey,
      _override = filePathOverride;

  static const int cap = 64;
  static const String _fileName = 'wake_stage.bin';

  final Uint8List _key;
  final String? _override;
  final c.AesGcm _aead = c.AesGcm.with256bits();

  Future<File> _file() async {
    if (_override != null) return File(_override);
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Decrypt + parse the store; returns [] on missing/corrupt/wrong-key (fail-closed).
  Future<List<StagedEnvelope>> readAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final wrapped = await f.readAsBytes();
      if (wrapped.length < 12 + 16) return [];
      final nonce = wrapped.sublist(0, 12);
      final mac = c.Mac(wrapped.sublist(wrapped.length - 16));
      final ct = wrapped.sublist(12, wrapped.length - 16);
      final clear = await _aead.decrypt(
        c.SecretBox(ct, nonce: nonce, mac: mac),
        secretKey: c.SecretKey(_key),
      );
      final list = json.decode(utf8.decode(clear)) as List<dynamic>;
      return [
        for (final e in list)
          StagedEnvelope.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeAll(List<StagedEnvelope> entries) async {
    final clear = utf8.encode(
      json.encode([for (final e in entries) e.toJson()]),
    );
    final box = await _aead.encrypt(clear, secretKey: c.SecretKey(_key));
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    final f = await _file();
    await f.writeAsBytes(out.toBytes(), flush: true);
  }

  /// Stage an envelope. No-op if its txid is already staged. FIFO-evicts the
  /// oldest when over [cap].
  Future<void> append(StagedEnvelope envelope) async {
    final entries = await readAll();
    if (entries.any((e) => e.txid == envelope.txid)) return;
    entries.add(envelope);
    while (entries.length > cap) {
      entries.removeAt(0);
    }
    await _writeAll(entries);
  }

  /// Return all staged envelopes and clear the store atomically-enough for a
  /// loss-tolerant cache (read-then-delete; a crash between leaves the file, and
  /// the next drain re-reads — dedupe-by-txid against the DB makes this safe).
  Future<List<StagedEnvelope>> drain() async {
    final entries = await readAll();
    await clear();
    return entries;
  }

  Future<int> count() async => (await readAll()).length;

  Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
