/// Stateless LogicSig signer for the Sealed TreasuryEscrow contract account.
///
/// TreasuryEscrow is a *contract-account* LogicSig (not delegated): the
/// LogicSig is its own account, funded directly. "Signing" a transaction sent
/// from this account requires no ed25519 signature — the wire format is just
/// the program bytes wrapped as `{lsig: {l: <prog>}, txn: <fields>}` msgpack.
///
/// Invariants checked by the TEAL (see `programs/sealed/src/treasury_escrow.algo.ts`):
///   - Txn.typeEnum == Payment (1)
///   - Txn.receiver == Txn.sender (self-payment, amount=0)
///   - Txn.amount == 0
///   - Txn.fee <= 10_000 µALGO
///   - Txn.rekeyTo == ZeroAddress
///   - Txn.closeRemainderTo == ZeroAddress
///   - Txn.groupIndex == 0 (escrow is always txn 0 of the 2-txn group)
///   - Global.groupSize == 2
///
/// Address derivation: Algorand LogicSig addresses are
///   pubkey32 = sha512_256("Program" || programBytes)
///   addr     = base32_nopad(pubkey32 || sha512_256(pubkey32)[28..32])
///
/// The byte-identical-to-algosdk-js property tested in
/// `test/chain/treasury_escrow_signer_test.dart` follows from the determinism
/// of sha512_256 + base32 — no implementation-defined behavior involved.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:messagepack/messagepack.dart';

class TreasuryEscrowSigner {
  /// Compiled TEAL program bytes (output of `algod /v2/teal/compile` on
  /// `programs/sealed/out/TreasuryEscrow.teal`). Caller loads from asset.
  final Uint8List program;

  /// Cached LogicSig address (base32-with-checksum form). Derived once.
  late final String address;

  /// Cached raw 32-byte pubkey portion of the address (no checksum).
  late final Uint8List addressPubkey;

  TreasuryEscrowSigner(this.program) {
    final pubkey = _logicSigPubkey(program);
    addressPubkey = pubkey;
    address = _encodeAlgoAddr(pubkey);
  }

  /// pubkey = sha512_256("Program" || programBytes).
  static Uint8List _logicSigPubkey(Uint8List prog) {
    final prefix = utf8.encode('Program');
    final buf = Uint8List(prefix.length + prog.length)
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, prefix.length + prog.length, prog);
    return Uint8List.fromList(pkg_crypto.sha512256.convert(buf).bytes);
  }

  /// Algorand address = base32_noPad(pubkey32 || sha512_256(pubkey32)[28..32]).
  /// We avoid `AlgoAddrEncoder` because it validates the pubkey as a curve
  /// point — LogicSig hashes are arbitrary 32-byte strings, not ed25519 points.
  static String _encodeAlgoAddr(Uint8List pubkey) {
    if (pubkey.length != 32) {
      throw ArgumentError('pubkey must be 32 bytes, got ${pubkey.length}');
    }
    final checksum = pkg_crypto.sha512256.convert(pubkey).bytes;
    final raw = Uint8List(36)
      ..setRange(0, 32, pubkey)
      ..setRange(32, 36, checksum.sublist(28, 32));
    return _base32NoPad(raw);
  }

  static const String _b32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String _base32NoPad(Uint8List bytes) {
    final sb = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_b32Alphabet[(buffer >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      sb.write(_b32Alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return sb.toString();
  }

  /// Wrap an unsigned txn-field map as a signed-LogicSig blob:
  ///   `{"lsig": {"l": program}, "txn": fields}` in canonical msgpack.
  ///
  /// `txnFields` must already exclude zero-value entries per Algorand canonical
  /// encoding rules (callers reuse the chain client's `_writeMapFields`
  /// helper). For this signer we just msgpack what we're given.
  Uint8List encodeSignedTxn(Map<String, dynamic> txnFields) {
    final p = Packer();
    p.packMapLength(2);
    p.packString('lsig');
    p.packMapLength(1);
    p.packString('l');
    p.packBinary(program);
    p.packString('txn');
    _packSortedMap(p, txnFields);
    return p.takeBytes();
  }

  static void _packSortedMap(Packer p, Map<String, dynamic> fields) {
    final keys = fields.keys.toList()..sort();
    final valid = keys.where((k) {
      final v = fields[k];
      if (v == null) return false;
      if (v is int && v == 0) return false;
      if (v is String && v.isEmpty) return false;
      if (v is List && v.isEmpty) return false;
      return true;
    }).toList();
    p.packMapLength(valid.length);
    for (final k in valid) {
      p.packString(k);
      final v = fields[k]!;
      if (v is int) {
        p.packInt(v);
      } else if (v is String) {
        p.packString(v);
      } else if (v is Uint8List) {
        p.packBinary(v);
      } else if (v is List<Uint8List>) {
        p.packListLength(v.length);
        for (final item in v) {
          p.packBinary(item);
        }
      } else if (v is List<int>) {
        p.packBinary(Uint8List.fromList(v));
      } else {
        throw ArgumentError(
          'Unsupported field type for "$k": ${v.runtimeType}',
        );
      }
    }
  }
}
