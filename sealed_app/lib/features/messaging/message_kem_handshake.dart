/// KEM (post-quantum) handshake: discovery-tag computation, send-side
/// encapsulation, and receive-side decapsulation. Owned by [MessageService].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/messaging/message_codec.dart' as codec;
import 'package:sealed_app/models/message.dart';

/// Deterministic KEM first-contact discovery tag = HMAC(label, sender‖recipient).
/// THE single source of truth for this tag — both the live KEM handshake and the
/// background pre-sync matcher call this so they can never diverge.
Future<Uint8List> kemDiscoveryTag(
  String senderWallet,
  String recipientWallet,
) async {
  final mac = await Hmac.sha256().calculateMac(
    Uint8List.fromList([
      ...utf8.encode(senderWallet),
      ...utf8.encode(recipientWallet),
    ]),
    secretKey: SecretKey(utf8.encode('sealed-kem-init-tag-v1')),
  );
  return Uint8List.fromList(mac.bytes);
}

/// Function signature mirroring [SealedChainClient.sendMessage]. Exists so
/// unit tests can inject a recording stub without constructing the full
/// chain client.
typedef ChainSendMessageFn =
    Future<String> Function({
      required Uint8List recipientTag,
      required Uint8List senderEphemeralPubkey,
      required Uint8List ciphertext,
    });

class MessageKemHandshake {
  final SealedChainClient sealedClient;
  final CryptoService cryptoService;
  final KeyService keyService;
  final ContactRepository contacts;
  final ChainSendMessageFn _sendMessageFn;

  MessageKemHandshake({
    required this.sealedClient,
    required this.cryptoService,
    required this.keyService,
    required this.contacts,
    ChainSendMessageFn? sendMessageFn,
  }) : _sendMessageFn = sendMessageFn ?? sealedClient.sendMessage;

  /// Deterministic discovery tag for KEM handshake messages. Lets the
  /// recipient pick out the KEM ciphertext from the on-chain stream without
  /// scanning every message with their PQ private key. Delegates to the shared
  /// pure [kemDiscoveryTag] so the background pre-sync matcher computes the same
  /// tag without depending on this (heavy) class.
  Future<Uint8List> computeKemDiscoveryTag(
    String senderWallet,
    String recipientWallet,
  ) => kemDiscoveryTag(senderWallet, recipientWallet);

