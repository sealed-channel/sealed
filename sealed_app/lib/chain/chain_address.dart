import 'dart:typed_data';

import 'package:blockchain_utils/bip/address/algo_addr.dart';

/// Chain-agnostic address encoding/decoding utility.
class ChainAddress {
  /// Decode a chain address to raw 32-byte public key bytes.
  static Uint8List decode(String address, String chainId) {
    if (chainId == 'algorand') {
      return _decodeAlgorandAddress(address);
    } else {
      throw UnsupportedError('Unsupported chain: $chainId');
    }
  }

  static String encode(Uint8List pubkeyBytes, String chainId) {
    if (chainId == 'algorand') {
      return _encodeAlgorandAddress(pubkeyBytes);
    } else {
      throw UnsupportedError('Unsupported chain: $chainId');
    }
  }

  static Uint8List _decodeAlgorandAddress(String address) {
    final decoded = AlgoAddrDecoder().decodeAddr(address);
    return Uint8List.fromList(decoded);
  }

  /// Encode raw 32-byte public key to Algorand address format.
  static String _encodeAlgorandAddress(Uint8List pubkeyBytes) {
    return AlgoAddrEncoder().encodeKey(pubkeyBytes.toList());
  }
}

/// Decode Algorand address (58-char base32) to raw 32-byte public key.
/// Algorand address = base32_noPad(pubkey[32] + sha512_256(pubkey)[28:32])
