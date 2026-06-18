/// User session + on-chain username orchestration.
///
/// Chain-first pipeline: every username write hits the unified Sealed SC
/// (`claimUsername` -> `waitForConfirmation`) BEFORE any local cache write.
/// Failures leave the in-memory + on-disk state untouched.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/local_user_repository.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/identity/bio_validator.dart';
import 'package:sealed_app/features/identity/username_validator.dart';

class UserService {
  final LocalUserRepository _localUser;
  final ContactRepository _contacts;
  final SealedChainClient _sealedClient;
  final KeyService _keyService;

  UserProfile? _currentUser;
  SealedKeys? _currentKeys;

  UserService({
    required LocalUserRepository localUser,
    required ContactRepository contacts,
    required KeyService keyService,
    required SealedChainClient sealedClient,
  }) : _localUser = localUser,
       _contacts = contacts,
       _keyService = keyService,
       _sealedClient = sealedClient;

  UserProfile? get currentUser => _currentUser;
  SealedKeys? get currentKeys => _currentKeys;
  bool get isLoggedIn => _currentUser != null;
  bool get isReady => _currentUser != null && _currentKeys != null;

  String? get username => _currentUser?.username;
  String? get walletAddress => _currentUser?.walletAddress;
  String? get displayName => _currentUser?.alias ?? _currentUser?.username;

  /// Restore session from local cache + key store. Returns true on success.
  Future<bool> restoreSession() async {
    final keys = await _keyService.loadKeys();
    if (keys == null) return false;

    final walletAddress = _sealedClient.wallet.walletAddress;
    if (walletAddress == null) return false;

    final localCached = await _localUser.getLocalUser(
      walletAddress: walletAddress,
    );

    // Cache miss (e.g. fresh mnemonic recovery): the local profile is wiped
    // but the username/alias live on-chain. Fetch them so restore rebuilds the
    // real identity instead of a blank wallet-only profile. Keep the locally-
    // derived keys (deterministic, authoritative) and graft on-chain identity.
    // Returns null when the restored address has no profile on the live
    // app-id (legacy/carried-over wallet) — then we fall back to wallet-only.
    UserProfile? resolved = localCached;
    if (resolved == null) {
      try {
        final onChain = await _sealedClient.getUserByWallet(walletAddress);
        if (onChain != null) {
          resolved = UserProfile(
            walletAddress: walletAddress,
            username: onChain.username,
            alias: onChain.alias,
            // Carry the on-chain bio through recovery — omitting it left the
            // device owner's bio blank after a cache-miss restore.
            bio: onChain.bio,
            encryptionPubkey: keys.encryptionPubkey,
            scanPubkey: keys.scanPubkey,
            pqPublicKey: keys.pqPublicKey,
            pqPubkeyHash: onChain.pqPubkeyHash,
            createdAt: onChain.createdAt,
          );
        }
      } catch (_) {
        // Chain/network hiccup — fall through to wallet-only profile.
      }
    }

    final profile =
        resolved ??
        UserProfile(
          walletAddress: walletAddress,
          encryptionPubkey: keys.encryptionPubkey,
          scanPubkey: keys.scanPubkey,
          pqPublicKey: keys.pqPublicKey,
          createdAt: DateTime.now(),
        );

    // Persist whenever the profile didn't come from the local cache (fresh
    // recovery, on-chain fetch, or fabricated fallback) so the next launch is
    // a fast local read.
    if (localCached == null) {
      await _localUser.saveLocalUser(profile);
    }
    _currentUser = profile;
    _currentKeys = keys;
    return true;
  }

  /// Login with a profile already constructed elsewhere (auto-login path).
  Future<void> loginWithProfile(UserProfile profile) async {
    final keys = await _keyService.loadKeys();
    if (keys == null) {
      throw StateError('Keys not available for loginWithProfile');
    }
    await _localUser.saveLocalUser(profile);
    _currentUser = profile;
    _currentKeys = keys;
  }

