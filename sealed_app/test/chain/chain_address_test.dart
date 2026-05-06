import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:sealed_app/chain/chain_address.dart';

/// Generate a valid Ed25519 public key from a 32-byte seed.
Uint8List validEd25519PubKey(int seedFill) {
  final seed = Uint8List(32)..fillRange(0, 32, seedFill);
  final signingKey = SigningKey.fromSeed(seed);
  return Uint8List.fromList(signingKey.verifyKey.asTypedList);
}

void main() {
  group('ChainAddress', () {
    // =========================================================================
    // Algorand
    // =========================================================================
    group('Algorand encode/decode', () {
      test('round-trips an arbitrary valid Ed25519 pubkey', () {
        final pubkey = validEd25519PubKey(0x42);
        final encoded = ChainAddress.encode(pubkey, 'algorand');
        final decoded = ChainAddress.decode(encoded, 'algorand');
        expect(decoded, equals(pubkey));
      });

      test('address is 58 characters long', () {
        final pubkey = validEd25519PubKey(0x01);
        final addr = ChainAddress.encode(pubkey, 'algorand');
        expect(addr.length, 58);
      });

      test('address contains only valid Algorand base32 chars (A-Z, 2-7)', () {
        final pubkey = validEd25519PubKey(0x07);
        final addr = ChainAddress.encode(pubkey, 'algorand');
        expect(RegExp(r'^[A-Z2-7]+$').hasMatch(addr), isTrue);
      });

      test('different seeds produce different addresses', () {
        final pk1 = validEd25519PubKey(0x01);
        final pk2 = validEd25519PubKey(0x02);
        expect(
          ChainAddress.encode(pk1, 'algorand'),
          isNot(equals(ChainAddress.encode(pk2, 'algorand'))),
        );
      });

      test('second round-trip also succeeds', () {
        final pubkey = validEd25519PubKey(0xAA);
        final addr = ChainAddress.encode(pubkey, 'algorand');
        final decoded = ChainAddress.decode(addr, 'algorand');
        expect(decoded, equals(pubkey));
      });
    });

    // =========================================================================
    // Solana
    // =========================================================================
    group('Solana encode/decode', () {
      test('round-trips an arbitrary 32-byte pubkey', () {
        final pubkey = Uint8List.fromList(List.generate(32, (i) => 255 - i));
        final encoded = ChainAddress.encode(pubkey, 'solana');
        final decoded = ChainAddress.decode(encoded, 'solana');
        expect(decoded, equals(pubkey));
      });

      test('different pubkeys produce different addresses', () {
        final pk1 = Uint8List(32)..fillRange(0, 32, 0x10);
        final pk2 = Uint8List(32)..fillRange(0, 32, 0x20);
        expect(
          ChainAddress.encode(pk1, 'solana'),
          isNot(equals(ChainAddress.encode(pk2, 'solana'))),
        );
      });
    });

    // =========================================================================
    // Cross-chain consistency
    // =========================================================================
    group('Cross-chain encoding differs', () {
      test(
        'same valid pubkey encodes to different addresses on different chains',
        () {
          final pubkey = validEd25519PubKey(0x55);
          final algoAddr = ChainAddress.encode(pubkey, 'algorand');
          final solAddr = ChainAddress.encode(pubkey, 'solana');
          expect(algoAddr, isNot(equals(solAddr)));
        },
      );
    });
  });
}
