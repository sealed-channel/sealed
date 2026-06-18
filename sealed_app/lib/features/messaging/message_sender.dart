/// Send pipeline: text DMs, raw bytes (envelopes), and alias-contact sends.
/// Owned by [MessageService]; encapsulates encryption, framing, on-chain
/// publish, and outgoing cache writes.
library;

import 'dart:convert';
import 'package:sealed_app/core/log.dart';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'package:sealed_app/infra/chain/chain_address.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/models/contact.dart' as cmodel;
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/message_codec.dart' as codec;
import 'package:sealed_app/features/messaging/message_kem_handshake.dart';
import 'package:sealed_app/features/wallet/credits_service.dart';
import 'package:sealed_app/features/identity/user_service.dart';

class MessageSender {
  final SealedChainClient sealedClient;
  final CryptoService cryptoService;
  final KeyService keyService;
  final UserService userService;
  final ContactRepository contacts;
  final MessageRepository messageCache;
  final MessageKemHandshake kem;
  final CreditsService? creditsService;

  MessageSender({
    required this.sealedClient,
    required this.cryptoService,
    required this.keyService,
    required this.userService,
    required this.contacts,
    required this.messageCache,
    required this.kem,
    this.creditsService,
  });

  /// Pre-flight credit gate shared by all send kinds. Refuses to spend ALGO +
  /// do crypto work when the sender has no credit box. The cached read can lag
  /// an out-of-band redeem (the cache lives in [SealedCreditChainOps] and isn't
  /// touched by `redeemAndPublish`), so a cached `< 1` is confirmed with one
  /// fresh chain read before throwing — otherwise a 0→N redeem leaves the first
  /// send wrongly blocked with "Credits Required".
  Future<void> _assertHasCredits(String senderWallet) async {
    final svc = creditsService;
    if (svc == null) return;
    if (await svc.getCredits(senderWallet) >= 1) return;
    if (await svc.refetchCredits(senderWallet) >= 1) return;
    throw const NoCreditsError();
  }

