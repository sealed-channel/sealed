/// Message sending, receiving, and synchronization service.
/// Handles end-to-end encrypted message transmission via blockchain,
/// three-layer sync strategy (WebSocket/HTTP/chain), and conversation management.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sealed_app/chain/chain_address.dart';
import 'package:sealed_app/chain/chain_client.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/local/alias_chat_cache.dart';
import 'package:sealed_app/local/message_cache.dart';
import 'package:sealed_app/local/sync_state.dart';
import 'package:sealed_app/local/user_cache.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/remote/indexer_client.dart';
import 'package:sealed_app/services/alias_key_service.dart';
import 'package:sealed_app/services/indexer_service.dart';
import 'package:sealed_app/services/key_format_converter.dart';
import 'package:sealed_app/services/user_service.dart';

import 'crypto_service.dart';
import 'key_service.dart';

// =============================================================================
// SYNC STRATEGY
// =============================================================================

enum SyncLayer {
  blockchain,
}

enum SyncStatus { idle, syncing, error }

// =============================================================================
// MESSAGE SERVICE
// =============================================================================

class MessageService {
  final ChainClient chainClient;
  final CryptoService cryptoService;
  final KeyService keyService;
  final UserService userService;
  final UserCache userCache;
  final SyncState syncState;
  final MessageCache messageCache;
  final IndexerService? indexerService;

  // Alias chat support (optional)
  final AliasChatCache? aliasChatCache;
  final AliasKeyService? aliasKeyService;

  // Sync state
  SyncStatus _syncStatus = SyncStatus.idle;
  SyncLayer? _lastSuccessfulLayer;
  StreamSubscription<NewMessageNotification>? _wsSubscription;
  Future<int>? _activeSync;
  bool _isForceResyncInProgress = false;

  // Callbacks for UI updates
  void Function(SyncStatus status)? onSyncStatusChanged;
  void Function(DecryptedMessage message)? onNewMessageReceived;
  void Function()? onAliasMessageReceived;

  MessageService({
    required this.syncState,
    required this.chainClient,
    required this.cryptoService,
    required this.userService,
    required this.userCache,
    required this.keyService,
    required this.messageCache,
    this.indexerService,
    this.aliasChatCache,
    this.aliasKeyService,
  });

  // ===========================================================================
  // GETTERS
  // ===========================================================================

  SyncStatus get syncStatus => _syncStatus;
  SyncLayer? get lastSuccessfulLayer => _lastSuccessfulLayer;
  bool get isIndexerAvailable => indexerService != null;

  // ===========================================================================
  // REAL-TIME PUSH-EVENT SUBSCRIPTION (Layer 1)
  // ===========================================================================

  /// Subscribe to push-driven message events streamed by IndexerService.
  /// Each event acts as a wake-up; sync layer fetches + decrypts on chain.
  void startRealtimeSync() {
    if (indexerService == null) {
      print(
        '[MessageService] ⚠️ IndexerService not available, skipping real-time sync',
      );
      return;
    }

    _wsSubscription?.cancel();

    print('[MessageService] 📨 Subscribing to indexer push events...');
    _wsSubscription = indexerService!.messageStream.listen(
      _handleRealtimeMessage,
      onError: (error) {
        print('[MessageService] ❌ Push event stream error: $error');
      },
    );
  }

  /// Stop listening to real-time messages
  void stopRealtimeSync() {
    print('[MessageService] 🔌 Stopping real-time sync');
    _wsSubscription?.cancel();
    _wsSubscription = null;
  }

  /// Handle incoming real-time message notification.
  ///
  /// Post-Option-B (Algorand-shaped WS event): the indexer no longer sends
  /// `accountPubkey`/`slot`. The event carries `ciphertext` directly. For
  /// this milestone we use the WS event as a wake-up signal and run the
  /// existing chain-backed sync to fetch + decrypt + cache. Ciphertext-direct
  /// decrypt is a follow-up.
  Future<void> _handleRealtimeMessage(
    NewMessageNotification notification,
  ) async {
    print(
      '[MessageService] ⚡ Real-time event: id=${notification.messageId} '
      'sender=${notification.sender ?? '?'} '
      'round=${notification.confirmedRound ?? '?'} '
      'ctLen=${notification.ciphertext.length}',
    );

    try {
      // Dedup against the dedup key (txId or messageId). If we've already
      // processed this txId, skip the chain round-trip.
      final dedup = notification.dedupKey;
      if (await messageCache.hasMessage(dedup)) {
        print('[MessageService] ↩️ Message already cached ($dedup), skipping');
        return;
      }
      if (aliasChatCache != null &&
          await aliasChatCache!.hasAliasMessage(dedup)) {
        print('[MessageService] ↩️ Alias message already cached ($dedup)');
        return;
      }

      // Trigger the existing chain-backed sync to pull + decrypt + cache.
      // The WS event guarantees there IS something new on chain for our
      // view key, so this is the fastest path until ciphertext-direct
      // decrypt is wired.
      final synced = await syncMessages();
  
    } catch (e) {
      print('[MessageService] ❌ Failed to process real-time event: $e');
    }
  }

