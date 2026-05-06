// One-shot verification script: derives the faucet address two ways and
// proves the 24-word BIP39 phrase and the re-encoded 25-word Algorand phrase
// resolve to the SAME on-chain address.
//
// Run from the project root:
//   dart run scripts/faucet_reencode.dart
//
// READ-ONLY. Does not touch secure storage, network, or any production code.
// Once the printed 25-word phrase is confirmed (e.g. by importing into Pera
// Wallet and seeing the 14 ALGO), paste it into FaucetService._faucetMnemonic
// in lib/services/faucet_service.dart as part of the migration.

import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:blockchain_utils/bip/address/algo_addr.dart';
import 'package:blockchain_utils/bip/algorand/algorand.dart';
import 'package:pinenacl/ed25519.dart';

// Same constant as lib/services/faucet_service.dart — pasted here so this
// script stands alone and doesn't import any app code.
const String _faucetMnemonic =
    'crucial found vintage movie near coconut bubble puzzle sentence tool '
    'limb tip young rain tennis sheriff bounce marine doctor castle lamp '
    'brief pool elder';

void main() {
  final words = _faucetMnemonic.split(RegExp(r'\s+'));
  print('Source mnemonic: ${words.length} words');
  print('BIP39 valid?   : ${bip39.validateMnemonic(_faucetMnemonic)}');

  // ── Path A: the CURRENT app derivation ───────────────────────────────────
  // bip39.mnemonicToSeed(...) → first 32 bytes → Ed25519 seed → public key →
  // AlgoAddrEncoder. Mirrors AlgorandWallet._seedFromMnemonic.
  final fullSeed = bip39.mnemonicToSeed(_faucetMnemonic);
  final seed32 = Uint8List.fromList(fullSeed.sublist(0, 32));
  final signingA = SigningKey.fromSeed(seed32);
  final pubA = Uint8List.fromList(signingA.verifyKey.asTypedList);
  final addrA = AlgoAddrEncoder().encodeKey(pubA.toList());

  print('\n── Path A: current BIP39-derived faucet address ──');
  print('seed32 (hex)   : ${_hex(seed32)}');
  print('Algorand addr  : $addrA');

  // ── Path B: re-encode those 32 bytes as a native 25-word Algorand phrase ─
  final mnemonic25 = AlgorandMnemonicEncoder().encode(seed32.toList());
  final phrase25 = mnemonic25.toStr();
  final words25 = phrase25.split(RegExp(r'\s+'));

  // Round-trip: decode the 25-word phrase back to entropy and re-derive the
  // address — must match Path A.
  final seedFrom25 = Uint8List.fromList(
    AlgorandSeedGenerator(mnemonic25).generate(),
  );
  final signingB = SigningKey.fromSeed(seedFrom25);
  final pubB = Uint8List.fromList(signingB.verifyKey.asTypedList);
  final addrB = AlgoAddrEncoder().encodeKey(pubB.toList());

  print('\n── Path B: 25-word Algorand-native phrase for the same seed ──');
  print('Re-encoded phrase (${words25.length} words):');
  print(phrase25);
  print('seed (hex)     : ${_hex(seedFrom25)}');
  print('Algorand addr  : $addrB');

  // ── Equality check ───────────────────────────────────────────────────────
  print('\n── Result ──');
  print('seeds match    : ${_eq(seed32, seedFrom25)}');
  print('addresses match: ${addrA == addrB}');
  if (addrA == addrB && _eq(seed32, seedFrom25)) {
    print('\n✅ Safe to swap: the 25-word phrase above resolves to the SAME');
    print('   faucet address. Import it into Pera (TestNet) to confirm the');
    print('   14 ALGO are visible, then replace _faucetMnemonic in');
    print('   lib/services/faucet_service.dart.');
  } else {
    print('\n❌ MISMATCH — DO NOT swap _faucetMnemonic. Investigate.');
  }
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
