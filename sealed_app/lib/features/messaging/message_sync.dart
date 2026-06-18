/// Sync pipeline: blockchain scan → KEM handshakes → incoming/outgoing
/// decrypt → alias scan. Owned by [MessageService].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;

import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/models/contact.dart' as cmodel;
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/alias/alias_onboarding_service.dart';
import 'package:sealed_app/features/messaging/message_codec.dart' as codec;
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/infra/network/indexer_service.dart';

// =============================================================================
// SYNC STRATEGY
// =============================================================================

enum SyncLayer { blockchain }

enum SyncStatus { idle, syncing, error }

/// Sender-impersonation guard.
///
/// The decrypted payload may carry a sender-CONTROLLED `sender_wallet` claim.
/// The only trustworthy sender identity is [txSender] — the consensus-verified
/// transaction sender. A message is spoofed when the payload asserts a
/// `sender_wallet` that is present (non-null, non-empty) AND disagrees with the
/// chain-verified sender. A missing/empty claim is fine (legacy / uniform
/// envelope) and is NOT treated as spoofing.
bool isSpoofedSender(String? claimedFromPayload, String txSender) {
  if (claimedFromPayload == null || claimedFromPayload.isEmpty) return false;
  return claimedFromPayload != txSender;
}

/// Transaction IDs known to be spam / poisoned broadcast txns. Any message
/// keyed by one of these txids is dropped before decrypt/cache to avoid the
/// "every new wallet syncs the same garbage" problem.
const Set<String> kBlacklistedTxIds = {
  'BE63QFDFBZTZ7T44RJ67UDGEHNKYACII5MBQ6NG7WC5B7HAAIESQ',
  'NG75XUFPALYEQ2OGG5FB7OYACOO6PGUZS5VEMLA4OPGFK2XWULLQ',
  '6LDJOKGEL2EGRV72JFAQZAKPYXO2N7WJ5NDV2YN6ZP2SOCXHIPBA',
  'KFX55BL44SUAFNBOXL2KGFWG3SCNM3HKBWZOWSHQMQFXOT52UNRQ',
  'MQOXVRR636L2JAKAFY2QOAYVMDIW4FXWLDXK43RTFB7RIYDK5F7A',
};

class MessageSync {
  final SealedChainClient sealedClient;
  final CryptoService cryptoService;
  final KeyService keyService;
  final ContactRepository contacts;
  final MessageRepository messageCache;
  final SyncRepository syncState;
  final MessageKemHandshake kem;
  final IndexerService? indexerService;
  final AliasOnboardingService? aliasOnboardingService;

  // Sync state
  SyncStatus _syncStatus = SyncStatus.idle;
  SyncLayer? _lastSuccessfulLayer;
  Future<int>? _activeSync;
  bool _isForceResyncInProgress = false;

  // Notification mute for blocked senders: messages from a blocked wallet are
  // still decrypted + stored (they surface in the Spam tab), but they must not
  // wake a local notification. `syncMessages`'s return value stays the FULL
  // new-message count (drives UI refresh, incl. Spam tab); this field carries
  // the count minus blocked-sender messages for the notification path.
  // Note: concurrent callers joined onto `_activeSync` read the same last-run
  // value — acceptable, they observe the run they awaited.
  int _lastNotifiableCount = 0;
  int get lastNotifiableCount => _lastNotifiableCount;

  // Per-run counter of stored messages from blocked senders. Reset at the
  // start of each `_syncViaBlockchain` pass.
  int _runBlockedCount = 0;
  // Per-run blocked-state cache (one repo lookup per sender per sync).
  final Map<String, bool> _blockedBySender = {};

  // ms-epoch of this install (cached). Alias invites older than this are not
  // resurfaced — see [_handleInviteEnvelope]. 0 = pre-migration install (no gate).
  int? _installEpoch;
  Future<int> _getInstallEpoch() async =>
      _installEpoch ??= await messageCache.getInstallEpoch();

  @visibleForTesting
  int get debugRunBlockedCount => _runBlockedCount;

  Future<bool> _isSenderBlocked(String senderWallet) async {
    final cached = _blockedBySender[senderWallet];
    if (cached != null) return cached;
    bool blocked;
    try {
      blocked = await contacts.isBlocked(senderWallet);
    } catch (_) {
      blocked = false; // fail open: never silently swallow a notification
    }
    _blockedBySender[senderWallet] = blocked;
    return blocked;
  }

