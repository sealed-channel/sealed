/// Pure classification for the QR-Scan entry point (chats screen → "Scan QR").
///
/// A scanned string is one of:
///   - a legacy single-frame Algorand **address** (start a normal/alias chat);
///   - a frame of a **combined** multi-frame QR (address + alias invite
///     envelope) emitted by the *My QR Code* screen;
///   - an unrelated/garbage payload.
///
/// [classifyScan] folds each scanned string through a caller-owned
/// [OfflineHandshakeAccumulator] and returns a [ScanOutcome]. The widget layer
/// only dispatches on the outcome — no parsing, no camera coupling — so this is
/// unit-testable with synthetic strings.
///
/// No chain side-effects.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sealed_app/features/messaging/alias/combined_qr_codec.dart';
import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';
import 'package:sealed_app/features/wallet/qr_address_validator.dart';

/// What the QR-Scan screen should pop to its caller on a successful scan.
class ScannedQrResult {
  /// The contact's wallet address (always present).
  final String address;

  /// Non-null only when the scan was a combined QR carrying an alias invite
  /// envelope — i.e. an **offline alias** chat is possible without re-scanning.
  final Uint8List? inviteEnvelope;

  const ScannedQrResult({required this.address, this.inviteEnvelope});

  bool get hasInvite => inviteEnvelope != null;
}

/// Result of classifying one scanned string.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// Legacy single-frame Algorand address.
class ScanAddress extends ScanOutcome {
  final String address;
  const ScanAddress(this.address);
}

/// Fully-assembled combined QR (address + invite envelope).
class ScanCombined extends ScanOutcome {
  final String address;
  final Uint8List inviteEnvelope;
  const ScanCombined(this.address, this.inviteEnvelope);
}

/// A recognized handshake frame was consumed; more frames needed. The caller
/// should keep scanning silently (no "invalid" toast).
class ScanAccumulating extends ScanOutcome {
  const ScanAccumulating();
}

/// Unrecognized payload — the caller should show the throttled invalid toast.
class ScanInvalid extends ScanOutcome {
  const ScanInvalid();
}

/// Classify [raw] against [acc] (the caller's running frame accumulator).
ScanOutcome classifyScan(String raw, OfflineHandshakeAccumulator acc) {
  final value = raw.trim();
  if (value.isEmpty) return const ScanInvalid();

  // Single-frame wallet address in any major-wallet QR form (bare address,
  // algorand:// URI, legacy Pera JSON).
  final address = extractAlgorandAddress(value);
  if (address != null) return ScanAddress(address);

  // Otherwise it may be a frame of a combined multi-frame QR.
  final assembled = acc.feed(value);
  if (assembled != null) {
    final decoded = decodeCombinedQr(assembled);
    if (decoded != null) {
      return ScanCombined(decoded.address, decoded.inviteEnvelope);
    }
    // Assembled, but not a combined-QR container (some other payload).
    return const ScanInvalid();
  }

  // Not assembled yet. If this was a real handshake frame we're mid-stream;
  // stay silent. Anything else is genuinely invalid.
  return _isHandshakeFrame(value)
      ? const ScanAccumulating()
      : const ScanInvalid();
}

/// True if [s] base64-decodes to a frame bearing the offline handshake magic.
bool _isHandshakeFrame(String s) {
  try {
    final bytes = base64.decode(s);
    return bytes.isNotEmpty && bytes[0] == OfflineHandshakeCodec.magic;
  } catch (_) {
    return false;
  }
}
