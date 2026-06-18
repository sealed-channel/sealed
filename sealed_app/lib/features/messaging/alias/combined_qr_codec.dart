/// Combined QR container — carries a wallet address + an alias invite envelope
/// in one payload, so a single scan of the *My QR Code* screen lets the scanner
/// choose a normal chat (use the address) or an offline alias chat (use the
/// invite envelope).
///
/// This is a PAYLOAD-layer format. It is the opaque `bytes` handed to
/// [OfflineHandshakeCodec] for multi-frame animation — the `0xA1` frame magic
/// lives one layer below and is stripped before these bytes are seen.
///
/// Wire format:
///
///     [magic:1 = 0x03][addrLen:1][addr:addrLen][inviteEnvelope:865B]
///
///   magic     0x03 — combined QR. `< 0x20` (no utf8 text collision) and
///             distinct from the alias envelope tags `0x01`/`0x02` and the
///             offline frame magic `0xA1`.
///   addrLen   Length of the UTF-8 address bytes (1 byte, ≤ 255).
///   addr      The Algorand wallet address, UTF-8.
///   envelope  An [AliasInviteEnvelope] (`AliasInviteEnvelope.encode()`, 865B),
///             unchanged — no wire-format change to the envelope itself.
///
/// [decodeCombinedQr] returns null on any malformation and never throws,
/// matching the silent-fail contract of the surrounding codec/scanner stack.
///
/// No chain side-effects.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';

/// Magic byte identifying a combined-QR container payload.
const int combinedQrMagic = 0x03;

const int _headerLen = 2; // magic + addrLen

/// Encode [address] + [inviteEnvelope] into a combined-QR container payload.
///
/// [inviteEnvelope] must be a `AliasInviteEnvelope.encode()` result
/// ([inviteEnvelopeLength] bytes). [address] must encode to ≤ 255 UTF-8 bytes.
Uint8List encodeCombinedQr({
  required String address,
  required Uint8List inviteEnvelope,
}) {
  final addr = utf8.encode(address);
  if (addr.length > 255) {
    throw ArgumentError.value(address, 'address', 'UTF-8 length must be ≤ 255');
  }
  if (inviteEnvelope.length != inviteEnvelopeLength) {
    throw ArgumentError.value(
      inviteEnvelope.length,
      'inviteEnvelope',
      'must be $inviteEnvelopeLength bytes (AliasInviteEnvelope.encode())',
    );
  }

  final out = Uint8List(_headerLen + addr.length + inviteEnvelope.length);
  out[0] = combinedQrMagic;
  out[1] = addr.length;
  out.setRange(_headerLen, _headerLen + addr.length, addr);
  out.setRange(_headerLen + addr.length, out.length, inviteEnvelope);
  return out;
}

/// Decode a combined-QR container payload.
///
/// Returns `(address, inviteEnvelope)` or null on wrong magic, length
/// mismatch, non-invite trailing bytes, or invalid UTF-8. Never throws.
({String address, Uint8List inviteEnvelope})? decodeCombinedQr(
  Uint8List bytes,
) {
  if (bytes.length < _headerLen) return null;
  if (bytes[0] != combinedQrMagic) return null;

  final addrLen = bytes[1];
  final expectedLen = _headerLen + addrLen + inviteEnvelopeLength;
  if (bytes.length != expectedLen) return null;

  final envelope = Uint8List.fromList(bytes.sublist(_headerLen + addrLen));
  // Trailing bytes must be a well-formed invite envelope.
  if (envelope[0] != aliasInviteTagByte) return null;

  try {
    final address = utf8.decode(
      bytes.sublist(_headerLen, _headerLen + addrLen),
    );
    return (address: address, inviteEnvelope: envelope);
  } catch (_) {
    return null;
  }
}