  /// Claim or rename a username on-chain, then cache locally.
  ///
  /// Pipeline:
  ///   1. Validate format (3-20 chars).
  ///   2. Resolve wallet + keys (StateError if missing).
  ///   3. SealedChainClient.claimUsername(name, oldName: _currentUser?.username).
  ///   4. waitForConfirmation(txId).
  ///   5. Build new profile, persist to local + contacts cache.
  ///
  /// Throws (typed, unchanged from chain layer):
  ///   - BadUsernameFormatError (length / chars)
  ///   - NoCreditsError       (no credit balance)
  ///   - NameTakenError       (already claimed)
  ///   - ConfirmationTimeoutError
  ///   - StateError           (wallet / keys missing)
  ///
  /// On any throw, _currentUser is unchanged and NO local write occurred.
  Future<UserProfile> setUsername({required String username}) async {
    final normalized = username.trim();
    final validation = validateUsername(normalized);
    if (!validation.isValid) {
      throw ArgumentError(validation.code?.name ?? 'invalid_username');
    }

    final walletAddress = _sealedClient.wallet.walletAddress;
    if (walletAddress == null) {
      throw StateError('Wallet not loaded');
    }
    final keys = await _keyService.loadKeys();
    if (keys == null) {
      throw StateError('Keys not derived');
    }

    final oldName = _currentUser?.username;

    // 1. CHAIN — claim first. Throws on TAKEN / NO_CREDITS / format errors.
    final txId = await _sealedClient.claimUsername(
      normalized,
      oldName: oldName,
    );
    await _sealedClient.waitForConfirmation(txId);

    // 2. CACHE — only after chain confirms.
    final profile = UserProfile(
      walletAddress: walletAddress,
      username: normalized,
      alias: _currentUser?.alias,
      bio: _currentUser?.bio,
      encryptionPubkey: keys.encryptionPubkey,
      scanPubkey: keys.scanPubkey,
      pqPublicKey: keys.pqPublicKey,
      pqPubkeyHash: Uint8List.fromList(sha256.convert(keys.pqPublicKey).bytes),
      createdAt: _currentUser?.createdAt ?? DateTime.now(),
    );

    await _localUser.saveLocalUser(profile);
    await _contacts.saveContact(profile);
    await _contacts.saveContactKeys(
      walletAddress,
      pqPublicKey: keys.pqPublicKey,
    );
    _currentUser = profile;
    _currentKeys = keys;
    return profile;
  }

  /// Set or clear (empty string) the on-chain profile bio.
  ///
  /// Chain-first like [setUsername]: `setBio` → `waitForConfirmation` BEFORE
  /// any cache write. Spends 1 credit ([NoCreditsError] bubbles unchanged).
  /// Bio is public on-chain plaintext.
  Future<UserProfile> setBio({required String bio}) async {
    final trimmed = bio.trim();
    final validation = validateBio(trimmed);
    if (!validation.isValid) {
      throw ArgumentError(validation.code?.name ?? 'invalid_bio');
    }

    final current = _currentUser;
    if (current == null) {
      throw StateError('No user session');
    }

    // 1. CHAIN — write first. Throws on NO_CREDITS / BIO_TOO_LONG.
    final txId = await _sealedClient.setBio(trimmed);
    await _sealedClient.waitForConfirmation(txId);

    // 2. CACHE — only after chain confirms. Empty = cleared.
    final profile = current.copyWith(
      bio: trimmed.isEmpty ? null : trimmed,
      clearBio: trimmed.isEmpty,
    );
    await _localUser.saveLocalUser(profile);
    await _contacts.saveContact(profile);
    _currentUser = profile;
    return profile;
  }

  /// Logout - clear in-memory + on-disk session.
  Future<void> logout() async {
    _currentUser = null;
    _currentKeys = null;
    await _localUser.deleteLocalUser();
  }
}
