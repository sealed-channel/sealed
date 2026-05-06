/// User registration, authentication, and profile management service.
/// Handles user account creation, identity verification via wallet signatures,
/// and profile data synchronization across device, blockchain, and indexer realms.

// lib/services/user_service.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:sealed_app/chain/chain_address.dart';
import 'package:sealed_app/chain/chain_client.dart';
import 'package:sealed_app/local/user_cache.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/remote/indexer_client.dart';
import 'package:sealed_app/services/key_service.dart';

class UserService {
  final UserCache _userCache;
  final ChainClient _chainClient;
  final KeyService _keyService;
  final IndexerClient? _indexerClient;

  // Current user state
  UserProfile? _currentUser;
  SealedKeys? _currentKeys;

  UserService({
    required UserCache userCache,
    required KeyService keyService,
    required ChainClient chainClient,
    IndexerClient? indexerClient,
  }) : _chainClient = chainClient,
       _userCache = userCache,
       _keyService = keyService,
       _indexerClient = indexerClient;

  // Getters for easy access
  UserProfile? get currentUser => _currentUser;
  SealedKeys? get currentKeys => _currentKeys;
  bool get isLoggedIn => _currentUser != null;
  bool get isReady => _currentUser != null && _currentKeys != null;

  // Quick access to common fields
  String? get username => _currentUser?.username;
  String? get walletAddress => _currentUser?.owner;
  String? get displayName => _currentUser?.displayName;

  /// Restore session from local cache
  Future<bool> restoreSession() async {
    final keys = await _keyService.loadKeys();
    if (keys == null) return false;

    final walletAddress = _chainClient.activeWalletAddress;
    if (walletAddress == null) return false;

    final localProfile = await _userCache.getLocalUser(
      walletAddress: walletAddress,
    );

    if (localProfile == null) {
      print(
        '[UserService] ⚠️ No cached profile for $walletAddress, checking indexer...',
      );

      // Try to recover username from the indexer before falling back to blank
      String? recoveredUsername;
      if (_indexerClient != null) {
        try {
          final result = await _indexerClient.getUserByOwner(walletAddress);
          if (result is IndexerSuccess<IndexerUserLookup>) {
            recoveredUsername = result.data.username;
            print(
              '[UserService] ✅ Recovered username from indexer: $recoveredUsername',
            );
          }
        } catch (e) {
          print('[UserService] ⚠️ Indexer lookup failed during restore: $e');
        }
      }

      // Chain fallback: if indexer didn't return a username (fresh deploy,
      // downtime, or never ingested), scan on-chain set_username app calls.
      // Chain is the source of truth — indexer is just a cache.
      if (recoveredUsername == null || recoveredUsername.isEmpty) {
        try {
          recoveredUsername = await _chainClient.fetchLatestUsernameForWallet(
            walletAddress,
          );
          if (recoveredUsername != null) {
            print(
              '[UserService] ✅ Recovered username from chain: $recoveredUsername',
            );
          } else {
            print(
              '[UserService] ℹ️ No on-chain username found for $walletAddress',
            );
          }
        } catch (e) {
          print('[UserService] ⚠️ Chain username lookup failed: $e');
        }
      }

      final profile = UserProfile(
        owner: walletAddress,
        username: recoveredUsername,
        displayName: recoveredUsername,
        encryptionPubkey: keys.encryptionPubkey,
        scanPubkey: keys.scanPubkey,
        createdAt: DateTime.now(),
      );
      await _userCache.saveLocalUser(profile);
      _currentUser = profile;
      _currentKeys = keys;
      return true;
    }

    print(
      '[UserService] ✅ Restored profile for $walletAddress, username: ${localProfile.username ?? "(none)"}',
    );
    _currentUser = localProfile.copyWith(
      encryptionPubkey: keys.encryptionPubkey,
      scanPubkey: keys.scanPubkey,
    );
    _currentKeys = keys;

    // Persist if keys were stale in the cache
    if (localProfile.encryptionPubkeyBase64 !=
            _currentUser!.encryptionPubkeyBase64 ||
        localProfile.scanPubkeyBase64 != _currentUser!.scanPubkeyBase64) {
      await _userCache.saveLocalUser(_currentUser!);
      await _userCache.cacheContact(_currentUser!);
    }
    return true;
  }