  /// One-time KEM handshake against [recipientPqPubkey].
  ///
  /// When [firstPayloadContent] is null (or doesn't fit the hybrid budget),
  /// emits a legacy 800B handshake frame `[kemCt 768 || scanPub 32]`. The
  /// caller is then responsible for a follow-up `sendMessage` to deliver
  /// the first text (legacy 2-call path).
  ///
  /// When [firstPayloadContent] is non-null AND
  /// [codec.hybridFrameFits] accepts the gzipped size, emits a hybrid frame
  /// `[kemCt 768 || innerLen 2 || AES-GCM(envelope)]` so the handshake and
  /// the first text ride in a single on-chain `sendMessage` (1-credit path).
  /// `senderEphemeralPubkey` is zeroed because the KEM-tag discovery path
  /// doesn't use the X25519 ephemeral slot — receiver-side scanning is
  /// driven entirely by the deterministic discovery tag.
  ///
  /// Returns the derived shared secret, the on-chain tx id, and whether
  /// the first-message payload rode along inside the handshake frame.
  Future<({Uint8List sharedSecret, String sendTxid, bool hybridIncluded})>
  performKemHandshake({
    required String senderWallet,
    required Uint8List senderScanPubkey,
    required String recipientWallet,
    required Uint8List recipientPqPubkey,
    Uint8List? firstPayloadContent,
    int? firstPayloadTimestampMs,
  }) async {
    // Deterministic encapsulation: derive the coins from our mnemonic + the
    // recipient's PQ pubkey so the initiator can re-derive this exact
    // (ciphertext, sharedSecret) after a logout/cache wipe — the basis for
    // recovering self-initiated chats. (Existing random-nonce handshakes on
    // chain stay unrecoverable; this is forward-only.)
    final encapsNonce = await keyService.deriveKemEncapsNonce(
      recipientPqPubkey,
    );
    final kemResult = await cryptoService.kemEncapsulate(
      recipientPqPubkey,
      nonce: encapsNonce,
    );
    final sharedSecret = kemResult.sharedSecret;
    final kemTag = await computeKemDiscoveryTag(senderWallet, recipientWallet);

    // Decide branch BEFORE any state mutation / on-chain submit.
    Uint8List? hybridFrame;
    if (firstPayloadContent != null) {
      final gzipped = codec.gzipCompress(firstPayloadContent);
      if (codec.hybridFrameFits(gzipped.length)) {
        final ts =
            firstPayloadTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
        final envelope = codec.encodeHybridInnerEnvelope(
          timestampMs: ts,
          content: firstPayloadContent,
        );
        final innerCt = await cryptoService.encryptWithEncKey(
          encKey: sharedSecret,
          plainTextBytes: envelope,
        );
        hybridFrame = codec.encodeHybridFirstFrame(
          kemCt: kemResult.ciphertext,
          innerCiphertext: innerCt,
        );
      }
    }

    final Uint8List payload;
    final bool hybridIncluded;
    if (hybridFrame != null) {
      payload = hybridFrame;
      hybridIncluded = true;
    } else {
      // Legacy 800B frame: kemCt || scanPub.
      payload = Uint8List.fromList([
        ...kemResult.ciphertext, // 768 bytes
        ...senderScanPubkey, // 32 bytes — so recipient knows who sent it
      ]);
      hybridIncluded = false;
    }

    // Legacy path keeps the pre-existing pre-send cache write so a retry
    // doesn't re-encapsulate (recipient can still find the secret via the
    // resubmitted tx). The hybrid path defers the cache write until the
    // chain accepts the frame, since a failed submit would otherwise leave
    // the sender with a secret the recipient can never derive.
    if (!hybridIncluded) {
      await contacts.saveContactKeys(
        recipientWallet,
        pqSharedSecret: sharedSecret,
      );
    }

    final txid = await _sendMessageFn(
      recipientTag: kemTag,
      senderEphemeralPubkey: Uint8List(32),
      ciphertext: payload,
    );

    if (hybridIncluded) {
      await contacts.saveContactKeys(
        recipientWallet,
        pqSharedSecret: sharedSecret,
      );
    }

    return (
      sharedSecret: sharedSecret,
      sendTxid: txid,
      hybridIncluded: hybridIncluded,
    );
  }