  // Steps:
  // 1. Load sender's keys via keyService.loadKeys()
  // 2. Resolve recipient wallet + key material from wallet identity
  // 3. Use wallet bytes as recipient encryption/scan pubkeys (wallet-first mode)
  // 4. Generate ephemeral keypair for this message
  // 5. Compute shared secret: ECDH(ephemeral_private, recipient_scan_pubkey)
  // 6. Compute recipient_tag: HMAC-SHA256(shared_secret, "sealed-recipient-tag-v1")
  // 7. Encrypt message: ECDH(ephemeral_private, recipient_encryption_pubkey) -> AES-GCM
  // 8. Pad ciphertext to 1KB
  // 9. Send transaction via chainClient.sendMessage()
  // 10. Cache outgoing message locally
  // 11. Return transaction signature
  //
  // ===========================================================================
  Future<String> sendMessage({
    required String recipientWallet,
    String? recipientUsername,
    required String plaintext,
    required String senderWallet,
  }) async {
    print(
      '[MessageService] 📤 sendMessage() START - recipient wallet: $recipientWallet',
    );
    // Step 1: Load sender's keys
    final senderKeys = await keyService.loadKeys();

    final balanceMicroAlgo = await chainClient.getWalletBalance(senderWallet);
    if (balanceMicroAlgo <= 0) {
      throw const SendMessageException(
        'Insufficient ALGO to send message',
        isRetryable: false,
      );
    }

    print('[MessageService] ✅ Keys loaded for sender: $senderWallet');
    print(
      '[MessageService] 🔑 My local scan pubkey: ${base64Encode(senderKeys!.scanPubkey)}',
    );

    // Step 2: Resolve recipient key material
    //   a) Try looking up the recipient's published X25519 keys (indexer/cache)
    //   b) Fall back to Ed25519→X25519 conversion of wallet address
    print('[MessageService] 🔍 Resolving recipient keys...');
    final walletBytesRaw = ChainAddress.decode(
      recipientWallet,
      chainClient.chainId,
    );
    if (walletBytesRaw.length != 32) {
      throw ArgumentError('Recipient wallet must decode to 32 bytes');
    }
    final walletBytes = walletBytesRaw;

    Uint8List recipientEncryptionPubkey;
    Uint8List recipientScanPubkey;

    // Try to get the recipient's published X25519 keys
    final recipientProfile = await userService.getUserByWallet(
      recipientWallet,
      useCache: false,
    );

    final hasPublishedKeys =
        recipientProfile != null &&
        !_bytesEqual(recipientProfile.encryptionPubkey, walletBytes) &&
        !_bytesEqual(recipientProfile.scanPubkey, walletBytes);

    if (hasPublishedKeys) {
      // Recipient has published their HKDF-derived X25519 keys
      recipientEncryptionPubkey = recipientProfile.encryptionPubkey;
      recipientScanPubkey = recipientProfile.scanPubkey;
      print('[MessageService] ✅ Using recipient published X25519 keys');
    } else {
      // No published keys — fall back to Ed25519→X25519 conversion
      // of the wallet public key (works for unregistered recipients)
      recipientEncryptionPubkey = ed25519PublicKeyToX25519(
        Uint8List.fromList(walletBytes),
      );
      recipientScanPubkey = ed25519PublicKeyToX25519(
        Uint8List.fromList(walletBytes),
      );
      print(
        '[MessageService] ⚠️ Recipient has no published keys, using Ed25519→X25519 wallet-derived keys',
      );
    }
    print(
      '[MessageService] 🔑 Recipient encryption pubkey: ${base64Encode(recipientEncryptionPubkey)}',
    );
    print(
      '[MessageService] 🔑 Recipient scan pubkey: ${base64Encode(recipientScanPubkey)}',
    );

    // Step 3: Generate ephemeral keypair for this message
    print('[MessageService] 🔑 Generating ephemeral keypair');
    final ephemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    print('[MessageService] ✅ Ephemeral keypair generated');
    print(
      '[MessageService] 🔑 Ephemeral pubkey: ${base64Encode(ephemeralPublicKey.bytes)}',
    );

    // Step 4: Compute shared secret for recipient tag (using SCAN key)
    print('[MessageService] 🔐 Computing shared secret for recipient tag');
    final sharedSecretForTag = await cryptoService.computeSharedSecret(
      keyPair: ephemeralKeyPair,
      publicKey: recipientScanPubkey,
    );
    print(
      '[MessageService] 🤝 Shared secret for tag: ${base64Encode(sharedSecretForTag)}',
    );

    // Step 5: Compute stealth recipient tag
    print('[MessageService] 🏷️ Computing recipient tag');
    final recipientTag = await cryptoService.computeRecipientTag(
      sharedSecretForTag,
    );
    print(
      '[MessageService] ✅ Recipient tag computed: ${base64Encode(recipientTag)}',
    );

    // Step 6: Build payload with sender AND recipient metadata
    // Including recipient info allows us to sync sent messages later
    final messageTimestamp = DateTime.now().millisecondsSinceEpoch;
    final payload = jsonEncode({
      'sender_wallet': senderWallet,
      'sender_username': userService.displayName,
      'recipient_wallet': recipientWallet,
      'recipient_username': recipientUsername,
      'content': plaintext,
      'timestamp': messageTimestamp,
    });
    final payloadBytes = Uint8List.fromList(utf8.encode(payload));
    final compressedPayload = _gzipCompress(payloadBytes);
    print(
      '[MessageService] 🗜️ GZIP: ${payloadBytes.length} → ${compressedPayload.length} bytes',
    );

    // ─── Step 6.5: PQ key exchange (once per contact) ───
    Uint8List? pqSharedSecret;
    final recipientPqPubkey = await userCache.getContactPqPublicKey(
      recipientWallet,
    );
    if (recipientPqPubkey != null) {
      pqSharedSecret = await userCache.getContactPqSharedSecret(
        recipientWallet,
      );
      if (pqSharedSecret == null) {
        // First message to this PQ-enabled contact — perform KEM encapsulation
        final kemResult = await cryptoService.kemEncapsulate(recipientPqPubkey);
        pqSharedSecret = kemResult.sharedSecret;
        await userCache.savePqSharedSecret(recipientWallet, pqSharedSecret);

        // Send KEM ciphertext to recipient in a separate transaction
        final kemPrefix = utf8.encode('KEM_INIT:v1:');
        final kemNote = Uint8List.fromList([
          ...kemPrefix, // 12 bytes
          ...kemResult.ciphertext, // 768 bytes
          ...senderKeys.scanPubkey, // 32 bytes
        ]); // Total: 812 bytes — fits in 1024-byte note limit
        await chainClient.sendRawNote(
          recipientWallet: recipientWallet,
          note: kemNote,
        );
      }
    }

    // Step 7: Encrypt payload for RECIPIENT (using ephemeral key)
    print(
      '[MessageService] 🔒 Encrypting payload for recipient (${payload.length} bytes)',
    );
    final recipientCiphertext = await cryptoService.encryptHybrid(
      plainTextBytes: compressedPayload,
      senderEncryptionKeyPair:
          ephemeralKeyPair, // 👈 EPHEMERAL, not senderKeys!
      recipientEncryptionPubkey: recipientEncryptionPubkey,
      pqSharedSecret: pqSharedSecret,
    );
    print(
      '[MessageService] ✅ Recipient ciphertext: ${recipientCiphertext.length} bytes',
    );

    // Step 7b: Also encrypt a self-copy for SENDER (using ephemeral -> our own pubkey)
    // This allows us to decrypt our sent messages on any device later
    print('[MessageService] 🔒 Encrypting self-copy for sender...');
    final senderEncryptionPubkey = await senderKeys.encryptionKeyPair
        .extractPublicKey();
    final selfCiphertext = await cryptoService.encryptHybrid(
      plainTextBytes: compressedPayload,
      senderEncryptionKeyPair: ephemeralKeyPair, // Same ephemeral key
      recipientEncryptionPubkey: Uint8List.fromList(
        senderEncryptionPubkey.bytes,
      ),
      pqSharedSecret: null, // self-copy uses classical only
    );
    print(
      '[MessageService] ✅ Self-copy ciphertext: ${selfCiphertext.length} bytes',
    );

    // Step 8: Combine both ciphertexts with length prefixes
    // Format: [2-byte recipient_len][recipient_ciphertext][self_ciphertext]
    print('[MessageService] 📦 Combining ciphertexts...');
    final combinedCiphertext = _combineCiphertexts(
      recipientCiphertext,
      selfCiphertext,
    );
    print('[MessageService] ✅ Combined: ${combinedCiphertext.length} bytes');

    // Step 9: Pad to fixed size
    print('[MessageService] 📋 Padding combined ciphertext to fixed size');
    final paddedCiphertext = _padForMemo(combinedCiphertext);
    print('[MessageService] ✅ Padded to ${paddedCiphertext.length} bytes');

    // Step 10: Send via blockchain
    print('[MessageService] ⛓️ Sending message via blockchain...');
    final txSignature = await chainClient.sendMessage(
      recipientTag: recipientTag,
      ciphertext: paddedCiphertext,
      senderEncryptionPubkey: Uint8List.fromList(ephemeralPublicKey.bytes),
      recipientWallet: recipientWallet,
    );
    print('[MessageService] ✅ Message sent! TX: $txSignature');
    final String senderUsername = userService.displayName ?? 'unknown';
    // Step 11: Cache outgoing message locally
    print('[MessageService] 💾 Caching outgoing message to local storage');
    await messageCache.saveMessage(
      DecryptedMessage(
        id: txSignature,
        senderWallet: senderWallet,
        senderUsername: senderUsername,
        recipientWallet: recipientWallet,
        recipientUsername: recipientUsername, // Store recipient username
        content: plaintext, // Store original, not payload
        timestamp: DateTime.fromMillisecondsSinceEpoch(messageTimestamp),
        isOutgoing: true,
        onChainPubkey: txSignature,
      ),
    );
    await userService.cacheContactedWallet(
      recipientWallet,
      username: recipientUsername,
    );
    print('[MessageService] ✅ Message cached successfully');
    print('[MessageService] 📤 sendMessage() COMPLETE\n');

    return txSignature;
  }

