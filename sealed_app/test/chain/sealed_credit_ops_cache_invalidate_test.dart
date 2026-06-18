// Cache-invalidate test for SealedCreditChainOps.redeemWithProof (T10).
//
// After a successful redeemWithProof, the per-wallet balance cache must be
// dropped — so the next `getCredits(wallet)` triggers a network refetch.
//
// Uses a stub `SealedChainClient` subclass overriding `getCredits` and
// `redeemWithProof` to count calls.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/sealed_credit_ops.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';

class _FakeWallet implements AlgorandWallet {
  @override
  final String? walletAddress;
  _FakeWallet(this.walletAddress);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubChain extends SealedChainClient {
  _StubChain()
    : super(
        sealedAppId: 1,
        algodUrl: 'http://test',
        indexerUrl: 'http://test',
        wallet: _FakeWallet('A' * 58),
        escrow: TreasuryEscrowSigner(Uint8List.fromList([0x06])),
      );

  int getCreditsCalls = 0;
  int balance = 5;
  int redeemCalls = 0;

  @override
  Future<int> getCredits(String address) async {
    getCreditsCalls += 1;
    return balance;
  }

  @override
  Future<String> redeemWithProof({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    String? username,
  }) async {
    redeemCalls += 1;
    balance += 100; // pretend credit granted
    return 'STUBTX';
  }
}

Uint8List _b(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xff));

void main() {
  test(
    'redeemWithProof invalidates cache so next getCredits refetches',
    () async {
      final chain = _StubChain();
      final ops = SealedCreditChainOps(chain);
      const wallet = 'WALLET_ADDR';

      // Prime cache: first call hits chain, second call is cached.
      final first = await ops.getCredits(wallet);
      expect(first, 5);
      expect(chain.getCreditsCalls, 1);

      final cached = await ops.getCredits(wallet);
      expect(cached, 5);
      expect(chain.getCreditsCalls, 1, reason: 'second read should be cached');

      // Redeem.
      final txid = await ops.redeemWithProof(
        rootRef: _b(0x10, 32),
        nullifier: _b(0x20, 32),
        proof: _b(0x30, 256),
        pubInputs: _b(0x40, 128),
        fromAddress: wallet,
      );
      expect(txid, 'STUBTX');
      expect(chain.redeemCalls, 1);

      // Next read must miss the cache and refetch the new balance.
      final refreshed = await ops.getCredits(wallet);
      expect(refreshed, 105);
      expect(
        chain.getCreditsCalls,
        2,
        reason: 'cache should be invalidated after redeemWithProof',
      );
    },
  );
}
