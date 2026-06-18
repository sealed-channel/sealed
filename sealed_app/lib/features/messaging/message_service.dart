/// Message sending, receiving, and synchronization orchestrator.
///
/// Public API surface for all messaging interactions. Internally composes:
///   • [MessageSender]        — send pipeline (text, raw bytes, alias)
///   • [MessageSync]          — chain scan + decrypt + alias scan
///   • [MessageKemHandshake]  — post-quantum key exchange
///   • message_codec.dart     — pure framing / padding / gzip helpers
///
/// Sync model: silent push wake → chain scan keyed by (SEALED_APP_ID,
/// recipient_tag). No WebSocket; no HTTP polling.
library;

import 'dart:async';
import 'package:sealed_app/core/log.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_onboarding_service.dart';
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/messaging/message_sender.dart';
import 'package:sealed_app/features/messaging/message_sync.dart';
import 'package:sealed_app/infra/network/indexer_service.dart';
import 'package:sealed_app/features/wallet/credits_service.dart';
import 'package:sealed_app/features/identity/user_service.dart';

// Re-export sync enums + blacklist so existing callers can keep importing
// them from message_service.dart.
export 'package:sealed_app/features/messaging/message_sync.dart'
    show SyncLayer, SyncStatus, kBlacklistedTxIds;

class MessageService {
  final SealedChainClient sealedClient;
  final CryptoService cryptoService;
  final KeyService keyService;
  final UserService userService;
  final ContactRepository contacts;
  final SyncRepository syncState;
  final MessageRepository messageCache;
  final IndexerService? indexerService;

  // Alias chat support (optional)
  final AliasKeyService? aliasKeyService;
  final AliasOnboardingService? aliasOnboardingService;

  final CreditsService? creditsService;

  // Internal collaborators.
  late final MessageKemHandshake _kem;
  late final MessageSender _sender;
  late final MessageSync _sync;

  MessageService({
    required this.syncState,
    required this.sealedClient,
    required this.cryptoService,
    required this.userService,
    required this.contacts,
    required this.keyService,
    required this.messageCache,
    this.indexerService,
    this.aliasKeyService,
    this.aliasOnboardingService,
    this.creditsService,
  }) {
    _kem = MessageKemHandshake(
      sealedClient: sealedClient,
      cryptoService: cryptoService,
      keyService: keyService,
      contacts: contacts,
    );
    _sender = MessageSender(
      sealedClient: sealedClient,
      cryptoService: cryptoService,
      keyService: keyService,
      userService: userService,
      contacts: contacts,
      messageCache: messageCache,
      kem: _kem,
      creditsService: creditsService,
    );
    _sync = MessageSync(
      sealedClient: sealedClient,
      cryptoService: cryptoService,
      keyService: keyService,
      contacts: contacts,
      messageCache: messageCache,
      syncState: syncState,
      kem: _kem,
      indexerService: indexerService,
      aliasOnboardingService: aliasOnboardingService,
    );
  }

  // ===========================================================================
  // CALLBACKS
  // ===========================================================================
  //
  // Backed by the [MessageSync] collaborator so subscribers wired here are
  // dispatched from the sync pipeline.

  set onSyncStatusChanged(void Function(SyncStatus status)? cb) =>
      _sync.onSyncStatusChanged = cb;
  void Function(SyncStatus status)? get onSyncStatusChanged =>
      _sync.onSyncStatusChanged;

  set onNewMessageReceived(void Function(DecryptedMessage message)? cb) =>
      _sync.onNewMessageReceived = cb;
  void Function(DecryptedMessage message)? get onNewMessageReceived =>
      _sync.onNewMessageReceived;

  set onAliasMessageReceived(void Function()? cb) =>
      _sync.onAliasMessageReceived = cb;
  void Function()? get onAliasMessageReceived => _sync.onAliasMessageReceived;

  // ===========================================================================
  // GETTERS
  // ===========================================================================

  SyncStatus get syncStatus => _sync.syncStatus;
  SyncLayer? get lastSuccessfulLayer => _sync.lastSuccessfulLayer;
  bool get isIndexerAvailable => indexerService != null;

  // ===========================================================================
  // PUSH WAKE-UP HOOK
  // ===========================================================================

  /// Invoke when a silent push arrives. Runs a single chain scan; the push
  /// payload itself is treated only as a wake signal.
  Future<void> onPushWakeup() async {
    if (kDebugMode) Log.d('[MessageService] ⚡ push wake-up → syncMessages()');
    try {
      await syncMessages();
    } catch (e) {
      if (kDebugMode) Log.d('[MessageService] ❌ push wake-up sync failed: $e');
    }
  }

  // ===========================================================================
  // SEND — delegated to MessageSender
  // ===========================================================================

  Future<String> sendMessage({
    required String recipientWallet,
    String? recipientUsername,
    required String plaintext,
    required String senderWallet,
  }) => _sender.sendMessage(
    recipientWallet: recipientWallet,
    recipientUsername: recipientUsername,
    plaintext: plaintext,
    senderWallet: senderWallet,
  );

  Future<String> sendMessageBytes({
    required String recipientWallet,
    required Uint8List plaintextBytes,
    required String senderWallet,
  }) => _sender.sendMessageBytes(
    recipientWallet: recipientWallet,
    plaintextBytes: plaintextBytes,
    senderWallet: senderWallet,
  );