  // ===========================================================================
  // HELPER: Combine recipient and sender ciphertexts with length prefix
  // Format: [2-byte recipient_len LE][recipient_ciphertext][sender_ciphertext]
  // ===========================================================================
  Uint8List _combineCiphertexts(Uint8List recipientCt, Uint8List senderCt) {
    final combined = Uint8List(2 + recipientCt.length + senderCt.length);
    // Store recipient ciphertext length as 2-byte little-endian
    combined[0] = recipientCt.length & 0xFF;
    combined[1] = (recipientCt.length >> 8) & 0xFF;
    // Copy recipient ciphertext
    combined.setRange(2, 2 + recipientCt.length, recipientCt);
    // Copy sender ciphertext
    combined.setRange(2 + recipientCt.length, combined.length, senderCt);
    return combined;
  }

  // ===========================================================================
  // HELPER: Split combined ciphertext into recipient and sender parts
  // ===========================================================================
  ({Uint8List recipientCt, Uint8List senderCt}) _splitCiphertexts(
    Uint8List combined,
  ) {
    if (combined.length < 4) {
      throw ArgumentError('Combined ciphertext too short');
    }
    // Read recipient ciphertext length
    final recipientLen = combined[0] | (combined[1] << 8);
    if (2 + recipientLen > combined.length) {
      throw ArgumentError('Invalid recipient ciphertext length');
    }
    final recipientCt = Uint8List.fromList(
      combined.sublist(2, 2 + recipientLen),
    );
    final senderCt = Uint8List.fromList(combined.sublist(2 + recipientLen));
    return (recipientCt: recipientCt, senderCt: senderCt);
  }

  // ===========================================================================
  // THREE-LAYER SYNC STRATEGY
  // ===========================================================================
  //
  // Layer 1: Direct blockchain scan - slowest, but always works as fallback
  //
  // ===========================================================================

  Future<int> syncMessages({
    bool fullSync = false,
    SyncLayer? preferredLayer,
  }) async {
    if (_isForceResyncInProgress && !fullSync) {
      print(
        '[MessageService] ⏸️ syncMessages() skipped: force resync in progress',
      );
      return 0;
    }

    // Avoid overlapping sync executions (e.g. poll tick during forceResync).
    if (_activeSync != null) {
      print('[MessageService] ⏳ syncMessages() already running, waiting...');
      return await _activeSync!;
    }

    final future = _syncMessagesInternal(
      fullSync: fullSync,
      preferredLayer: preferredLayer,
    );
    _activeSync = future;

    try {
      return await future;
    } finally {
      _activeSync = null;
    }
  }

