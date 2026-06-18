/// Alias onboarding: invite creation, acceptance, and key-exchange completion.
///
/// Replaces the old AliasChatService invite/accept/complete flow.
/// Writes to ContactRepository (pending_invites + contacts tables).
///
/// Bootstrap payload v2 layout:
///   Invite:  [encPub(32) || scanPub(32) || pqPub(800)]  = 864B
///   Accept:  [encPub(32) || scanPub(32) || kemCT(768B)] = 832B
///
/// Key exchange summary:
///   1. Creator → acceptor's wallet: HMAC-tag(inviteSecret, "alias-invite-tag-v1")
///      ciphertext = AES-GCM(SHA256(inviteSecret), invite_payload)
///   2. Acceptor → creator's wallet: HMAC-tag(inviteSecret, "alias-accept-tag-v1")
///      ciphertext = AES-GCM(SHA256(inviteSecret), accept_payload)
///   3. Both sides:
///      classicalShared = ECDH(myEncSk, peerEncPub)
///      pqShared = KEM-encapsulate/decapsulate
///      sharedSecret = HKDF(classicalShared || pqShared, "sealed-hybrid-aes-gcm-v1")
///      msgKey = HKDF(sharedSecret, "sealed-msg-key-v1", L=32) [placeholder]
///      recipientTag = HMAC-SHA256(sharedSecret, "sealed-recipient-tag-v1")
///      tagSalt = random 16 bytes (stored, not derived)
///
/// No raw inviteSecret is written to SQLite.
library;

import 'dart:convert';
import 'package:sealed_app/infra/crypto/secure_random.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/contact.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';

/// Minimal chain interface required by [AliasOnboardingService].
/// Allows easy mocking in tests without needing the full [SealedChainClient].
abstract class AliasChainGateway {
  String? get myWalletAddress;

  Future<void> sendNote({
    required Uint8List recipientTag,
    required Uint8List ciphertext,
  });

  /// Scan messages FROM [senderAddress]. Used by acceptor to find invite note.
  Future<List<Map<String, dynamic>>> fetchNotesFromSender(String senderAddress);

  /// Scan messages received by own wallet. Used by creator to find accept note.
  Future<List<Map<String, dynamic>>> fetchOwnNotes();

  /// Scan ALL app-call notes (no sender / recipient filter). Used for
  /// tag-based discovery that must not leak which wallet is being queried.
  Future<List<Map<String, dynamic>>> fetchAllNotes();
}

/// Adapts [SealedChainClient] to [AliasChainGateway].
class SealedClientGateway implements AliasChainGateway {
  final SealedChainClient _client;
  SealedClientGateway(this._client);

  @override
  String? get myWalletAddress => _client.wallet.walletAddress;

  @override
  Future<void> sendNote({
    required Uint8List recipientTag,
    required Uint8List ciphertext,
  }) => _client.sendMessage(
    recipientTag: recipientTag,
    senderEphemeralPubkey: Uint8List(32),
    ciphertext: ciphertext,
  );

  // The chain fetch methods now throw on transport/indexer failure so the
  // message-sync cursor can hold. Alias discovery, by contrast, treats a fetch
  // failure as "no matching note found this pass" (it returns null and the
  // caller retries) — so swallow to an empty list here to preserve that
  // contract and keep the behaviour change scoped to the message-loss path.
  Future<List<Map<String, dynamic>>> _bestEffort(
    Future<List<Map<String, dynamic>>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } catch (e) {
      Log.d('[AliasGateway] fetch failed, treating as no notes: $e');
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchNotesFromSender(
    String senderAddress,
  ) => _bestEffort(() => _client.fetchMessagesFromSender(senderAddress));

  @override
  Future<List<Map<String, dynamic>>> fetchOwnNotes() =>
      _bestEffort(() => _client.fetchMessages());

  @override
  Future<List<Map<String, dynamic>>> fetchAllNotes() =>
      _bestEffort(() => _client.fetchAllAppMessages());
}

class AliasOnboardingService {
  final ContactRepository _repo;
  final AliasKeyService _keyService;
  final CryptoService _cryptoService;
  final AliasChainGateway _chain;

