/// Anonymous messaging service via shared alias channels.
/// Manages alias chat creation, invitations, and routing through
/// the global wallet system and Algorand Smart Contracts.

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:sealed_app/chain/algorand_chain_client.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/local/alias_chat_cache.dart';
import 'package:sealed_app/models/alias_chat.dart';
import 'package:sealed_app/services/alias_key_service.dart';
import 'package:sealed_app/services/crypto_service.dart';
import 'package:sealed_app/services/indexer_service.dart';

/// Orchestrates the alias chat lifecycle.
///
/// Invitations and key-exchange notes are sent as regular transactions to the
/// contact's personal wallet.  After key exchange completes, all alias chat
/// messages are sent to ALIAS_GLOBAL_WALLET so that both parties' real
/// addresses are hidden.
///
/// Key exchange uses a hybrid X25519 + ML-KEM-512 scheme:
///   1. Creator sends [x25519Pub(32B) || pqPub(800B)] encrypted with
///      AES-GCM(SHA256(inviteSecret)) and tagged HMAC(inviteSecret, "alias-invite-tag-v1")
///      to the **contact's wallet**
///   2. Acceptor sends [x25519Pub(32B) || kemCiphertext(768B)] encrypted the
///      same way, tagged HMAC(inviteSecret, "alias-accept-tag-v1")
///      to the **creator's wallet**
///   3. Both sides derive enc_key = HKDF(ECDH || pqShared, "sealed-hybrid-aes-gcm-v1")
///
/// After key exchange only enc_key + recipientTag are kept on device.
class AliasChatService {
  final AliasChatCache _cache;
  final AliasKeyService _aliasKeyService;
  final AlgorandChainClient _chainClient;
  final CryptoService _cryptoService;
  final IndexerService? _indexerService;

  AliasChatService({
    required AliasChatCache cache,
    required AliasKeyService aliasKeyService,
    required AlgorandChainClient chainClient,
    required CryptoService cryptoService,
    IndexerService? indexerService,
  }) : _cache = cache,
       _aliasKeyService = aliasKeyService,
       _chainClient = chainClient,
       _cryptoService = cryptoService,
       _indexerService = indexerService;

  // ---------------------------------------------------------------------------
  // Step 1: Create invitation (Device 1)
  // ---------------------------------------------------------------------------

  /// Create a new alias chat channel and broadcast the invite note.
  ///
  /// 1. Generate random inviteSecret + temp X25519 keypair + temp PQ keypair
  /// 2. Encrypt [x25519Pub || pqPub] with AES-GCM(SHA256(inviteSecret))
  /// 3. Send as a regular-format note to the **contact's wallet**
  /// 4. Save minimal AliasChat locally (status=pending)
  Future<AliasChat> createInvitation({
    required String alias,
    required String contactWallet,
  }) async {
    final inviteSecret = AliasKeyService.generateInviteSecret();
    final secretBytes = _inviteSecretBytes(inviteSecret);

    // Generate temp X25519 keypair
    final tempKeys = await _aliasKeyService.generateTempKeyPair(inviteSecret);

    // Generate temp PQ keypair
    final pqKeys = await _cryptoService.generatePqKeyPair();
    await _aliasKeyService.storeTempPqKeyPair(
      inviteSecret,
      privateKey: pqKeys.privateKey,
      publicKey: pqKeys.publicKey,
    );

    // Build invite payload: [x25519Pub(32B) || pqPub(800B)]
    final invitePayload = Uint8List.fromList([
      ...tempKeys.publicKey,
      ...pqKeys.publicKey,
    ]);

    // Encrypt payload + compute discovery tag
    final inviteTag = await _computeDiscoveryTag(
      secretBytes,
      ALIAS_INVITE_TAG_LABEL,
    );
    final inviteCiphertext = await _encryptWithDiscoveryKey(
      secretBytes,
      invitePayload,
    );

    // Send invite note to the CONTACT's wallet (regular transaction)
    await _chainClient.sendMessage(
      recipientTag: inviteTag,
      ciphertext: inviteCiphertext,
      senderEncryptionPubkey: _randomBytes(32), // dummy — no identity leak
      recipientWallet: contactWallet,
    );

    final chat = AliasChat(
      inviteSecret: inviteSecret,
      alias: alias,
      status: AliasChannelStatus.pending,
      createdAt: DateTime.now(),
      isCreator: true,
    );

    await _cache.saveAliasChat(chat);
    return chat;
  }