  Future<int> _syncMessagesInternal({
    required bool fullSync,
    required SyncLayer? preferredLayer,
  }) async {
    print(
      '[MessageService] 🔄 syncMessages() START (fullSync: $fullSync, preferredLayer: $preferredLayer)',
    );

    _syncStatus = SyncStatus.syncing;
    onSyncStatusChanged?.call(_syncStatus);

    int newCount = 0;

    int? sinceTimestamp;

    if (!fullSync) {
      final lastSync = await syncState.lastSyncTime;
      // Add 5 minute buffer to avoid missing messages due to clock drift
      final bufferedTime = lastSync.subtract(const Duration(minutes: 5));
      sinceTimestamp = bufferedTime.millisecondsSinceEpoch ~/ 1000;
      print(
        '[MessageService] ⏰ Last sync: $lastSync (checking from $bufferedTime)',
      );
    } else {
      // Full sync must explicitly use 0 so indexer fetches complete history.
      // Passing null lets IndexerService fall back to lastSyncTime.
      sinceTimestamp = 0;
      print('[MessageService] 🔄 Full sync - fetching ALL messages');
    }

    try {
      // Determine which layer to use
      final layer = preferredLayer ?? await _selectBestSyncLayer();
      print(
        '[MessageService] 📡 Using sync layer: $layer, sinceTimestamp: $sinceTimestamp',
      );

      switch (layer) {
      
        case SyncLayer.blockchain:
          newCount = await _syncViaBlockchain(sinceTimestamp);
          _lastSuccessfulLayer = SyncLayer.blockchain;
          break;
      }

      await syncState.updateLastSyncTime(DateTime.now());
      _syncStatus = SyncStatus.idle;
      onSyncStatusChanged?.call(_syncStatus);
      print(
        '[MessageService] ✅ syncMessages() COMPLETE - synced $newCount messages via $layer\n',
      );
    } catch (e) {
      print('[MessageService] ❌ Sync error on preferred layer: $e');

      // Fallback to blockchain if indexer failed
      if (preferredLayer != SyncLayer.blockchain) {
        print('[MessageService] 🔄 Falling back to blockchain sync...');
        try {
          newCount = await _syncViaBlockchain(sinceTimestamp);
          _lastSuccessfulLayer = SyncLayer.blockchain;
          await syncState.updateLastSyncTime(DateTime.now());
          _syncStatus = SyncStatus.idle;
          onSyncStatusChanged?.call(_syncStatus);
          print(
            '[MessageService] ✅ Fallback sync complete - synced $newCount messages\n',
          );
        } catch (fallbackError) {
          print('[MessageService] ❌ Fallback sync also failed: $fallbackError');
          _syncStatus = SyncStatus.error;
          onSyncStatusChanged?.call(_syncStatus);
          rethrow;
        }
      } else {
        _syncStatus = SyncStatus.error;
        onSyncStatusChanged?.call(_syncStatus);
        rethrow;
      }
    }

    return newCount;
  }

  // ===========================================================================
  // SMART LAYER SELECTION
  // ===========================================================================

  Future<SyncLayer> _selectBestSyncLayer() async {

    if (kDebugPollingFallback && indexerService != null) {
      try {
        final isAvailable = await indexerService!.isIndexerAvailable();
        if (isAvailable) {
          print('[MessageService] 📡 Indexer available, using Layer 2 (API)');
         
        }
      } catch (e) {
        print('[MessageService] ⚠️ Indexer health check failed: $e');
      }
    }

    // Fallback to blockchain
    print('[MessageService] 📡 Using Layer 3 (Blockchain) for backfill sync');
    return SyncLayer.blockchain;
  }

  

  // ===========================================================================
  // LAYER 1: SYNC VIA BLOCKCHAIN 
  // ===========================================================================

  Future<int> _syncViaBlockchain(int? sinceTimestamp) async {
    print('[MessageService] 🔗 _syncViaBlockchain() START');

    // ── Pass 0: process KEM handshakes and PQ pubkey publications first so
    // that the shared secrets are cached before we attempt to decrypt messages.
    print('[MessageService] 🔑 Processing PQ/KEM notes from blockchain...');
    await _processPqKeyPublications(sinceTimestamp);
    await _processKemHandshakes(sinceTimestamp);

    // Incoming and outgoing both reuse the same memo fetch cache,
    // so we avoid duplicate RPC scans while keeping each pass focused.
    print('[MessageService] 📥 Syncing incoming messages from blockchain...');
    final incomingCount = await _syncIncomingMessages(sinceTimestamp);
    print('[MessageService] ✅ Synced $incomingCount incoming messages');

    print('[MessageService] 📤 Syncing outgoing messages from blockchain...');
    final outgoingCount = await _syncOutgoingMessages(sinceTimestamp);
    print('[MessageService] ✅ Synced $outgoingCount outgoing messages');

    final newCount = incomingCount + outgoingCount;
    print(
      '[MessageService] 🔗 _syncViaBlockchain() COMPLETE - $newCount messages',
    );
    return newCount;
  }

  // ===========================================================================
  // PROCESS MESSAGE POINTER (shared by Layer 1 & 2)
  // Fetches full message from blockchain and decrypts it
  // ===========================================================================