  /// Fired with the contactId once an alias contact is fully established
  /// (acceptor accept or creator completion). Used to auto-enable per-alias
  /// push when the device's global push is on. Best-effort: the handshake does
  /// not depend on it, and the callback is expected to swallow its own errors.
  final Future<void> Function(String contactId)? _onContactEstablished;

  AliasOnboardingService({
    required ContactRepository repo,
    required AliasKeyService keyService,
    required CryptoService cryptoService,
    required AliasChainGateway chain,
    Future<void> Function(String contactId)? onContactEstablished,
  }) : _repo = repo,
       _keyService = keyService,
       _cryptoService = cryptoService,
       _chain = chain,
       _onContactEstablished = onContactEstablished;

  // ---------------------------------------------------------------------------
  // Step 1: Create invitation (creator device)
  // ---------------------------------------------------------------------------

  /// Create a pending invite and broadcast the invite note to the contact's wallet.
  ///
  /// Returns the invite URI for sharing via QR / deep link.
  Future<String> createInvitation({
    required String alias,
    required String contactWallet,
  }) async {
    final inviteSecret = AliasKeyService.generateInviteSecret();
    final secretBytes = _secretBytes(inviteSecret);

    // Generate temp X25519 enc + scan keypairs.
    final tempKeys = await _keyService.generateTempKeyPair(inviteSecret);

    // Generate temp ML-KEM-512 keypair.
    final pqKeys = await _cryptoService.generatePqKeyPair();
    await _keyService.storeTempPqKeyPair(
      inviteSecret,
      privateKey: pqKeys.privateKey,
      publicKey: pqKeys.publicKey,
    );

    // Payload v2: [encPub(32) || scanPub(32) || pqPub(800)] = 864B
    final payload = Uint8List.fromList([
      ...tempKeys.enc.publicKey,
      ...tempKeys.scan.publicKey,
      ...pqKeys.publicKey,
    ]);

    final inviteTag = await _hmacDiscoveryTag(
      secretBytes,
      ALIAS_INVITE_TAG_LABEL,
    );
    final ciphertext = await _encryptDiscovery(secretBytes, payload);

    await _chain.sendNote(recipientTag: inviteTag, ciphertext: ciphertext);

    // inviteRef = sha256hex of raw inviteSecret bytes (never store raw secret in SQLite).
    final inviteRef = await _inviteRef(secretBytes);

    // Store raw inviteSecret in secure storage so the sync loop can call
    // completeKeyExchange when it detects the accept note on-chain.
    await _keyService.storeInviteSecret(inviteRef, inviteSecret);

    await _repo.savePendingInvite(
      PendingInvite(
        inviteRef: inviteRef,
        aliasDisplay: alias,
        isCreator: true,
        status: 'pending',
        createdAt: _nowSecs(),
      ),
    );

    return 'sealed://alias?c=${Uri.encodeComponent(inviteSecret)}&w=${Uri.encodeComponent(contactWallet)}';
  }

  // ---------------------------------------------------------------------------
  // Step 1b: Create invitation via DM envelope (no on-chain write)
  // ---------------------------------------------------------------------------