  // ===========================================================================
  // RECEIVE-SIDE: KEM HANDSHAKE PROCESSING
  // Detects KEM ciphertexts addressed to us via the discovery tag,
  // decapsulates with our PQ private key, and caches the resulting shared
  // secret for hybrid decrypt. Hybrid frames (>800B) also carry the first
  // text payload — decrypted inline and emitted as DecryptedMessage records
  // that the caller hands to the message cache before the regular incoming
  // sync runs.
  // ===========================================================================
  Future<({int kemSaved, List<DecryptedMessage> hybridMessages})>
  processKemHandshakes(List<Map<String, dynamic>> messages) async {
    int savedCount = 0;
    final hybridMessages = <DecryptedMessage>[];

    // Per-sender on-chain username cache for this run. A hybrid frame is the
    // FIRST message a brand-new peer sends (KEM handshake = first contact), so
    // the sender has no local contact row and the frame carries no username.
    // Resolve it at arrival — mirrors _syncIncomingMessages — so the very
    // first message from an unknown peer shows their username, not a shortened
    // wallet, instead of waiting for the periodic refresh. One chain lookup per
    // new sender per run; chain failure leaves username null (snapshot fallback).
    final chainUsernameBySender = <String, String?>{};

    final myAddress = sealedClient.wallet.walletAddress;
    if (myAddress == null) {
      return (kemSaved: savedCount, hybridMessages: hybridMessages);
    }

    final pqKeys = await keyService.loadPqKeys();
    if (pqKeys == null) {
      return (kemSaved: savedCount, hybridMessages: hybridMessages);
    }

    for (final msg in messages) {
      final senderAddress = (msg['senderAddress'] as String?) ?? '';
      if (senderAddress.isEmpty) continue;

      // Cheap length/tag pre-checks before any DB hit.
      final ciphertext = msg['ciphertext'] as Uint8List?;
      if (ciphertext == null ||
          ciphertext.length < codec.kLegacyKemFrameLen ||
          ciphertext.length > codec.kHybridFrameMaxBytes) {
        continue;
      }
      final isHybrid = ciphertext.length > codec.kLegacyKemFrameLen;
      final expectedTag = await computeKemDiscoveryTag(
        senderAddress,
        myAddress,
      );
      final msgTag = msg['recipientTag'] as Uint8List?;
      if (msgTag == null ||
          !cryptoService.constantTimeEquals(msgTag, expectedTag)) {
        continue;
      }

      final existingKeys = await contacts.getContactKeys(senderAddress);
      final cachedSecret = existingKeys.pqSharedSecret;
      final kemCiphertext = ciphertext.sublist(0, codec.kKemCtLen);

      Uint8List sharedSecret;
      try {
        sharedSecret = await cryptoService.kemDecapsulate(
          kemCiphertext,
          pqKeys.privateKey,
        );
      } catch (e) {
        if (kDebugMode) {
          final pqPubFp = base64Encode(
            crypto_pkg.sha256.convert(pqKeys.publicKey).bytes.sublist(0, 8),
          );
          Log.d(
            '[KEM] ❌ Decapsulation failed for $senderAddress myPqPubFp=$pqPubFp '
            'ctLen=${kemCiphertext.length} err=$e',
          );
        }
        continue;
      }

      // Cache decision: legacy frames cache immediately; hybrid frames defer
      // until AES-GCM auth verifies the trailing payload (so a tampered KEM
      // half can't poison the cache).
      if (!isHybrid) {
        await _cacheSecretIfChanged(senderAddress, sharedSecret, cachedSecret);
        if (cachedSecret == null ||
            !cryptoService.constantTimeEquals(cachedSecret, sharedSecret)) {
          savedCount++;
        }
        continue;
      }

      // Hybrid path: decrypt the trailing payload before trusting the secret.
      final parsed = codec.decodeHybridFirstFrame(ciphertext);
      if (parsed == null) {
        // Length said hybrid but parse said legacy — frame is malformed.
        if (kDebugMode) {
          Log.d(
            '[KEM] ⚠️ hybrid length ${ciphertext.length} but decodeHybridFirstFrame returned null',
          );
        }
        continue;
      }

      Uint8List innerEnvelope;
      try {
        innerEnvelope = await cryptoService.decryptWithEncKey(
          encKey: sharedSecret,
          cipherText: parsed.innerCiphertext,
        );
      } catch (e) {
        if (kDebugMode) {
          Log.d('[KEM] ❌ hybrid AES-GCM auth failed for $senderAddress: $e');
        }
        // AES-GCM auth failure means the frame is tampered or the secret
        // doesn't match — do NOT cache. Drop the frame entirely.
        continue;
      }

      // AES-GCM authenticated the secret. Cache it now so future sends use
      // the legacy 1-call path regardless of envelope-decode outcome.
      final secretIsNew =
          cachedSecret == null ||
          !cryptoService.constantTimeEquals(cachedSecret, sharedSecret);
      if (secretIsNew) {
        await _cacheSecretIfChanged(senderAddress, sharedSecret, cachedSecret);
        savedCount++;
      }

      ({int timestampMs, Uint8List content}) envelope;
      try {
        envelope = codec.decodeHybridInnerEnvelope(innerEnvelope);
      } catch (e) {
        if (kDebugMode) {
          Log.d(
            '[KEM] ⚠️ hybrid envelope decode failed for $senderAddress: $e '
            '(secret cached, payload dropped)',
          );
        }
        continue;
      }

      // Resolve the sender's on-chain username now (unknown-peer first
      // contact). Best-effort: one lookup per sender per run, cached; any
      // failure keeps it null and the periodic refresh fills it in later.
      if (!chainUsernameBySender.containsKey(senderAddress)) {
        String? fetched;
        try {
          fetched = (await sealedClient.getUserByWallet(
            senderAddress,
          ))?.username;
        } catch (_) {
          fetched = null;
        }
        chainUsernameBySender[senderAddress] = fetched;
      }
      final resolvedUsername = chainUsernameBySender[senderAddress];

      final txid = (msg['accountPubkey'] as String?) ?? '';
      final ts = DateTime.fromMillisecondsSinceEpoch(envelope.timestampMs);
      hybridMessages.add(
        DecryptedMessage(
          id: txid,
          senderWallet: senderAddress,
          senderUsername: (resolvedUsername?.isNotEmpty == true)
              ? resolvedUsername
              : null,
          recipientWallet: myAddress,
          recipientUsername: null,
          content: utf8.decode(envelope.content, allowMalformed: true),
          timestamp: ts,
          isOutgoing: false,
          onChainPubkey: txid,
        ),
      );
    }

    return (kemSaved: savedCount, hybridMessages: hybridMessages);
  }

