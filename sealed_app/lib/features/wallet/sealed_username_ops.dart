/// Thin ops surface for username writes/reads on the unified Sealed SC.
///
/// Delegates to [SealedChainClient]. Bubbles typed exceptions unchanged
/// ([NameTakenError], [BadUsernameFormatError], [NoCreditsError],
/// [UserNotFoundException], [MbrShortfallError]).
library;

import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/core/errors.dart';

class SealedUsernameOps {
  final SealedChainClient _chain;

  SealedUsernameOps(this._chain);

  /// Claim or rename. On rename, callers should pass [oldName] so the box
  /// reference for the existing name slot is declared explicitly.
  Future<String> claim(String name, {String? oldName}) {
    return _chain.claimUsername(name, oldName: oldName);
  }

  /// Clear the caller's username slot. [oldName] should be supplied to
  /// declare the box ref for the slot being released.
  Future<String> release({String? oldName}) {
    return _chain.releaseUsername(oldName: oldName);
  }

  /// Reverse lookup: name → owner wallet address.
  ///
  /// Uses [SealedChainClient.getUserByUsername] (two algod box reads, no indexer).
  /// Throws [UserNotFoundException] when name is unclaimed.
  Future<String> resolve(String name) async {
    final profile = await _chain.getUserByUsername(name);
    if (profile == null) throw const UserNotFoundException();
    return profile.walletAddress;
  }

  /// Cheap availability check: applies length bounds locally, then performs a
  /// single box read via [SealedChainClient.getUserByUsername].
  ///
  /// Returns `true` when:
  ///   * the name is unclaimed, or
  ///   * the name is currently owned by [selfWallet] (rename-to-self).
  ///
  /// Returns `false` otherwise, including when the normalized name's length
  /// falls outside the contract-enforced `[3, 20]` bounds — in that case no
  /// chain call is made.
  Future<bool> isAvailable(String name, {String? selfWallet}) async {
    final normalized = name.trim().toLowerCase();
    if (normalized.length < 3 || normalized.length > 20) return false;
    final profile = await _chain.getUserByUsername(normalized);
    if (profile == null) return true;
    if (selfWallet != null && profile.walletAddress == selfWallet) return true;
    return false;
  }
}