  Future<String> sendAliasMessage({
    required String contactId,
    required String plaintext,
  }) => _sender.sendAliasMessage(contactId: contactId, plaintext: plaintext);

  // ===========================================================================
  // SYNC — delegated to MessageSync
  // ===========================================================================

  Future<int> syncMessages({
    bool fullSync = false,
    SyncLayer? preferredLayer,
  }) => _sync.syncMessages(fullSync: fullSync, preferredLayer: preferredLayer);

  /// Decrypt + persist a batch of push pre-staged raw messages without fetching
  /// or advancing the cursor (the [WakeStageStore] drain path). Idempotent.
  Future<int> ingestRawMessages(List<Map<String, dynamic>> messages) =>
      _sync.ingestRawMessages(messages);

  /// New-message count of the last completed sync MINUS messages from blocked
  /// senders. Feed THIS (not [syncMessages]'s return value) to the local
  /// notification path so blocked senders don't ping; the full count keeps
  /// driving UI refresh so the Spam tab stays live.
  int get lastNotifiableCount => _sync.lastNotifiableCount;

  Future<void> forceResync(SyncLayer layer) => _sync.forceResync(layer);

  // ===========================================================================
  // ALIAS CONTACT MANAGEMENT
  // ===========================================================================

  /// Enumerate the contact ids of every alias chat. Used by the bulk
  /// "delete all alias chats" flow to feed [deleteAliasContact] one id at a
  /// time. Tolerates an empty registry (returns an empty list).
  Future<List<String>> getAllAliasContacts() async {
    final aliasContacts = await contacts.getAllAliasContacts();
    return aliasContacts.map((c) => c.contactId).toList();
  }

  /// Delete an alias contact: erase local key material, remove repo row +
  /// messages.
  ///
  /// If the user had opted this contact in to per-alias push, unregister its
  /// scan_priv from the indexer registry **before** wiping the alias key
  /// material — otherwise the key needed to derive the blinded_id is gone
  /// and the indexer row leaks until the next bulk cleanup.
  Future<void> deleteAliasContact(String contactId) async {
    // Best-effort push unregister. Reads the per-alias flag from settings;
    // skipped silently if the indexer service / settings aren't wired (tests
    // or partial-init paths).
    try {
      final indexer = indexerService;
      final aliasKeys = aliasKeyService;
      final settings = indexer?.appSettings;
      if (indexer != null &&
          aliasKeys != null &&
          settings != null &&
          settings.getAliasPushEnabled(contactId)) {
        final scanPriv = await aliasKeys.loadAliasScanPrivForContact(contactId);
        if (scanPriv != null) {
          await indexer.unregisterAliasViewKey(aliasScanPriv: scanPriv);
        }
        await settings.setAliasPushEnabled(contactId, false);
      }
    } catch (e) {
      if (kDebugMode) {
        Log.d('[MessageService] ⚠️ alias push unregister on delete failed: $e');
      }
    }

    // Erase all key material from secure storage.
    if (aliasKeyService != null) {
      final inviteSecret = await aliasKeyService!.loadInviteSecretForContact(
        contactId,
      );
      if (inviteSecret != null) {
        await aliasKeyService!.deleteAll(inviteSecret);
      }
      await aliasKeyService!.eraseInviteSecretForContact(contactId);
    }
    await contacts.deleteAliasContact(contactId);
  }

  // ===========================================================================
  // CONVERSATION READS
  // ===========================================================================

  /// Return all messages exchanged with [contactWallet], sorted by timestamp.
  Future<List<DecryptedMessage>> getConversation(String contactWallet) async {
    if (kDebugMode) {
      Log.d(
        '[MessageService] 💬 getConversation() - fetching with $contactWallet',
      );
    }
    final messages = await messageCache.getConversationMessages(
      userService.walletAddress!,
      contactWallet,
    );
    if (kDebugMode) {
      Log.d(
        '[MessageService] ✅ Found ${messages.length} messages in conversation',
      );
    }
    return messages;
  }

  /// Return previews for the inbox view (one entry per conversation).
  Future<List<ChatPreview>> getAllConversations() async {
    if (kDebugMode) {
      Log.d(
        '[MessageService] 📋 getAllConversations() - fetching all conversation previews',
      );
    }
    final conversations = await messageCache.getConversations();
    if (kDebugMode) {
      Log.d(
        '[MessageService] ✅ Found ${conversations.length} conversation previews',
      );
    }
    return conversations;
  }

  /// Returns the number of messages flipped to read (0 = nothing was unread).
  Future<int> markConversationAsRead(String contactWallet) async {
    if (kDebugMode) {
      Log.d(
        '[MessageService] 👁️ markConversationAsRead() - marking $contactWallet as read',
      );
    }
    final flipped = await messageCache.markAsRead(contactWallet);
    if (kDebugMode) {
      Log.d('[MessageService] ✅ Conversation marked as read ($flipped rows)');
    }
    return flipped;
  }

  Future<int> getUnreadCount(String contactWallet) async {
    if (kDebugMode) {
      Log.d('[MessageService] 🔔 getUnreadCount() - checking $contactWallet');
    }
    final count = await messageCache.getUnreadCount(contactWallet);
    if (kDebugMode) Log.d('[MessageService] ✅ Unread count: $count');
    return count;
  }
}
