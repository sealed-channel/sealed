/// Pure codec helpers for messaging: padding, gzip, payload JSON, and the
/// recipient/sender ciphertext framing. No service dependencies — all
/// functions are stateless and take inputs / return outputs.
library;

import 'dart:convert';
import 'package:sealed_app/core/log.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;

// ===========================================================================
// HYBRID FIRST-MESSAGE FRAME CONSTANTS
// ===========================================================================
//
// Legacy KEM handshake frame (publishKeys discovery path):
//   [KEM_ct 768B][scanPub 32B] = 800B
//
// Hybrid first-message frame (KEM handshake + first payload in 1 tx):
//   [KEM_ct 768B][payloadLen 2B LE][AES-GCM(inner) variable]  ≤ 1024B
//
// Inner envelope (encrypted under KEM-derived shared secret):
//   [1B version=0x01][8B timestamp_ms uint64 BE][gzipped content]
//
// Discrimination is length-based at receive time:
//   frame.length == 800  → legacy handshake (parse trailing scanPub)
//   frame.length  > 800  → hybrid (parse trailing payload, drop scanPub)

/// KEM ciphertext length (ML-KEM-768).
const int kKemCtLen = 768;

/// Legacy KEM handshake frame length: [kemCt 768B][scanPub 32B].
const int kLegacyKemFrameLen = 800;

/// Hard cap on hybrid frame bytes.
///
/// Math: AVM `log` opcode emits ≤ 1024B per call. The contract logs the
/// `ciphertext` arg directly (see `contract.algo.ts:976`), and mobile's
/// `sealedClient.sendMessage` prepends a 32B `senderEphemeralPubkey`
/// before that arg (see `sealed_chain_client.dart:171-173`). Therefore
/// mobile-side hybrid frame max = 1024 − 32 = 992 bytes.
const int kHybridFrameMaxBytes = 992;

/// Version byte for the encrypted inner envelope of a hybrid first message.
const int kHybridInnerVersion = 0x01;

/// Inner envelope header: [1B version][8B timestamp BE].
const int kHybridInnerHeaderLen = 9;

/// AES-GCM overhead: 12B nonce + 16B auth tag.
const int kAesGcmOverheadLen = 28;

/// English-character threshold above which we fall back to the legacy
/// 2-call send (handshake then payload) instead of the hybrid 1-call path.
const int kHybridFirstMessageCharThreshold = 280;

// ===========================================================================
// PADDING
// ===========================================================================
//
// NOTE: AVM `log` accepts up to 1024 bytes per call. The contract logs the
// 32B `senderEphemeralPubkey || ciphertext` frame, so the mobile-side
// ciphertext budget is 992B. `maxDataSize` is tuned so 64B-aligned padding
// lands at ≤ 960B (+ 32B framing = 992B logged).
//
// Format: [1-byte version] [2-byte length prefix (LE)] [original ciphertext]
//         [zero padding to 64-byte boundary]

/// Memo version byte for compressed messages.
const int memoVersion = 0x02;

/// Pad to nearest 64-byte boundary for privacy (variable but quantized).
const int padAlignment = 64;

/// Pad ciphertext to a fixed alignment so size doesn't leak content length.
Uint8List pad(Uint8List data) {
  const headerSize = 3; // 1 version + 2 length
  const maxDataSize = 900 - headerSize;
  if (data.length > maxDataSize) {
    throw ArgumentError(
      'Message too large: ${data.length} bytes (max $maxDataSize)',
    );
  }

  final totalUnpadded = headerSize + data.length;
  // Round up to nearest 64-byte boundary
  final paddedSize =
      ((totalUnpadded + padAlignment - 1) ~/ padAlignment) * padAlignment;

  final padded = Uint8List(paddedSize);
  padded[0] = memoVersion;
  padded[1] = data.length & 0xFF;
  padded[2] = (data.length >> 8) & 0xFF;
  padded.setRange(headerSize, headerSize + data.length, data);
  return padded;
}