  /// Create a pending invite and return envelope bytes for sending via DM.
  ///
  /// inviteRef is derived as sha256hex(encPub || scanPub || pqPub) so both
  /// creator and acceptor can independently compute it from the envelope — no
  /// inviteSecret needs to traverse the wire.
  ///
  /// No on-chain write. Caller sends [envelopeBytes] via MessageService.sendMessageBytes.
  Future<({String inviteRef, Uint8List envelopeBytes})>
  createInvitationEnvelope({required String alias}) async {
    // Generate temp X25519 enc + scan keypairs.
    // We need the raw pubkeys to compute inviteRef before storing, so generate
    // the pair directly here and store under inviteRef afterwards.
    final x25519 = X25519();
    final encKp = await x25519.newKeyPair();
    final scanKp = await x25519.newKeyPair();
    final encPub = Uint8List.fromList((await encKp.extractPublicKey()).bytes);
    final scanPub = Uint8List.fromList((await scanKp.extractPublicKey()).bytes);
    final encPriv = Uint8List.fromList(await encKp.extractPrivateKeyBytes());
    final scanPriv = Uint8List.fromList(await scanKp.extractPrivateKeyBytes());

    // Generate temp ML-KEM-512 keypair.
    final pqKeys = await _cryptoService.generatePqKeyPair();

    // inviteRef = sha256hex(encPub || scanPub || pqPub) — same formula acceptor uses.
    final inviteRef = await _inviteRefFromPubs(
      encPub,
      scanPub,
      pqKeys.publicKey,
    );

    // Persist temp keys under inviteRef (envelope-flow keying).
    await _keyService.storeTempPqKeyPairByRef(
      inviteRef,
      privateKey: pqKeys.privateKey,
      publicKey: pqKeys.publicKey,
    );
    await _keyService.storeTempX25519ByRef(
      inviteRef,
      encPriv: encPriv,
      encPub: encPub,
      scanPriv: scanPriv,
      scanPub: scanPub,
    );

    // Build and encode the invite envelope.
    final envelope = AliasInviteEnvelope(
      encPub: encPub,
      scanPub: scanPub,
      pqPub: pqKeys.publicKey,
    );
    final envelopeBytes = envelope.encode();

    // Save pending invite row (no inviteSecret — not needed in envelope flow).
    await _repo.savePendingInvite(
      PendingInvite(
        inviteRef: inviteRef,
        aliasDisplay: alias,
        isCreator: true,
        status: 'pending',
        createdAt: _nowSecs(),
      ),
    );

    return (inviteRef: inviteRef, envelopeBytes: envelopeBytes);
  }

  /// Discard an abandoned creator invite (from [createInvitationEnvelope]) that
  /// never completed a handshake: erase its temp key material and delete the
  /// pending row. No-op if the invite already promoted to a contact (so a
  /// completed handshake is never torn down) or never existed. Both underlying
  /// ops are idempotent. Used when the My QR Code screen is left before the
  /// partner's reply is scanned.
  Future<void> discardPendingInvite(String inviteRef) async {
    if (await _repo.getAliasContact(_contactId(inviteRef)) != null) return;
    await _keyService.eraseTempKeysByRef(inviteRef);
    await _repo.deletePendingInvite(inviteRef);
  }

  // ---------------------------------------------------------------------------
  // Step 2: Accept invitation (acceptor device)
  // ---------------------------------------------------------------------------

  /// Parse an invite URI and return the inviteSecret and optional creatorWallet.
  ///
  /// URI form: `sealed://alias?c=<inviteSecret>&w=<creatorWallet>`
  ///
  /// `w` is optional for backward compat with old URIs.
  static ({String inviteSecret, String? creatorWallet})? parseInviteUri(
    String uri,
  ) {
    final p = Uri.tryParse(uri);
    if (p == null || p.scheme != 'sealed' || p.host != 'alias') return null;
    final c = p.queryParameters['c'];
    if (c == null || c.isEmpty) return null;
    final w = p.queryParameters['w'];
    return (inviteSecret: c, creatorWallet: w?.isNotEmpty == true ? w : null);
  }

