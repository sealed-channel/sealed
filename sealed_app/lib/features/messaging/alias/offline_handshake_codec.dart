/// Framed QR codec for offline alias handshake envelopes.
///
/// Wraps an opaque payload (typically the 925B combined invite or 841B
/// accept envelope) into QR frames. With the default chunk size both
/// handshake payloads fit a single static frame (~1240-char base64,
/// QR ~v25 ECC-L); larger payloads fall back to N animated frames that
/// the accumulator reassembles in any order.
///
/// Wire format per frame, base64-encoded as the QR string content:
///
///     [magic:1 = 0xA1][seq:1][total:1][payloadId:2] || chunk
///
///   magic     0xA1 — offline alias handshake. Anything else → silently
///             dropped by the accumulator.
///   seq       Frame index, 0-based.
///   total     Number of frames for this payload.
///   payloadId First 2 bytes of sha256(fullPayloadBytes). De-dups frames
///             across concurrent pairings — if the accumulator sees a
///             different payloadId mid-stream it resets to the new one.
///   chunk     Slice of the original payload bytes, length <= chunkSize.
///
/// Threat model note: the codec is transport-layer only. It performs no
/// authentication, no decryption, no MAC. The envelope it carries handles
/// PQ + X25519 confidentiality and authenticity. Garbage frames (wrong
/// magic, bad base64, total mismatch) are silently discarded — never throws.
///
/// No chain side-effects.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int _magic = 0xA1;
const int _headerLen = 5; // magic + seq + total + payloadId(2)
const int _payloadIdLen = 2;

/// Encoder + decoder pair for animated multi-frame handshake QRs.
class OfflineHandshakeCodec {
  OfflineHandshakeCodec._();

  /// Magic byte identifying an offline alias handshake frame.
  static const int magic = _magic;

  /// Split [bytes] into base64-encoded QR-payload strings of <= ~chunkSize
  /// bytes of original payload per frame.
  ///
  /// Returns one string per frame, in ascending `seq` order. Caller animates.
  ///
  /// [chunkSize] is the count of *original* payload bytes per frame, not the
  /// final base64 string length. Default 1000 fits both handshake envelopes
  /// (925B combined invite, 841B accept) in one static frame.
  static Future<List<String>> encode(
    Uint8List bytes, {
    int chunkSize = 1000,
  }) async {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be empty');
    }

    final payloadId = await _computePayloadId(bytes);
    final total = ((bytes.length + chunkSize - 1) ~/ chunkSize).clamp(1, 255);
    if (total > 255) {
      throw ArgumentError('payload too large: ${bytes.length} bytes');
    }

    final out = <String>[];
    for (int seq = 0; seq < total; seq++) {
      final start = seq * chunkSize;
      final end = (start + chunkSize) > bytes.length
          ? bytes.length
          : start + chunkSize;
      final chunk = bytes.sublist(start, end);

      final frame = Uint8List(_headerLen + chunk.length);
      frame[0] = _magic;
      frame[1] = seq;
      frame[2] = total;
      frame[3] = payloadId[0];
      frame[4] = payloadId[1];
      frame.setRange(_headerLen, _headerLen + chunk.length, chunk);

      out.add(base64.encode(frame));
    }
    return out;
  }

  /// Stateful accumulator for incoming QR strings.
  static OfflineHandshakeAccumulator decoder() => OfflineHandshakeAccumulator();

  /// First 2 bytes of sha256(bytes). Exposed for tests.
  static Future<Uint8List> _computePayloadId(Uint8List bytes) async {
    final hash = await Sha256().hash(bytes);
    return Uint8List.fromList(hash.bytes.sublist(0, _payloadIdLen));
  }
}

/// Reassembles a multi-frame payload from QR strings fed in any order.
///
/// `feed` returns `null` until every `seq` in `[0, total)` has been seen
/// for the current `payloadId`, at which point it returns the assembled
/// `Uint8List`. Subsequent calls after completion return `null` until a
/// new `payloadId` is observed (which triggers an internal reset).
///
/// Silent on all parse errors — never throws.
class OfflineHandshakeAccumulator {
  Uint8List? _payloadId;
  int? _total;
  final Map<int, Uint8List> _chunks = <int, Uint8List>{};

  /// Feed one decoded QR string. Returns the assembled payload when
  /// complete, otherwise `null`. Garbage frames are silently dropped.
  Uint8List? feed(String qrPayload) {
    final frame = _decodeBase64(qrPayload);
    if (frame == null) return null;
    if (frame.length < _headerLen) return null;
    if (frame[0] != _magic) return null;

    final seq = frame[1];
    final total = frame[2];
    if (total == 0) return null;
    if (seq >= total) return null;

    final payloadId = Uint8List.fromList(frame.sublist(3, 3 + _payloadIdLen));
    final chunk = Uint8List.fromList(frame.sublist(_headerLen));

    // New payload observed — reset.
    if (_payloadId == null || !_bytesEqual(_payloadId!, payloadId)) {
      _payloadId = payloadId;
      _total = total;
      _chunks.clear();
    } else if (_total != total) {
      // Same payloadId but different total → malformed, ignore.
      return null;
    }

    // Duplicate seq — keep first (silent discard of duplicates).
    _chunks.putIfAbsent(seq, () => chunk);

    if (_chunks.length != _total) return null;

    // Assemble in order.
    final builder = BytesBuilder(copy: false);
    for (int i = 0; i < _total!; i++) {
      final c = _chunks[i];
      if (c == null) return null; // defensive — should not happen
      builder.add(c);
    }
    return builder.toBytes();
  }

  /// Drop accumulated state.
  void reset() {
    _payloadId = null;
    _total = null;
    _chunks.clear();
  }

  static Uint8List? _decodeBase64(String s) {
    try {
      return base64.decode(s);
    } catch (_) {
      return null;
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