/// Remove padding from a padded ciphertext.
Uint8List unpad(Uint8List data) {
  if (data.isEmpty) throw ArgumentError('Empty padded data');

  final version = data[0];
  if (version != memoVersion) {
    throw ArgumentError(
      'Unsupported memo version: 0x${version.toRadixString(16)}',
    );
  }
  if (data.length < 3) {
    throw ArgumentError('Padded data too short for v2 header');
  }

  final originalLength = data[1] | (data[2] << 8);
  if (originalLength > data.length - 3) {
    throw ArgumentError(
      'Invalid length prefix: $originalLength > ${data.length - 3}',
    );
  }
  return Uint8List.fromList(data.sublist(3, 3 + originalLength));
}

// ===========================================================================
// CIPHERTEXT FRAMING
// Format: [2-byte recipient_len LE][recipient_ciphertext][sender_ciphertext]
// ===========================================================================

/// Combine recipient + sender ciphertexts with a length prefix.
Uint8List combineCiphertexts(Uint8List recipientCt, Uint8List senderCt) {
  final combined = Uint8List(2 + recipientCt.length + senderCt.length);
  combined[0] = recipientCt.length & 0xFF;
  combined[1] = (recipientCt.length >> 8) & 0xFF;
  combined.setRange(2, 2 + recipientCt.length, recipientCt);
  combined.setRange(2 + recipientCt.length, combined.length, senderCt);
  return combined;
}

/// Split combined ciphertext into recipient and sender parts.
({Uint8List recipientCt, Uint8List senderCt}) splitCiphertexts(
  Uint8List combined,
) {
  if (combined.length < 4) {
    throw ArgumentError('Combined ciphertext too short');
  }
  final recipientLen = combined[0] | (combined[1] << 8);
  if (2 + recipientLen > combined.length) {
    throw ArgumentError('Invalid recipient ciphertext length');
  }
  final recipientCt = Uint8List.fromList(combined.sublist(2, 2 + recipientLen));
  final senderCt = Uint8List.fromList(combined.sublist(2 + recipientLen));
  return (recipientCt: recipientCt, senderCt: senderCt);
}

// ===========================================================================
// GZIP
// ===========================================================================

Uint8List gzipCompress(Uint8List payloadBytes) {
  return Uint8List.fromList(gzip.encode(payloadBytes));
}

Uint8List gzipDecompress(Uint8List compressedBytes) {
  return Uint8List.fromList(gzip.decode(compressedBytes));
}

// ===========================================================================
// CONTENT BUDGET (live "too large" check for the input bar)
// ===========================================================================
//
// A normal DM gzips a JSON envelope {content + wallets + usernames + ts},
// encrypts it for BOTH the recipient and a self-copy, then combines them.
// `pad()` throws once the combined ciphertext exceeds `900 - 3 = 897` bytes:
//
//   2 * (gzip(payload) + AES-GCM overhead) + 2-byte combine prefix  <= 897
//   => gzip(payload) <= (897 - 2) / 2 - 28  ≈ 419 bytes
//
// We can't gzip the real envelope from the UI (it needs identity strings), so
// we reserve a conservative slice for the non-content fields and bound the
// gzipped CONTENT by the remainder. gzip(content)+gzip(env) >= gzip(content+env),
// so this never under-rejects a message the codec would actually throw on —
// at worst it rejects one that would have just barely fit.

/// Conservative gzipped-byte allowance for the non-content envelope fields
/// (two wallets, two usernames, JSON keys, timestamp), already compressed.
const int _kEnvelopeGzipReserveBytes = 220;

/// Max gzipped CONTENT bytes that still fit the two-copy DM frame.
int get maxGzippedContentBytes =>
    ((900 - 3 - 2) ~/ 2) - kAesGcmOverheadLen - _kEnvelopeGzipReserveBytes;