  Future<DecryptedMessage?> _processMessagePointer(
    IndexerMessagePointer pointer,
  ) async {
    print(
      '[MessageService] 📨 Processing message pointer: ${pointer.accountPubkey}',
    );

    final myKeys = await keyService.loadKeys();
    if (myKeys == null) {
      throw KeyValidationException('Keys not found in storage');
    }

    try {
      // Fetch full message data from blockchain
      final messageData = await chainClient.getMessageByAccount(
        pointer.accountPubkey,
      );
      if (messageData == null) {
        print(
          '[MessageService] ⚠️ Message not found on blockchain: ${pointer.accountPubkey}',
        );
        return null;
      }

      final paddedCiphertext = messageData['ciphertext'] as Uint8List;
      final senderEphemeralPubkey =
          messageData['sender_encryption_pubkey'] as Uint8List;
      final timestamp = messageData['timestamp'] as int;

      // Try regular message decryption first
      Uint8List? decrypted;
      try {
        // Unpad the ciphertext
        final combinedCiphertext = _unpad(paddedCiphertext);

        // Split and get recipient ciphertext
        Uint8List ciphertext;
        try {
          final parts = _splitCiphertexts(combinedCiphertext);
          ciphertext = parts.recipientCt;
        } catch (e) {
          // Fallback for old message format
          ciphertext = combinedCiphertext;
        }

        // Look up any PQ shared secret established via KEM handshake
        final senderAddr = messageData['senderAddress'] as String? ?? '';
        final pqSharedSecret = senderAddr.isNotEmpty
            ? await userCache.getContactPqSharedSecret(senderAddr)
            : null;

        // Try decryption with HKDF-derived encryption key first, then
        // fall back to wallet-derived X25519 key.
        try {
          decrypted = await cryptoService.decryptHybrid(
            encryptionKeyPair: myKeys.encryptionKeyPair,
            senderEncryptionPubkey: senderEphemeralPubkey,
            cipherText: ciphertext,
            pqSharedSecret: pqSharedSecret,
          );
        } catch (_) {
          // Primary decryption failed — try wallet-derived X25519 key
          final walletKeyPair = await keyService
              .getWalletDerivedX25519KeyPair();
          if (walletKeyPair != null) {
            try {
              decrypted = await cryptoService.decryptHybrid(
                encryptionKeyPair: walletKeyPair,
                senderEncryptionPubkey: senderEphemeralPubkey,
                cipherText: ciphertext,
                pqSharedSecret: pqSharedSecret,
              );
              print(
                '[MessageService] 🔑 Decrypted via wallet-derived X25519 key',
              );
            } catch (_) {
              // Neither key worked
            }
          }
        }
      } catch (_) {
        // _unpad or other regular pipeline step failed — not a regular message
      }

      if (decrypted != null) {
        final decompressed = _gzipDecompress(decrypted);
        final decryptedPayload = utf8.decode(decompressed);
        final payload = _parseMessagePayload(decryptedPayload);

        // Create and cache message
        final message = DecryptedMessage(
          id: pointer.accountPubkey,
          senderWallet: payload['sender_wallet'] as String,
          senderUsername: payload['sender_username'] as String?,
          recipientWallet:
              chainClient.activeWalletAddress ?? myKeys.walletAddress,
          content: payload['content'] as String,
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
          isOutgoing: false,
          onChainPubkey: pointer.accountPubkey,
        );

        await messageCache.saveMessage(message);
        print(
          '[MessageService] ✅ Message processed and cached: ${pointer.accountPubkey}',
        );

        return message;
      }

      // Regular decryption failed — try alias decryption
      final aliasHandled = await _tryProcessAsAliasMessage(
        txId: pointer.accountPubkey,
        ciphertext: paddedCiphertext,
        senderPubkey: senderEphemeralPubkey,
        timestamp: timestamp,
      );
      if (aliasHandled) {
        print(
          '[MessageService] ✅ Message processed as alias: ${pointer.accountPubkey}',
        );
        return null; // Alias messages don't return DecryptedMessage
      }

      print(
        '[MessageService] ❌ Failed to decrypt message ${pointer.accountPubkey}',
      );
      return null;
    } catch (e) {
      print(
        '[MessageService] ❌ Failed to process message ${pointer.accountPubkey}: $e',
      );
      return null;
    }
  }

  /// Alias messages are now synced by AliasChatService.syncAliasMessages().
  /// This method is kept as a no-op stub so call-sites don't need changes.
  Future<bool> _tryProcessAsAliasMessage({
    required String txId,
    required Uint8List ciphertext,
    required Uint8List senderPubkey,
    required int timestamp,
  }) async {
    return false;
  }