  /// Record an inbound invite envelope as a durable receiver-side pending row
  /// so it surfaces in `ChatsScreen` (banner + invitation row) before the user
  /// accepts. Acceptance/decline are deferred to explicit user action; the raw
  /// envelope is carried by the synthetic DM `MessageSync` also writes.
  ///
  /// Idempotent: no-op if this invite is already a contact (accepted), already
  /// pending, or has been dismissed — so it survives re-sync / forceResync.
  /// Returns the inviteRef (always), even when no new row was written.
  Future<String> recordIncomingInvite({
    required AliasInviteEnvelope env,
    required String senderWallet,
  }) async {
    final inviteRef = await _inviteRefFromPubs(
      env.encPub,
      env.scanPub,
      env.pqPub,
    );

    // Already accepted?
    if (await _repo.getAliasContact(_contactId(inviteRef)) != null) {
      return inviteRef;
    }
    // Already pending or dismissed? (dismissed rows persist with the flag set)
    if (await _repo.getPendingInvite(inviteRef) != null) {
      return inviteRef;
    }

    await _repo.savePendingInvite(
      PendingInvite(
        inviteRef: inviteRef,
        // No alias handle on the wire envelope; label by sender for the UI.
        aliasDisplay: senderWallet,
        isCreator: false,
        status: 'pending',
        createdAt: _nowSecs(),
      ),
    );
    return inviteRef;
  }

  /// Accept an alias invite received as a DM envelope.
  ///
  /// Does not call _findDiscoveryNote. inviteRef derived purely from envelope fields.
  /// Returns the promoted AliasContact + the 841-byte accept envelope to send back.
  Future<({AliasContact contact, Uint8List acceptEnvelopeBytes})>
  acceptInvitationFromEnvelope({
    required AliasInviteEnvelope env,
    required String alias,
  }) async {
    // inviteRef = sha256hex(encPub||scanPub||pqPub) — matches creator's computation.
    final inviteRef = await _inviteRefFromPubs(
      env.encPub,
      env.scanPub,
      env.pqPub,
    );
    final contactId = _contactId(inviteRef);

    // Idempotency: already accepted?
    final existing = await _repo.getAliasContact(contactId);
    if (existing != null) {
      // Return empty acceptEnvelopeBytes — caller must not re-send.
      return (contact: existing, acceptEnvelopeBytes: Uint8List(0));
    }

    // Generate acceptor's ephemeral X25519 enc + scan keypairs (in-memory only).
    final x25519 = X25519();
    final myEncKp = await x25519.newKeyPair();
    final myScanKp = await x25519.newKeyPair();
    final myEncPub = Uint8List.fromList(
      (await myEncKp.extractPublicKey()).bytes,
    );
    final myScanPub = Uint8List.fromList(
      (await myScanKp.extractPublicKey()).bytes,
    );
    final myEncSk = Uint8List.fromList(await myEncKp.extractPrivateKeyBytes());
    final myScanSk = Uint8List.fromList(
      await myScanKp.extractPrivateKeyBytes(),
    );

    // Classical ECDH: acceptor enc-sk × creator enc-pub.
    final classicalShared = await x25519.sharedSecretKey(
      keyPair: myEncKp,
      remotePublicKey: SimplePublicKey(env.encPub, type: KeyPairType.x25519),
    );
    final classicalBytes = Uint8List.fromList(
      await classicalShared.extractBytes(),
    );

    // PQ KEM-encapsulate creator's pub.
    final kemResult = await _cryptoService.kemEncapsulate(env.pqPub);
    final pqSharedBytes = kemResult.sharedSecret;
    final kemCiphertext = kemResult.ciphertext;

    // Derive shared secret + related keys.
    final sharedSecret = await _deriveSharedSecret(
      classicalBytes,
      pqSharedBytes,
    );
    final recipientTag = await _cryptoService.computeAliasRecipientTag(
      sharedSecret,
    );
    final msgKey = await _deriveMsgKey(sharedSecret);
    final tagSalt = _randomBytes(16);

    // Build accept envelope: [0x02][inviteRefPrefix:8][myEncPub:32][myScanPub:32][kemCT:768].
    // inviteRefPrefix = first 8 raw bytes of sha256(encPub||scanPub||pqPub).
    final inviteRefRawHash = await _inviteRefRawHash(
      env.encPub,
      env.scanPub,
      env.pqPub,
    );
    final inviteRefPrefix = Uint8List.fromList(inviteRefRawHash.sublist(0, 8));
    final acceptEnvelope = AliasAcceptEnvelope(
      inviteRefPrefix: inviteRefPrefix,
      encPub: myEncPub,
      scanPub: myScanPub,
      kemCiphertext: kemCiphertext,
    );
    final acceptEnvelopeBytes = acceptEnvelope.encode();

    final contact = AliasContact(
      contactId: contactId,
      createdAt: _nowSecs(),
      keys: ContactKeys(
        sharedSecret: sharedSecret,
        recipientTag: recipientTag,
        msgKey: msgKey,
        peerX25519Pub: env.encPub,
        peerX25519Scan: env.scanPub,
        peerMlkemPub: env.pqPub,
        myX25519Sk: myEncSk,
        myX25519ScanSk: myScanSk,
        myMlkemSk: null, // acceptor never generates a KEM keypair
        tagSalt: tagSalt,
        pqSharedSecret: pqSharedBytes,
      ),
      aliasHandle: alias,
      inviteRef: inviteRef,
      isCreator: false,
    );

    // Save pending row then immediately promote (acceptor completes in one step).
    await _repo.savePendingInvite(
      PendingInvite(
        inviteRef: inviteRef,
        aliasDisplay: alias,
        isCreator: false,
        status: 'awaiting_accept',
        createdAt: _nowSecs(),
      ),
    );
    await _repo.promotePendingToContact(inviteRef: inviteRef, contact: contact);

    await _onContactEstablished?.call(contact.contactId);

    return (contact: contact, acceptEnvelopeBytes: acceptEnvelopeBytes);
  }

