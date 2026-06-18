// Device-secret-encrypted mirror of the wallet block list, readable from the
// FCM background isolate WITHOUT the PIN (#17, spec-17-background-block-
// suppression.md). The DEK-backed `contacts.is_blocked` stays the source of
// truth; this is a write-through cache so the background can suppress a blocked
// sender's notification before the DEK DB is ever unlocked.
//
// At rest it holds only SALTED HMAC TAGS — `HMAC(mirrorKey, wallet)` — never
// plaintext wallet addresses, so a disk-image attacker can't read who's blocked
// (block COUNT is not hidden; see spec Decision 2). [mirrorKey] is HKDF'd from
// the PIN-free device secret (`DekManager.deriveBlockMirrorKey`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:path_provider/path_provider.dart';

class BlockMirror {
  BlockMirror({required Uint8List mirrorKey, String? filePathOverride})
    : _key = mirrorKey,
      _override = filePathOverride;

  static const String _fileName = 'block_mirror.bin';

  final Uint8List _key;
  final String? _override;
  final c.AesGcm _aead = c.AesGcm.with256bits();
  final c.Hmac _hmac = c.Hmac.sha256();

  Future<File> _file() async {
    if (_override != null) return File(_override);
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Salted, deterministic tag for [wallet]. Background and foreground compute
  /// the same tag from the same device-secret-derived key.
  Future<String> _tag(String wallet) async {
    final mac = await _hmac.calculateMac(
      utf8.encode(wallet),
      secretKey: c.SecretKey(_key),
    );
    return base64Url.encode(mac.bytes);
  }

  /// Decrypt + parse the tag set; [] on missing/corrupt/wrong-key (fail-closed —
  /// the background then just doesn't suppress, which is the safe default).
  Future<Set<String>> _readTags() async {
    try {
      final f = await _file();
      if (!await f.exists()) return <String>{};
      final wrapped = await f.readAsBytes();
      if (wrapped.length < 12 + 16) return <String>{};
      final nonce = wrapped.sublist(0, 12);
      final mac = c.Mac(wrapped.sublist(wrapped.length - 16));
      final ct = wrapped.sublist(12, wrapped.length - 16);
      final clear = await _aead.decrypt(
        c.SecretBox(ct, nonce: nonce, mac: mac),
        secretKey: c.SecretKey(_key),
      );
      final list = json.decode(utf8.decode(clear)) as List<dynamic>;
      return {for (final t in list) t as String};
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _writeTags(Set<String> tags) async {
    final clear = utf8.encode(json.encode(tags.toList()));
    final box = await _aead.encrypt(clear, secretKey: c.SecretKey(_key));
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    await (await _file()).writeAsBytes(out.toBytes(), flush: true);
  }

  Future<bool> contains(String wallet) async =>
      (await _readTags()).contains(await _tag(wallet));

  Future<void> add(String wallet) async {
    final tags = await _readTags();
    if (tags.add(await _tag(wallet))) await _writeTags(tags);
  }

  Future<void> remove(String wallet) async {
    final tags = await _readTags();
    if (tags.remove(await _tag(wallet))) await _writeTags(tags);
  }

  /// Rebuild the mirror from the DB's current block list (idempotent). Called on
  /// full sync / resume so an out-of-band block (e.g. synced from another
  /// device) converges.
  Future<void> reconcile(Iterable<String> blockedWallets) async {
    final tags = <String>{for (final w in blockedWallets) await _tag(w)};
    await _writeTags(tags);
  }

  Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