  Future<UserProfile> setUsername({required String username}) async {
    final normalized = username.trim();
    if (normalized.length < 3 || normalized.length > 20) {
      throw ArgumentError('Username must be between 3 and 20 characters');
    }

    final walletAddress = _chainClient.activeWalletAddress;
    final keys = await _keyService.loadKeys();
    if (walletAddress == null || keys == null) {
      throw StateError('Wallet or keys not available');
    }

    final txSignature = await _chainClient.setUsernameViaMemo(
      username: normalized,
    );
    await _chainClient.waitForConfirmation(txSignature);

    // Publish PQ public key on-chain in a separate transaction
    // (too large to fit in the username memo)
    await _chainClient.publishPqPublicKey(keys.pqPublicKey);
    print('[UserService] ✅ PQ public key published on-chain');

    final profile = UserProfile(
      owner: walletAddress,
      username: normalized,
      displayName: normalized,
      encryptionPubkey: keys.encryptionPubkey,
      scanPubkey: keys.scanPubkey,
      pqPublicKey: keys.pqPublicKey,
      createdAt: _currentUser?.createdAt ?? DateTime.now(),
    );

    await _userCache.saveLocalUser(profile);
    await _userCache.cacheContact(profile);
    // Also store PQ pubkey in contacts cache for self-lookup
    await _userCache.savePqPublicKey(walletAddress, keys.pqPublicKey);
    _currentUser = profile;
    _currentKeys = keys;

    // Register with indexer immediately so the username is searchable
    // by other users right away (don't wait for catchup worker).
    if (_indexerClient != null) {
      try {
        await _indexerClient.registerUsername(
          username: normalized,
          ownerPubkey: walletAddress,
          encryptionPubkeyBase64: profile.encryptionPubkeyBase64,
          scanPubkeyBase64: profile.scanPubkeyBase64,
          pqPublicKeyBase64: keys.pqPublicKeyBase64,
          txSignature: txSignature,
        );
        print('[UserService] ✅ Username registered with indexer immediately');
      } catch (e) {
        // Non-fatal: catchup worker will eventually index it from chain
        print('[UserService] ⚠️ Direct indexer registration failed: $e');
      }
    }

    return profile;
  }

  Future<UserProfile?> getUserByUsername(
    String username, {
    bool useCache = true,
  }) async {
    // Strip leading '@' so lookup works with or without it
    final cleanUsername = username.startsWith('@')
        ? username.substring(1)
        : username;
    if (useCache) {
      final cached = await _userCache.getCachedContactByUsername(cleanUsername);
      if (cached != null) return cached;
    }

    // Username lookups go straight to chain (algonode public indexer via
    // OHTTP). The sealed-indexer was hanging on these queries when the
    // user wasn't ingested locally, so it's bypassed for username search.
    // Chain is the source of truth anyway.
    try {
      final walletAddress = await _chainClient.fetchWalletForUsername(
        cleanUsername,
      );
      if (walletAddress != null && walletAddress.isNotEmpty) {
        print(
          '[UserService] ✅ Resolved $cleanUsername → $walletAddress from chain',
        );
        // Reuse getUserByWallet to hydrate keys (PQ pubkey, encryption,
        // scan keys). If hydration fails, synthesize a minimal profile from
        // the wallet bytes so the user is at least selectable in the UI.
        final hydrated = await getUserByWallet(walletAddress, useCache: false);
        if (hydrated != null) {
          final withName = hydrated.copyWith(
            username: cleanUsername,
            displayName: cleanUsername,
          );
          await _userCache.cacheContact(withName);
          return withName;
        }
        try {
          final walletBytes = ChainAddress.decode(
            walletAddress,
            _chainClient.chainId,
          );
          if (walletBytes.length == 32) {
            final profile = UserProfile(
              owner: walletAddress,
              username: cleanUsername,
              displayName: cleanUsername,
              encryptionPubkey: walletBytes,
              scanPubkey: walletBytes,
              createdAt: DateTime.now(),
            );
            await _userCache.cacheContact(profile);
            return profile;
          }
        } catch (_) {
          // Fall through
        }
      }
    } catch (e) {
      print('[UserService] ⚠️ Chain username lookup failed: $e');
    }
    return null;
  }