  // ===========================================================================
  // SYNC INCOMING MESSAGES (messages sent TO me)
  // Uses stealth address detection via recipient_tag.
  //
  // Checks with TWO key types to handle both scenarios:
  //   1. HKDF-derived scan key — sender knew our published X25519 keys
  //   2. Wallet-derived X25519 key — sender used Ed25519→X25519 conversion
  //      (for messages sent before we published keys, or from senders who
  //       didn't have our profile)
  // ===========================================================================
  Future<int> _syncIncomingMessages(int? sinceTimestamp) async {
    print(
      '[MessageService] 📥 _syncIncomingMessages() START (sinceTimestamp: $sinceTimestamp)',
    );

    int newCount = 0;
    final myKeys = await keyService.loadKeys();
    if (myKeys == null) {
      print('[MessageService] ❌ Keys not found in storage for incoming sync');
      throw KeyValidationException('Keys not found in storage');
    }

    // Get the wallet-derived X25519 keypair for fallback tag/decrypt checks.
    final walletDerivedKeyPair = await keyService
        .getWalletDerivedX25519KeyPair();

    final messages = await chainClient.fetchRecentMemoMessages(
      sinceTimestamp: sinceTimestamp,
    );

    for (final message in messages) {
      final txSignature = message['accountPubkey'] as String;

      if (await messageCache.hasMessage(txSignature)) {
        continue;
      }

      final paddedCiphertext = message['ciphertext'] as Uint8List;
      final senderEphemeralPubkey =
          message['sender_encryption_pubkey'] as Uint8List;
      final recipientTag = message['recipient_tag'] as Uint8List;
      final timestamp = message['timestamp'] as int;

      // Check recipient tag with HKDF-derived scan key (primary)
      bool isForMe = await cryptoService.checkRecipientTag(
        senderEncryptionPubkey: senderEphemeralPubkey,
        recipientTag: recipientTag,
        myScanKeyPair: myKeys.scanKeyPair,
      );

      // If primary check fails, try wallet-derived X25519 scan key (fallback)
      bool usedWalletDerivedKeys = false;
      if (!isForMe && walletDerivedKeyPair != null) {
        isForMe = await cryptoService.checkRecipientTag(
          senderEncryptionPubkey: senderEphemeralPubkey,
          recipientTag: recipientTag,
          myScanKeyPair: walletDerivedKeyPair,
        );
        if (isForMe) {
          usedWalletDerivedKeys = true;
          print(
            '[MessageService] 🔑 Tag matched via wallet-derived X25519 key',
          );
        }
      }

      if (!isForMe) {
        continue;
      }

      try {
        final combinedCiphertext = _unpad(paddedCiphertext);

        Uint8List ciphertext;
        try {
          final parts = _splitCiphertexts(combinedCiphertext);
          ciphertext = parts.recipientCt;
        } catch (_) {
          ciphertext = combinedCiphertext;
        }

        // Decrypt with the matching key type
        final decryptionKeyPair = usedWalletDerivedKeys
            ? walletDerivedKeyPair!
            : myKeys.encryptionKeyPair;

        // Look up PQ shared secret from the KEM handshake (if any)
        final msgSenderAddr = message['senderAddress'] as String? ?? '';
        final pqSecret = msgSenderAddr.isNotEmpty
            ? await userCache.getContactPqSharedSecret(msgSenderAddr)
            : null;

        final decrypted = await cryptoService.decryptHybrid(
          encryptionKeyPair: decryptionKeyPair,
          senderEncryptionPubkey: senderEphemeralPubkey,
          cipherText: ciphertext,
          pqSharedSecret: pqSecret,
        );

        final decompressed = _gzipDecompress(decrypted);
        final decryptedPayload = utf8.decode(decompressed);
        final payload = _parseMessagePayload(decryptedPayload);

        await messageCache.saveMessage(
          DecryptedMessage(
            id: txSignature,
            senderWallet: payload['sender_wallet'] as String,
            senderUsername: payload['sender_username'] as String?,
            recipientWallet:
                chainClient.activeWalletAddress ?? myKeys.walletAddress,
            recipientUsername: payload['recipient_username'] as String?,
            content: payload['content'] as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
            isOutgoing: false,
            onChainPubkey: txSignature,
          ),
        );
        newCount++;
      } catch (_) {
        continue;
      }
    }

    print(
      '[MessageService] 📥 _syncIncomingMessages() COMPLETE - $newCount incoming messages',
    );
    return newCount;
  }

  // ===========================================================================
  // SYNC OUTGOING MESSAGES (messages sent BY me)
  // Needed for Indexer API path because indexer currently tracks incoming only.
  // We recover outgoing messages by decrypting the sender self-copy from RPC.
  // ===========================================================================
  Future<int> _syncOutgoingMessages(int? sinceTimestamp) async {
    print(
      '[MessageService] 📤 _syncOutgoingMessages() START (sinceTimestamp: $sinceTimestamp)',
    );

    final myKeys = await keyService.loadKeys();
    if (myKeys == null) {
      print('[MessageService] ❌ Keys not found in storage for outgoing sync');
      throw KeyValidationException('Keys not found in storage');
    }

    int newCount = 0;
    final messages = await chainClient.fetchRecentMemoMessages(
      sinceTimestamp: sinceTimestamp,
    );

    for (final message in messages) {
      final txSignature = message['accountPubkey'] as String;

      // Skip if already cached (incoming from indexer or previously synced)
      if (await messageCache.hasMessage(txSignature)) {
        continue;
      }

      try {
        final paddedCiphertext = message['ciphertext'] as Uint8List;
        final senderEphemeralPubkey =
            message['sender_encryption_pubkey'] as Uint8List;

        final combinedCiphertext = _unpad(paddedCiphertext);
        final parts = _splitCiphertexts(combinedCiphertext);
        final selfCiphertext = parts.senderCt;

        final decrypted = await cryptoService.decryptHybrid(
          encryptionKeyPair: myKeys.encryptionKeyPair,
          senderEncryptionPubkey: senderEphemeralPubkey,
          cipherText: selfCiphertext,
        );

        final decompressed = _gzipDecompress(decrypted);
        final decryptedPayload = utf8.decode(decompressed);
        final payload = _parseMessagePayload(decryptedPayload);

        await messageCache.saveMessage(
          DecryptedMessage(
            id: txSignature,
            senderWallet:
                chainClient.activeWalletAddress ?? myKeys.walletAddress,
            senderUsername: payload['sender_username'] as String?,
            recipientWallet:
                payload['recipient_wallet'] as String? ?? 'unknown',
            recipientUsername: payload['recipient_username'] as String?,
            content: payload['content'] as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (message['timestamp'] as int) * 1000,
            ),
            isOutgoing: true,
            onChainPubkey: txSignature,
          ),
        );
        newCount++;
      } catch (_) {
        // Not decryptable as sender self-copy (likely incoming/foreign message)
        continue;
      }
    }

