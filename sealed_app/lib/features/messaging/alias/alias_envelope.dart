/// Wire-format codecs for alias onboarding DM envelopes.
///
/// Invite envelope — 865B:
///   [0x01][encPub:32][scanPub:32][pqPub:800]
///
/// Accept envelope — 841B:
///   [0x02][inviteRefPrefix:8][encPub:32][scanPub:32][kemCiphertext:768]
///
/// Type byte at offset 0:
///   0x01 = invite
///   0x02 = accept
///
/// Normal text DMs have first byte ≥ 0x20 (utf8), no collision.
/// All parse methods return null on any error — never throw.
library;

import 'dart:typed_data';

const int aliasInviteTagByte = 0x01;
const int aliasAcceptTagByte = 0x02;

const int _kEncPubLen = 32;
const int _kScanPubLen = 32;
const int _kPqPubLen = 800;
const int _kInviteRefPrefixLen = 8;
const int _kKemCiphertextLen = 768;

const int inviteEnvelopeLength =
    1 + _kEncPubLen + _kScanPubLen + _kPqPubLen; // 865
const int acceptEnvelopeLength =
    1 +
    _kInviteRefPrefixLen +
    _kEncPubLen +
    _kScanPubLen +
    _kKemCiphertextLen; // 841

/// Invite envelope sent from creator → acceptor via DM.
class AliasInviteEnvelope {
  final Uint8List encPub;
  final Uint8List scanPub;
  final Uint8List pqPub;

  const AliasInviteEnvelope({
    required this.encPub,
    required this.scanPub,
    required this.pqPub,
  });

  /// Encode to 865-byte wire format.
  Uint8List encode() {
    assert(encPub.length == _kEncPubLen);
    assert(scanPub.length == _kScanPubLen);
    assert(pqPub.length == _kPqPubLen);

    final out = Uint8List(inviteEnvelopeLength);
    int offset = 0;
    out[offset++] = aliasInviteTagByte;
    out.setRange(offset, offset + _kEncPubLen, encPub);
    offset += _kEncPubLen;
    out.setRange(offset, offset + _kScanPubLen, scanPub);
    offset += _kScanPubLen;
    out.setRange(offset, offset + _kPqPubLen, pqPub);
    return out;
  }

  /// Parse from raw bytes. Returns null on wrong tag, wrong length, or any error.
  static AliasInviteEnvelope? tryParse(Uint8List bytes) {
    if (bytes.length != inviteEnvelopeLength) return null;
    if (bytes[0] != aliasInviteTagByte) return null;

    int offset = 1;
    final encPub = Uint8List.fromList(
      bytes.sublist(offset, offset + _kEncPubLen),
    );
    offset += _kEncPubLen;
    final scanPub = Uint8List.fromList(
      bytes.sublist(offset, offset + _kScanPubLen),
    );
    offset += _kScanPubLen;
    final pqPub = Uint8List.fromList(
      bytes.sublist(offset, offset + _kPqPubLen),
    );

    return AliasInviteEnvelope(encPub: encPub, scanPub: scanPub, pqPub: pqPub);
  }
}

/// Accept envelope sent from acceptor → creator via DM.
class AliasAcceptEnvelope {
  /// First 8 bytes of sha256(inviteEnvelopeEncPub || inviteEnvelopeScanPub || inviteEnvelopePqPub).
  /// Lets creator look up correct pending invite without trial decap.
  final Uint8List inviteRefPrefix;
  final Uint8List encPub;
  final Uint8List scanPub;
  final Uint8List kemCiphertext;

  const AliasAcceptEnvelope({
    required this.inviteRefPrefix,
    required this.encPub,
    required this.scanPub,
    required this.kemCiphertext,
  });

  /// Encode to 841-byte wire format.
  Uint8List encode() {
    assert(inviteRefPrefix.length == _kInviteRefPrefixLen);
    assert(encPub.length == _kEncPubLen);
    assert(scanPub.length == _kScanPubLen);
    assert(kemCiphertext.length == _kKemCiphertextLen);

    final out = Uint8List(acceptEnvelopeLength);
    int offset = 0;
    out[offset++] = aliasAcceptTagByte;
    out.setRange(offset, offset + _kInviteRefPrefixLen, inviteRefPrefix);
    offset += _kInviteRefPrefixLen;
    out.setRange(offset, offset + _kEncPubLen, encPub);
    offset += _kEncPubLen;
    out.setRange(offset, offset + _kScanPubLen, scanPub);
    offset += _kScanPubLen;
    out.setRange(offset, offset + _kKemCiphertextLen, kemCiphertext);
    return out;
  }

  /// Parse from raw bytes. Returns null on wrong tag, wrong length, or any error.
  static AliasAcceptEnvelope? tryParse(Uint8List bytes) {
    if (bytes.length != acceptEnvelopeLength) return null;
    if (bytes[0] != aliasAcceptTagByte) return null;

    int offset = 1;
    final inviteRefPrefix = Uint8List.fromList(
      bytes.sublist(offset, offset + _kInviteRefPrefixLen),
    );
    offset += _kInviteRefPrefixLen;
    final encPub = Uint8List.fromList(
      bytes.sublist(offset, offset + _kEncPubLen),
    );
    offset += _kEncPubLen;
    final scanPub = Uint8List.fromList(
      bytes.sublist(offset, offset + _kScanPubLen),
    );
    offset += _kScanPubLen;
    final kemCiphertext = Uint8List.fromList(
      bytes.sublist(offset, offset + _kKemCiphertextLen),
    );

    return AliasAcceptEnvelope(
      inviteRefPrefix: inviteRefPrefix,
      encPub: encPub,
      scanPub: scanPub,
      kemCiphertext: kemCiphertext,
    );
  }
}