  Future<UserProfile?> getUserByWallet(
    String walletAddress, {
    bool useCache = true,
  }) async {
    if (useCache) {
      final cached = await _userCache.getCachedContact(walletAddress);
      if (cached != null) return cached;
    }

    Uint8List? walletBytes;
    try {
      final decoded = ChainAddress.decode(walletAddress, _chainClient.chainId);
      if (decoded.length == 32) {
        walletBytes = decoded;
      }
    } catch (_) {
      walletBytes = null;
    }

    if (_indexerClient != null) {
      final lookupResult = await _indexerClient.getUserByOwner(walletAddress);
      if (lookupResult is IndexerSuccess<IndexerUserLookup>) {
        final user = lookupResult.data;
        Uint8List? resolvedWalletBytes = walletBytes;
        if (resolvedWalletBytes == null) {
          try {
            final decoded = ChainAddress.decode(
              user.ownerPubkey,
              _chainClient.chainId,
            );
            if (decoded.length == 32) {
              resolvedWalletBytes = decoded;
            }
          } catch (_) {
            resolvedWalletBytes = null;
          }
        }

        if (user.encryptionPubkey == null && resolvedWalletBytes == null) {
          // Cannot build a safe crypto profile, continue to wallet bytes fallback
        } else {
          final profile = UserProfile(
            owner: user.ownerPubkey,
            username: user.username,
            displayName: user.username,
            encryptionPubkey: user.encryptionPubkey ?? resolvedWalletBytes!,
            scanPubkey: user.scanPubkey ?? resolvedWalletBytes!,
            pqPublicKey: user.pqPublicKey,
            createdAt: DateTime.now(),
          );
          await _userCache.cacheContact(profile);
          if (user.pqPublicKey != null) {
            await _userCache.savePqPublicKey(
              user.ownerPubkey,
              user.pqPublicKey!,
            );
          }
          return profile;
        }
      }
    }

    // No PDA fallback — fall through to wallet-derived keys
    if (walletBytes != null) {
      return UserProfile(
        owner: walletAddress,
        username: null,
        displayName: null,
        encryptionPubkey: walletBytes,
        scanPubkey: walletBytes,
        createdAt: DateTime.now(),
      );
    }

    return null;
  }

  Future<void> cacheContactedWallet(
    String walletAddress, {
    String? username,
  }) async {
    Uint8List walletBytes;
    try {
      final decoded = ChainAddress.decode(walletAddress, _chainClient.chainId);
      if (decoded.length != 32) return;
      walletBytes = decoded;
    } catch (_) {
      return;
    }

    final existing = await _userCache.getCachedContact(walletAddress);
    if (existing != null && (existing.username?.isNotEmpty ?? false)) {
      return;
    }

    final normalizedUsername = username?.trim();
    final contact = UserProfile(
      owner: walletAddress,
      username: (normalizedUsername?.isNotEmpty ?? false)
          ? normalizedUsername
          : existing?.username,
      displayName: (normalizedUsername?.isNotEmpty ?? false)
          ? normalizedUsername
          : existing?.displayName,
      encryptionPubkey: existing?.encryptionPubkey ?? walletBytes,
      scanPubkey: existing?.scanPubkey ?? walletBytes,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );

    await _userCache.cacheContact(contact);
  }

  // Search users from cache, then sealed-indexer, then chain.
  // Only Algorand wallets/nicknames are returned — Solana results are excluded.
  Future<List<UserProfile>> searchUsers(String query) async {
    // Strip leading '@' so search works with or without it
    final cleanQuery = query.startsWith('@') ? query.substring(1) : query;

    // 1. Local contacts cache (instant, fuzzy via string_similarity).
    var cachedFuzzyUsers = await _userCache.searchUsers(cleanQuery);
    if (cachedFuzzyUsers.isNotEmpty) {
      cachedFuzzyUsers = cachedFuzzyUsers
          .where((u) => u.owner != _currentUser?.owner && _isAlgorandWallet(u))
          .toList();
    }

    // 2. Wallet-address queries skip the indexer/fuzzy path entirely.
    if (_looksLikeWallet(cleanQuery)) {
      print("🔍 Searching blockchain for Algorand wallet address: $cleanQuery");
      final profile = await getUserByWallet(cleanQuery, useCache: false);
      if (profile != null &&
          profile.owner != _currentUser?.owner &&
          _isAlgorandWallet(profile)) {
        return {profile, ...cachedFuzzyUsers}.toList();
      }
      return cachedFuzzyUsers;
    }

    // 3. Fuzzy username search via sealed-indexer.
    //
    // The indexer's /user/search now returns trigram-ranked, typo-tolerant
    // results in a single Tor round-trip — much faster than the chain-scan
    // path below. Earlier code bypassed this endpoint with a comment
    // claiming it "hangs"; that was a misdiagnosis of slow first-time Tor
    // circuit build. The handler is fully synchronous and returns in <5ms.
    final indexerProfiles = <UserProfile>[];
    if (_indexerClient != null) {
      try {
        final result = await _indexerClient.searchUsersByUsername(
          cleanQuery,
          limit: 20,
        );
        if (result is IndexerSuccess<UsernameSearchResponse>) {
          for (final entry in result.data.users) {
            final profile = _indexerLookupToProfile(entry);
            if (profile == null) continue;
            if (profile.owner == _currentUser?.owner) continue;
            if (!_isAlgorandWallet(profile)) continue;
            indexerProfiles.add(profile);
          }
        }
      } catch (e) {
        print('[UserService] indexer search failed: $e');
      }
    }

    // 4. Chain fallback — only if neither cache nor indexer surfaced anything.
    //    Avoids the multi-second Algonode round-trip on every keystroke.
    UserProfile? chainProfile;
    if (indexerProfiles.isEmpty && cachedFuzzyUsers.isEmpty) {
      print("🔍 Searching blockchain for username: $cleanQuery");
      chainProfile = await getUserByUsername(cleanQuery, useCache: false);
      if (chainProfile != null &&
          (chainProfile.owner == _currentUser?.owner ||
              !_isAlgorandWallet(chainProfile))) {
        chainProfile = null;
      }
    }

    // 5. Legacy (pre-Algorand, non-messageable) names — surfaced last, dimmed.
    final legacyMatches = <UserProfile>[];
    if (_indexerClient != null) {
      try {
        final legacyResult = await _indexerClient.searchLegacyUsers(
          cleanQuery,
          limit: 20,
        );
        if (legacyResult is IndexerSuccess<LegacyUsernameSearchResponse>) {
          for (final entry in legacyResult.data.users) {
            legacyMatches.add(_legacyToProfile(entry));
          }
        }
      } catch (e) {
        print('[UserService] legacy search failed: $e');
      }
    }

    // De-dupe by owner. Order: indexer (ranked) → cache → chain → legacy.
    final seen = <String>{};
    final out = <UserProfile>[];
    for (final p in [
      ...indexerProfiles,
      ...cachedFuzzyUsers,
      ?chainProfile,
      ...legacyMatches,
    ]) {
      if (seen.add(p.owner)) out.add(p);
    }
    return out;
  }