  /// Generate a shareable invite URI for QR code / deep link.
  /// Includes the creator's wallet so the acceptor knows where to scan.
  String generateInviteUri(AliasChat chat) {
    final wallet = _chainClient.activeWalletAddress ?? '';
    return 'sealed://alias?c=${Uri.encodeComponent(chat.inviteSecret)}&w=${Uri.encodeComponent(wallet)}';
  }

  /// Parse an invite URI.  Returns null if the URI is not a valid alias invite.
  static ({String inviteSecret, String creatorWallet})? parseInviteUri(
    String uri,
  ) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return null;
    if (parsed.scheme != 'sealed' || parsed.host != 'alias') return null;
    final inviteSecret = parsed.queryParameters['c'];
    if (inviteSecret == null || inviteSecret.isEmpty) return null;
    final creatorWallet = parsed.queryParameters['w'] ?? '';
    return (inviteSecret: inviteSecret, creatorWallet: creatorWallet);
  }

  // ---------------------------------------------------------------------------
  // Step 2: Accept invitation (Device 2)
  // ---------------------------------------------------------------------------

  /// Accept an alias chat invitation.
  ///
  /// 1. Scan **creator's wallet** for invite note tagged for this inviteSecret
  /// 2. Decrypt to get creator's [x25519Pub || pqPub]
  /// 3. Generate ephemeral X25519 keypair, compute ECDH
  /// 4. KEM-encapsulate creator's pqPub → (kemCiphertext, pqShared)
  /// 5. Derive enc_key = HKDF(classicalShared || pqShared)
  /// 6. Send accept note [acceptorX25519Pub || kemCiphertext] to **creator's wallet**
  /// 7. Store enc_key + recipientTag; register with indexer
  Future<AliasChat> acceptInvitation({
    required String inviteSecret,
    required String alias,
    required String creatorWallet,
  }) async {
    final secretBytes = _inviteSecretBytes(inviteSecret);

    // Find and decrypt the invite note from the creator's wallet
    final invitePayload = await _findDiscoveryNote(
      secretBytes,
      ALIAS_INVITE_TAG_LABEL,
      creatorWallet,
    );
    if (invitePayload == null) {
      throw StateError('Invite note not found on-chain for $inviteSecret');
    }
    if (invitePayload.length < 832) {
      throw StateError(
        'Invite payload too short: ${invitePayload.length} bytes',
      );
    }

    final creatorX25519Pub = invitePayload.sublist(0, 32);
    final creatorPqPub = invitePayload.sublist(32, 832);

    // Generate ephemeral X25519 keypair (in-memory only)
    final x25519 = X25519();
    final myKeyPair = await x25519.newKeyPair();
    final myX25519Pub = Uint8List.fromList(
      (await myKeyPair.extractPublicKey()).bytes,
    );

    // Classical ECDH
    final classicalSharedSecret = await x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(
        creatorX25519Pub,
        type: KeyPairType.x25519,
      ),
    );
    final classicalSharedBytes = Uint8List.fromList(
      await classicalSharedSecret.extractBytes(),
    );

    // PQ KEM encapsulate
    final kemResult = await _cryptoService.kemEncapsulate(creatorPqPub);
    final pqSharedBytes = kemResult.sharedSecret;
    final kemCiphertext = kemResult.ciphertext;

    // Derive enc_key
    final encKey = await _deriveEncKey(classicalSharedBytes, pqSharedBytes);
    final recipientTag = await _cryptoService.computeAliasRecipientTag(encKey);

    // Build accept payload: [acceptorX25519Pub(32B) || kemCiphertext(768B)]
    final acceptPayload = Uint8List.fromList([
      ...myX25519Pub,
      ...kemCiphertext,
    ]);
    final acceptTag = await _computeDiscoveryTag(
      secretBytes,
      ALIAS_ACCEPT_TAG_LABEL,
    );
    final acceptCiphertext = await _encryptWithDiscoveryKey(
      secretBytes,
      acceptPayload,
    );

    // Send accept note to the CREATOR's wallet (regular transaction)
    await _chainClient.sendMessage(
      recipientTag: acceptTag,
      ciphertext: acceptCiphertext,
      senderEncryptionPubkey: _randomBytes(32),
      recipientWallet: creatorWallet,
    );

    // Store enc_key + recipientTag
    await _aliasKeyService.storeEncKey(
      inviteSecret,
      encKey: encKey,
      recipientTag: recipientTag,
    );

    final chat = AliasChat(
      inviteSecret: inviteSecret,
      alias: alias,
      status: AliasChannelStatus.active,
      createdAt: DateTime.now(),
      isCreator: false,
    );
    await _cache.saveAliasChat(chat);

    // Register recipientTag with indexer for push notifications
    await _registerTag(inviteSecret, recipientTag);

    return chat;
  }

  // ---------------------------------------------------------------------------
  // Step 3: Finalize (Device 1 polls for acceptance)
  // ---------------------------------------------------------------------------

  /// Poll for the accept note and finalise key exchange.
  ///
  /// 1. Scan **own wallet** for accept note tagged for this inviteSecret
  /// 2. Load creator's temp X25519 + PQ private keys
  /// 3. Compute ECDH + KEM-decapsulate → derive enc_key
  /// 4. Store enc_key + recipientTag, erase temp keys
  /// 5. Register recipientTag with indexer
  ///
  /// Returns true if channel was successfully finalised.
  Future<bool> checkAndFinalizeChannel(String inviteSecret) async {
    final chat = await _cache.getAliasChat(inviteSecret);
    if (chat == null || chat.status != AliasChannelStatus.pending) {
      return chat?.status == AliasChannelStatus.active;
    }

    final secretBytes = _inviteSecretBytes(inviteSecret);

    // The accept note was sent TO our own wallet, so scan our address
    final myWallet = _chainClient.activeWalletAddress;
    if (myWallet == null) return false;

    // Find and decrypt the accept note
    final acceptPayload = await _findDiscoveryNote(
      secretBytes,
      ALIAS_ACCEPT_TAG_LABEL,
      myWallet,
    );
    if (acceptPayload == null) return false;
    if (acceptPayload.length < 800) {
      debugPrint('[ALIAS] Accept payload too short: ${acceptPayload.length}B');
      return false;
    }

    final acceptorX25519Pub = acceptPayload.sublist(0, 32);
    final kemCiphertext = acceptPayload.sublist(32, 800);

    // Load temp keys
    final tempKeys = await _aliasKeyService.loadTempKeyPair(inviteSecret);
    if (tempKeys == null) {
      debugPrint('[ALIAS] Temp X25519 keys not found for $inviteSecret');
      return false;
    }
    final pqPrivKey = await _aliasKeyService.loadTempPqPrivateKey(inviteSecret);
    if (pqPrivKey == null) {
      debugPrint('[ALIAS] Temp PQ private key not found for $inviteSecret');
      return false;
    }

    // Reconstruct creator's X25519 key pair
    final x25519 = X25519();
    final creatorKeyPair = SimpleKeyPairData(
      tempKeys.privateKey,
      publicKey: SimplePublicKey(tempKeys.publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );

    // Classical ECDH
    final classicalSharedSecret = await x25519.sharedSecretKey(
      keyPair: creatorKeyPair,
      remotePublicKey: SimplePublicKey(
        acceptorX25519Pub,
        type: KeyPairType.x25519,
      ),
    );
    final classicalSharedBytes = Uint8List.fromList(
      await classicalSharedSecret.extractBytes(),
    );

    // PQ KEM decapsulate
    final pqSharedBytes = await _cryptoService.kemDecapsulate(
      kemCiphertext,
      pqPrivKey,
    );

    // Derive enc_key
    final encKey = await _deriveEncKey(classicalSharedBytes, pqSharedBytes);
    final recipientTag = await _cryptoService.computeAliasRecipientTag(encKey);

    // Persist enc_key + recipientTag and erase temp keys
    await _aliasKeyService.storeEncKey(
      inviteSecret,
      encKey: encKey,
      recipientTag: recipientTag,
    );
    await _aliasKeyService.eraseTempKeys(inviteSecret);

    // Activate channel in DB
    await _cache.updateAliasChatStatus(inviteSecret, AliasChannelStatus.active);

    // Register recipientTag with indexer
    await _registerTag(inviteSecret, recipientTag);

    return true;
  }

  // ---------------------------------------------------------------------------
  // Step 4: Messaging
  // ---------------------------------------------------------------------------

  /// Send an alias message. Encrypted with the shared enc_key.
  Future<void> sendAliasMessage({
    required String inviteSecret,
    required String plaintext,
  }) async {
    final chat = await _cache.getAliasChat(inviteSecret);
    if (chat == null || chat.status != AliasChannelStatus.active) {
      throw StateError('Alias chat not active');
    }

    final encKey = await _aliasKeyService.getEncKey(inviteSecret);
    if (encKey == null) throw StateError('enc_key not found for $inviteSecret');
    final recipientTag = await _aliasKeyService.getRecipientTag(inviteSecret);
    if (recipientTag == null) {
      throw StateError('recipientTag not found for $inviteSecret');
    }

    final payload = {
      'content': plaintext,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    final plainBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final ciphertext = await _cryptoService.encryptWithEncKey(
      encKey: encKey,
      plainTextBytes: plainBytes,
    );

    // Send as a standard message note — senderEncryptionPubkey is random
    // (dummy) so the sender is unlinkable on-chain
    final txId = await _chainClient.sendMessage(
      recipientTag: recipientTag,
      ciphertext: ciphertext,
      senderEncryptionPubkey: _randomBytes(32),
      recipientWallet: ALIAS_GLOBAL_WALLET,
    );

    await _cache.saveAliasMessage(
      AliasMessage(
        id: txId,
        inviteSecret: inviteSecret,
        content: plaintext,
        timestamp: DateTime.now(),
        isOutgoing: true,
        onChainRef: txId,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 5: Sync incoming alias messages
  // ---------------------------------------------------------------------------

  /// Sync all active alias channels against the global wallet transaction log.
  /// Returns total number of new messages stored.
  Future<int> syncAliasMessages() async {
    final chats = await _cache.getAllAliasChats();
    if (chats.isEmpty) return 0;

    // Fetch all notes from the global wallet once (shared across all channels)
    final allNotes = await _chainClient.fetchMemoMessagesForAddress(
      ALIAS_GLOBAL_WALLET,
    );

    int totalNew = 0;
    for (final chat in chats) {
      if (chat.status != AliasChannelStatus.active) continue;

      try {
        final count = await _syncMessagesForChat(chat, allNotes);
        totalNew += count;
      } catch (e) {
        debugPrint(
          '[ALIAS-SYNC] Error syncing channel ${chat.inviteSecret}: $e',
        );
      }
    }

    if (totalNew > 0) {
      debugPrint('[ALIAS-SYNC] Total new alias messages: $totalNew');
    }
    return totalNew;
  }

  Future<int> _syncMessagesForChat(
    AliasChat chat,
    List<Map<String, dynamic>> allNotes,
  ) async {
    final encKey = await _aliasKeyService.getEncKey(chat.inviteSecret);
    if (encKey == null) return 0;
    final recipientTag = await _aliasKeyService.getRecipientTag(
      chat.inviteSecret,
    );
    if (recipientTag == null) return 0;

    int newCount = 0;
    for (final note in allNotes) {
      final noteTag = note['recipient_tag'] as Uint8List?;
      if (noteTag == null) continue;
      if (!_constantTimeEquals(noteTag, recipientTag)) continue;

      final txId = note['accountPubkey'] as String;
      if (await _cache.hasAliasMessage(txId)) continue;

      final ciphertext = note['ciphertext'] as Uint8List;
      final timestamp = note['timestamp'] as int;

      try {
        final decrypted = await _cryptoService.decryptWithEncKey(
          encKey: encKey,
          cipherText: ciphertext,
        );
        final payload =
            jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
        final content = payload['content'] as String? ?? '';

        await _cache.saveAliasMessage(
          AliasMessage(
            id: txId,
            inviteSecret: chat.inviteSecret,
            content: content,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
            isOutgoing: false,
            isRead: false,
            onChainRef: txId,
          ),
        );
        newCount++;
      } catch (e) {
        debugPrint('[ALIAS-SYNC] Decrypt failed for $txId: $e');
      }
    }
    return newCount;
  }

  // ---------------------------------------------------------------------------
  // Step 6: Destroy
  // ---------------------------------------------------------------------------

  /// Permanently destroy an alias chat: wipe keys + DB entries.
  Future<void> destroyAliasChat(String inviteSecret) async {
    // Unregister from indexer (best effort)
    try {
      await _indexerService?.unregisterAliasTag(channelId: inviteSecret);
    } catch (_) {}

    // Wipe all key material
    await _aliasKeyService.deleteAll(inviteSecret);

    // Remove from local DB
    await _cache.deleteAliasChat(inviteSecret);
  }

  // ---------------------------------------------------------------------------
  // Status probe (lightweight — local cache only)
  // ---------------------------------------------------------------------------

  /// Return the current status of a channel from local cache.
  /// No network calls — just checks what the device already knows.
  Future<AliasChannelStatus> probeInviteStatus({
    required String inviteSecret,
  }) async {
    final local = await _cache.getAliasChat(inviteSecret);
    if (local == null) return AliasChannelStatus.pending;
    return local.status;
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  Future<AliasChat?> getAliasChat(String inviteSecret) =>
      _cache.getAliasChat(inviteSecret);

  Future<List<AliasChat>> getAllAliasChats() => _cache.getAllAliasChats();

  Future<List<AliasMessage>> getMessages(String inviteSecret) =>
      _cache.getAliasMessages(inviteSecret);

  Future<List<AliasConversationPreview>> getConversationPreviews() =>
      _cache.getAliasConversationPreviews();

  Future<void> markAsRead(String inviteSecret) =>
      _cache.markAliasMessagesAsRead(inviteSecret);

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Uint8List _inviteSecretBytes(String inviteSecret) =>
      Uint8List.fromList(base64Url.decode(inviteSecret));

  /// Compute HMAC-SHA256(secretBytes, label) — used for discovery tags.
  Future<Uint8List> _computeDiscoveryTag(
    Uint8List secretBytes,
    String label,
  ) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode(label),
      secretKey: SecretKey(secretBytes),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// SHA256(secretBytes) → 32-byte discovery encryption key.
  Future<Uint8List> _discoveryKey(Uint8List secretBytes) async {
    final hash = await Sha256().hash(secretBytes);
    return Uint8List.fromList(hash.bytes);
  }

  /// Encrypt [payload] with AES-GCM keyed by SHA256(inviteSecret).
  Future<Uint8List> _encryptWithDiscoveryKey(
    Uint8List secretBytes,
    Uint8List payload,
  ) async {
    final key = await _discoveryKey(secretBytes);
    return _cryptoService.encryptWithEncKey(
      encKey: key,
      plainTextBytes: payload,
    );
  }

  /// Decrypt [ciphertext] with AES-GCM keyed by SHA256(inviteSecret).
  Future<Uint8List> _decryptWithDiscoveryKey(
    Uint8List secretBytes,
    Uint8List ciphertext,
  ) async {
    final key = await _discoveryKey(secretBytes);
    return _cryptoService.decryptWithEncKey(
      encKey: key,
      cipherText: ciphertext,
    );
  }

  /// Scan [walletAddress] for a discovery note matching [inviteSecret]+[label].
  /// Returns the decrypted payload or null if not found.
  Future<Uint8List?> _findDiscoveryNote(
    Uint8List secretBytes,
    String label,
    String walletAddress,
  ) async {
    final expectedTag = await _computeDiscoveryTag(secretBytes, label);
    final notes = await _chainClient.fetchMemoMessagesForAddress(
      walletAddress,
      limit: 200,
    );

    for (final note in notes) {
      final tag = note['recipient_tag'] as Uint8List?;
      if (tag == null) continue;
      if (!_constantTimeEquals(tag, expectedTag)) continue;

      final ciphertext = note['ciphertext'] as Uint8List;
      try {
        return await _decryptWithDiscoveryKey(secretBytes, ciphertext);
      } catch (_) {
        continue; // try next matching note in case of collision
      }
    }
    return null;
  }

  /// Derive enc_key from classical ECDH bytes + PQ shared secret bytes.
  Future<Uint8List> _deriveEncKey(
    Uint8List classicalSharedBytes,
    Uint8List pqSharedBytes,
  ) async {
    final combined = Uint8List.fromList([
      ...classicalSharedBytes,
      ...pqSharedBytes,
    ]);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derivedKey = await hkdf.deriveKey(
      secretKey: SecretKey(combined),
      info: utf8.encode('sealed-hybrid-aes-gcm-v1'),
    );
    return Uint8List.fromList(await derivedKey.extractBytes());
  }

  /// Register the alias recipientTag with the indexer (best effort).
  Future<void> _registerTag(String inviteSecret, Uint8List recipientTag) async {
    try {
      await _indexerService?.registerAliasTag(
        channelId: inviteSecret,
        recipientTag: recipientTag,
      );
    } catch (e) {
      debugPrint('[ALIAS] Failed to register tag with indexer: $e');
    }
  }

  Uint8List _randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}