    print(
      '[MessageService] 📤 _syncOutgoingMessages() COMPLETE - $newCount outgoing messages',
    );
    return newCount;
  }

  // ===========================================================================
  // RECEIVE-SIDE: PQ KEY PUBLICATION INGESTION
  // Detects SEALED_PQ:v1: notes and caches the sender's ML-KEM public key so
  // we can KEM-encapsulate when we first message them.
  // ===========================================================================
  Future<void> _processPqKeyPublications(int? sinceTimestamp) async {
    final prefix = utf8.encode('SEALED_PQ:v1:');
    List<Map<String, dynamic>> rawNotes;
    try {
      rawNotes = await chainClient.fetchRawNotes(
        sinceTimestamp: sinceTimestamp,
      );
    } catch (_) {
      return; // Non-fatal — Solana returns [] anyway
    }

    for (final entry in rawNotes) {
      final noteBytes = entry['noteBytes'] as Uint8List;
      final senderAddress = entry['senderAddress'] as String;

      // Must start with our PQ prefix
      if (noteBytes.length < prefix.length) continue;
      bool hasPrefix = true;
      for (int i = 0; i < prefix.length; i++) {
        if (noteBytes[i] != prefix[i]) {
          hasPrefix = false;
          break;
        }
      }
      if (!hasPrefix) continue;

      final pqPubkey = noteBytes.sublist(prefix.length);
      if (pqPubkey.length != 800) continue; // Must be exactly 800 bytes

      final existing = await userCache.getContactPqPublicKey(senderAddress);
      if (existing != null) continue; // Already cached — skip

      await userCache.savePqPublicKey(senderAddress, pqPubkey);
      print(
        '[MessageService] 🔑 Cached PQ pubkey for $senderAddress (${pqPubkey.length} bytes)',
      );
    }
  }

  // ===========================================================================
  // RECEIVE-SIDE: KEM HANDSHAKE PROCESSING
  // Detects KEM_INIT:v1: notes sent to us, decapsulates the ML-KEM ciphertext
  // using our PQ private key, and stores the resulting shared secret so that
  // the decrypt path can use hybrid key derivation for this sender.
  // ===========================================================================
  Future<void> _processKemHandshakes(int? sinceTimestamp) async {
    final prefix = utf8.encode('KEM_INIT:v1:');
    const kemCtLen = 768;
    const scanPubLen = 32;
    final expectedLen = prefix.length + kemCtLen + scanPubLen; // 812 bytes

    List<Map<String, dynamic>> rawNotes;
    try {
      rawNotes = await chainClient.fetchRawNotes(
        sinceTimestamp: sinceTimestamp,
      );
    } catch (_) {
      return;
    }

    final myAddress = chainClient.activeWalletAddress;
    if (myAddress == null) return;

    final pqKeys = await keyService.loadPqKeys();
    if (pqKeys == null) {
      print(
        '[MessageService] ⚠️ No PQ keys found — skipping KEM handshake processing',
      );
      return;
    }

    for (final entry in rawNotes) {
      final noteBytes = entry['noteBytes'] as Uint8List;
      final senderAddress = entry['senderAddress'] as String;

      if (noteBytes.length != expectedLen) continue;

      // Check prefix
      bool hasPrefix = true;
      for (int i = 0; i < prefix.length; i++) {
        if (noteBytes[i] != prefix[i]) {
          hasPrefix = false;
          break;
        }
      }
      if (!hasPrefix) continue;

      // Skip if we already have a shared secret from this sender
      final existing = await userCache.getContactPqSharedSecret(senderAddress);
      if (existing != null) continue;

      final kemCiphertext = noteBytes.sublist(
        prefix.length,
        prefix.length + kemCtLen,
      );

      try {
        final sharedSecret = await cryptoService.kemDecapsulate(
          kemCiphertext,
          pqKeys.privateKey,
        );
        await userCache.savePqSharedSecret(senderAddress, sharedSecret);
        print(
          '[MessageService] 🔐 KEM handshake processed for $senderAddress — PQ shared secret stored',
        );
      } catch (e) {
        print(
          '[MessageService] ⚠️ KEM decapsulation failed for $senderAddress: $e',
        );
        continue;
      }
    }
  }

  // ===========================================================================
  //  GET CONVERSATION
  // ===========================================================================
  //
  // Returns all messages with a specific user, sorted by timestamp
  //
  // ===========================================================================
  Future<List<DecryptedMessage>> getConversation(String contactWallet) async {
    print(
      '[MessageService] 💬 getConversation() - fetching with $contactWallet',
    );
    final messages = await messageCache.getConversationMessages(
      userService.walletAddress!,
      contactWallet,
    );
    print(
      '[MessageService] ✅ Found ${messages.length} messages in conversation',
    );
    return messages;
  }

  // ===========================================================================
  // GET ALL CONVERSATIONS (Preview list)
  // ===========================================================================
  //
  // Returns list of conversation previews for inbox view
  //
  // ===========================================================================
  Future<List<ConversationPreview>> getAllConversations() async {
    print(
      '[MessageService] 📋 getAllConversations() - fetching all conversation previews',
    );
    final conversations = await messageCache.getConversations();
    print(
      '[MessageService] ✅ Found ${conversations.length} conversation previews',
    );
    return conversations;
  }

  // ===========================================================================
  //  MARK AS READ
  // ===========================================================================
  Future<void> markConversationAsRead(String contactWallet) async {
    print(
      '[MessageService] 👁️ markConversationAsRead() - marking $contactWallet as read',
    );
    await messageCache.markAsRead(contactWallet);
    print('[MessageService] ✅ Conversation marked as read');
  }

  // ===========================================================================
  // GET UNREAD COUNT
  // ===========================================================================
  Future<int> getUnreadCount(String contactWallet) async {
    print('[MessageService] 🔔 getUnreadCount() - checking $contactWallet');
    // TODO: Add to MessageCache:
    // Future<int> getUnreadCount();
    final count = await messageCache.getUnreadCount(contactWallet);
    print('[MessageService] ✅ Unread count: $count');
    return count;
  }

  // ===========================================================================
  // FORCE RESYNC
  // ===========================================================================
  Future<void> forceResync(SyncLayer layer) async {
    print(
      '[MessageService] 🔄 forceResync() START - clearing cache and resetting sync state',
    );
    _isForceResyncInProgress = true;
    try {
      if (_activeSync != null) {
        print('[MessageService] ⏳ Waiting for active sync before force resync');
        await _activeSync!;
      }

      print('[MessageService] 🗑️ Clearing message cache...');
      await messageCache.clearMessages();
      print('[MessageService] ✅ Cache cleared');
      print('[MessageService] 🔄 Resetting sync state...');
      await syncState.reset();
      print('[MessageService] ✅ Sync state reset');

      // Re-register view key with indexer to ensure it's current
      if (indexerService != null) {
        try {
          print('[MessageService] 🔑 Re-registering view key with indexer...');
          await indexerService!.registerViewKey();
          print('[MessageService] ✅ View key re-registered');
        } catch (e) {
          print(
            '[MessageService] ⚠️ Failed to re-register view key: $e (will use blockchain fallback)',
          );
        }
      }

      print('[MessageService] 📡 Starting fresh sync (full sync)...');
      await syncMessages(
        fullSync: true,
        preferredLayer: layer,
      ); // 👈 Use fullSync to get ALL messages
      print(
        '[MessageService] 👁️ Marking resynced historical messages as read...',
      );
      await messageCache.markAllAsRead();
      print('[MessageService] ✅ forceResync() COMPLETE\n');
    } finally {
      _isForceResyncInProgress = false;
    }
  }

  // ===========================================================================
  // HELPER: Pad ciphertext to fixed size
  // ===========================================================================
  // NOTE: Solana transaction limit is 1232 bytes. With overhead (accounts,
  // signatures, recipient_tag, sender_pubkey), max ciphertext is ~900 bytes.
  // This still provides meaningful privacy protection against size analysis.
  //
  // Format: [2-byte length prefix (LE)] [original ciphertext] [zero padding]
  /// Memo version byte for compressed messages
  static const int _memoVersion = 0x02;

  /// Pad to nearest 64-byte boundary for privacy (variable but quantized)
  static const int _padAlignment = 64;

  /// Pad for memo format:
  /// [1-byte version=0x02][2-byte LE original_len][data][zero_pad to 64-byte boundary]
  Uint8List _padForMemo(Uint8List data) {
    const headerSize = 3; // 1 version + 2 length
    const maxDataSize = 900 - headerSize; // stay within Solana tx limits
    if (data.length > maxDataSize) {
      throw ArgumentError(
        'Message too large: ${data.length} bytes (max $maxDataSize)',
      );
    }

    final totalUnpadded = headerSize + data.length;
    // Round up to nearest 64-byte boundary
    final paddedSize =
        ((totalUnpadded + _padAlignment - 1) ~/ _padAlignment) * _padAlignment;

    final padded = Uint8List(paddedSize);
    padded[0] = _memoVersion;
    // Store original data length as 2-byte little-endian
    padded[1] = data.length & 0xFF;
    padded[2] = (data.length >> 8) & 0xFF;
    // Copy data after header
    padded.setRange(headerSize, headerSize + data.length, data);
    // Remaining bytes are already 0
    return padded;
  }

  // ===========================================================================
  // HELPER: Remove padding from ciphertext
  // ===========================================================================
  Uint8List _unpad(Uint8List data) {
    if (data.isEmpty) throw ArgumentError('Empty padded data');

    final version = data[0];
    if (version != _memoVersion) {
      throw ArgumentError(
        'Unsupported memo version: 0x${version.toRadixString(16)}',
      );
    }
    if (data.length < 3) {
      throw ArgumentError('Padded data too short for v2 header');
    }

    // Read 2-byte little-endian length after version byte
    final originalLength = data[1] | (data[2] << 8);
    if (originalLength > data.length - 3) {
      throw ArgumentError(
        'Invalid length prefix: $originalLength > ${data.length - 3}',
      );
    }
    return Uint8List.fromList(data.sublist(3, 3 + originalLength));
  }

  // ===========================================================================
  // HELPER: Parse decrypted message payload
  // ===========================================================================
  Map<String, dynamic> _parseMessagePayload(String decryptedJson) {
    // Expected JSON format:
    // {
    //   "sender_wallet": "7Xf9kL2mN8pQ3rT5vW9x...",
    //   "sender_username": "alice",  // optional
    //   "content": "Hello Bob!",
    //   "timestamp": 1706000000000
    // }
    try {
      final parsed = jsonDecode(decryptedJson) as Map<String, dynamic>;
      return parsed;
    } catch (e) {
      print('[MessageService] ⚠️ Failed to parse JSON payload: $e');
      print('[MessageService] 📝 Raw payload: $decryptedJson');
      // Fallback for plain text messages
      return {
        'sender_wallet': 'unknown',
        'sender_username': null,
        'content': decryptedJson,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
    }
  }

  Uint8List _gzipCompress(Uint8List payloadBytes) {
    return Uint8List.fromList(gzip.encode(payloadBytes));
  }

  Uint8List _gzipDecompress(Uint8List compressedBytes) {
    return Uint8List.fromList(gzip.decode(compressedBytes));
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// =============================================================================
// SUMMARY: Methods needed in other services
// =============================================================================
//
// CryptoService (add these methods):
// --------------------------------
// Future<SimpleKeyPair> generateEphemeralKeyPair();
//
// Future<Uint8List> encryptMessage({
//   required String plaintext,
//   required Uint8List ephemeralPrivateKey,
//   required Uint8List recipientEncryptionPubkey,
// });
//
// Future<String> decryptMessage({
//   required Uint8List ciphertext,
//   required Uint8List senderEphemeralPubkey,
//   required Uint8List myEncryptionPrivateKey,
// });
//
// MessageCache (add these methods):
// ---------------------------------
// Future<bool> hasMessage(String txSignature);
//
// Future<void> cacheOutgoingMessage({
//   required String txSignature,
//   required String recipientUsername,
//   required String recipientWallet,
//   required String content,
//   required int timestamp,
// });
//
// Future<void> cacheIncomingMessage({
//   required String txSignature,
//   required String senderWallet,
//   required String? senderUsername,
//   required String content,
//   required int timestamp,
// });
//
// Future<List<DecryptedMessage>> getConversationByWallet(String wallet);
//
// Future<List<ConversationPreview>> getConversationPreviews();
//
// Future<void> Read(String contactWallet);
//
// Future<int> getUnreadCount();
//
// Future<int?> getLastSyncTime();
//
// Future<void> setLastSyncTime(int timestamp);
//
// Future<void> clearCache();
//
// =============================================================================
