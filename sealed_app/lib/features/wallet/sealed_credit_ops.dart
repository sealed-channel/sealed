/// Concrete [SealedCreditOps] binding for [SealedChainClient].
///
/// Adds an in-process credit-balance cache:
///   • [getCredits] returns the cached value when present, otherwise refetches
///     and caches.
///   • [refetchCredits] (called by [MessageService] when a pre-flight throws
///     [NoCreditsError]) bypasses the cache once and refreshes the entry.
///   • [redeem] invalidates the cache for the redeemer's wallet on success.
///
/// Cache scope is per-process and per-wallet — cleared on app restart. Stale
/// reads across multiple sends are bounded by `sendMessage`'s NO_CREDITS
/// refetch path.
library;

import 'dart:typed_data';

import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/credits_service.dart';

class SealedCreditChainOps implements SealedCreditOps {
  final SealedChainClient _chain;
  final Map<String, int> _cache = <String, int>{};

  SealedCreditChainOps(this._chain);

  @override
  Future<int> getCredits(String walletAddress) async {
    final cached = _cache[walletAddress];
    if (cached != null) return cached;
    final fresh = await _chain.getCredits(walletAddress);
    _cache[walletAddress] = fresh;
    return fresh;
  }

  /// Bypass cache for one read; refresh the entry on success. Callers
  /// (e.g. [MessageService] after a NoCreditsError pre-flight) use this
  /// before deciding to throw.
  @override
  Future<int> refetchCredits(String walletAddress) async {
    final fresh = await _chain.getCredits(walletAddress);
    _cache[walletAddress] = fresh;
    return fresh;
  }

  @override
  Future<String> redeem({
    required Uint8List preimage,
    required String username,
    required String fromAddress,
  }) async {
    final txid = await _chain.redeem(preimage: preimage, username: username);
    // Drop cached balance — caller refetches on next read.
    _cache.remove(fromAddress);
    return txid;
  }

  @override
  Future<String> redeemWithProof({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required String fromAddress,
    String? username,
  }) async {
    final txid = await _chain.redeemWithProof(
      rootRef: rootRef,
      nullifier: nullifier,
      proof: proof,
      pubInputs: pubInputs,
      username: username,
    );
    // Drop cached balance — caller refetches on next read.
    _cache.remove(fromAddress);
    return txid;
  }

  @override
  Future<String> redeemWithProofAndPublishKeys({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required String fromAddress,
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    final txid = await _chain.redeemWithProofAndPublishKeys(
      rootRef: rootRef,
      nullifier: nullifier,
      proof: proof,
      pubInputs: pubInputs,
      encryptionPubkey: encryptionPubkey,
      scanPubkey: scanPubkey,
      pqPubkey: pqPubkey,
    );
    // Drop cached balance — caller refetches on next read.
    _cache.remove(fromAddress);
    return txid;
  }

  @override
  Future<bool> rootBoxExists(Uint8List rootRef) =>
      _chain.rootBoxExists(rootRef);

  /// Test/UI helper: drop a cached entry without an RPC.
  void invalidate(String walletAddress) {
    _cache.remove(walletAddress);
  }
}