  // ---------------------------------------------------------------------------
  // Step 3b: Complete key exchange via accept envelope (creator device)
  // ---------------------------------------------------------------------------

  /// Finalize the alias KEX when an accept envelope arrives via DM.
  ///
  /// Looks up the pending invite by 8-byte inviteRefPrefix scan.
  /// Loads creator's temp keys (stored by inviteRef at T2).
  /// Derives identical sharedSecret/recipientTag as acceptor.
  /// Idempotent: returns existing contact if already promoted.
  /// Returns null if no matching pending invite found (envelope for unknown invite).
  Future<AliasContact?> completeFromAcceptEnvelope(
    AliasAcceptEnvelope env,
  ) async {
    // Find matching pending invite by 8-byte inviteRefPrefix scan.
    // Also check already-promoted contacts (idempotency after pending row deleted).
    final allPending = await _repo.getAllPendingInvites();
    String? matchedInviteRef;
    for (final p in allPending) {
      if (!p.isCreator) continue;
      final rawHash = _inviteRefRawHashFromHex(p.inviteRef);
      if (rawHash == null) continue;
      if (_ctEq(
        Uint8List.fromList(rawHash.sublist(0, 8)),
        env.inviteRefPrefix,
      )) {
        matchedInviteRef = p.inviteRef;
        break;
      }
    }
    if (matchedInviteRef == null) {
      // Pending row may already be deleted (contact promoted). Check existing contacts.
      final allContacts = await _repo.getAllAliasContacts();
      for (final c in allContacts) {
        if (!c.isCreator) continue;
        final rawHash = _inviteRefRawHashFromHex(c.inviteRef);
        if (rawHash == null) continue;
        if (_ctEq(
          Uint8List.fromList(rawHash.sublist(0, 8)),
          env.inviteRefPrefix,
        )) {
          return c; // already promoted — idempotent
        }
      }
      debugPrint(
        '[ALIAS-ONBOARD] completeFromAcceptEnvelope: no matching pending invite for prefix',
      );
      return null;
    }

    final contactId = _contactId(matchedInviteRef);

    // Idempotency: already promoted?
    final existing = await _repo.getAliasContact(contactId);
    if (existing != null) return existing;

    // Load creator's temp X25519 + PQ keys (stored by inviteRef at createInvitationEnvelope).
    final tempKeys = await _keyService.loadTempKeyPairByRef(matchedInviteRef);
    if (tempKeys == null) {
      debugPrint(
        '[ALIAS-ONBOARD] completeFromAcceptEnvelope: temp X25519 keys missing for $matchedInviteRef',
      );
      return null;
    }
    final pqPrivKey = await _keyService.loadTempPqPrivateKeyByRef(
      matchedInviteRef,
    );
    if (pqPrivKey == null) {
      debugPrint(
        '[ALIAS-ONBOARD] completeFromAcceptEnvelope: temp PQ key missing for $matchedInviteRef',
      );
      return null;
    }

    // Reconstruct creator enc SimpleKeyPair.
    final x25519 = X25519();
    final creatorEncKp = SimpleKeyPairData(
      tempKeys.enc.privateKey,
      publicKey: SimplePublicKey(
        tempKeys.enc.publicKey,
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );

    // Classical ECDH: creator enc-sk × acceptor enc-pub.
    final classicalShared = await x25519.sharedSecretKey(
      keyPair: creatorEncKp,
      remotePublicKey: SimplePublicKey(env.encPub, type: KeyPairType.x25519),
    );
    final classicalBytes = Uint8List.fromList(
      await classicalShared.extractBytes(),
    );

    // PQ KEM-decapsulate.
    final pqSharedBytes = await _cryptoService.kemDecapsulate(
      env.kemCiphertext,
      pqPrivKey,
    );

    // Derive shared keys — must match acceptor's derivation.
    final sharedSecret = await _deriveSharedSecret(
      classicalBytes,
      pqSharedBytes,
    );
    final recipientTag = await _cryptoService.computeAliasRecipientTag(
      sharedSecret,
    );
    final msgKey = await _deriveMsgKey(sharedSecret);
    final tagSalt = _randomBytes(16);

    final pending = await _repo.getPendingInvite(matchedInviteRef);

    final contact = AliasContact(
      contactId: contactId,
      createdAt: _nowSecs(),
      keys: ContactKeys(
        sharedSecret: sharedSecret,
        recipientTag: recipientTag,
        msgKey: msgKey,
        peerX25519Pub: env.encPub,
        peerX25519Scan: env.scanPub,
        peerMlkemPub: null, // acceptor has no KEM pub in envelope flow
        myX25519Sk: tempKeys.enc.privateKey,
        myX25519ScanSk: tempKeys.scan.privateKey,
        myMlkemSk: pqPrivKey,
        tagSalt: tagSalt,
        pqSharedSecret: pqSharedBytes,
      ),
      aliasHandle: pending?.aliasDisplay ?? 'Alias',
      inviteRef: matchedInviteRef,
      isCreator: true,
    );

    await _repo.promotePendingToContact(
      inviteRef: matchedInviteRef,
      contact: contact,
    );

    // Erase temp key material — KEX complete.
    await _keyService.eraseTempKeysByRef(matchedInviteRef);

    await _onContactEstablished?.call(contact.contactId);

    return contact;
  }

  // ---------------------------------------------------------------------------
  // Step 3: Complete key exchange (creator device polls for accept note)
  // ---------------------------------------------------------------------------

  /// Poll own wallet for the accept note and finalize.
  ///
  /// Returns the completed [AliasContact] or null if accept note not yet on-chain.
  /// Idempotent: returns existing contact if key exchange already completed.
  Future<AliasContact?> completeKeyExchange(String inviteSecret) async {
    final secretBytes = _secretBytes(inviteSecret);
    final inviteRef = await _inviteRef(secretBytes);
    final contactId = _contactId(inviteRef);

    // Already completed?
    final existing = await _repo.getAliasContact(contactId);
    if (existing != null) return existing;

    // Not pending either? Nothing to do.
    final pending = await _repo.getPendingInvite(inviteRef);
    if (pending == null) return null;

    // Find accept note via global tag scan (no recipient filter).
    final acceptPayload = await _findDiscoveryNote(
      secretBytes,
      ALIAS_ACCEPT_TAG_LABEL,
    );
    if (acceptPayload == null) return null;

    if (acceptPayload.length < 832) {
      debugPrint(
        '[ALIAS-ONBOARD] Accept payload too short: ${acceptPayload.length}B',
      );
      return null;
    }

    final acceptorEncPub = acceptPayload.sublist(0, 32);
    final acceptorScanPub = acceptPayload.sublist(32, 64);
    final kemCiphertext = acceptPayload.sublist(64, 832);

    // Load creator's temp X25519 enc keypair.
    final tempKeys = await _keyService.loadTempKeyPair(inviteSecret);
    if (tempKeys == null) {
      debugPrint('[ALIAS-ONBOARD] Temp X25519 keys missing for $inviteSecret');
      return null;
    }
    final pqPrivKey = await _keyService.loadTempPqPrivateKey(inviteSecret);
    if (pqPrivKey == null) {
      debugPrint(
        '[ALIAS-ONBOARD] Temp PQ private key missing for $inviteSecret',
      );
      return null;
    }

    // Reconstruct creator's enc SimpleKeyPair.
    final creatorEncKp = SimpleKeyPairData(
      tempKeys.enc.privateKey,
      publicKey: SimplePublicKey(
        tempKeys.enc.publicKey,
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );

    // Classical ECDH (creator enc-sk × acceptor enc-pub).
    final x25519 = X25519();
    final classicalShared = await x25519.sharedSecretKey(
      keyPair: creatorEncKp,
      remotePublicKey: SimplePublicKey(
        acceptorEncPub,
        type: KeyPairType.x25519,
      ),
    );
    final classicalBytes = Uint8List.fromList(
      await classicalShared.extractBytes(),
    );

    // PQ KEM-decapsulate.
    final pqSharedBytes = await _cryptoService.kemDecapsulate(
      kemCiphertext,
      pqPrivKey,
    );

    // Derive shared keys.
    final sharedSecret = await _deriveSharedSecret(
      classicalBytes,
      pqSharedBytes,
    );
    final recipientTag = await _cryptoService.computeAliasRecipientTag(
      sharedSecret,
    );
    final msgKey = await _deriveMsgKey(sharedSecret);
    final tagSalt = _randomBytes(16);

    final contact = AliasContact(
      contactId: contactId,
      createdAt: _nowSecs(),
      keys: ContactKeys(
        sharedSecret: sharedSecret,
        recipientTag: recipientTag,
        msgKey: msgKey,
        peerX25519Pub: acceptorEncPub,
        peerX25519Scan: acceptorScanPub,
        peerMlkemPub: null, // acceptor doesn't have a KEM pub in current scheme
        myX25519Sk: tempKeys.enc.privateKey,
        myX25519ScanSk: tempKeys.scan.privateKey,
        myMlkemSk: pqPrivKey,
        tagSalt: tagSalt,
        pqSharedSecret: pqSharedBytes,
      ),
      aliasHandle: pending.aliasDisplay,
      inviteRef: inviteRef,
      isCreator: true,
    );

    // Atomic: insert contact + delete pending row.
    await _repo.promotePendingToContact(inviteRef: inviteRef, contact: contact);

    // Store contactId → inviteSecret mapping for the delete path.
    await _keyService.storeInviteSecretForContact(
      contact.contactId,
      inviteSecret,
    );
    // Erase temp key material + stored invite secret from secure storage.
    await _keyService.eraseTempKeys(inviteSecret);
    await _keyService.eraseInviteSecret(inviteRef);

    return contact;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Uint8List _secretBytes(String inviteSecret) =>
      Uint8List.fromList(base64Url.decode(inviteSecret));

  Future<String> _inviteRef(Uint8List secretBytes) async {
    final hash = await Sha256().hash(secretBytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// inviteRef for envelope flow: sha256hex(encPub || scanPub || pqPub).
  /// Acceptor computes the same from the parsed envelope fields.
  Future<String> _inviteRefFromPubs(
    Uint8List encPub,
    Uint8List scanPub,
    Uint8List pqPub,
  ) async {
    final combined = Uint8List.fromList([...encPub, ...scanPub, ...pqPub]);
    final hash = await Sha256().hash(combined);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Raw sha256 bytes for inviteRefPrefix computation.
  Future<List<int>> _inviteRefRawHash(
    Uint8List encPub,
    Uint8List scanPub,
    Uint8List pqPub,
  ) async {
    final combined = Uint8List.fromList([...encPub, ...scanPub, ...pqPub]);
    final hash = await Sha256().hash(combined);
    return hash.bytes;
  }

  /// Decode a hex inviteRef back to raw bytes for prefix comparison.
  /// Returns null if inviteRef is not valid hex.
  List<int>? _inviteRefRawHashFromHex(String inviteRef) {
    if (inviteRef.length < 16) return null;
    try {
      final bytes = <int>[];
      for (int i = 0; i < inviteRef.length; i += 2) {
        bytes.add(int.parse(inviteRef.substring(i, i + 2), radix: 16));
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// contactId = first 32 hex chars of inviteRef (stable, non-guessable, short).
  String _contactId(String inviteRef) => inviteRef.substring(0, 32);

  Future<Uint8List> _hmacDiscoveryTag(
    Uint8List secretBytes,
    String label,
  ) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(label),
      secretKey: SecretKey(secretBytes),
    );
    return Uint8List.fromList(mac.bytes);
  }

  Future<Uint8List> _discoveryKey(Uint8List secretBytes) async {
    final hash = await Sha256().hash(secretBytes);
    return Uint8List.fromList(hash.bytes);
  }

  Future<Uint8List> _encryptDiscovery(
    Uint8List secretBytes,
    Uint8List payload,
  ) async {
    final key = await _discoveryKey(secretBytes);
    return _cryptoService.encryptWithEncKey(
      encKey: key,
      plainTextBytes: payload,
    );
  }

  Future<Uint8List> _decryptDiscovery(
    Uint8List secretBytes,
    Uint8List ciphertext,
  ) async {
    final key = await _discoveryKey(secretBytes);
    return _cryptoService.decryptWithEncKey(
      encKey: key,
      cipherText: ciphertext,
    );
  }

  Future<Uint8List?> _findDiscoveryNote(
    Uint8List secretBytes,
    String label,
  ) async {
    final expectedTag = await _hmacDiscoveryTag(secretBytes, label);
    // Tag-based discovery: scan ALL app-call notes globally and match by
    // HMAC tag client-side. We deliberately avoid filtering by sender or
    // recipient so the indexer operator cannot observe which wallet pair is
    // negotiating an alias chat.
    final notes = await _chain.fetchAllNotes();
    for (final note in notes) {
      final tag = note['recipientTag'] as Uint8List?;
      if (tag == null) continue;
      if (!_ctEq(tag, expectedTag)) continue;
      final ct = note['ciphertext'] as Uint8List;
      try {
        return await _decryptDiscovery(secretBytes, ct);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<Uint8List> _deriveSharedSecret(
    Uint8List classicalBytes,
    Uint8List pqSharedBytes,
  ) async {
    final combined = Uint8List.fromList([...classicalBytes, ...pqSharedBytes]);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(combined),
      info: utf8.encode('sealed-hybrid-aes-gcm-v1'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  Future<Uint8List> _deriveMsgKey(Uint8List sharedSecret) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      info: utf8.encode('sealed-msg-key-v1'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  Uint8List _randomBytes(int n) => secureRandomBytes(n);

  int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static bool _ctEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
