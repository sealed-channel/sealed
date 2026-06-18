/// Alias chat cryptographic key management service.
/// Handles shared secret derivation, invitation keys, and
/// ephemeral cryptographic material for anonymous channels.
library;

import 'dart:convert';
import 'package:sealed_app/infra/crypto/secure_random.dart';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/models/contact.dart' show AliasContact;

/// Manages cryptographic key material for alias chats.
///
/// During key exchange (pending state) a temporary X25519 keypair and a
/// temporary ML-KEM-512 keypair are stored here. Once key exchange completes
/// the enc_key (hybrid X25519 + ML-KEM derived key) is stored and all
/// temporary keypairs are erased.
///
/// After key exchange the device stores only:
///   alias_{inviteSecret}_enckey     — 32-byte symmetric enc_key
///   alias_{inviteSecret}_rectag     — 32-byte recipientTag (HMAC of enc_key)
class AliasKeyService {
  final FlutterSecureStorage _storage;
  final X25519 _x25519;
  final ContactRepository? _contactRepo;

  AliasKeyService({
    FlutterSecureStorage? storage,
    X25519? x25519,
    ContactRepository? contactRepository,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _x25519 = x25519 ?? X25519(),
       _contactRepo = contactRepository;

  // ---------------------------------------------------------------------------
  // Key naming
  // ---------------------------------------------------------------------------
  String _encKeyName(String inviteSecret) => 'alias_${inviteSecret}_enckey';
  String _recTagName(String inviteSecret) => 'alias_${inviteSecret}_rectag';
  // Temporary X25519 enc-role keypair (erased after key exchange).
  // Legacy single-pair naming retained as the enc slot to avoid a flutter_secure_storage
  // key rename for in-flight invites (pre-launch — none exist, but keeps API stable).
  String _tempEncPrivName(String inviteSecret) =>
      'alias_${inviteSecret}_tmp_priv';
  String _tempEncPubName(String inviteSecret) =>
      'alias_${inviteSecret}_tmp_pub';
  // Temporary X25519 scan-role keypair (erased after key exchange). Bootstrap
  // payload v2 carries this pubkey alongside the enc pubkey so the peer can
  // derive recipient_tags via ECDH(ephemeral_sk, scan_pub).
  String _tempScanPrivName(String inviteSecret) =>
      'alias_${inviteSecret}_tmp_scan_priv';
  String _tempScanPubName(String inviteSecret) =>
      'alias_${inviteSecret}_tmp_scan_pub';
  // Temporary PQ keypair (erased after key exchange)
  String _pqPrivName(String inviteSecret) => 'alias_${inviteSecret}_pq_priv';
  String _pqPubName(String inviteSecret) => 'alias_${inviteSecret}_pq_pub';

  // Invite secret (stored by creator after createInvitation; erased after completeKeyExchange).
  String _inviteSecretName(String inviteRef) =>
      'alias_${inviteRef}_invite_secret';

  // contactId → inviteSecret mapping (stored after key exchange for delete path).
  String _contactInviteSecretName(String contactId) =>
      'alias_contact_${contactId}_secret';

  // ---------------------------------------------------------------------------
  // Temporary X25519 keypairs (used during key-exchange only)
  // ---------------------------------------------------------------------------

  /// Generate two X25519 keypairs (enc + scan) for a new alias chat and
  /// persist both until key exchange completes.
  ///
  /// - `enc` is the role used for ECDH against the peer's ephemeral pubkey on
  ///   each send to derive the message AES key.
  /// - `scan` is the role whose pubkey the *peer* uses to derive `recipient_tag`
  ///   when sending to us; the private side is needed locally to scan inbound
  ///   messages and to register a view key with the push indexer.
  ///
  /// Returned record: `(enc: keypair, scan: keypair)`.
  Future<
    ({
      ({Uint8List privateKey, Uint8List publicKey}) enc,
      ({Uint8List privateKey, Uint8List publicKey}) scan,
    })
  >
  generateTempKeyPair(String inviteSecret) async {
    final enc = await _newTempPair();
    final scan = await _newTempPair();

    await _storage.write(
      key: _tempEncPrivName(inviteSecret),
      value: base64Encode(enc.privateKey),
    );
    await _storage.write(
      key: _tempEncPubName(inviteSecret),
      value: base64Encode(enc.publicKey),
    );
    await _storage.write(
      key: _tempScanPrivName(inviteSecret),
      value: base64Encode(scan.privateKey),
    );
    await _storage.write(
      key: _tempScanPubName(inviteSecret),
      value: base64Encode(scan.publicKey),
    );

    return (enc: enc, scan: scan);
  }

  Future<({Uint8List privateKey, Uint8List publicKey})> _newTempPair() async {
    final keyPair = await _x25519.newKeyPair();
    final privateBytes = Uint8List.fromList(
      await keyPair.extractPrivateKeyBytes(),
    );
    final publicBytes = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );
    return (privateKey: privateBytes, publicKey: publicBytes);
  }

  /// Load both temp X25519 keypairs (null if either is missing/erased).
  Future<
    ({
      ({Uint8List privateKey, Uint8List publicKey}) enc,
      ({Uint8List privateKey, Uint8List publicKey}) scan,
    })?
  >
  loadTempKeyPair(String inviteSecret) async {
    final encPriv = await _storage.read(key: _tempEncPrivName(inviteSecret));
    final encPub = await _storage.read(key: _tempEncPubName(inviteSecret));
    final scanPriv = await _storage.read(key: _tempScanPrivName(inviteSecret));
    final scanPub = await _storage.read(key: _tempScanPubName(inviteSecret));
    if (encPriv == null ||
        encPub == null ||
        scanPriv == null ||
        scanPub == null) {
      return null;
    }
    return (
      enc: (
        privateKey: Uint8List.fromList(base64Decode(encPriv)),
        publicKey: Uint8List.fromList(base64Decode(encPub)),
      ),
      scan: (
        privateKey: Uint8List.fromList(base64Decode(scanPriv)),
        publicKey: Uint8List.fromList(base64Decode(scanPub)),
      ),
    );
  }

  /// Reconstruct a [SimpleKeyPair] from the stored enc-role temp bytes for
  /// use with `CryptoService`. The scan-role keypair is only needed for tag
  /// derivation + indexer registration and is exposed as raw bytes via
  /// [loadTempKeyPair].
  Future<SimpleKeyPair?> getTempKeyPairForCrypto(String inviteSecret) async {
    final keys = await loadTempKeyPair(inviteSecret);
    if (keys == null) return null;
    return SimpleKeyPairData(
      keys.enc.privateKey,
      publicKey: SimplePublicKey(keys.enc.publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  // ---------------------------------------------------------------------------
  // Temporary ML-KEM-512 keypair (used during key-exchange only)
  // ---------------------------------------------------------------------------

  /// Persist a temporary PQ keypair generated externally (by CryptoService).
  Future<void> storeTempPqKeyPair(
    String inviteSecret, {
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await _storage.write(
      key: _pqPrivName(inviteSecret),
      value: base64Encode(privateKey),
    );
    await _storage.write(
      key: _pqPubName(inviteSecret),
      value: base64Encode(publicKey),
    );
  }

  /// Load the temporary PQ private key (null if already erased).
  Future<Uint8List?> loadTempPqPrivateKey(String inviteSecret) async {
    final b64 = await _storage.read(key: _pqPrivName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Load the temporary PQ public key (null if already erased).
  Future<Uint8List?> loadTempPqPublicKey(String inviteSecret) async {
    final b64 = await _storage.read(key: _pqPubName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  // ---------------------------------------------------------------------------
  // Derived enc_key + recipientTag (stored after key exchange)
  // ---------------------------------------------------------------------------

  /// Store the final enc_key and pre-computed recipientTag after key exchange.
  /// Call this after deriving enc_key; temporary keypairs can then be erased.
  Future<void> storeEncKey(
    String inviteSecret, {
    required Uint8List encKey,
    required Uint8List recipientTag,
  }) async {
    await _storage.write(
      key: _encKeyName(inviteSecret),
      value: base64Encode(encKey),
    );
    await _storage.write(
      key: _recTagName(inviteSecret),
      value: base64Encode(recipientTag),
    );
  }

  /// Load the enc_key for a channel (null if not yet derived or already wiped).
  Future<Uint8List?> getEncKey(String inviteSecret) async {
    final b64 = await _storage.read(key: _encKeyName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Load the pre-computed recipientTag for a channel.
  Future<Uint8List?> getRecipientTag(String inviteSecret) async {
    final b64 = await _storage.read(key: _recTagName(inviteSecret));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  // ---------------------------------------------------------------------------
  // Envelope-flow helpers (keyed by inviteRef, not inviteSecret)
  //
  // Envelope flow derives inviteRef = sha256(encPub||scanPub||pqPub) from the
  // invite envelope itself, so there is no inviteSecret string.  These methods
  // mirror the inviteSecret-keyed variants but use a "ref_" prefix to avoid
  // any collision with the legacy on-chain flow keys.
  // ---------------------------------------------------------------------------

  String _refEncPrivName(String inviteRef) => 'alias_ref_${inviteRef}_tmp_priv';
  String _refEncPubName(String inviteRef) => 'alias_ref_${inviteRef}_tmp_pub';
  String _refScanPrivName(String inviteRef) =>
      'alias_ref_${inviteRef}_tmp_scan_priv';
  String _refScanPubName(String inviteRef) =>
      'alias_ref_${inviteRef}_tmp_scan_pub';
  String _refPqPrivName(String inviteRef) => 'alias_ref_${inviteRef}_pq_priv';
  String _refPqPubName(String inviteRef) => 'alias_ref_${inviteRef}_pq_pub';

  /// Store pre-generated X25519 keypairs (enc + scan) keyed by [inviteRef].
  /// Use when the pubkeys are needed before storage (e.g. to compute inviteRef).
  Future<void> storeTempX25519ByRef(
    String inviteRef, {
    required Uint8List encPriv,
    required Uint8List encPub,
    required Uint8List scanPriv,
    required Uint8List scanPub,
  }) async {
    await _storage.write(
      key: _refEncPrivName(inviteRef),
      value: base64Encode(encPriv),
    );
    await _storage.write(
      key: _refEncPubName(inviteRef),
      value: base64Encode(encPub),
    );
    await _storage.write(
      key: _refScanPrivName(inviteRef),
      value: base64Encode(scanPriv),
    );
    await _storage.write(
      key: _refScanPubName(inviteRef),
      value: base64Encode(scanPub),
    );
  }

  /// Generate two X25519 keypairs (enc + scan) and persist under [inviteRef].
  Future<
    ({
      ({Uint8List privateKey, Uint8List publicKey}) enc,
      ({Uint8List privateKey, Uint8List publicKey}) scan,
    })
  >
  generateTempKeyPairByRef(String inviteRef) async {
    final enc = await _newTempPair();
    final scan = await _newTempPair();

    await _storage.write(
      key: _refEncPrivName(inviteRef),
      value: base64Encode(enc.privateKey),
    );
    await _storage.write(
      key: _refEncPubName(inviteRef),
      value: base64Encode(enc.publicKey),
    );
    await _storage.write(
      key: _refScanPrivName(inviteRef),
      value: base64Encode(scan.privateKey),
    );
    await _storage.write(
      key: _refScanPubName(inviteRef),
      value: base64Encode(scan.publicKey),
    );

    return (enc: enc, scan: scan);
  }

  /// Load both temp X25519 keypairs keyed by [inviteRef] (null if missing/erased).
  Future<
    ({
      ({Uint8List privateKey, Uint8List publicKey}) enc,
      ({Uint8List privateKey, Uint8List publicKey}) scan,
    })?
  >
  loadTempKeyPairByRef(String inviteRef) async {
    final encPriv = await _storage.read(key: _refEncPrivName(inviteRef));
    final encPub = await _storage.read(key: _refEncPubName(inviteRef));
    final scanPriv = await _storage.read(key: _refScanPrivName(inviteRef));
    final scanPub = await _storage.read(key: _refScanPubName(inviteRef));
    if (encPriv == null ||
        encPub == null ||
        scanPriv == null ||
        scanPub == null)
      return null;
    return (
      enc: (
        privateKey: Uint8List.fromList(base64Decode(encPriv)),
        publicKey: Uint8List.fromList(base64Decode(encPub)),
      ),
      scan: (
        privateKey: Uint8List.fromList(base64Decode(scanPriv)),
        publicKey: Uint8List.fromList(base64Decode(scanPub)),
      ),
    );
  }

  /// Persist a temporary PQ keypair keyed by [inviteRef].
  Future<void> storeTempPqKeyPairByRef(
    String inviteRef, {
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await _storage.write(
      key: _refPqPrivName(inviteRef),
      value: base64Encode(privateKey),
    );
    await _storage.write(
      key: _refPqPubName(inviteRef),
      value: base64Encode(publicKey),
    );
  }

  /// Load the temporary PQ private key keyed by [inviteRef].
  Future<Uint8List?> loadTempPqPrivateKeyByRef(String inviteRef) async {
    final b64 = await _storage.read(key: _refPqPrivName(inviteRef));
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Erase all temporary key material keyed by [inviteRef].
  Future<void> eraseTempKeysByRef(String inviteRef) async {
    await _storage.delete(key: _refEncPrivName(inviteRef));
    await _storage.delete(key: _refEncPubName(inviteRef));
    await _storage.delete(key: _refScanPrivName(inviteRef));
    await _storage.delete(key: _refScanPubName(inviteRef));
    await _storage.delete(key: _refPqPrivName(inviteRef));
    await _storage.delete(key: _refPqPubName(inviteRef));
  }

  // ---------------------------------------------------------------------------
  // Lifecycle helpers
  // ---------------------------------------------------------------------------

  /// Persist raw inviteSecret keyed by inviteRef (creator only).
  /// Needed so the sync loop can call completeKeyExchange(inviteSecret)
  /// when it detects an accept note on-chain.
  Future<void> storeInviteSecret(String inviteRef, String inviteSecret) =>
      _storage.write(key: _inviteSecretName(inviteRef), value: inviteSecret);

  /// Load raw inviteSecret for [inviteRef]. Returns null if already erased.
  Future<String?> loadInviteSecret(String inviteRef) =>
      _storage.read(key: _inviteSecretName(inviteRef));

  /// Erase the stored invite secret (call after completeKeyExchange succeeds).
  Future<void> eraseInviteSecret(String inviteRef) =>
      _storage.delete(key: _inviteSecretName(inviteRef));

  /// Persist inviteSecret keyed by contactId (stored after key exchange).
  /// Needed so the delete path can erase enc/rec keys from secure storage.
  Future<void> storeInviteSecretForContact(
    String contactId,
    String inviteSecret,
  ) => _storage.write(
    key: _contactInviteSecretName(contactId),
    value: inviteSecret,
  );

  /// Load inviteSecret for [contactId]. Returns null if not stored.
  Future<String?> loadInviteSecretForContact(String contactId) =>
      _storage.read(key: _contactInviteSecretName(contactId));

  /// Erase the contactId → inviteSecret mapping.
  Future<void> eraseInviteSecretForContact(String contactId) =>
      _storage.delete(key: _contactInviteSecretName(contactId));

  /// Erase all temporary key material for a channel (X25519 enc + scan + PQ).
  /// Call this immediately after storeEncKey() succeeds.
  Future<void> eraseTempKeys(String inviteSecret) async {
    await _storage.delete(key: _tempEncPrivName(inviteSecret));
    await _storage.delete(key: _tempEncPubName(inviteSecret));
    await _storage.delete(key: _tempScanPrivName(inviteSecret));
    await _storage.delete(key: _tempScanPubName(inviteSecret));
    await _storage.delete(key: _pqPrivName(inviteSecret));
    await _storage.delete(key: _pqPubName(inviteSecret));
  }

  /// Erase enc_key and recipientTag for a channel (used when destroying the
  /// alias chat).
  Future<void> eraseEncKey(String inviteSecret) async {
    await _storage.delete(key: _encKeyName(inviteSecret));
    await _storage.delete(key: _recTagName(inviteSecret));
  }

  /// Erase everything associated with a channel.
  Future<void> deleteAll(String inviteSecret) async {
    await eraseTempKeys(inviteSecret);
    await eraseEncKey(inviteSecret);
  }

  /// Delete all alias key material (used on logout).
  Future<void> deleteAllChannels() async {
    final all = await _storage.readAll();
    for (final key in all.keys) {
      if (key.startsWith('alias_')) {
        await _storage.delete(key: key);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Per-alias scan_priv accessors (for indexer push registration)
  //
  // Each alias contact stores its own X25519 scan secret (`myX25519ScanSk`)
  // on the [AliasContact] row in the SQLCipher contacts table. Outgoing
  // messages from the peer use this scan_pub to derive
  //   recipient_tag = HMAC(X25519(eph_sk, peerScanPub), "sealed-recipient-tag-v1")
  // so the indexer needs this device's scan_priv to trial-decrypt and
  // dispatch a targeted push. The plain view_priv (main key) does NOT match
  // alias chat messages; that is why a separate registration row per alias
  // contact is required.
  //
  // These helpers expose the scan_priv bytes by contactId so
  // [IndexerService] can register/unregister them without reaching into the
  // contacts repo from the network layer.
  // ---------------------------------------------------------------------------

  /// Load a single alias contact's scan_priv (32 bytes). Returns null if the
  /// contact is missing or not an [AliasContact].
  Future<Uint8List?> loadAliasScanPrivForContact(String contactId) async {
    final repo = _contactRepo;
    if (repo == null) return null;
    final c = await repo.getAliasContact(contactId);
    if (c == null) return null;
    return c.keys.myX25519ScanSk;
  }

  /// Load every alias contact's scan_priv along with its contactId so callers
  /// can correlate registrations to logical contacts.
  Future<List<({String contactId, Uint8List scanPriv})>>
  loadAllAliasScanPrivs() async {
    final repo = _contactRepo;
    if (repo == null) return const [];
    final all = await repo.getAllAliasContacts();
    return [
      for (final c in all)
        (contactId: c.contactId, scanPriv: c.keys.myX25519ScanSk),
    ];
  }

  /// Generate a random 32-byte invite secret (base64url-encoded).
  static String generateInviteSecret() {
    return base64Url.encode(secureRandomBytes(32));
  }
}