  /// Hydrate a [UserProfile] from a fuzzy /user/search result. Falls back to
  /// the wallet bytes for missing key material so the row stays selectable
  /// in the UI; callers that need real keys for messaging will hit
  /// `getUserByWallet` on selection.
  UserProfile? _indexerLookupToProfile(IndexerUserLookup entry) {
    Uint8List? bytes = entry.encryptionPubkey;
    Uint8List? scan = entry.scanPubkey;
    if (bytes == null || scan == null) {
      try {
        final walletBytes = ChainAddress.decode(
          entry.ownerPubkey,
          _chainClient.chainId,
        );
        bytes ??= walletBytes;
        scan ??= walletBytes;
      } catch (_) {
        return null;
      }
    }
    return UserProfile(
      owner: entry.ownerPubkey,
      username: entry.username,
      displayName: entry.username,
      encryptionPubkey: bytes,
      scanPubkey: scan,
      createdAt: DateTime.now(),
    );
  }

  /// Build a [UserProfile] from a legacy indexer entry. Solana owner is
  /// preserved verbatim; missing key material is filled with zero-bytes
  /// so widgets that read `encryptionPubkey` don't NPE — but `legacy: true`
  /// means callers must refuse to send messages to this profile.
  UserProfile _legacyToProfile(IndexerLegacyUserLookup entry) {
    Uint8List decodeOrZero(String? b64) {
      if (b64 == null || b64.isEmpty) return Uint8List(32);
      try {
        return Uint8List.fromList(base64Decode(b64));
      } catch (_) {
        return Uint8List(32);
      }
    }

    return UserProfile(
      owner: entry.ownerPubkey,
      username: entry.username,
      displayName: null,
      encryptionPubkey: decodeOrZero(entry.encryptionPubkeyBase64),
      scanPubkey: decodeOrZero(entry.scanPubkeyBase64),
      pqPublicKey: null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(entry.registeredAt * 1000),
      legacy: true,
    );
  }

  static final _algorandAddressRe = RegExp(r'^[A-Z2-7]{58}$');

  bool _looksLikeWallet(String query) {
    // Only Algorand addresses are supported: 58 uppercase Base32 chars
    return _algorandAddressRe.hasMatch(query);
  }

  static bool _isAlgorandWallet(UserProfile u) =>
      _algorandAddressRe.hasMatch(u.owner);

  /// Login with an existing profile (for auto-login scenarios)
  Future<void> loginWithProfile(UserProfile profile) async {
    _currentUser = profile;
    _currentKeys = await _keyService.loadKeys();
    await _userCache.saveLocalUser(profile);
    print('✅ User auto-logged in: ${profile.username ?? profile.owner}');
  }

  /// Logout - clear memory and local cache
  Future<void> logout() async {
    _currentUser = null;
    _currentKeys = null;
    await _userCache.deleteLocalUser();
    print('✅ User logged out');
  }
}