  Future<void> _cacheSecretIfChanged(
    String senderAddress,
    Uint8List sharedSecret,
    Uint8List? cachedSecret,
  ) async {
    if (cachedSecret != null &&
        cryptoService.constantTimeEquals(cachedSecret, sharedSecret)) {
      return; // Idempotent: same secret already in cache.
    }
    if (cachedSecret != null) {
      Log.d(
        '[KEM] 🔄 supersede cache sender=${redactAddr(senderAddress)} '
        'oldFp=${secretFp(cachedSecret)} newFp=${secretFp(sharedSecret)}',
      );
    }
    await contacts.saveContactKeys(senderAddress, pqSharedSecret: sharedSecret);
  }

  // ===========================================================================
  // KEY PUBLICATION INGESTION
  // Reads publishKeys / publishPqKey app-call logs and caches the sender's
  // enc + scan + PQ keys keyed by wallet address.
  //
  // publishKeys log layout: [sender(32), encPub(32), scanPub(32), pqPub(800)]
  // ===========================================================================
  Future<void> processKeyPublications(int? sinceTimestamp) async {
    List<Map<String, dynamic>> txns;
    try {
      txns = await sealedClient.fetchKeyPublicationTxns(
        sinceTimestamp: sinceTimestamp,
      );
    } catch (_) {
      return;
    }

    for (final tx in txns) {
      final senderAddress = tx['senderAddress'] as String;
      if (senderAddress.isEmpty) continue;

      final selector = Uint8List.fromList(tx['selector'] as List<int>);
      final logs = tx['logs'] as List<Uint8List>;

      final isPublishKeys = codec.bytesEqual(
        selector,
        SealedChainClient.publishKeysSelector,
      );

      if (isPublishKeys && logs.length >= 4) {
        // Combined format — cache all three keys.
        final encPub = logs[1];
        final scanPub = logs[2];
        final pqPub = logs[3];

        if (encPub.length != 32 || scanPub.length != 32) continue;
        if (pqPub.length < 32) continue;
        await contacts.saveContactKeys(
          senderAddress,
          encryptionPubkey: encPub,
          scanPubkey: scanPub,
          pqPublicKey: pqPub,
        );
        if (kDebugMode) {
          Log.d('[Sync] Cached enc+scan+pq keys for $senderAddress');
        }
      }
    }
  }
}
