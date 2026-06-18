/// Alias-chat handshake bootstrap payloads (Spec H §5.1, amended H4).
///
/// Two intents traverse the DM tag:
///   - `alias_invite`: scanner-mints alias keypairs, ships pubkeys + tag_salt.
///   - `alias_accept`: scanned-mints alias keypair, encapsulates ML-KEM-512.
///
/// Payloads are JSON-encoded under the DM `msg_key` (which is derived from
/// the identity-X25519 ECDH, no ML-KEM). After both intents land, both sides
/// derive the contact-level `shared_secret` from
/// `(x25519_alias_shared || mlkem_shared || tag_salt)` and forget the alias
/// secret keys (per Spec §3 — keep only `recipient_tag` + `msg_key`).
library;

import 'dart:convert';
import 'dart:typed_data';

enum AliasBootstrapIntent { invite, accept }

class AliasInvitePayload {
  /// Wire-presented alias name. Encoded under JSON key `alias_label`
  /// (Spec H §5.1) — wire name preserved for peer compat. Dart-side name
  /// renamed to `aliasHandle` to match the model.
  final String aliasHandle;
  final Uint8List aliasX25519Pub; // 32B
  final Uint8List aliasMlkemPub; // 800B (ML-KEM-512)
  final Uint8List tagSalt; // 32B

  const AliasInvitePayload({
    required this.aliasHandle,
    required this.aliasX25519Pub,
    required this.aliasMlkemPub,
    required this.tagSalt,
  });

  Uint8List encode() {
    final m = <String, Object?>{
      'intent': 'alias_invite',

      'alias_label': aliasHandle,
      'alias_x25519_pub': base64Encode(aliasX25519Pub),
      'alias_mlkem_pub': base64Encode(aliasMlkemPub),
      'tag_salt': base64Encode(tagSalt),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  static AliasInvitePayload decode(Uint8List bytes) {
    final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (m['intent'] != 'alias_invite') {
      throw const FormatException('not an alias_invite payload');
    }
    return AliasInvitePayload(
      aliasHandle: m['alias_label'] as String,
      aliasX25519Pub: base64Decode(m['alias_x25519_pub'] as String),
      aliasMlkemPub: base64Decode(m['alias_mlkem_pub'] as String),
      tagSalt: base64Decode(m['tag_salt'] as String),
    );
  }
}

class AliasAcceptPayload {
  final Uint8List aliasX25519Pub; // 32B — scanned-side
  final Uint8List
  kemCiphertext; // 768B — ML-KEM-512 encapsulation under scanner's mlkemPub

  const AliasAcceptPayload({
    required this.aliasX25519Pub,
    required this.kemCiphertext,
  });

  Uint8List encode() {
    final m = <String, Object?>{
      'intent': 'alias_accept',

      'alias_x25519_pub': base64Encode(aliasX25519Pub),
      'kem_ct': base64Encode(kemCiphertext),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  static AliasAcceptPayload decode(Uint8List bytes) {
    final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (m['intent'] != 'alias_accept') {
      throw const FormatException('not an alias_accept payload');
    }
    return AliasAcceptPayload(
      aliasX25519Pub: base64Decode(m['alias_x25519_pub'] as String),
      kemCiphertext: base64Decode(m['kem_ct'] as String),
    );
  }
}

AliasBootstrapIntent peekIntent(Uint8List bytes) {
  final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  switch (m['intent']) {
    case 'alias_invite':
      return AliasBootstrapIntent.invite;
    case 'alias_accept':
      return AliasBootstrapIntent.accept;
    default:
      throw FormatException('unknown intent: ${m['intent']}');
  }
}