  Future<String> sendMessage({
    required String recipientWallet,
    String? recipientUsername,
    required String plaintext,
    required String senderWallet,
  }) async {
    if (kDebugMode) {
      Log.d(
        '[MessageSender] 📤 sendMessage() START - recipient wallet: $recipientWallet',
      );
    }

    // M24 pre-flight: refuse to spend ALGO + do crypto work when the sender
    // has no credit box on the unified Sealed contract.
    await _assertHasCredits(senderWallet);

    final senderKeys = await keyService.loadKeys();
    if (senderKeys == null) {
      throw StateError('Sender keys not loaded');
    }

    if (kDebugMode) {
      Log.d('[MessageSender] ✅ Keys loaded for sender: $senderWallet');
      Log.d(
        '[MessageSender] 🔑 My local scan pubkey: ${base64Encode(senderKeys.scanPubkey)}',
      );
      Log.d('[MessageSender] 🔍 Resolving recipient keys...');
    }
    final walletBytesRaw = ChainAddress.decode(recipientWallet, 'algorand');
    if (walletBytesRaw.length != 32) {
      throw ArgumentError('Recipient wallet must decode to 32 bytes');
    }

    final recipientKeys = await contacts.getContactKeys(recipientWallet);

    Uint8List recipientEncryptionPubkey = recipientKeys.encryptionPubkey!;
    Uint8List recipientScanPubkey = recipientKeys.scanPubkey!;
    Uint8List? recipientPqPubkey = recipientKeys.pqPublicKey;
    Uint8List? pqSharedSecret = recipientKeys.pqSharedSecret;

    // ─── Freshness check: detect rotated keys ───
    try {
      final fresh = await sealedClient.getUserByWallet(recipientWallet);
      if (fresh != null) {
        final onChainHash = fresh.pqPubkeyHash;
        final cachedHash = recipientPqPubkey != null
            ? Uint8List.fromList(
                crypto_pkg.sha256.convert(recipientPqPubkey).bytes,
              )
            : null;
        final pqRotated =
            onChainHash != null &&
            cachedHash != null &&
            !cryptoService.constantTimeEquals(onChainHash, cachedHash);
        final classicalRotated =
            !cryptoService.constantTimeEquals(
              fresh.encryptionPubkey,
              recipientEncryptionPubkey,
            ) ||
            !cryptoService.constantTimeEquals(
              fresh.scanPubkey,
              recipientScanPubkey,
            );
        if (pqRotated || classicalRotated) {
          if (kDebugMode) {
            Log.d(
              '[MessageSender] 🔄 recipient key rotation detected wallet=$recipientWallet pqRotated=$pqRotated classicalRotated=$classicalRotated — invalidating PQ cache',
            );
          }
          await contacts.invalidatePqCache(recipientWallet);
          recipientEncryptionPubkey = fresh.encryptionPubkey;
          recipientScanPubkey = fresh.scanPubkey;
          recipientPqPubkey = null;
          pqSharedSecret = null;
          final refreshed = await contacts.getContactKeys(recipientWallet);
          recipientPqPubkey = refreshed.pqPublicKey;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Log.d(
          '[MessageSender] ⚠️ freshness check failed wallet=$recipientWallet err=$e — proceeding with cached keys',
        );
      }
    }

    if (kDebugMode) {
      Log.d(
        '[MessageSender] 🎯 resolved recipientScanPub=${base64Encode(recipientScanPubkey)} encPub=${base64Encode(recipientEncryptionPubkey)} hasPQ=${recipientPqPubkey != null}',
      );
    }

    // ─── PQ key exchange (once per contact) ───
    //
    // Branch selection for the first message to a peer:
    //   A — cached secret present              → 1× sendMessage (legacy).
    //   B — no cache + content fits hybrid     → 1× sendMessage (hybrid).
    //   C — no cache + content too big to fit  → 2× sendMessage (handshake
    //                                            then payload).
    // The decision is locked before any chain submit. Branch B is only
    // attempted when the gzipped plaintext fits the hybrid frame budget and
    // the character count stays under the per-language threshold.
    if (recipientPqPubkey != null) {
      pqSharedSecret = recipientKeys.pqSharedSecret;
      final cachedHit = pqSharedSecret != null;

      if (pqSharedSecret == null) {
        final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
        final gzippedLen = codec.gzipCompress(plaintextBytes).length;
        final hybridEligible =
            plaintext.length <= codec.kHybridFirstMessageCharThreshold &&
            codec.hybridFrameFits(gzippedLen);

        final handshake = await kem.performKemHandshake(
          senderWallet: senderWallet,
          senderScanPubkey: senderKeys.scanPubkey,
          recipientWallet: recipientWallet,
          recipientPqPubkey: recipientPqPubkey,
          firstPayloadContent: hybridEligible ? plaintextBytes : null,
        );
        pqSharedSecret = handshake.sharedSecret;

        if (handshake.hybridIncluded) {
          // Branch B: handshake + first text rode in 1 tx. Persist outgoing
          // cache + contact keys and return.
          final senderUsername = userService.displayName ?? 'unknown';
          await messageCache.saveMessage(
            DecryptedMessage(
              id: handshake.sendTxid,
              senderWallet: senderWallet,
              senderUsername: senderUsername,
              recipientWallet: recipientWallet,
              recipientUsername: recipientUsername,
              content: plaintext,
              timestamp: DateTime.now(),
              isOutgoing: true,
              onChainPubkey: handshake.sendTxid,
            ),
          );
          await contacts.saveContactKeys(
            recipientWallet,
            encryptionPubkey: recipientEncryptionPubkey,
            scanPubkey: recipientScanPubkey,
            pqPublicKey: recipientPqPubkey,
            pqSharedSecret: pqSharedSecret,
          );
          if (kDebugMode) {
            Log.d(
              '[MessageSender] 🧬 hybrid first-message tx=${handshake.sendTxid}',
            );
          }
          return handshake.sendTxid;
        }
      }

      if (kDebugMode) {
        Log.d(
          '[MessageSender] 🧬 sender PQ secret source=${cachedHit ? "CACHE" : "fresh-KEM"} len=${pqSharedSecret.length} fp=${base64Encode(pqSharedSecret.sublist(0, 8))} recipientPqPubFp=${base64Encode(recipientPqPubkey.sublist(0, 8))}',
        );
      }
    } else {
      debugPrint(
        '[MessageSender] ⚠️ Recipient has no PQ pubkey — classical-only encryption',
      );
      pqSharedSecret = null;
    }

    // Branch A or C: legacy regular-tag sendMessage with the encrypted payload.
    final txSignature = await _send(
      recipientEncPub: recipientEncryptionPubkey,
      recipientScanPub: recipientScanPubkey,
      pqSharedSecret: pqSharedSecret,
      recipientWallet: recipientWallet,
      recipientUsername: recipientUsername,
      plaintext: plaintext,
      senderWallet: senderWallet,
      senderEncKp: senderKeys.encryptionKeyPair,
    );

    // The TX is already on-chain and the outgoing message is cached. Caching
    // the recipient's keys is a best-effort optimization for the NEXT send — it
    // can touch the network (_resolveProfile) inside its DB transaction and so
    // may throw on a flaky connection. That must NOT fail this send: a throw
    // here would surface a "send failed" snackbar (whose retry double-sends and
    // double-burns credits) on a message that already went through.
    try {
      await contacts.saveContactKeys(
        recipientWallet,
        encryptionPubkey: recipientEncryptionPubkey,
        scanPubkey: recipientScanPubkey,
        pqPublicKey: recipientPqPubkey,
        pqSharedSecret: pqSharedSecret,
      );
    } catch (e, st) {
      if (kDebugMode) {
        Log.d(
          '[MessageSender] ⚠️ post-send saveContactKeys failed; '
          'message already sent (TX $txSignature): $e\n$st',
        );
      }
    }

    return txSignature;
  }

  /// Core send path — encryption, tag computation, on-chain send, local cache.
  Future<String> _send({
    required Uint8List recipientEncPub,
    required Uint8List recipientScanPub,
    required Uint8List? pqSharedSecret,
    required String recipientWallet,
    required String? recipientUsername,
    required String plaintext,
    required String senderWallet,
    SimpleKeyPair? senderEncKp, // null = skip self-copy
  }) async {
    if (kDebugMode) Log.d('[MessageSender] 🔑 Generating ephemeral keypair');
    final ephemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    if (kDebugMode) {
      Log.d('[MessageSender] ✅ Ephemeral keypair generated');
      Log.d(
        '[MessageSender] 🔑 Ephemeral pubkey: ${base64Encode(ephemeralPublicKey.bytes)}',
      );
      Log.d('[MessageSender] 🔐 Computing shared secret for recipient tag');
    }
    final sharedSecretForTag = await cryptoService.computeSharedSecret(
      keyPair: ephemeralKeyPair,
      publicKey: recipientScanPub,
    );

    if (kDebugMode) Log.d('[MessageSender] 🏷️ Computing recipient tag');
    final recipientTag = await cryptoService.computeRecipientTag(
      sharedSecretForTag,
    );

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
    final compressedPayload = codec.gzipCompress(payloadBytes);

    final recipientCiphertext = await cryptoService.encryptHybrid(
      plainTextBytes: compressedPayload,
      senderEncryptionKeyPair: ephemeralKeyPair,
      recipientEncryptionPubkey: recipientEncPub,
      pqSharedSecret: pqSharedSecret,
    );

    Uint8List combinedCiphertext;
    if (senderEncKp != null) {
      if (kDebugMode) {
        Log.d('[MessageSender] 🔒 Encrypting self-copy for sender...');
      }
      final senderEncPub = await senderEncKp.extractPublicKey();
      final selfCiphertext = await cryptoService.encryptHybrid(
        plainTextBytes: compressedPayload,
        senderEncryptionKeyPair: ephemeralKeyPair,
        recipientEncryptionPubkey: Uint8List.fromList(senderEncPub.bytes),
        pqSharedSecret: null,
      );
      combinedCiphertext = codec.combineCiphertexts(
        recipientCiphertext,
        selfCiphertext,
      );
    } else {
      // Alias path: single ciphertext, no self-copy overhead. Wrap as combined
      // so unpad/splitCiphertexts still works on receipt.
      combinedCiphertext = codec.combineCiphertexts(
        recipientCiphertext,
        Uint8List(0),
      );
    }

    final paddedCiphertext = codec.pad(combinedCiphertext);

    if (kDebugMode) {
      Log.d('[MessageSender] ⛓️ Sending message via blockchain...');
    }
    final txSignature = await sealedClient.sendMessage(
      recipientTag: recipientTag,
      senderEphemeralPubkey: Uint8List.fromList(ephemeralPublicKey.bytes),
      ciphertext: paddedCiphertext,
    );
    if (kDebugMode) Log.d('[MessageSender] ✅ Message sent! TX: $txSignature');

    if (senderEncKp != null) {
      final senderUsername = userService.displayName ?? 'unknown';
      if (kDebugMode) {
        Log.d('[MessageSender] 💾 Caching outgoing message to local storage');
      }
      await messageCache.saveMessage(
        DecryptedMessage(
          id: txSignature,
          senderWallet: senderWallet,
          senderUsername: senderUsername,
          recipientWallet: recipientWallet,
          recipientUsername: recipientUsername,
          content: plaintext,
          timestamp: DateTime.fromMillisecondsSinceEpoch(messageTimestamp),
          isOutgoing: true,
          onChainPubkey: txSignature,
        ),
      );
      if (kDebugMode) Log.d('[MessageSender] ✅ Message cached successfully');
    }

    return txSignature;
  }

  // ===========================================================================
  // BYTES SEND — envelope path (alias onboarding)
  // ===========================================================================

  /// Send raw bytes via the hybrid-encrypt pipeline (no JSON, no gzip on the
  /// payload, no outgoing-cache write of user content). Used for alias
  /// onboarding invite/accept envelopes only.
  Future<String> sendMessageBytes({
    required String recipientWallet,
    required Uint8List plaintextBytes,
    required String senderWallet,
  }) async {
    await _assertHasCredits(senderWallet);

    final senderKeys = await keyService.loadKeys();
    if (senderKeys == null) throw StateError('Sender keys not loaded');

    final walletBytesRaw = ChainAddress.decode(recipientWallet, 'algorand');
    if (walletBytesRaw.length != 32) {
      throw ArgumentError('Recipient wallet must decode to 32 bytes');
    }

    final recipientKeys = await contacts.getContactKeys(recipientWallet);
    Uint8List recipientEncryptionPubkey = recipientKeys.encryptionPubkey!;
    Uint8List recipientScanPubkey = recipientKeys.scanPubkey!;
    Uint8List? recipientPqPubkey = recipientKeys.pqPublicKey;
    Uint8List? pqSharedSecret = recipientKeys.pqSharedSecret;

    // Key freshness check — same as sendMessage.
    try {
      final fresh = await sealedClient.getUserByWallet(recipientWallet);
      if (fresh != null) {
        final onChainHash = fresh.pqPubkeyHash;
        final cachedHash = recipientPqPubkey != null
            ? Uint8List.fromList(
                crypto_pkg.sha256.convert(recipientPqPubkey).bytes,
              )
            : null;
        final pqRotated =
            onChainHash != null &&
            cachedHash != null &&
            !cryptoService.constantTimeEquals(onChainHash, cachedHash);
        final classicalRotated =
            !cryptoService.constantTimeEquals(
              fresh.encryptionPubkey,
              recipientEncryptionPubkey,
            ) ||
            !cryptoService.constantTimeEquals(
              fresh.scanPubkey,
              recipientScanPubkey,
            );
        if (pqRotated || classicalRotated) {
          await contacts.invalidatePqCache(recipientWallet);
          recipientEncryptionPubkey = fresh.encryptionPubkey;
          recipientScanPubkey = fresh.scanPubkey;
          recipientPqPubkey = null;
          pqSharedSecret = null;
          final refreshed = await contacts.getContactKeys(recipientWallet);
          recipientPqPubkey = refreshed.pqPublicKey;
        }
      }
    } catch (e) {
      debugPrint(
        '[MessageSender] sendMessageBytes: freshness check failed: $e',
      );
    }

    if (recipientPqPubkey != null && pqSharedSecret == null) {
      final handshake = await kem.performKemHandshake(
        senderWallet: senderWallet,
        senderScanPubkey: senderKeys.scanPubkey,
        recipientWallet: recipientWallet,
        recipientPqPubkey: recipientPqPubkey,
      );
      pqSharedSecret = handshake.sharedSecret;
    }

    final txSignature = await _sendRawBytes(
      recipientEncPub: recipientEncryptionPubkey,
      recipientScanPub: recipientScanPubkey,
      pqSharedSecret: pqSharedSecret,
      payloadBytes: plaintextBytes,
    );

    // Write synthetic outgoing message so sender sees the invite/accept card.
    if (plaintextBytes.isNotEmpty &&
        (plaintextBytes[0] == aliasInviteTagByte ||
            plaintextBytes[0] == aliasAcceptTagByte)) {
      final sentContent =
          'sealed://alias-envelope?b=${base64Url.encode(plaintextBytes)}';
      await messageCache.saveMessage(
        DecryptedMessage(
          id: txSignature,
          senderWallet: senderWallet,
          recipientWallet: recipientWallet,
          content: sentContent,
          timestamp: DateTime.now(),
          isOutgoing: true,
          onChainPubkey: txSignature,
        ),
      );
    }

    // Best-effort key cache for the next send — see the note on the text-send
    // path above. Must not fail this already-confirmed send.
    try {
      await contacts.saveContactKeys(
        recipientWallet,
        encryptionPubkey: recipientEncryptionPubkey,
        scanPubkey: recipientScanPubkey,
        pqPublicKey: recipientPqPubkey,
        pqSharedSecret: pqSharedSecret,
      );
    } catch (e, st) {
      if (kDebugMode) {
        Log.d(
          '[MessageSender] ⚠️ post-send saveContactKeys failed; '
          'message already sent (TX $txSignature): $e\n$st',
        );
      }
    }

    return txSignature;
  }

  /// Internal send path for raw bytes — hybrid encrypt, no JSON, no cache.
  Future<String> _sendRawBytes({
    required Uint8List recipientEncPub,
    required Uint8List recipientScanPub,
    required Uint8List? pqSharedSecret,
    required Uint8List payloadBytes,
  }) async {
    final ephemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    final sharedSecretForTag = await cryptoService.computeSharedSecret(
      keyPair: ephemeralKeyPair,
      publicKey: recipientScanPub,
    );
    final recipientTag = await cryptoService.computeRecipientTag(
      sharedSecretForTag,
    );

    // Crypto bytes are incompressible — skip gzip to stay within tx limits.
    final recipientCiphertext = await cryptoService.encryptHybrid(
      plainTextBytes: payloadBytes,
      senderEncryptionKeyPair: ephemeralKeyPair,
      recipientEncryptionPubkey: recipientEncPub,
      pqSharedSecret: pqSharedSecret,
    );

    // Envelope messages: single ciphertext, no self-copy.
    final combinedCiphertext = codec.combineCiphertexts(
      recipientCiphertext,
      Uint8List(0),
    );
    final paddedCiphertext = codec.pad(combinedCiphertext);

    return sealedClient.sendMessage(
      recipientTag: recipientTag,
      senderEphemeralPubkey: Uint8List.fromList(ephemeralPublicKey.bytes),
      ciphertext: paddedCiphertext,
    );
  }

  // ===========================================================================
  // ALIAS SEND
  // ===========================================================================

  /// Send a message to an alias contact identified by [contactId].
  /// Credits are checked against the sender's main wallet — anonymity comes
  /// from the recipient tag, not the tx signer.
  Future<String> sendAliasMessage({
    required String contactId,
    required String plaintext,
  }) async {
    final c = await contacts.getAliasContact(contactId);
    if (c == null) {
      throw StateError('AliasContact not found: $contactId');
    }

    final senderWallet = userService.walletAddress;
    if (senderWallet == null) throw StateError('Sender wallet not loaded');

    await _assertHasCredits(senderWallet);

    final txSignature = await _send(
      recipientEncPub: c.keys.peerX25519Pub,
      recipientScanPub: c.keys.peerX25519Scan,
      pqSharedSecret: c.keys.pqSharedSecret,
      recipientWallet:
          contactId, // alias — no real wallet; use contactId as routing key
      recipientUsername: c.aliasHandle,
      plaintext: plaintext,
      senderWallet: senderWallet,
      senderEncKp: null, // no self-copy for alias messages
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    await contacts.saveContactMessage(
      cmodel.ContactMessage(
        id: txSignature,
        contactId: contactId,
        direction: 1, // outgoing
        content: plaintext,
        timestamp: ts,
      ),
    );

    return txSignature;
  }
}