/// True if [content] is too large to send. Conservative — see notes above.
/// English compresses ~3x so this allows long prose; emoji/CJK barely
/// compress, so those cap much lower (matching the real wire limit).
///
/// Cheap on old phones: short messages take the raw-length fast path and never
/// gzip. gzip only runs once a message is already long, and compressing a
/// sub-1KB string is sub-millisecond even on low-end hardware.
bool messageContentTooLarge(String content) {
  if (content.isEmpty) return false;
  final bytes = Uint8List.fromList(utf8.encode(content));
  // Fast path: raw bytes already under budget ⇒ gzip (which only shrinks
  // sizable input) can't exceed it. The -64 cushion covers gzip's small-input
  // framing overhead. Skips compression for the common short-message case.
  if (bytes.length <= maxGzippedContentBytes - 64) return false;
  return gzipCompress(bytes).length > maxGzippedContentBytes;
}

// ===========================================================================
// PAYLOAD PARSING
// ===========================================================================

/// Parse the decrypted message JSON envelope. Falls back to a plain-text
/// shape if JSON decoding fails so legacy/malformed payloads still render.
Map<String, dynamic> parseMessagePayload(String decryptedJson) {
  try {
    final parsed = jsonDecode(decryptedJson) as Map<String, dynamic>;
    return parsed;
  } catch (e) {
    if (kDebugMode) {
      Log.d('[message_codec] ⚠️ Failed to parse JSON payload: $e');
      Log.d('[message_codec] 📝 Raw payload: $decryptedJson');
    }
    return {
      'sender_wallet': 'unknown',
      'sender_username': null,
      'content': decryptedJson,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }
}

// ===========================================================================
// MISC
// ===========================================================================

/// Constant-time byte comparison would be nicer, but this is used for
/// selector matching on log payloads where timing is not a concern.
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ===========================================================================
// HYBRID FIRST-MESSAGE FRAME CODEC
// ===========================================================================

/// Thrown when an encoded frame would exceed the on-chain log byte cap.
class MessageTooLargeError implements Exception {
  final int actualBytes;
  final int maxBytes;
  MessageTooLargeError(this.actualBytes, this.maxBytes);
  @override
  String toString() =>
      'MessageTooLargeError: $actualBytes bytes exceeds cap of $maxBytes';
}

/// Pack a hybrid first-message frame:
///   [KEM_ct kKemCtLen][innerLen 2B LE][innerCiphertext]
///
/// `innerCiphertext` is already AES-GCM-encrypted (caller's responsibility).
/// Throws [MessageTooLargeError] if the total exceeds [kHybridFrameMaxBytes].
Uint8List encodeHybridFirstFrame({
  required Uint8List kemCt,
  required Uint8List innerCiphertext,
}) {
  if (kemCt.length != kKemCtLen) {
    throw ArgumentError('kemCt must be $kKemCtLen bytes, got ${kemCt.length}');
  }
  if (innerCiphertext.length > 0xFFFF) {
    throw ArgumentError(
      'innerCiphertext length ${innerCiphertext.length} exceeds 2B prefix',
    );
  }
  final total = kKemCtLen + 2 + innerCiphertext.length;
  if (total <= kLegacyKemFrameLen) {
    throw ArgumentError(
      'hybrid frame would be $total bytes, which collides with the legacy '
      '$kLegacyKemFrameLen-byte handshake range and would be silently '
      'dropped by receivers',
    );
  }
  if (total > kHybridFrameMaxBytes) {
    throw MessageTooLargeError(total, kHybridFrameMaxBytes);
  }
  final out = Uint8List(total);
  out.setRange(0, kKemCtLen, kemCt);
  out[kKemCtLen] = innerCiphertext.length & 0xFF;
  out[kKemCtLen + 1] = (innerCiphertext.length >> 8) & 0xFF;
  out.setRange(kKemCtLen + 2, total, innerCiphertext);
  return out;
}

/// Parse a candidate frame as a hybrid first message.
///
/// Returns `null` when the frame is too small to be hybrid (caller should
/// try the legacy 800B parse). Throws [FormatException] for malformed
/// frames that DO have hybrid length and [MessageTooLargeError] for frames
/// past the cap.
({Uint8List kemCt, Uint8List innerCiphertext})? decodeHybridFirstFrame(
  Uint8List frame,
) {
  if (frame.length <= kLegacyKemFrameLen) return null;
  if (frame.length > kHybridFrameMaxBytes) {
    throw MessageTooLargeError(frame.length, kHybridFrameMaxBytes);
  }
  if (frame.length < kKemCtLen + 2) {
    throw const FormatException('hybrid frame missing payload length prefix');
  }
  final kemCt = Uint8List.fromList(frame.sublist(0, kKemCtLen));
  final innerLen = frame[kKemCtLen] | (frame[kKemCtLen + 1] << 8);
  final expectedTotal = kKemCtLen + 2 + innerLen;
  if (expectedTotal != frame.length) {
    throw FormatException(
      'hybrid frame inner length $innerLen does not match remaining ${frame.length - kKemCtLen - 2} bytes',
    );
  }
  final inner = Uint8List.fromList(frame.sublist(kKemCtLen + 2));
  return (kemCt: kemCt, innerCiphertext: inner);
}

/// Build the inner-envelope plaintext that gets AES-GCM-encrypted:
///   [1B version=kHybridInnerVersion][8B timestamp_ms uint64 BE][gzip(content)]
Uint8List encodeHybridInnerEnvelope({
  required int timestampMs,
  required Uint8List content,
}) {
  if (timestampMs < 0) {
    throw ArgumentError('timestampMs must be non-negative, got $timestampMs');
  }
  final gz = gzipCompress(content);
  final out = Uint8List(1 + 8 + gz.length);
  out[0] = kHybridInnerVersion;
  ByteData.view(out.buffer).setUint64(1, timestampMs, Endian.big);
  out.setRange(9, out.length, gz);
  return out;
}

/// Parse the inner envelope. Throws [FormatException] on unknown version
/// byte or malformed gzip payload.
({int timestampMs, Uint8List content}) decodeHybridInnerEnvelope(
  Uint8List bytes,
) {
  if (bytes.length < kHybridInnerHeaderLen) {
    throw const FormatException('hybrid inner envelope shorter than header');
  }
  final ver = bytes[0];
  if (ver != kHybridInnerVersion) {
    throw FormatException(
      'unsupported hybrid inner version 0x${ver.toRadixString(16)}',
    );
  }
  final ts = ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
  ).getUint64(1, Endian.big);
  final content = gzipDecompress(
    Uint8List.fromList(bytes.sublist(kHybridInnerHeaderLen)),
  );
  return (timestampMs: ts, content: content);
}

/// Returns `true` iff a hybrid first-message frame carrying [gzippedContentLen]
/// bytes of gzipped content would fit under [kHybridFrameMaxBytes] after
/// envelope + AES-GCM + framing overhead.
///
/// Formula matches [encodeHybridFirstFrame] exactly: predicate-true ⇒
/// encode succeeds without [MessageTooLargeError].
///
///   hybridFrameLen = kKemCtLen          (768)
///                  + 2                  (innerLen prefix)
///                  + kHybridInnerHeaderLen (9: version + timestamp)
///                  + gzippedContentLen
///                  + kAesGcmOverheadLen (28: nonce + tag)
bool hybridFrameFits(int gzippedContentLen) {
  if (gzippedContentLen < 0) {
    throw ArgumentError(
      'gzippedContentLen must be non-negative, got $gzippedContentLen',
    );
  }
  final frameLen =
      kKemCtLen +
      2 +
      kHybridInnerHeaderLen +
      gzippedContentLen +
      kAesGcmOverheadLen;
  return frameLen <= kHybridFrameMaxBytes;
}