  // Callbacks for UI updates
  void Function(SyncStatus status)? onSyncStatusChanged;
  void Function(DecryptedMessage message)? onNewMessageReceived;
  void Function()? onAliasMessageReceived;

  MessageSync({
    required this.sealedClient,
    required this.cryptoService,
    required this.keyService,
    required this.contacts,
    required this.messageCache,
    required this.syncState,
    required this.kem,
    this.indexerService,
    this.aliasOnboardingService,
  });

  SyncStatus get syncStatus => _syncStatus;
  SyncLayer? get lastSuccessfulLayer => _lastSuccessfulLayer;
  Future<int>? get activeSync => _activeSync;

  Future<int> syncMessages({
    bool fullSync = false,
    SyncLayer? preferredLayer,
  }) async {
    if (_isForceResyncInProgress && !fullSync) {
      if (kDebugMode) {
        Log.d(
          '[MessageSync] ⏸️ syncMessages() skipped: force resync in progress',
        );
      }
      return 0;
    }

    // Avoid overlapping sync executions (e.g. poll tick during forceResync).
    if (_activeSync != null) {
      if (kDebugMode) {
        Log.d('[MessageSync] ⏳ syncMessages() already running, waiting...');
      }
      return await _activeSync!;
    }

    final future = _syncMessages(
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

  Future<int> _syncMessages({
    required bool fullSync,
    required SyncLayer? preferredLayer,
  }) async {
    debugPrint(
      '[MessageSync] 🔄 syncMessages() START (fullSync: $fullSync, preferredLayer: $preferredLayer)',
    );

    // Load keys up front. If the device is locked or keys are missing, abort
    // WITHOUT touching status or the cursor — the app's PIN gate prompts the
    // unlock, and the next sync resumes from the same cursor (doc: "Keys
    // missing / device locked → Sync aborts"). Advancing the cursor here would
    // skip every message that arrived while locked.
    final myKeys = await keyService.loadKeys();
    if (myKeys == null) {
      Log.d('[MessageSync] 🔒 keys unavailable — sync aborted, cursor held');
      return 0;
    }

    _syncStatus = SyncStatus.syncing;
    onSyncStatusChanged?.call(_syncStatus);

    try {
      int? sinceTimestamp;
      if (!fullSync) {
        final lastSync = await syncState.lastSyncTime;
        // Add 5 minute buffer to avoid missing messages due to clock drift.
        final bufferedTime = lastSync.subtract(const Duration(minutes: 5));
        sinceTimestamp = bufferedTime.millisecondsSinceEpoch ~/ 1000;
        if (kDebugMode) {
          Log.d(
            '[MessageSync] ⏰ Last sync: $lastSync (checking from $bufferedTime)',
          );
        }
      } else {
        // Full sync must explicitly use 0 so indexer fetches complete history.
        sinceTimestamp = 0;
        if (kDebugMode) {
          Log.d('[MessageSync] 🔄 Full sync - fetching ALL messages');
        }
      }

      const layer = SyncLayer.blockchain;
      debugPrint(
        '[MessageSync] 📡 Using sync layer: $layer, sinceTimestamp: $sinceTimestamp',
      );

      final newCount = await _syncViaBlockchain(sinceTimestamp, myKeys);
      _lastSuccessfulLayer = SyncLayer.blockchain;

      // Advance the cursor ONLY after a fully successful scan. If
      // _syncViaBlockchain threw (e.g. a fetch failed), we skip this and the
      // cursor holds so the next sync re-scans the same window — no loss.
      await syncState.updateLastSyncTime(DateTime.now());
      _syncStatus = SyncStatus.idle;
      debugPrint(
        '[MessageSync] ✅ syncMessages() COMPLETE - synced $newCount messages via $layer\n',
      );
      return newCount;
    } catch (e) {
      _syncStatus = SyncStatus.error;
      Log.e('[MessageSync] sync failed — cursor held', e);
      rethrow;
    } finally {
      onSyncStatusChanged?.call(_syncStatus);
    }
  }

  // ===========================================================================
  // LAYER 1: SYNC VIA BLOCKCHAIN
  // ===========================================================================

  Future<int> _syncViaBlockchain(int? sinceTimestamp, SealedKeys myKeys) async {
    if (kDebugMode) Log.d('[MessageSync] 🔗 _syncViaBlockchain() START');

    _runBlockedCount = 0;
    _blockedBySender.clear();

    // Single shared fetch — used by KEM processing, incoming decrypt, and
    // alias scanning. Eliminates redundant RPCs per sync round.
    final rawMessages = await sealedClient.fetchMessages(
      sinceTimestamp: sinceTimestamp,
    );

    // Drop blacklisted txids before any decrypt / KEM / cache work.
    final messages = rawMessages.where((m) {
      final txid = m['accountPubkey'] as String?;
      if (txid != null && kBlacklistedTxIds.contains(txid)) {
        if (kDebugMode) {
          Log.d('[MessageSync] 🚫 blacklisted txid skipped: $txid');
        }
        return false;
      }
      return true;
    }).toList();

    // Process KEM handshakes first so PQ secrets are available before decrypt.
    // Hybrid first-message frames also surface a [DecryptedMessage] — store
    // them HERE (before _syncIncomingMessages) so the regular decrypt pass
    // can't race a duplicate insert. saveMessage uses REPLACE conflict
    // resolution keyed on `id`, so a re-sync of the same txid is a no-op.
    final kemResult = await kem.processKemHandshakes(messages);
    final kemSaved = kemResult.kemSaved;
    final hybridStored = await storeHybridMessages(kemResult.hybridMessages);
    if (kDebugMode) {
      Log.d(
        '[MessageSync] 🔑 KEM saved=$kemSaved '
        'hybridMessages=${kemResult.hybridMessages.length} '
        'hybridStored(new)=$hybridStored',
      );
    }

    if (kDebugMode) {
      final myPq = await keyService.loadPqKeys();
      final myAddr = sealedClient.wallet.walletAddress;
      if (myPq != null && myAddr != null) {
        final localFp = base64Encode(
          crypto_pkg.sha256.convert(myPq.publicKey).bytes.sublist(0, 8),
        );
        String onChainFp = 'null';
        try {
          final profile = await sealedClient.getUserByWallet(myAddr);
          final hash = profile?.pqPubkeyHash;
          onChainFp = hash == null ? 'null' : base64Encode(hash.sublist(0, 8));
        } catch (_) {}
        Log.d(
          '[MessageSync] 🧬 PQ key alignment localFp=$localFp onChainFp=$onChainFp '
          'aligned=${localFp == onChainFp}',
        );
      }
    }
    final incomingCount = await _syncIncomingMessages(
      messages: messages,
      myKeys: myKeys,
    );

    final outgoingCount = await _syncOutgoingMessages(
      sinceTimestamp: sinceTimestamp,
      myKeys: myKeys,
    );

    final aliasCount = await _syncAliasIncoming(messages: messages);

    final newCount = hybridStored + incomingCount + outgoingCount + aliasCount;
    // Notifiable = newly-arrived INCOMING messages only, minus blocked senders.
    // Outgoing self-copies (your own sends, incl. into a spam/blocked thread)
    // must never raise a notification, so they're excluded here. Alias messages
    // have no block concept and stay notifiable.
    _lastNotifiableCount =
        (hybridStored + incomingCount + aliasCount) - _runBlockedCount;
    if (_lastNotifiableCount < 0) _lastNotifiableCount = 0;
    if (kDebugMode) {
      Log.d(
        '[MessageSync] 🔗 _syncViaBlockchain() COMPLETE - $newCount messages '
        '(notifiable: $_lastNotifiableCount)',
      );
    }
    return newCount;
  }

  /// Decrypt + persist a caller-supplied batch of raw on-chain messages WITHOUT
  /// fetching or advancing the cursor — the drain path for push pre-staged
  /// envelopes ([WakeStageStore]). Reuses the exact decrypt-and-save pipeline
  /// (`_syncViaBlockchain`'s incoming half): KEM handshakes, hybrid first
  /// frames, steady-state incoming, and alias envelopes. Idempotent — txids
  /// already in the DB dedupe to a no-op, so a staged message that also arrives
  /// via a normal sync yields exactly one row. Returns the new-row count.
  Future<int> ingestRawMessages(List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty) return 0;
    final myKeys = await keyService.loadKeys();
    if (myKeys == null) return 0; // locked / missing keys → caller retries

    _runBlockedCount = 0;
    _blockedBySender.clear();

    final kemResult = await kem.processKemHandshakes(messages);
    final hybridStored = await storeHybridMessages(kemResult.hybridMessages);
    final incomingCount = await _syncIncomingMessages(
      messages: messages,
      myKeys: myKeys,
    );
    final aliasCount = await _syncAliasIncoming(messages: messages);
    return hybridStored + incomingCount + aliasCount;
  }

  /// Persist hybrid first-message [DecryptedMessage]s surfaced by
  /// [MessageKemHandshake.processKemHandshakes]. Returns the count of
  /// rows that were genuinely new (existing txids dedupe to no-op).
  ///
  /// Visible for tests so the idempotency contract can be exercised
  /// without driving the full `_syncViaBlockchain` fan-out.
  @visibleForTesting
  Future<int> storeHybridMessages(List<DecryptedMessage> hybrid) async {
    int stored = 0;
    for (final hm in hybrid) {
      // Skip rows we already hold. saveMessage upserts with
      // ConflictAlgorithm.replace and is_read = 0 for incoming, so
      // re-saving an existing message silently wipes its read flag.
      if (await messageCache.hasMessage(hm.onChainPubkey)) continue;
      await messageCache.saveMessage(hm);
      stored++;
      if (!hm.isOutgoing && await _isSenderBlocked(hm.senderWallet)) {
        _runBlockedCount++;
      }
    }
    return stored;
  }

  // ===========================================================================
  // SYNC ALIAS INCOMING
  // ===========================================================================
  Future<int> _syncAliasIncoming({
    required List<Map<String, dynamic>> messages,
  }) async {
    final aliasContacts = await contacts.getAllAliasContacts();
    if (aliasContacts.isEmpty) return 0;
    if (messages.isEmpty) return 0;

    int newCount = 0;

    for (final c in aliasContacts) {
      // Reconstruct scan + enc keypairs from stored raw private key bytes.
      final x25519 = X25519();
      final scanKp = await x25519.newKeyPairFromSeed(c.keys.myX25519ScanSk);
      final encKp = await x25519.newKeyPairFromSeed(c.keys.myX25519Sk);

      // Load this contact's existing message ids ONCE per contact, not once per
      // (contact × on-chain message) — the inner getContactMessages() call was
      // an O(aliasContacts × chainMsgs) full-table read every sync tick.
      final existingIds = <String>{
        for (final m in await contacts.getContactMessages(c.contactId)) m.id,
      };

      for (final message in messages) {
        final txId = message['accountPubkey'] as String;

        // Skip if already stored in contact_messages.
        if (existingIds.contains(txId)) continue;

        final ephemeralPub = message['senderEncryptionPubkey'] as Uint8List;
        final tagBytes = message['recipientTag'] as Uint8List;
        final paddedCt = message['ciphertext'] as Uint8List;
        final ts = message['timestamp'] as int;

        bool isForMe = false;
        try {
          isForMe = await cryptoService.checkRecipientTag(
            senderEncryptionPubkey: ephemeralPub,
            recipientTag: tagBytes,
            myScanKeyPair: scanKp,
          );
        } catch (_) {
          continue;
        }
        if (!isForMe) continue;

        try {
          final combined = codec.unpad(paddedCt);
          Uint8List ct;
          try {
            ct = codec.splitCiphertexts(combined).recipientCt;
          } catch (_) {
            ct = combined;
          }

          Uint8List decrypted;
          try {
            decrypted = await cryptoService.decryptHybrid(
              encryptionKeyPair: encKp,
              senderEncryptionPubkey: ephemeralPub,
              cipherText: ct,
              pqSharedSecret: c.keys.pqSharedSecret,
            );
          } catch (_) {
            decrypted = await cryptoService.decryptHybrid(
              encryptionKeyPair: encKp,
              senderEncryptionPubkey: ephemeralPub,
              cipherText: ct,
              pqSharedSecret: null,
            );
          }

          final decompressed = codec.gzipDecompress(decrypted);
          final payload = codec.parseMessagePayload(utf8.decode(decompressed));
          final content = payload['content'] as String? ?? '';

          await contacts.saveContactMessage(
            cmodel.ContactMessage(
              id: txId,
              contactId: c.contactId,
              direction: 0, // incoming
              content: content,
              timestamp: ts * 1000, // store as ms
              isRead: false,
            ),
          );
          newCount++;
          onAliasMessageReceived?.call();
        } catch (_) {
          continue;
        }
      }
    }

    return newCount;
  }

  // ===========================================================================
  // SYNC INCOMING MESSAGES (messages sent TO me)
  // ===========================================================================
  Future<int> _syncIncomingMessages({
    required List<Map<String, dynamic>> messages,
    required SealedKeys myKeys,
  }) async {
    int newCount = 0;
    int failCount = 0;

    final walletDerivedKeyPair = await keyService
        .getWalletDerivedX25519KeyPair();

    // Per-sender pqSecret cache to avoid hitting the contacts repo on every message.
    final pqSecretBySender = <String, Uint8List?>{};
    // Per-sender on-chain username cache for UNKNOWN peers (no contact row).
    // One chain lookup per new sender per sync run — see usage below.
    final chainUsernameBySender = <String, String?>{};

    // Pre-load which of these txids we already hold in ONE query, instead of a
    // per-message hasMessage() SELECT (was N round trips per sync pass).
    final existingIds = await messageCache.existingMessageIds([
      for (final m in messages) m['accountPubkey'] as String,
    ]);

    for (final message in messages) {
      final txSignature = message['accountPubkey'] as String;
      if (kBlacklistedTxIds.contains(txSignature)) continue;
      if (existingIds.contains(txSignature)) continue;

      final senderAddress = (message['senderAddress'] as String);
      final paddedCiphertext = message['ciphertext'] as Uint8List;
      final senderEphemeralPubkey =
          message['senderEncryptionPubkey'] as Uint8List;
      final recipientTag = message['recipientTag'] as Uint8List;
      final timestamp = message['timestamp'] as int;
      if (senderAddress == myKeys.walletAddress) continue;

      // Primary: HKDF-derived scan key.
      bool isForMe = await cryptoService.checkRecipientTag(
        senderEncryptionPubkey: senderEphemeralPubkey,
        recipientTag: recipientTag,
        myScanKeyPair: myKeys.scanKeyPair,
      );

      // Fallback: wallet-derived X25519 scan key (legacy senders).
      bool usedWalletDerivedKeys = false;
      if (!isForMe && walletDerivedKeyPair != null) {
        isForMe = await cryptoService.checkRecipientTag(
          senderEncryptionPubkey: senderEphemeralPubkey,
          recipientTag: recipientTag,
          myScanKeyPair: walletDerivedKeyPair,
        );
        if (isForMe) usedWalletDerivedKeys = true;
      }
      if (!isForMe) continue;
      Uint8List? pqSecret;
      try {
        final combinedCiphertext = codec.unpad(paddedCiphertext);
        Uint8List ciphertext;
        try {
          final parts = codec.splitCiphertexts(combinedCiphertext);
          ciphertext = parts.recipientCt;
        } catch (_) {
          ciphertext = combinedCiphertext;
        }
        final decryptionKeyPair = usedWalletDerivedKeys
            ? walletDerivedKeyPair!
            : myKeys.encryptionKeyPair;

        if (pqSecretBySender.containsKey(senderAddress)) {
          pqSecret = pqSecretBySender[senderAddress];
        } else {
          pqSecret = (await contacts.getContactKeys(
            senderAddress,
          )).pqSharedSecret;
          pqSecretBySender[senderAddress] = pqSecret;
        }

        // Try hybrid first; fall back to classical-only for free-tier senders
        // that skipped KEM even if we have a cached secret.
        Uint8List decrypted;
        try {
          decrypted = await cryptoService.decryptHybrid(
            encryptionKeyPair: decryptionKeyPair,
            senderEncryptionPubkey: senderEphemeralPubkey,
            cipherText: ciphertext,
            pqSharedSecret: pqSecret,
          );
        } catch (_) {
          // Initiator recovery: after a logout the cached KEM secret is gone.
          // If WE started this chat, re-derive the shared secret by
          // re-encapsulating to the sender's PQ pub with our deterministic
          // nonce, then retry. AEAD auth confirms correctness; cache only on a
          // successful decrypt (a peer-initiated chat or rotated PQ key yields
          // a non-matching secret and never poisons the cache).
          Uint8List? recovered;
          Uint8List? recoveredSecret;
          if (pqSecret == null) {
            final reEncap = await _reEncapsulateSecret(senderAddress);
            if (reEncap != null) {
              try {
                recovered = await cryptoService.decryptHybrid(
                  encryptionKeyPair: decryptionKeyPair,
                  senderEncryptionPubkey: senderEphemeralPubkey,
                  cipherText: ciphertext,
                  pqSharedSecret: reEncap,
                );
                recoveredSecret = reEncap;
              } catch (_) {
                recovered = null;
              }
            }
          }
          if (recovered != null) {
            decrypted = recovered;
            // Cache the recovered secret as a non-fatal side effect — a DB
            // hiccup must not discard a message we already decrypted.
            try {
              await contacts.saveContactKeys(
                senderAddress,
                pqSharedSecret: recoveredSecret,
              );
              pqSecretBySender[senderAddress] = recoveredSecret;
              if (kDebugMode) {
                Log.d(
                  '[MessageSync] 🔓 initiator-recovery: rebuilt KEM secret for '
                  '$senderAddress via re-encapsulation',
                );
              }
            } catch (e) {
              if (kDebugMode) {
                Log.d(
                  '[MessageSync] ⚠️ initiator-recovery cache write failed for '
                  '$senderAddress (message kept): $e',
                );
              }
            }
          } else {
            // Classical-only fallback (free-tier sender skipped KEM).
            decrypted = await cryptoService.decryptHybrid(
              encryptionKeyPair: decryptionKeyPair,
              senderEncryptionPubkey: senderEphemeralPubkey,
              cipherText: ciphertext,
              pqSharedSecret: null,
            );
          }
        }

        // ── Alias onboarding envelope router ──────────────────────────────
        // Envelope bytes are NOT gzip-compressed (random crypto bytes don't
        // compress). Tag byte check before decompress — 0x01/0x02 never
        // appears as first byte of gzip (0x1f 0x8b).
        if (decrypted.isNotEmpty) {
          final tag = decrypted[0];
          if (tag == aliasInviteTagByte) {
            final env = AliasInviteEnvelope.tryParse(decrypted);
            if (env != null) {
              await _handleInviteEnvelope(
                env,
                senderAddress,
                txSignature,
                timestamp,
              );
              newCount++;
              continue;
            }
          } else if (tag == aliasAcceptTagByte) {
            final env = AliasAcceptEnvelope.tryParse(decrypted);
            if (env != null) {
              await _handleAcceptEnvelope(env);
              newCount++;
              continue;
            }
          }
        }
        // ── End envelope router ───────────────────────────────────────────

        final decompressed = codec.gzipDecompress(decrypted);
        final decryptedPayload = utf8.decode(decompressed);
        final payload = codec.parseMessagePayload(decryptedPayload);

        // Unknown sender (no contact row): resolve their on-chain username
        // NOW, at arrival, instead of trusting the sender-declared payload
        // snapshot (stale/absent for fresh peers) or waiting for the periodic
        // refresh — which skips row-less peers entirely. Known contacts are
        // rendered from cc.username in getConversations, so the snapshot
        // doesn't matter for them. Best-effort: chain failure keeps snapshot.
        String? senderUsername = payload['sender_username'] as String?;
        if (!chainUsernameBySender.containsKey(senderAddress)) {
          String? fetched;
          try {
            if (await contacts.getContact(senderAddress) == null) {
              fetched = (await sealedClient.getUserByWallet(
                senderAddress,
              ))?.username;
            }
          } catch (_) {
            fetched = null;
          }
          chainUsernameBySender[senderAddress] = fetched;
        }
        final chainUsername = chainUsernameBySender[senderAddress];
        if (chainUsername != null && chainUsername.isNotEmpty) {
          senderUsername = chainUsername;
        }

        // Sender-impersonation guard. The decrypted payload is sender-
        // controlled; `sender_wallet` is a CLAIM. The only trustworthy sender
        // identity is `senderAddress` (the consensus-verified tx sender, read
        // at the top of the loop). If the payload claims a different wallet,
        // drop the message — storing the claimed wallet would let any sender
        // impersonate another wallet in a trusted thread and bypass the Spam
        // tab (spam routing joins on stored sender_wallet while the block
        // check below uses senderAddress; they must agree).
        final claimedSenderWallet = payload['sender_wallet'] as String?;
        if (isSpoofedSender(claimedSenderWallet, senderAddress)) {
          Log.d(
            '[MessageSync] ⚠️ dropping spoofed sender: '
            'payload=${redactAddr(claimedSenderWallet!)} '
            'tx=${redactAddr(senderAddress)}',
          );
          continue;
        }

        await messageCache.saveMessage(
          DecryptedMessage(
            id: txSignature,
            senderWallet: senderAddress,
            senderUsername: senderUsername,
            recipientWallet: sealedClient.wallet.walletAddress!,
            recipientUsername: payload['recipient_username'] as String?,
            content: payload['content'] as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
            isOutgoing: false,
            onChainPubkey: txSignature,
          ),
        );
        newCount++;
        if (await _isSenderBlocked(senderAddress)) _runBlockedCount++;
      } catch (e) {
        failCount++;
        Log.d(
          '[MessageSync] ❌ incoming decrypt fail tx=$txSignature '
          'sender=${redactAddr(senderAddress)} pqSecretFp=${secretFp(pqSecret)} '
          'usedWalletDerivedKeys=$usedWalletDerivedKeys err=$e',
        );
        continue;
      }
    }

    if (kDebugMode && failCount > 0) {
      Log.d('[MessageSync] ⚠️ _syncIncomingMessages failCount=$failCount');
    }
    return newCount;
  }

  // ===========================================================================
  // SYNC OUTGOING MESSAGES (messages sent BY me)
  // Recovers outgoing messages by decrypting the sender self-copy from RPC.
  // ===========================================================================
  /// Re-derive the KEM shared secret WE encapsulated to [peerWallet] when we
  /// initiated the chat — deterministic re-encapsulation to the peer's PQ pub
  /// (same coins our send used). Returns null if the peer has no resolvable PQ
  /// pubkey. Caller MUST AEAD-verify before trusting/caching: a peer-initiated
  /// chat or a rotated peer PQ key yields a non-matching secret.
  Future<Uint8List?> _reEncapsulateSecret(String peerWallet) async {
    try {
      final peerPqPub = (await contacts.getContactKeys(peerWallet)).pqPublicKey;
      if (peerPqPub == null) return null;
      final nonce = await keyService.deriveKemEncapsNonce(peerPqPub);
      final result = await cryptoService.kemEncapsulate(
        peerPqPub,
        nonce: nonce,
      );
      return result.sharedSecret;
    } catch (_) {
      return null;
    }
  }

  Future<int> _syncOutgoingMessages({
    int? sinceTimestamp,
    required SealedKeys myKeys,
  }) async {
    int newCount = 0;
    final messages = await sealedClient.fetchMessagesFromSender(
      sealedClient.wallet.walletAddress!,
      sinceTimestamp: sinceTimestamp,
    );

    for (final message in messages) {
      final txSignature = message['accountPubkey'] as String;
      if (kBlacklistedTxIds.contains(txSignature)) continue;

      if (await messageCache.hasMessage(txSignature)) {
        continue;
      }

      try {
        final paddedCiphertext = message['ciphertext'] as Uint8List;
        final senderEphemeralPubkey =
            message['senderEncryptionPubkey'] as Uint8List;

        // KEM handshakes and alias notes skip _pad framing — bail quietly
        // when the memo header doesn't match the v2 layout.
        Uint8List combinedCiphertext;
        try {
          combinedCiphertext = codec.unpad(paddedCiphertext);
        } on ArgumentError {
          continue;
        }
        final parts = codec.splitCiphertexts(combinedCiphertext);

        // No sender self-copy (envelope DMs use recipient-only ciphertext).
        if (parts.senderCt.isEmpty) continue;

        final payload = await _decrypt(
          encryptionKeyPair: myKeys.encryptionKeyPair,
          senderEphemeralPubkey: senderEphemeralPubkey,
          ciphertext: parts.senderCt,
        );
        await messageCache.saveMessage(
          DecryptedMessage(
            id: txSignature,
            senderWallet:
                sealedClient.wallet.walletAddress ?? myKeys.walletAddress,
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
      } catch (e, st) {
        if (kDebugMode) {
          Log.d(
            '[MessageSync] ❌ outgoing decrypt fail tx=$txSignature err=$e\n$st',
          );
        }
        // Not decryptable as sender self-copy (likely incoming/foreign).
        continue;
      }
    }

    if (kDebugMode) {
      Log.d(
        '[MessageSync] 📤 _syncOutgoingMessages() COMPLETE - $newCount outgoing messages',
      );
    }
    return newCount;
  }

  Future<Map<String, dynamic>> _decrypt({
    required SimpleKeyPair encryptionKeyPair,
    required Uint8List senderEphemeralPubkey,
    required Uint8List ciphertext,
    Uint8List? pqSharedSecret,
  }) async {
    final decrypted = await cryptoService.decryptHybrid(
      encryptionKeyPair: encryptionKeyPair,
      senderEncryptionPubkey: senderEphemeralPubkey,
      cipherText: ciphertext,
      pqSharedSecret: pqSharedSecret,
    );
    final decompressed = codec.gzipDecompress(decrypted);
    return codec.parseMessagePayload(utf8.decode(decompressed));
  }

  // ===========================================================================
  // ALIAS ONBOARDING ENVELOPE HANDLERS
  // ===========================================================================

  /// Handle an inbound invite envelope (tag 0x01). Saves an invite-card row
  /// to the inbox so the UI can display a card the user can tap to accept.
  /// Deduplicated by txSignature.
  Future<void> _handleInviteEnvelope(
    AliasInviteEnvelope env,
    String senderAddress,
    String txSignature,
    int timestamp,
  ) async {
    try {
      // Don't resurface invites that predate this install: after a reinstall the
      // alias keys are wiped, so re-accepting an old invite would fork the
      // channel (and can't restore history). timestamp is on-chain seconds.
      final installEpoch = await _getInstallEpoch();
      if (installEpoch > 0 && timestamp * 1000 < installEpoch) {
        return;
      }

      // Don't surface alias invites from a blocked/spam sender.
      if (await _isSenderBlocked(senderAddress)) return;

      if (await messageCache.hasMessage(txSignature)) return;

      // Store as a synthetic DM so the existing chat-detail bubble renderer
      // can display an invite card. Content is a sentinel URI carrying the
      // base64url-encoded envelope bytes; the accept screen decodes it.
      final envelopeB64 = base64Url.encode(env.encode());
      final syntheticContent = 'sealed://alias-envelope?b=$envelopeB64';

      await messageCache.saveMessage(
        DecryptedMessage(
          id: txSignature,
          senderWallet: senderAddress,
          senderUsername: null,
          recipientWallet: sealedClient.wallet.walletAddress ?? '',
          recipientUsername: null,
          content: syntheticContent,
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
          isOutgoing: false,
          onChainPubkey: txSignature,
        ),
      );

      // Also record a durable receiver-side pending invite so the invitation
      // surfaces in ChatsScreen (banner + invitation row) and can be declined
      // persistently. Idempotent; the synthetic DM above remains the envelope
      // carrier used at accept time. Failure here must not stall sync.
      final onboarding = aliasOnboardingService;
      if (onboarding != null) {
        await onboarding.recordIncomingInvite(
          env: env,
          senderWallet: senderAddress,
        );
      }
    } catch (e) {
      debugPrint('[MessageSync] _handleInviteEnvelope error: $e');
    }
  }

  /// Handle an inbound accept envelope (tag 0x02). Promotes the pending
  /// invite to a full contact on the creator's side. Errors are swallowed
  /// so one bad envelope can't stall the sync loop.
  Future<void> _handleAcceptEnvelope(AliasAcceptEnvelope env) async {
    try {
      final onboarding = aliasOnboardingService;
      if (onboarding == null) {
        debugPrint(
          '[MessageSync] _handleAcceptEnvelope: aliasOnboardingService not available',
        );
        return;
      }
      await onboarding.completeFromAcceptEnvelope(env);
    } catch (e) {
      debugPrint('[MessageSync] _handleAcceptEnvelope error: $e');
    }
  }

  // ===========================================================================
  // FORCE RESYNC
  // ===========================================================================
  Future<void> forceResync(SyncLayer layer) async {
    if (kDebugMode) {
      Log.d(
        '[MessageSync] 🔄 forceResync() START - clearing cache and resetting sync state',
      );
    }
    _isForceResyncInProgress = true;
    try {
      if (_activeSync != null) {
        if (kDebugMode) {
          Log.d('[MessageSync] ⏳ Waiting for active sync before force resync');
        }
        await _activeSync!;
      }

      if (kDebugMode) Log.d('[MessageSync] 🗑️ Clearing message cache...');
      await messageCache.clear();
      if (kDebugMode) Log.d('[MessageSync] ✅ Cache cleared');
      if (kDebugMode) Log.d('[MessageSync] 🔄 Resetting sync state...');
      await syncState.reset();
      if (kDebugMode) Log.d('[MessageSync] ✅ Sync state reset');

      if (kDebugMode)
        Log.d('[MessageSync] 📡 Starting fresh sync (full sync)...');
      await syncMessages(fullSync: true, preferredLayer: layer);
      if (kDebugMode) {
        Log.d(
          '[MessageSync] 👁️ Marking resynced historical messages as read...',
        );
      }
      await messageCache.markAllAsRead();
      await contacts.markAllContactMessagesRead();
      if (kDebugMode) Log.d('[MessageSync] ✅ forceResync() COMPLETE\n');
    } finally {
      _isForceResyncInProgress = false;
    }
  }
}
