/// Sealed unified-contract chain client.
///
/// Targets the unified Sealed Algorand app (post-cutover, replaces the legacy
/// trio `topup` + `alias_channel` + `sealed_message`). All user-mutating
/// methods ride a 2-txn fee-pool group:
///
///   Txn 0 — TreasuryEscrow self-payment, amount=0, fee covers both txns plus
///           any opup inner-appl budget. The escrow LogicSig invariants force
///           this shape (see `treasury_escrow_signer.dart`).
///   Txn 1 — App-call NoOp targeting `SEALED_APP_ID` with method selector +
///           args. Fee=0; covered by Txn 0's bumped fee per Algorand's fee
///           pool rule.
///
/// The sender wallet only signs Txn 1. Txn 0 is signed by wrapping the escrow
/// program bytes as a LogicSig — no ed25519 signature required.
///
/// Covered ABI: `sendMessage`, `redeem`, `publishKeys`, `claimUsername`,
/// `releaseUsername`, plus readonly `getCredits` + box reads
/// (`getUserByWallet`, `getUserByUsername`).
library;

import 'dart:convert';
import 'package:sealed_app/core/log.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:dio/dio.dart';
import 'package:messagepack/messagepack.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/models/user_profile.dart';

/// Minimal signer surface used by [SealedChainClient].
///
/// Lets callers swap the identity wallet for a per-channel ephemeral signer
/// without exposing the full [AlgorandWallet] API.
abstract class SealedSigner {
  /// 32-byte Ed25519 public key (the txn `snd` field).
  Uint8List get senderPubkey;

  /// Sign canonical-msgpack-encoded txn bytes (already prefixed with "TX").
  Future<Uint8List> signTransactionBytes(Uint8List bytes);
}

/// True only when [e] genuinely indicates a logic-eval / bad-or-spent-code
/// rejection on the redeem path — i.e. the contract asserted `BAD_CODE` (the
/// `c:<sha256(preimage)>` commitment box is missing) or `BAD_PREIMAGE`.
///
/// Deliberately conservative: this is a paid product, so we must NOT tell a
/// user their valid code is burned for transient or unrelated failures.
/// Returns false (→ caller rethrows the original error untouched) for:
///   • pool errors (fee too small / lastValid expired) — code still unspent,
///   • the credit-batch limit (`TOO_MANY_BATCHES` / "batch limit") — full box,
///   • HTTP 5xx relay/gateway failures — server-side, code untouched,
///   • responseless DioException (timeout / no connectivity).
bool isBadCodeRejection(Object e) {
  // Markers algod emits for a TEAL logic-eval rejection (the contract assert).
  const evalMarkers = [
    'bad_code',
    'bad_preimage',
    'logic eval error',
    'rejected by logic',
    'assert',
  ];
  bool hasEvalMarker(String haystack) {
    final lower = haystack.toLowerCase();
    return evalMarkers.any(lower.contains);
  }

  if (e is GenericSealedException) {
    // Probe message AND details together: the disambiguating context lives in
    // the message (`pool-error: …`, `algod rejected group (HTTP 5xx): …`) while
    // `details` carries only the raw inner body, so checking details alone
    // misses the exclusions.
    final probe = '${e.toString()} ${e.details ?? ''}';
    final lower = probe.toLowerCase();
    // Explicitly exclude non-code failures that can otherwise share wording.
    if (lower.contains('pool-error') ||
        lower.contains('too_many_batches') ||
        lower.contains('batch limit') ||
        lower.contains('http 5')) {
      return false;
    }
    return hasEvalMarker(probe);
  }

  if (e is DioException && e.response != null) {
    final status = e.response!.statusCode ?? 0;
    if (status < 400 || status >= 500) return false; // only 4xx is a rejection
    return hasEvalMarker('${e.response!.data}');
  }

  return false;
}

class SealedChainClient {
  /// ARC4 selector for `sendMessage(byte[32],byte[])void`.
  static final Uint8List sendMessageSelector = Uint8List.fromList([
    0x05,
    0x20,
    0xee,
    0xbb,
  ]);

  /// ARC4 selector for `publishKeys(byte[32],byte[32],byte[])void`.
  /// sha512_256("publishKeys(byte[32],byte[32],byte[])void")[0..4].
  static final Uint8List publishKeysSelector = Uint8List.fromList([
    0xe2,
    0x8c,
    0x04,
    0x34,
  ]);

  /// ARC4 selector for `claimUsername(byte[])void`.
  /// sha512_256("claimUsername(byte[])void")[0..4].
  static final Uint8List claimUsernameSelector = Uint8List.fromList([
    0x27,
    0x34,
    0x39,
    0x94,
  ]);

  /// ARC4 selector for `releaseUsername()void`.
  /// sha512_256("releaseUsername()void")[0..4].
  static final Uint8List releaseUsernameSelector = Uint8List.fromList([
    0xec,
    0x03,
    0xaf,
    0x64,
  ]);

  /// ARC4 selector for `setBio(byte[])void`.
  /// sha512_256("setBio(byte[])void")[0..4].
  static final Uint8List setBioSelector = Uint8List.fromList([
    0xf4,
    0x28,
    0xf4,
    0x7a,
  ]);

  /// Max bio length in BYTES (UTF-8 encoded) — mirrors contract `BIO_MAX`.
  static const int bioMaxBytes = 160;

  /// ARC4 selector for `redeem(byte[],byte[])void`.
  /// sha512_256("redeem(byte[],byte[])void")[0..4].
  static final Uint8List redeemSelector = Uint8List.fromList([
    0x85,
    0x60,
    0xbf,
    0x42,
  ]);

  /// ARC4 selector for
  /// `redeemWithProof(byte[32],byte[32],byte[],byte[],byte[])void`.
  /// sha512_256("redeemWithProof(byte[32],byte[32],byte[],byte[],byte[])void")[0..4].
  static final Uint8List redeemWithProofSelector = Uint8List.fromList([
    0xbe,
    0x2a,
    0xd9,
    0xef,
  ]);

  /// Fee pool (µAlgo) for the `redeemWithProof` group's escrow self-pay leg.
  /// Sized per the contract docblock + T5 integration test: ~115 OpUp inner
  /// txns + outer + MBR-seed inner-pay = 220_000 µA worst case.
  static const int redeemWithProofFeePool = 220000;

  /// ARC4 selector for
  /// `redeemAndPublish(byte[],byte[32],byte[32],byte[])void`.
  /// sha512_256("redeemAndPublish(byte[],byte[32],byte[32],byte[])void")[0..4].
  static final Uint8List redeemAndPublishSelector = Uint8List.fromList([
    0xcd,
    0x60,
    0xea,
    0x68,
  ]);

  /// ARC4 selector for `redeemWithProofAndPublishKeys(byte[32],byte[32],byte[],
  /// byte[],byte[32],byte[32],byte[])void`. sha512_256(sig)[0..4]. Folds the
  /// PQ-key publish into the SNARK redeem so a SNARK-sold-code buyer keeps the
  /// full denomination (no separate publishKeys credit spend).
  static final Uint8List redeemWithProofAndPublishKeysSelector =
      Uint8List.fromList([
    0x1a,
    0x2a,
    0xa3,
    0xfb,
  ]);

  /// ARC4 selector for `getCredits(address)uint64`.
  /// sha512_256("getCredits(address)uint64")[0..4].
  static final Uint8List getCreditsSelector = Uint8List.fromList([
    0xe1,
    0x43,
    0x9c,
    0x0c,
  ]);

  final int sealedAppId;
  final String algodUrl;
  final String indexerUrl;
  final AlgorandWallet wallet;
  final TreasuryEscrowSigner escrow;
  final Dio _dio;

  SealedChainClient({
    required this.sealedAppId,
    required this.algodUrl,
    required this.indexerUrl,
    required this.wallet,
    required this.escrow,
    Dio? dio,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
               responseType: ResponseType.json,
               headers: {'Accept': 'application/json'},
             ),
           );

  /// Submit `sendMessage(recipientTag, framed)` as a 2-txn fee-pool group.
  ///
  /// `framed` = senderEphemeralPubkey(32) || ciphertext  — sent ABI-encoded
  /// as `byte[]` (2-byte BE length prefix prepended automatically).
  ///
  /// Returns the app-call (Txn 1) transaction ID.
  Future<String> sendMessage({
    required Uint8List recipientTag,
    required Uint8List senderEphemeralPubkey,
    required Uint8List ciphertext,
  }) async {
    if (recipientTag.length != 32) {
      throw ArgumentError('recipientTag must be 32 bytes');
    }
    if (senderEphemeralPubkey.length != 32) {
      throw ArgumentError('senderEphemeralPubkey must be 32 bytes');
    }

    if (wallet.walletAddress == null) {
      throw StateError('Wallet not loaded');
    }

    final framed = Uint8List(32 + ciphertext.length)
      ..setRange(0, 32, senderEphemeralPubkey)
      ..setRange(32, 32 + ciphertext.length, ciphertext);

    final params = await _getSuggestedParams();
    final senderPubkey = _decodeAddress(wallet.walletAddress!);

    // Escrow Txn 0: self-payment, amount=0, fee covers both txns (2 * minFee).
    final escrowTxn = _buildEscrowSelfPayTxn(
      escrowPubkey: escrow.addressPubkey,
      fee: params.minFee * 2,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
    );

    // App-call Txn 1: fee=0, paid via the escrow's fee pool surplus.
    // Box ref: `w:<sender>` — Phase 3b spendOneCredit reads/writes UserState.
    final appCallTxn = _buildAppCallTxnWithBoxes(
      senderPubkey: senderPubkey,
      appId: sealedAppId,
      methodSelector: sendMessageSelector,
      appArgs: [recipientTag, _encodeAbiDynamicBytes(framed)],
      boxes: [_makeWalletBoxKey(senderPubkey)],
      fee: 0,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
    );

    // Compute group ID over ungrouped txns, then bind both to it.
    final groupId = _computeGroupId([escrowTxn, appCallTxn]);
    escrowTxn['grp'] = groupId;
    appCallTxn['grp'] = groupId;

    // Sign each leg.
    final escrowSigned = escrow.encodeSignedTxn(escrowTxn);
    final appCallToSign = _encodeTxForSigning(appCallTxn);
    final appCallSig = await wallet.signTransactionBytes(appCallToSign);
    final appCallSigned = _encodeSignedTxWithEd25519(appCallTxn, appCallSig);

    // Submit concatenated msgpack blobs in group order (escrow first).
    final blob = Uint8List(escrowSigned.length + appCallSigned.length)
      ..setRange(0, escrowSigned.length, escrowSigned)
      ..setRange(
        escrowSigned.length,
        escrowSigned.length + appCallSigned.length,
        appCallSigned,
      );

    final appCallTxId = _computeTxId(appCallTxn);
    await _submitGroup(blob);
    return appCallTxId;
  }

  /// Claim or rename a username for the caller.
  ///
  /// SC Phase 3b: spends 1 credit. Throws [NoCreditsError] before submit when
  /// balance is zero. Call [estimateCreditCost] first to surface the cost in UI.
  ///
  /// Atomic delete-old + create-new on rename (net MBR = 0). Caller must
  /// already have a credit box (prior `redeem`). Throws typed exceptions on
  /// contract rejection via [_mapContractError].
  ///
  /// Box refs: `n:<sha256(name)>` (new), `w:<sender>` (credit state). Old
  /// name's `n:` box is resolved by algod via `allow-unnamed-resources` at
  /// simulate; for the actual submit we declare new+wallet only — the
  /// contract's old-name delete uses an *itxn* MBR refund that doesn't
  /// require pre-declaration. If a rename fails with "invalid Box reference",
  /// caller passes the old name explicitly via [oldName].
  Future<String> claimUsername(String username, {String? oldName}) async {
    final nameBytes = utf8.encode(username);
    // Contract enforces NAME_MIN=3, NAME_MAX=20. Reject early with typed error
    // rather than letting the contract revert BAD_LEN.
    if (nameBytes.length < 3 || nameBytes.length > 20) {
      throw const BadUsernameFormatError(
        'BAD_LEN',
        'Username must be 3-20 bytes (a-z, 0-9, _).',
      );
    }
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');

    final credits = await getCredits(wallet.walletAddress!);
    Log.d('[claimUsername] credits=$credits');
    if (credits < 1) throw const NoCreditsError();

    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final nameBoxKey = _makeNameBoxKey(Uint8List.fromList(nameBytes));
    final walletBoxKey = _makeWalletBoxKey(senderPubkey);
    final boxes = <Uint8List>[nameBoxKey, walletBoxKey];
    if (oldName != null && oldName.isNotEmpty) {
      boxes.add(_makeNameBoxKey(Uint8List.fromList(utf8.encode(oldName))));
    }

    return _mapContractError(() async {
      final params = await _getSuggestedParams();
      // Phase 3b: claimUsername calls ensureBudget(2400, GroupCredit) which
      // spawns ~3 opup inner-appl txns funded from group fee credit. Pool
      // 5 × minFee: 1 escrow leg + 1 app-call leg + 3 opup itxns.
      final escrowTxn = _buildEscrowSelfPayTxn(
        escrowPubkey: escrow.addressPubkey,
        fee: params.minFee * 5,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final appCallTxn = _buildAppCallTxnWithBoxes(
        senderPubkey: senderPubkey,
        appId: sealedAppId,
        methodSelector: claimUsernameSelector,
        appArgs: [_encodeAbiDynamicBytes(Uint8List.fromList(nameBytes))],
        boxes: boxes,
        fee: 0,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      return _signAndSubmitGroup(escrowTxn, appCallTxn);
    });
  }

  /// Clear the caller's username slot.
  ///
  /// SC Phase 3b: spends 1 credit. Throws [NoCreditsError] before submit when
  /// balance is zero. Call [estimateCreditCost] first to surface the cost in UI.
  ///
  /// Auto-resolves the prior username from the on-chain UserState box and
  /// declares the `n:<oldName>` box ref so submits never trip
  /// `invalid Box reference`. Caller may pass [oldName] to skip the profile
  /// read.
  Future<String> releaseUsername({String? oldName}) async {
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');

    // SC Phase 3b: credit-gated
    final credits = await getCredits(wallet.walletAddress!);
    if (credits < 1) throw const NoCreditsError();

    // Resolve oldName from on-chain UserState if not supplied. Phase 3b
    // contract reads `prev.username` and walks `n:<sha256(name)>` — without
    // a pre-declared box ref algod rejects on submit.
    String? resolvedOld = oldName;
    if (resolvedOld == null || resolvedOld.isEmpty) {
      final profile = await getUserByWallet(wallet.walletAddress!);
      resolvedOld = profile?.username;
    }
    if (resolvedOld == null || resolvedOld.isEmpty) {
      // Contract reverts NO_USERNAME; surface as typed error pre-submit.
      throw const GenericSealedException('No username set to release.');
    }

    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final boxes = <Uint8List>[
      _makeWalletBoxKey(senderPubkey),
      _makeNameBoxKey(Uint8List.fromList(utf8.encode(resolvedOld))),
    ];

    return _mapContractError(() async {
      final params = await _getSuggestedParams();
      // Phase 3b: releaseUsername calls ensureBudget(2400, GroupCredit).
      // Pool 5 × minFee for opup itxns (same budget as claimUsername).
      final escrowTxn = _buildEscrowSelfPayTxn(
        escrowPubkey: escrow.addressPubkey,
        fee: params.minFee * 5,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final appCallTxn = _buildAppCallTxnWithBoxes(
        senderPubkey: senderPubkey,
        appId: sealedAppId,
        methodSelector: releaseUsernameSelector,
        appArgs: const [],
        boxes: boxes,
        fee: 0,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      return _signAndSubmitGroup(escrowTxn, appCallTxn);
    });
  }

  /// Set or clear the caller's public profile bio.
  ///
  /// `setBio(byte[])void` — UserState v3. Free-form UTF-8 capped at
  /// [bioMaxBytes] BYTES (multibyte chars count as encoded width); empty
  /// string clears the field. Spends 1 credit ([NoCreditsError] surfaced
  /// pre-submit). Bio is public on-chain plaintext, same exposure as
  /// username.
  ///
  /// Box refs: `w:<sender>` only — no reverse-index box, unlike usernames.
  Future<String> setBio(String bio) async {
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');
    final bioBytes = utf8.encode(bio);
    if (bioBytes.length > bioMaxBytes) {
      throw const BioTooLongError();
    }

    final credits = await getCredits(wallet.walletAddress!);
    if (credits < 1) throw const NoCreditsError();

    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final boxes = <Uint8List>[_makeWalletBoxKey(senderPubkey)];

    return _mapContractError(() async {
      final params = await _getSuggestedParams();
      // setBio calls ensureBudget(2400, GroupCredit) — same fee pool as
      // claimUsername: 1 escrow leg + 1 app-call leg + 3 opup itxns.
      final escrowTxn = _buildEscrowSelfPayTxn(
        escrowPubkey: escrow.addressPubkey,
        fee: params.minFee * 5,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final appCallTxn = _buildAppCallTxnWithBoxes(
        senderPubkey: senderPubkey,
        appId: sealedAppId,
        methodSelector: setBioSelector,
        appArgs: [_encodeAbiDynamicBytes(Uint8List.fromList(bioBytes))],
        boxes: boxes,
        fee: 0,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      return _signAndSubmitGroup(escrowTxn, appCallTxn);
    });
  }

  /// Dry-run credit cost for any 1-credit operation (claimUsername,
  /// releaseUsername, publishKeys).
  ///
  /// Returns [CreditCost] with current balance and post-op balance.
  /// Throws [NoCreditsError] if balance is 0 (caller can show error early).
  /// No txn is submitted.
  Future<CreditCost> estimateCreditCost() async {
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');
    final current = await getCredits(wallet.walletAddress!);
    if (current < 1) throw const NoCreditsError();
    return CreditCost(current: current, after: current - 1);
  }

  /// Submit `redeem(preimage, username)` as a 2-txn fee-pool group.
  ///
  /// `preimage` must be 16 bytes (`PREIMAGE_LEN` per contract). `username`
  /// may be empty (deferred claim — recommended path; pass empty and call
  /// [claimUsername] separately to avoid the contract's `USERNAME_SET` /
  /// `USERNAME_NOT_IMPL` cliff on rename-via-redeem).
  ///
  /// Box refs: `c:<sha256(preimage)>` (commitment, deleted on success),
  /// `w:<sender>` (credit box, created or appended), and `n:<sha256(name)>`
  /// if [username] non-empty.
  Future<String> redeem({
    required Uint8List preimage,
    String username = '',
  }) async {
    if (preimage.length != 16) {
      throw ArgumentError('preimage must be 16 bytes');
    }
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');
    final nameBytes = username.isEmpty
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(username));
    // Contract enforces NAME_MIN=3, NAME_MAX=20 when non-empty. Empty allowed
    // (deferred claim path).
    if (nameBytes.isNotEmpty &&
        (nameBytes.length < 3 || nameBytes.length > 20)) {
      throw const BadUsernameFormatError(
        'BAD_LEN',
        'Username must be 3-20 bytes (a-z, 0-9, _).',
      );
    }
    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final boxes = <Uint8List>[
      _makeCommitmentBoxKey(preimage),
      _makeWalletBoxKey(senderPubkey),
    ];
    if (nameBytes.isNotEmpty) {
      boxes.add(_makeNameBoxKey(nameBytes));
    }

    return _mapContractError(() async {
      final params = await _getSuggestedParams();
      // Belt-and-suspenders: even if _getSuggestedParams ever returns 0,
      // hard-floor at 1000µA so the escrow leg always pays the protocol
      // minimum (escrow pays both legs via fee pooling).
      final perLegFee = params.minFee < 1000 ? 1000 : params.minFee;
      // Pool 3 × minFee: escrow leg + app-call leg + 1 potential inner-txn
      // (contract seeds caller MBR via `itxn.payment{fee:0}` when balance <
      // ACCOUNT_MBR_MIN; itxn fee is drawn from group surplus). Without this
      // headroom, redeems from 0-ALGO wallets fail "group fee 0.0A too small".
      // ignore: avoid_print
      Log.d('[redeem] minFee=${params.minFee} escrowFee=${perLegFee * 3}');
      final escrowTxn = _buildEscrowSelfPayTxn(
        escrowPubkey: escrow.addressPubkey,
        fee: perLegFee * 3,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final appCallTxn = _buildAppCallTxnWithBoxes(
        senderPubkey: senderPubkey,
        appId: sealedAppId,
        methodSelector: redeemSelector,
        appArgs: [
          _encodeAbiDynamicBytes(preimage),
          _encodeAbiDynamicBytes(nameBytes),
        ],
        boxes: boxes,
        fee: 0,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final txId = await _signAndSubmitGroup(escrowTxn, appCallTxn);
      // Block on confirmation so silent reverts (logic-eval errors, missing
      // boxes, dead commitments) surface as exceptions instead of UI lying
      // "Code redeemed".
      await waitForConfirmation(txId);
      return txId;
    });
  }

  /// Submit `redeemAndPublish(preimage, encPub, scanPub, pqPub)` as a 2-txn
  /// fee-pool group. Combines `redeem` + `publishKeys` atomically and SKIPS
  /// the credit spend on the publish leg, so the caller keeps the full
  /// `denomination` credits (e.g. 500 instead of the legacy two-call 499).
  ///
  /// Use this on fresh-wallet onboarding. The contract enforces:
  ///   - `preimage.length == 16`
  ///   - `pqPubkey.length ∈ [32, 2048]`
  ///   - sale-pool 1-year expiry fuse (if `soldAtRound > 0`)
  ///
  /// Box refs: `c:<sha256(preimage)>` + `w:<sender>`. Username is always
  /// empty on this path — `claimUsername` is a separate call.
  ///
  /// Escrow fee pool: 5 × minFee covers commitment delete + UserState write +
  /// `KeysPublished` event log (up to 2048B pqPub) + sha256 + optional
  /// MBR-seed inner-txn for 0-ALGO wallets.
  Future<String> redeemAndPublish({
    required Uint8List preimage,
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    if (preimage.length != 16) {
      throw ArgumentError('preimage must be 16 bytes');
    }
    if (encryptionPubkey.length != 32) {
      throw ArgumentError('encryptionPubkey must be 32 bytes');
    }
    if (scanPubkey.length != 32) {
      throw ArgumentError('scanPubkey must be 32 bytes');
    }
    if (pqPubkey.length < 32 || pqPubkey.length > 2048) {
      throw ArgumentError('pqPubkey must be 32–2048 bytes');
    }
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');

    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final boxes = <Uint8List>[
      _makeCommitmentBoxKey(preimage),
      _makeWalletBoxKey(senderPubkey),
    ];

    try {
      return await _mapContractError(() async {
        final params = await _getSuggestedParams();
        final perLegFee = params.minFee < 1000 ? 1000 : params.minFee;
        final escrowTxn = _buildEscrowSelfPayTxn(
          escrowPubkey: escrow.addressPubkey,
          fee: perLegFee * 5,
          firstValid: params.firstValid,
          lastValid: params.lastValid,
          genesisId: params.genesisId,
          genesisHash: params.genesisHash,
        );
        final appCallTxn = _buildAppCallTxnWithBoxes(
          senderPubkey: senderPubkey,
          appId: sealedAppId,
          methodSelector: redeemAndPublishSelector,
          appArgs: [
            _encodeAbiDynamicBytes(preimage),
            encryptionPubkey,
            scanPubkey,
            _encodeAbiDynamicBytes(pqPubkey),
          ],
          boxes: boxes,
          fee: 0,
          firstValid: params.firstValid,
          lastValid: params.lastValid,
          genesisId: params.genesisId,
          genesisHash: params.genesisHash,
        );
        final txId = await _signAndSubmitGroup(escrowTxn, appCallTxn);
        await waitForConfirmation(txId);
        return txId;
      });
    } on BadRedeemCodeError {
      rethrow;
    } on RedeemSpentError {
      rethrow;
    } on RedeemContractError {
      rethrow;
    } on MbrShortfallError {
      rethrow;
    } catch (e) {
      // Unmapped failure on the redeem path. The only user-supplied input here
      // is the code, and the contract asserts `BAD_CODE` when the
      // `c:<sha256(preimage)>` commitment box is missing (bad or already-spent
      // code), or `BAD_PREIMAGE`. Map to BadRedeemCodeError ONLY when the error
      // actually carries a logic-eval / bad-code marker — see
      // [isBadCodeRejection]. Everything else (pool errors, credit-batch limit,
      // HTTP 5xx relay failures, responseless DioException / timeouts) is a
      // transient or unrelated failure where the paid code is still unspent, so
      // we must rethrow it unchanged rather than burn-flag a valid code.
      if (isBadCodeRejection(e)) throw const BadRedeemCodeError();
      rethrow;
    }
  }

  /// Submit `redeemWithProof(rootRef, nullifier, proof, pubInputs, username)`
  /// as a 2-txn fee-pool group (SPEC-snark-redeem-B §4.1).
  ///
  /// Args are passed straight through — caller is responsible for the proof
  /// byte layout (`A_G1 || B_G2 || C_G1` = 256B) and `pubInputs` (4 Fr's
  /// BE-32B each = 128B).
  ///
  /// Box refs:
  ///   `r:<rootRef>`         — Merkle-root metadata box (read).
  ///   `nb:<nullifier>`      — nullifier box (created → DOUBLE_SPEND if exists).
  ///   `w:<senderPubkey>`    — credit state (created or appended).
  ///   `n:<sha256(username)>` — only when [username] non-null/non-empty.
  ///
  /// Fee pool: [redeemWithProofFeePool] µAlgo on the escrow leg, paid by the
  /// treasury escrow LogicSig. App-call leg fee=0 (pooled).
  Future<String> redeemWithProof({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    String? username,
  }) async {
    if (rootRef.length != 32) {
      throw ArgumentError('rootRef must be 32 bytes');
    }
    if (nullifier.length != 32) {
      throw ArgumentError('nullifier must be 32 bytes');
    }
    if (pubInputs.length != 128) {
      throw ArgumentError('pubInputs must be 128 bytes (4 × 32B Fr)');
    }
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');

    final nameBytes = (username == null || username.isEmpty)
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(username));
    if (nameBytes.isNotEmpty &&
        (nameBytes.length < 3 || nameBytes.length > 20)) {
      throw const BadUsernameFormatError(
        'BAD_LEN',
        'Username must be 3-20 bytes (a-z, 0-9, _).',
      );
    }

    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final boxes = <Uint8List>[
      _makeRootBoxKey(rootRef),
      _makeNullifierBoxKey(nullifier),
      _makeWalletBoxKey(senderPubkey),
    ];
    if (nameBytes.isNotEmpty) {
      boxes.add(_makeNameBoxKey(nameBytes));
    }

    return _mapContractError(() async {
      final params = await _getSuggestedParams();
      final escrowTxn = _buildEscrowSelfPayTxn(
        escrowPubkey: escrow.addressPubkey,
        fee: redeemWithProofFeePool,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final appCallTxn = _buildAppCallTxnWithBoxes(
        senderPubkey: senderPubkey,
        appId: sealedAppId,
        methodSelector: redeemWithProofSelector,
        appArgs: [
          rootRef,
          nullifier,
          _encodeAbiDynamicBytes(proof),
          _encodeAbiDynamicBytes(pubInputs),
          _encodeAbiDynamicBytes(nameBytes),
        ],
        boxes: boxes,
        fee: 0,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final txId = await _signAndSubmitGroup(escrowTxn, appCallTxn);
      await waitForConfirmation(txId);
      return txId;
    });
  }

  /// Submit `redeemWithProofAndPublishKeys(rootRef, nullifier, proof,
  /// pubInputs, encPub, scanPub, pqPub)` as a 2-txn fee-pool group.
  ///
  /// Identical group shape, boxes, and fee pool as [redeemWithProof] — it just
  /// also writes the caller's key triple in the same call, so a SNARK-sold-code
  /// buyer redeems the full denomination AND publishes keys without paying the
  /// separate publishKeys credit (no atomic alternative otherwise exists).
  /// Claims no username; use `claimUsername` separately.
  ///
  /// Box refs: `r:<rootRef>`, `nb:<nullifier>`, `w:<senderPubkey>`.
  Future<String> redeemWithProofAndPublishKeys({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    if (rootRef.length != 32) {
      throw ArgumentError('rootRef must be 32 bytes');
    }
    if (nullifier.length != 32) {
      throw ArgumentError('nullifier must be 32 bytes');
    }
    if (pubInputs.length != 128) {
      throw ArgumentError('pubInputs must be 128 bytes (4 × 32B Fr)');
    }
    if (encryptionPubkey.length != 32) {
      throw ArgumentError('encryptionPubkey must be 32 bytes');
    }
    if (scanPubkey.length != 32) {
      throw ArgumentError('scanPubkey must be 32 bytes');
    }
    if (pqPubkey.length < 32 || pqPubkey.length > 2048) {
      throw ArgumentError('pqPubkey must be 32–2048 bytes');
    }
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');

    final senderPubkey = _decodeAddress(wallet.walletAddress!);
    final boxes = <Uint8List>[
      _makeRootBoxKey(rootRef),
      _makeNullifierBoxKey(nullifier),
      _makeWalletBoxKey(senderPubkey),
    ];

    return _mapContractError(() async {
      final params = await _getSuggestedParams();
      final escrowTxn = _buildEscrowSelfPayTxn(
        escrowPubkey: escrow.addressPubkey,
        fee: redeemWithProofFeePool,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final appCallTxn = _buildAppCallTxnWithBoxes(
        senderPubkey: senderPubkey,
        appId: sealedAppId,
        methodSelector: redeemWithProofAndPublishKeysSelector,
        appArgs: [
          rootRef,
          nullifier,
          _encodeAbiDynamicBytes(proof),
          _encodeAbiDynamicBytes(pubInputs),
          encryptionPubkey,
          scanPubkey,
          _encodeAbiDynamicBytes(pqPubkey),
        ],
        boxes: boxes,
        fee: 0,
        firstValid: params.firstValid,
        lastValid: params.lastValid,
        genesisId: params.genesisId,
        genesisHash: params.genesisHash,
      );
      final txId = await _signAndSubmitGroup(escrowTxn, appCallTxn);
      await waitForConfirmation(txId);
      return txId;
    });
  }

  /// Test seam: build (but do not sign or submit) the `redeemWithProof` 2-txn
  /// group. Exposes exact field layout to unit tests without needing a live
  /// algod or signer.
  static ({
    Map<String, dynamic> escrowTxn,
    Map<String, dynamic> appCallTxn,
    Uint8List groupId,
  })
  debugBuildRedeemWithProofGroup({
    required Uint8List senderPubkey,
    required Uint8List escrowPubkey,
    required int sealedAppId,
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    String? username,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
  }) {
    final nameBytes = (username == null || username.isEmpty)
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(username));
    final boxes = <Uint8List>[
      _makeRootBoxKey(rootRef),
      _makeNullifierBoxKey(nullifier),
      _makeWalletBoxKey(senderPubkey),
    ];
    if (nameBytes.isNotEmpty) {
      boxes.add(_makeNameBoxKey(nameBytes));
    }
    final escrowTxn = _buildEscrowSelfPayTxn(
      escrowPubkey: escrowPubkey,
      fee: redeemWithProofFeePool,
      firstValid: firstValid,
      lastValid: lastValid,
      genesisId: genesisId,
      genesisHash: genesisHash,
    );
    final appCallTxn = _buildAppCallTxnWithBoxes(
      senderPubkey: senderPubkey,
      appId: sealedAppId,
      methodSelector: redeemWithProofSelector,
      appArgs: [
        rootRef,
        nullifier,
        _encodeAbiDynamicBytes(proof),
        _encodeAbiDynamicBytes(pubInputs),
        _encodeAbiDynamicBytes(nameBytes),
      ],
      boxes: boxes,
      fee: 0,
      firstValid: firstValid,
      lastValid: lastValid,
      genesisId: genesisId,
      genesisHash: genesisHash,
    );
    final groupId = _computeGroupId([escrowTxn, appCallTxn]);
    final escrowGrouped = Map<String, dynamic>.from(escrowTxn)
      ..['grp'] = groupId;
    final appCallGrouped = Map<String, dynamic>.from(appCallTxn)
      ..['grp'] = groupId;
    return (
      escrowTxn: escrowGrouped,
      appCallTxn: appCallGrouped,
      groupId: groupId,
    );
  }

  // ---------------------------------------------------------------------------
  // Profile reads (algod box)
  // ---------------------------------------------------------------------------

  /// Read the `w:<wallet>` UserState box and return a [UserProfile].
  ///
  /// `pqPublicKey` is null — caller fetches lazily via [IndexerClient.getPqPublicKey]
  /// and verifies against `pqPubkeyHash`. Returns null when box doesn't exist.
  Future<UserProfile?> getUserByWallet(String walletAddress) async {
    final pubkey = _decodeAddress(walletAddress);
    final boxKey = _makeWalletBoxKey(pubkey);
    final raw = await _readBox(boxKey);
    if (raw == null) return null;
    final state = _decodeUserState(raw);
    return UserProfile(
      walletAddress: walletAddress,
      username: state.username.isEmpty
          ? null
          : utf8.decode(state.username, allowMalformed: false),
      bio: state.bio.isEmpty
          ? null
          : utf8.decode(state.bio, allowMalformed: true),
      encryptionPubkey: state.encryptionPubkey,
      scanPubkey: state.scanPubkey,
      pqPublicKey: null,
      pqPubkeyHash: _isZero32(state.pqPubkeyHash) ? null : state.pqPubkeyHash,
      createdAt: DateTime.now(),
    );
  }

  /// Resolve username → wallet via `n:<sha256(lower(name))>` box, then fetch profile.
  ///
  /// Two algod box reads, zero indexer calls. Returns null when name unclaimed.
  Future<UserProfile?> getUserByUsername(String name) async {
    final nameBytes = utf8.encode(name.toLowerCase());
    final nameBox = _makeNameBoxKey(Uint8List.fromList(nameBytes));
    final raw = await _readBox(nameBox);
    if (raw == null || raw.length < 32) return null;
    final walletAddress = _encodeAlgorandAddress(
      Uint8List.fromList(raw.sublist(0, 32)),
    );
    return getUserByWallet(walletAddress);
  }

  // ---------------------------------------------------------------------------
  // Fetch key publication txns (publishKeys only — publishPqKey deleted in SC)
  // ---------------------------------------------------------------------------

  /// Fetch `publishKeys` app-call txns from the indexer.
  ///
  /// Returns a list of maps with keys:
  ///   `senderAddress` (String), `selector` (Uint8List 4B),
  ///   `logs` (List<Uint8List>), `timestamp` (int, Unix seconds).
  ///
  /// Log layout: [sender(32), encPub(32), scanPub(32), pqPub(32..2048)]
  Future<List<Map<String, dynamic>>> fetchKeyPublicationTxns({
    String? senderAddress,
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    final queryParams = <String, dynamic>{
      'application-id': sealedAppId,
      'tx-type': 'appl',
      'limit': limit,
    };
    if (senderAddress != null) {
      queryParams['address'] = senderAddress;
    }
    if (sinceTimestamp != null && sinceTimestamp > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        sinceTimestamp * 1000,
        isUtc: true,
      );
      queryParams['after-time'] = dt.toIso8601String();
    }

    // Paginated; errors propagate (the sole caller wraps this in try/catch).
    final txList = await _fetchTxnPages(queryParams);
    final publishKeysB64 = base64Encode(publishKeysSelector);
    final results = <Map<String, dynamic>>[];

    for (final tx in txList) {
      final appTx = tx['application-transaction'] as Map<String, dynamic>?;
      if (appTx == null) continue;
      final args = (appTx['application-args'] as List?) ?? const [];
      if (args.isEmpty) continue;
      final selectorB64 = args[0] as String?;
      if (selectorB64 != publishKeysB64) continue;

      final rawLogs = (tx['logs'] as List?) ?? const [];
      if (rawLogs.isEmpty) continue;

      final logs = rawLogs
          .map((l) => base64Decode(l as String))
          .map(Uint8List.fromList)
          .toList();

      results.add({
        'senderAddress': (tx['sender'] as String?) ?? '',
        'selector': base64Decode(selectorB64!),
        'logs': logs,
        'timestamp': (tx['round-time'] as int?) ?? 0,
      });
    }

    return results;
  }

  // ---------------------------------------------------------------------------
  // Fetch messages (indexer queries against sealedAppId)
  // ---------------------------------------------------------------------------

  /// Fetch all `sendMessage` app-call txns for the current wallet.
  ///
  /// Returns a list of parsed message maps with keys:
  ///   `accountPubkey` (txId), `recipientTag` (Uint8List 32B),
  ///   `ciphertext` (Uint8List), `senderEncryptionPubkey` (Uint8List 32B),
  ///   `timestamp` (int, Unix seconds), `senderAddress` (String).
  Future<List<Map<String, dynamic>>> fetchMessages({
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    if (wallet.walletAddress == null) return [];
    return _fetchAppCallMessages(sinceTimestamp: sinceTimestamp, limit: limit);
  }

  /// Fetch `sendMessage` app-call txns filtered by a specific sender address.
  Future<List<Map<String, dynamic>>> fetchMessagesFromSender(
    String senderAddress, {
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    return _fetchAppCallMessages(
      senderAddress: senderAddress,
      sinceTimestamp: sinceTimestamp,
      limit: limit,
    );
  }

  /// Fetch ALL `sendMessage` app-call txns with no sender/recipient filter.
  ///
  /// Used for tag-based discovery (alias invite/accept) where filtering by a
  /// specific wallet would leak the queried wallet to the indexer operator.
  /// Caller filters client-side by `recipientTag`.
  Future<List<Map<String, dynamic>>> fetchAllAppMessages({
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    return _fetchAppCallMessages(sinceTimestamp: sinceTimestamp, limit: limit);
  }

  /// Core indexer query: scans app-call txns for [sealedAppId] with the
  /// `sendMessage` ABI selector, parses the framed args, and returns
  /// structured message maps.
  ///
  /// Optionally filters by [senderAddress]. When null, returns all txns
  /// for the app.
  Future<List<Map<String, dynamic>>> _fetchAppCallMessages({
    String? senderAddress,
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    final queryParams = <String, dynamic>{
      'application-id': sealedAppId,
      'tx-type': 'appl',
      'limit': limit,
    };
    if (senderAddress != null) {
      queryParams['address'] = senderAddress;
    }
    if (sinceTimestamp != null && sinceTimestamp > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        sinceTimestamp * 1000,
        isUtc: true,
      );
      queryParams['after-time'] = dt.toIso8601String();
    }

    // Paginate through ALL matching txns and let any transport/indexer error
    // PROPAGATE. A swallowed error here previously looked identical to "no new
    // messages", so the caller advanced its sync cursor past messages it never
    // fetched — permanent loss on any outage longer than the cursor buffer.
    final txList = await _fetchTxnPages(queryParams);
    final selectorB64 = base64Encode(sendMessageSelector);
    final messages = <Map<String, dynamic>>[];

    for (final tx in txList) {
      final appTx = tx['application-transaction'] as Map<String, dynamic>?;
      if (appTx == null) continue;
      final args = (appTx['application-args'] as List?) ?? const [];
      if (args.length < 3) continue;
      if (args[0] != selectorB64) continue;

      try {
        final recipientTag = base64Decode(args[1] as String);
        if (recipientTag.length != 32) continue;

        // ABI dynamic bytes: 2-byte big-endian length prefix + payload.
        final framedArg = base64Decode(args[2] as String);
        if (framedArg.length < 2) continue;
        final payloadLen = (framedArg[0] << 8) | framedArg[1];
        if (framedArg.length < 2 + payloadLen) continue;
        final framed = framedArg.sublist(2, 2 + payloadLen);

        // Wire layout: [senderEphemeralPubkey(32) || ciphertext]
        if (framed.length < 32) continue;
        final senderEncPubkey = Uint8List.fromList(framed.sublist(0, 32));
        final ciphertext = Uint8List.fromList(framed.sublist(32));

        final timestamp = (tx['round-time'] as int?) ?? 0;
        final txId = (tx['id'] as String?) ?? '';

        messages.add({
          'accountPubkey': txId,
          'recipientTag': Uint8List.fromList(recipientTag),
          'ciphertext': ciphertext,
          'senderEncryptionPubkey': senderEncPubkey,
          'timestamp': timestamp,
          'senderAddress': (tx['sender'] as String?) ?? '',
        });
      } catch (_) {
        // Per-txn parse failure (malformed/foreign arg layout) — skip just
        // this txn, never the whole batch.
        continue;
      }
    }

    messages.sort(
      (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int),
    );
    return messages;
  }

  /// Page through every `/v2/transactions` result for [baseParams], following
  /// the indexer's `next-token` until exhausted. Returns the combined raw txn
  /// maps. Errors propagate (callers that want best-effort empty results must
  /// catch). A single un-paginated `limit`-capped query previously dropped any
  /// message beyond the first page whenever app-wide traffic in the window
  /// exceeded the limit.
  Future<List<Map<String, dynamic>>> _fetchTxnPages(
    Map<String, dynamic> baseParams, {
    int maxPages = 100,
  }) async {
    final all = <Map<String, dynamic>>[];
    String? next;
    var pages = 0;

    do {
      final params = Map<String, dynamic>.from(baseParams);
      if (next != null && next.isNotEmpty) params['next'] = next;

      final resp = await _dio.get(
        '$indexerUrl/v2/transactions',
        queryParameters: params,
      );

      final txList = (resp.data['transactions'] as List?) ?? const [];
      all.addAll(txList.whereType<Map<String, dynamic>>());

      next = resp.data['next-token'] as String?;
      pages++;
      if (txList.isEmpty) break;
    } while (next != null && next.isNotEmpty && pages < maxPages);

    if (pages >= maxPages && next != null && next.isNotEmpty) {
      Log.w(
        '[ChainClient] pagination cap ($maxPages pages) hit — results may be '
        'truncated; some history not scanned this pass',
      );
    }
    return all;
  }

  /// Publish all cryptographic keys in a single txn.
  /// Publish all cryptographic keys in a single txn.
  ///
  /// `encryptionPubkey` and `scanPubkey` must be 32-byte X25519 public keys.
  /// `pqPubkey` must be 32–2048 bytes (ML-KEM-512 = 800 bytes).
  ///
  /// The contract logs [sender, encPub, scanPub, pqPub] — the indexer
  /// user-watcher picks these up to populate the profile lookup table.
  ///
  /// SC Phase 3b pre-conditions (checked client-side before submitting):
  ///   1. UserState box must exist — i.e. user has redeemed at least once.
  ///      Throws [NoBoxError] if missing.
  ///   2. Credit balance must be ≥ 1. Throws [NoCreditsError] if zero.
  /// Pre-checks are UX-only guards; the contract still asserts `NO_BOX` /
  /// `NO_CREDITS` on-chain so a race window is handled gracefully.
  Future<String> publishKeys({
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    if (encryptionPubkey.length != 32) {
      throw ArgumentError('encryptionPubkey must be 32 bytes');
    }
    if (scanPubkey.length != 32) {
      throw ArgumentError('scanPubkey must be 32 bytes');
    }
    if (pqPubkey.length < 32 || pqPubkey.length > 2048) {
      throw ArgumentError('pqPubkey must be 32–2048 bytes');
    }
    if (wallet.walletAddress == null) throw StateError('Wallet not loaded');
    // SC Phase 3b pre-conditions
    final profile = await getUserByWallet(wallet.walletAddress!);
    if (profile == null) throw const NoBoxError();
    final credits = await getCredits(wallet.walletAddress!);
    if (credits < 1) throw const NoCreditsError();

    final params = await _getSuggestedParams();
    final senderPubkey = _decodeAddress(wallet.walletAddress!);

    final escrowTxn = _buildEscrowSelfPayTxn(
      escrowPubkey: escrow.addressPubkey,
      fee: params.minFee * 2,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
    );
    final appCallTxn = _buildAppCallTxnWithBoxes(
      senderPubkey: senderPubkey,
      appId: sealedAppId,
      methodSelector: publishKeysSelector,
      appArgs: [encryptionPubkey, scanPubkey, _encodeAbiDynamicBytes(pqPubkey)],
      boxes: [_makeWalletBoxKey(senderPubkey)],
      fee: 0,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
    );

    return _signAndSubmitGroup(escrowTxn, appCallTxn);
  }

  /// Publish keys only if the on-chain UserState diverges from local material.
  ///
  /// Returns:
  ///   - `null` when no UserState box exists (caller hasn't redeemed — do NOT
  ///     throw; this is the post-redeem idempotency call site path).
  ///   - `null` when on-chain `pqPubkeyHash` matches `sha256(pqPubkey)` AND
  ///     `encryptionPubkey` + `scanPubkey` match (idempotent skip).
  ///   - the submitted app-call txId otherwise. The submitted txn is awaited
  ///     via [waitForConfirmation] before returning.
  Future<String?> publishKeysIfStale({
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    if (wallet.walletAddress == null) {
      throw StateError('Wallet not loaded');
    }
    final profile = await getUserByWallet(wallet.walletAddress!);
    if (profile == null) return null;
    final hash = Uint8List.fromList(pkg_crypto.sha256.convert(pqPubkey).bytes);
    if (isKeyPublicationFresh(
      onChainPqPubkeyHash: profile.pqPubkeyHash,
      onChainEncryptionPubkey: profile.encryptionPubkey,
      onChainScanPubkey: profile.scanPubkey,
      newPqPubkeyHash: hash,
      newEncryptionPubkey: encryptionPubkey,
      newScanPubkey: scanPubkey,
    )) {
      return null;
    }
    final txId = await publishKeys(
      encryptionPubkey: encryptionPubkey,
      scanPubkey: scanPubkey,
      pqPubkey: pqPubkey,
    );
    await waitForConfirmation(txId);
    return txId;
  }

  /// Pure comparison: returns true when on-chain key material matches what
  /// we would publish (and therefore the publish call can be skipped).
  ///
  /// Exposed as a static test seam — concrete [SealedChainClient] is
  /// awkward to mock, so the decision logic lives here and is exercised
  /// directly in unit tests.
  static bool isKeyPublicationFresh({
    required Uint8List? onChainPqPubkeyHash,
    required Uint8List onChainEncryptionPubkey,
    required Uint8List onChainScanPubkey,
    required Uint8List newPqPubkeyHash,
    required Uint8List newEncryptionPubkey,
    required Uint8List newScanPubkey,
  }) {
    if (onChainPqPubkeyHash == null) return false;
    return _bytesEqual(onChainPqPubkeyHash, newPqPubkeyHash) &&
        _bytesEqual(onChainEncryptionPubkey, newEncryptionPubkey) &&
        _bytesEqual(onChainScanPubkey, newScanPubkey);
  }

  /// Non-constant-time byte equality — this is a UX optimization, not a
  /// security check, so timing leaks are irrelevant here.
  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Readonly `getCredits(address)uint64` via algod simulate.
  ///
  /// Kept while credits UI still queries it directly. Candidate for removal
  /// once UI computes credits from [getUserByWallet] UserState batches.
  /// Returns 0 when the credit box does not exist.
  Future<int> getCredits(String address) async {
    final addrPubkey = _decodeAddress(address);
    final params = await _getSuggestedParams();
    // Readonly simulate. `getCredits(wallet)` reads the box keyed by the ARG,
    // not by Txn.sender, so the sender is irrelevant to the result. Use the
    // funded escrow as the simulate sender — NOT the user's wallet. Algod
    // /simulate deducts the txn fee from the sender during evaluation; a fresh
    // wallet is seeded to exactly ACCOUNT_MBR_MIN (100_000µA), so charging it a
    // minFee drops the evaluated balance below min and aborts the simulate with
    // "balance NN below min" — even though no funds ever move and the on-chain
    // balance is untouched. The escrow holds fee-pool headroom, so the phantom
    // fee deduction never trips its min-balance floor.
    final senderPubkey = escrow.addressPubkey;
    final appCallTxn = _buildAppCallTxnWithBoxes(
      senderPubkey: senderPubkey,
      appId: sealedAppId,
      methodSelector: getCreditsSelector,
      appArgs: [addrPubkey],
      boxes: [_makeWalletBoxKey(addrPubkey)],
      fee: params.minFee,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
    );
    final payload = await _simulateAbiReturn(appCallTxn);
    // ignore: avoid_print
    Log.d(
      '[getCredits] addr=${address.substring(0, 8)}… '
      'payload.len=${payload?.length} '
      'payload.hex=${payload == null ? "null" : payload.map((b) => b.toRadixString(16).padLeft(2, "0")).join()}',
    );
    if (payload == null || payload.length < 8) return 0;
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | payload[i];
    }
    return v;
  }

  // ---------------------------------------------------------------------------
  // Box read helpers
  // ---------------------------------------------------------------------------

  /// True iff the Merkle-root box `r:<rootRef>` exists on the configured app.
  ///
  /// The indexer's `/roots` registry is cumulative across every app it has
  /// watched, and historical batches can reuse a preimage, so a leaf can map to
  /// a root that was posted to a *different* app. Submitting such a root to this
  /// app fails on-chain with BAD_ROOT (`box_len; assert`). Callers pre-flight
  /// the root here and skip any candidate whose box is absent on this app.
  Future<bool> rootBoxExists(Uint8List rootRef) async {
    final raw = await _readBox(_makeRootBoxKey(rootRef));
    return raw != null;
  }

  /// Algod box GET — returns raw bytes or null on 404.
  ///
  /// `GET /v2/applications/:id/box?name=b64:<base64(boxKey)>`
  Future<Uint8List?> _readBox(Uint8List boxKey) async {
    try {
      final nameParam = 'b64:${base64Encode(boxKey)}';
      final resp = await _dio.get(
        '$algodUrl/v2/applications/$sealedAppId/box',
        queryParameters: {'name': nameParam},
        options: Options(headers: {'Accept': 'application/json'}),
      );
      final valueB64 = (resp.data as Map<String, dynamic>)['value'] as String?;
      if (valueB64 == null) return null;
      return Uint8List.fromList(base64Decode(valueB64));
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // UserState ARC4 decoder — wire versions v2 and v3
  //
  // v3 tuple: (uint8, byte[], uint8, (uint64,uint64)[], byte[32], byte[32],
  //            byte[32], byte[])           ← bio appended 2026-06-12
  // v2 tuple: same minus the trailing bio byte[].
  //
  // ARC4 tuple head for mixed static/dynamic fields:
  //   Each field is either inlined (static) or represented by a 2-byte BE offset
  //   into the tuple bytes (dynamic). Layout:
  //
  //   offset 0:   version      uint8      1B  static
  //   offset 1:   usernameOff  uint16     2B  → points to username length+data
  //   offset 3:   batchCount   uint8      1B  static
  //   offset 4:   batchesOff   uint16     2B  → points to batches array
  //   offset 6:   encPubkey    byte[32]  32B  static
  //   offset 38:  scanPubkey   byte[32]  32B  static
  //   offset 70:  pqPubkeyHash byte[32]  32B  static
  //   offset 102: bioOff       uint16     2B  → v3 ONLY
  //   Total head: 102 bytes (v2) / 104 bytes (v3)
  //
  //   Dynamic: username  = bytes[usernameOff .. usernameOff+2+len]
  //                        (2-byte BE length prefix + raw UTF8)
  //            batches   = bytes[batchesOff ..]
  //                        2-byte BE count + count × (uint64 BE + uint64 BE)
  //            bio (v3)  = bytes[bioOff .. bioOff+2+len]
  //
  // The contract migrates v2 boxes lazily (rewritten as v3 on the wallet's
  // next credit-spending write), so BOTH layouts are live on chain — branch
  // on the version byte. v2 decodes with an empty bio.
  // ---------------------------------------------------------------------------

  _DecodedUserState _decodeUserState(Uint8List bytes) {
    if (bytes.length < 102) {
      throw FormatException(
        'UserState too short: ${bytes.length} bytes (need ≥ 102)',
      );
    }

    // Fixed fields from head
    final version = bytes[0];
    if (version != 2 && version != 3) {
      throw FormatException('UserState unknown version: $version');
    }
    if (version == 3 && bytes.length < 104) {
      throw FormatException(
        'UserState v3 too short: ${bytes.length} bytes (need ≥ 104)',
      );
    }
    final usernameOff = (bytes[1] << 8) | bytes[2];
    final batchCount = bytes[3];
    final batchesOff = (bytes[4] << 8) | bytes[5];
    final encryptionPubkey = Uint8List.fromList(bytes.sublist(6, 38));
    final scanPubkey = Uint8List.fromList(bytes.sublist(38, 70));
    final pqPubkeyHash = Uint8List.fromList(bytes.sublist(70, 102));

    // ARC4 dynamic bytes at [off]: 2B BE length + payload. Empty on any
    // out-of-range read (defensive — box bytes come from algod).
    Uint8List readDynBytes(int off) {
      if (off + 2 > bytes.length) return Uint8List(0);
      final len = (bytes[off] << 8) | bytes[off + 1];
      final end = off + 2 + len;
      return end <= bytes.length
          ? Uint8List.fromList(bytes.sublist(off + 2, end))
          : Uint8List(0);
    }

    final username = readDynBytes(usernameOff);

    // Decode bio (v3 only; v2 has no bio slot → empty).
    Uint8List bio = Uint8List(0);
    if (version == 3) {
      final bioOff = (bytes[102] << 8) | bytes[103];
      bio = readDynBytes(bioOff);
    }

    // Decode batches (ARC4 array: 2B BE count + count × 16B tuples)
    final batches = <_Batch>[];
    if (batchesOff + 2 <= bytes.length) {
      final arrLen = (bytes[batchesOff] << 8) | bytes[batchesOff + 1];
      var cursor = batchesOff + 2;
      for (var i = 0; i < arrLen && cursor + 16 <= bytes.length; i++) {
        var amount = 0;
        var expiry = 0;
        for (var j = 0; j < 8; j++) {
          amount = (amount << 8) | bytes[cursor + j];
          expiry = (expiry << 8) | bytes[cursor + 8 + j];
        }
        batches.add(_Batch(amount: amount, expiryRound: expiry));
        cursor += 16;
      }
    }

    return _DecodedUserState(
      version: version,
      username: username,
      batchCount: batchCount,
      batches: batches,
      encryptionPubkey: encryptionPubkey,
      scanPubkey: scanPubkey,
      pqPubkeyHash: pqPubkeyHash,
      bio: bio,
    );
  }

  /// True iff all 32 bytes are zero (signals "not set" for key fields).
  static bool _isZero32(Uint8List bytes) {
    if (bytes.length != 32) return false;
    var acc = 0;
    for (final b in bytes) {
      acc |= b;
    }
    return acc == 0;
  }

  /// Simulate an unsigned app-call and return the ABI return payload
  /// (bytes after the 4-byte `0x151f7c75` return prefix), or null if absent.
  Future<Uint8List?> _simulateAbiReturn(Map<String, dynamic> appCallTxn) async {
    // Algod /v2/transactions/simulate expects msgpack-encoded SimulateRequest
    // matching go-algorand's struct exactly. SDK wire shape (captured from
    // py-algorand-sdk):
    //   { "allow-empty-signatures": true,
    //     "allow-unnamed-resources": true,
    //     "exec-trace-config": {},
    //     "txn-groups": [{ "txns": [{ "txn": {...fields, apan:0...} }] }] }
    // Critical: txns is a list of nested SignedTransaction MAPS (not binary
    // blobs), and `apan: 0` must be present explicitly. Our _packSortedMap
    // strips zero ints which would drop apan; build the body inline instead.
    final reqPacker = Packer();
    reqPacker.packMapLength(4);
    reqPacker.packString('allow-empty-signatures');
    reqPacker.packBool(true);
    reqPacker.packString('allow-unnamed-resources');
    reqPacker.packBool(true);
    reqPacker.packString('exec-trace-config');
    reqPacker.packMapLength(0);
    reqPacker.packString('txn-groups');
    reqPacker.packListLength(1);
    reqPacker.packMapLength(1);
    reqPacker.packString('txns');
    reqPacker.packListLength(1);
    // Each txn entry = {"txn": fields}; pack txn with apan:0 forced.
    reqPacker.packMapLength(1);
    reqPacker.packString('txn');
    _packSimulateAppCallTxn(reqPacker, appCallTxn);
    final reqBody = reqPacker.takeBytes();

    // ignore: avoid_print
    Log.d(
      '[simulate] reqLen=${reqBody.length} '
      'head=${reqBody.take(64).map((b) => b.toRadixString(16).padLeft(2, "0")).join()}',
    );

    // ignore: avoid_print
    Log.d('[simulate] PRE-DIO algodUrl=$algodUrl');
    final resp = await _dio.post<dynamic>(
      '$algodUrl/v2/transactions/simulate',
      data: reqBody,
      options: Options(
        contentType: 'application/msgpack',
        responseType: ResponseType.json,
        headers: {'Accept': 'application/json'},
      ),
    );
    final Map<String, dynamic> body;
    if (resp.data is Map) {
      body = (resp.data as Map).cast<String, dynamic>();
    } else if (resp.data is String) {
      body = jsonDecode(resp.data as String) as Map<String, dynamic>;
    } else if (resp.data is List<int>) {
      body =
          jsonDecode(utf8.decode(resp.data as List<int>))
              as Map<String, dynamic>;
    } else {
      throw StateError(
        'Unexpected simulate response: ${resp.data.runtimeType}',
      );
    }
    // ignore: avoid_print
    Log.d(
      '[simulate] http.status=${resp.statusCode} '
      'bodyHead=${jsonEncode(body).substring(0, jsonEncode(body).length.clamp(0, 400))}',
    );
    final groupErr = body['txn-groups']?[0]?['failure-message'];
    final txErr =
        body['txn-groups']?[0]?['txn-results']?[0]?['txn-result']?['pool-error'];
    // ignore: avoid_print
    Log.d('[simulate] groupErr=$groupErr txErr=$txErr');
    final logs =
        (body['txn-groups']?[0]?['txn-results']?[0]?['txn-result']?['logs']
            as List<dynamic>?) ??
        const [];
    // ignore: avoid_print
    Log.d('[simulate] logs.len=${logs.length}');
    if (logs.isEmpty) return null;
    final last = base64Decode(logs.last as String);
    if (last.length < 4) return null;
    return last.sublist(4);
  }

  /// Encode 32-byte ed25519 pubkey as Algorand address (base32(pubkey ||
  /// sha512_256(pubkey)[0..4]), no padding).
  static String _encodeAlgorandAddress(Uint8List pubkey) {
    if (pubkey.length != 32) {
      throw ArgumentError('pubkey must be 32 bytes');
    }
    final checksum = pkg_crypto.sha512256.convert(pubkey).bytes.sublist(0, 4);
    final combined = Uint8List(36)
      ..setRange(0, 32, pubkey)
      ..setRange(32, 36, checksum);
    return _base32NoPad(combined);
  }

  /// Signs both txns, submits group, returns app-call TxID.
  ///
  /// If [signerOverride] is supplied, it signs the app-call leg instead of the
  /// constructor-time identity wallet — used for ephemeral per-channel sends.
  Future<String> _signAndSubmitGroup(
    Map<String, dynamic> escrowTxn,
    Map<String, dynamic> appCallTxn, {
    SealedSigner? signerOverride,
  }) async {
    final groupId = _computeGroupId([escrowTxn, appCallTxn]);
    escrowTxn['grp'] = groupId;
    appCallTxn['grp'] = groupId;

    // ignore: avoid_print
    Log.d(
      '[submit] escrow.fee=${escrowTxn['fee']} app.fee=${appCallTxn['fee']} '
      'escrow.snd=${(escrowTxn['snd'] as Uint8List).length}B '
      'escrow.keys=${(escrowTxn.keys.toList()..sort()).join(',')}',
    );

    final escrowSigned = escrow.encodeSignedTxn(escrowTxn);
    final appCallToSign = _encodeTxForSigning(appCallTxn);
    final appCallSig = signerOverride != null
        ? await signerOverride.signTransactionBytes(appCallToSign)
        : await wallet.signTransactionBytes(appCallToSign);
    final appCallSigned = _encodeSignedTxWithEd25519(appCallTxn, appCallSig);

    final blob = Uint8List(escrowSigned.length + appCallSigned.length)
      ..setRange(0, escrowSigned.length, escrowSigned)
      ..setRange(
        escrowSigned.length,
        escrowSigned.length + appCallSigned.length,
        appCallSigned,
      );

    final txId = _computeTxId(appCallTxn);
    // ignore: avoid_print
    Log.d(
      '[submit-debug] escrow=${escrowSigned.length}B appCall=${appCallSigned.length}B sigLen=${appCallSig.length}',
    );
    // ignore: avoid_print
    Log.d(
      '[submit-debug] sigHex=${appCallSig.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
    // ignore: avoid_print
    Log.d(
      '[submit-debug] escrowHex=${escrowSigned.sublist(0, escrowSigned.length > 80 ? 80 : escrowSigned.length).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
    // ignore: avoid_print
    Log.d(
      '[submit-debug] appCallHex=${appCallSigned.sublist(0, appCallSigned.length > 80 ? 80 : appCallSigned.length).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
    await _submitGroup(blob);
    return txId;
  }

  /// Name reverse-index box key = UTF8("n:") || sha256(name) (34 bytes).
  static Uint8List _makeNameBoxKey(Uint8List nameUtf8) {
    final hash = pkg_crypto.sha256.convert(nameUtf8).bytes;
    return Uint8List.fromList([0x6e, 0x3a, ...hash]); // "n:"
  }

  /// Wallet credit-state box key = UTF8("w:") || senderPubkey (34 bytes).
  static Uint8List _makeWalletBoxKey(Uint8List senderPubkey) {
    return Uint8List.fromList([0x77, 0x3a, ...senderPubkey]); // "w:"
  }

  /// Commitment box key = UTF8("c:") || sha256(preimage) (34 bytes).
  static Uint8List _makeCommitmentBoxKey(Uint8List preimage) {
    final hash = pkg_crypto.sha256.convert(preimage).bytes;
    return Uint8List.fromList([0x63, 0x3a, ...hash]); // "c:"
  }

  /// Merkle root box key = UTF8("r:") || rootRef (34 bytes).
  static Uint8List _makeRootBoxKey(Uint8List rootRef) {
    return Uint8List.fromList([0x72, 0x3a, ...rootRef]); // "r:"
  }

  /// Nullifier box key = UTF8("nb:") || nullifier (35 bytes).
  static Uint8List _makeNullifierBoxKey(Uint8List nullifier) {
    return Uint8List.fromList([0x6e, 0x62, 0x3a, ...nullifier]); // "nb:"
  }

  /// Wrap a contract-call closure, translating TEAL `assert` reasons in the
  /// algod error body into typed [SealedException]s. Pass-through on other
  /// errors.
  Future<T> _mapContractError<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on DioException catch (e) {
      final body = (e.response?.data?.toString() ?? '') + e.message.toString();
      if (body.contains('TAKEN')) throw const NameTakenError();
      if (body.contains('NO_CREDITS')) throw const NoCreditsError();
      if (body.contains('NO_BOX')) {
        throw const UserNotFoundException('No UserState box — redeem first.');
      }
      if (body.contains('NOT_FOUND')) throw const UserNotFoundException();
      if (body.contains('KEYS_UNSET')) {
        throw const UserNotFoundException('Keys not published.');
      }
      if (body.contains('PQ_HASH_MISMATCH')) {
        throw const GenericSealedException('PQ pubkey hash mismatch.');
      }
      if (body.contains('PQ_KEY_TOO_SHORT') ||
          body.contains('PQ_KEY_TOO_LONG')) {
        throw const GenericSealedException(
          'PQ pubkey size out of range (32-2048).',
        );
      }
      if (body.contains('BIO_TOO_LONG')) throw const BioTooLongError();
      if (body.contains('BAD_PREIMAGE')) throw const BadRedeemCodeError();
      if (body.contains('BAD_CODE')) throw const BadRedeemCodeError();
      // SNARK redeem (T5) assert reasons — surfaced verbatim so the UI
      // can map them to a user-visible string via `redeemMessageForCode`.
      if (body.contains('DOUBLE_SPEND')) {
        throw const RedeemContractError(
          'DOUBLE_SPEND',
          'This code has already been redeemed.',
        );
      }
      if (body.contains('BAD_PROOF')) {
        throw const RedeemContractError(
          'BAD_PROOF',
          'Could not verify this code. Try again or contact support.',
        );
      }
      if (body.contains('BAD_ROOT')) {
        throw const RedeemContractError(
          'BAD_ROOT',
          'This code is from an old batch that has expired.',
        );
      }
      if (body.contains('BAD_RECIPIENT')) {
        throw const RedeemContractError(
          'BAD_RECIPIENT',
          'Wallet address does not match the code.',
        );
      }
      if (body.contains('BAD_DENOM')) {
        throw const RedeemContractError(
          'BAD_DENOM',
          'Code value mismatch. Contact support.',
        );
      }
      if (body.contains('INSUFFICIENT_MBR')) throw const MbrShortfallError();
      if (body.contains('NO_USERNAME')) {
        throw const GenericSealedException('No username set to release.');
      }
      if (body.contains('USERNAME_SET')) {
        throw const GenericSealedException(
          'Username already set — use claimUsername to rename.',
        );
      }
      if (body.contains('TOO_MANY_BATCHES')) {
        throw const GenericSealedException('Credit batch limit (12) reached.');
      }
      if (body.contains('NOT_ADMIN')) {
        throw const GenericSealedException('Admin-only operation.');
      }
      if (body.contains('NOT_CREATOR')) {
        throw const GenericSealedException('Creator-only operation.');
      }
      if (body.contains('NOT_OWNER')) {
        throw const GenericSealedException('Not the owner of this name.');
      }
      if (body.contains('BAD_STATE')) {
        throw const GenericSealedException('On-chain state inconsistency.');
      }
      if (body.contains('BAD_HASH')) {
        throw const GenericSealedException('Commitment hash must be 32 bytes.');
      }
      if (body.contains('BAD_FEE_PAYER')) {
        throw const GenericSealedException(
          'Escrow misconfigured — Txn 0 must be from treasury escrow.',
        );
      }
      if (body.contains('BAD_FEE')) {
        throw const GenericSealedException(
          'Escrow fee below GROUP_FEE_MIN (2000µA).',
        );
      }
      if (body.contains('BAD_FUND_PAYER') ||
          body.contains('BAD_FUND_RECEIVER')) {
        throw const GenericSealedException('Invalid funding txn.');
      }
      if (body.contains('BAD_GROUP_SHAPE') ||
          body.contains('NOT_GROUP') ||
          body.contains('BAD_GROUP_INDEX')) {
        throw GenericSealedException(
          'Invalid group shape — programmer error.',
          details: body,
        );
      }
      if (body.contains('BAD_MBR_RECEIVER') ||
          body.contains('BAD_MBR_AMOUNT')) {
        throw const GenericSealedException('Invalid MBR txn shape.');
      }
      if (body.contains('LEADING_UNDERSCORE')) {
        throw const BadUsernameFormatError(
          'LEADING_UNDERSCORE',
          'Username cannot start with "_".',
        );
      }
      if (body.contains('LEADING_DIGIT')) {
        throw const BadUsernameFormatError(
          'LEADING_DIGIT',
          'Username cannot start with a digit.',
        );
      }
      if (body.contains('TRAILING_UNDERSCORE')) {
        throw const BadUsernameFormatError(
          'TRAILING_UNDERSCORE',
          'Username cannot end with "_".',
        );
      }
      if (body.contains('BAD_CHAR')) {
        throw const BadUsernameFormatError(
          'BAD_CHAR',
          'Username must be a-z, 0-9, or "_".',
        );
      }
      if (body.contains('BAD_LEN')) {
        throw const BadUsernameFormatError(
          'BAD_LEN',
          'Username length out of range.',
        );
      }
      if (body.contains('overspend')) throw const MbrShortfallError();
      rethrow;
    }
  }

  static Map<String, dynamic> _buildEscrowSelfPayTxn({
    required Uint8List escrowPubkey,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
  }) {
    return <String, dynamic>{
      'fee': fee,
      'fv': firstValid,
      'gen': genesisId,
      'gh': genesisHash,
      'lv': lastValid,
      'rcv': escrowPubkey,
      'snd': escrowPubkey,
      'type': 'pay',
      // 'amt' omitted (canonical encoding strips zero ints).
    };
  }

  static Map<String, dynamic> _buildAppCallTxn({
    required Uint8List senderPubkey,
    required int appId,
    required Uint8List methodSelector,
    required List<Uint8List> appArgs,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
  }) {
    return <String, dynamic>{
      'apid': appId,
      'apaa': <Uint8List>[methodSelector, ...appArgs],
      'fee': fee,
      'fv': firstValid,
      'gen': genesisId,
      'gh': genesisHash,
      'lv': lastValid,
      'snd': senderPubkey,
      'type': 'appl',
    };
  }

  /// Same as [_buildAppCallTxn] but includes a `apbx` (box references) field.
  ///
  /// Each box key is encoded as `{'i': 0, 'n': boxKeyBytes}` per ARC-4 / algod
  /// msgpack encoding (app index 0 = self).
  static Map<String, dynamic> _buildAppCallTxnWithBoxes({
    required Uint8List senderPubkey,
    required int appId,
    required Uint8List methodSelector,
    required List<Uint8List> appArgs,
    required List<Uint8List> boxes,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
  }) {
    return <String, dynamic>{
      'apid': appId,
      'apaa': <Uint8List>[methodSelector, ...appArgs],
      'apbx': boxes.map((b) => <String, dynamic>{'i': 0, 'n': b}).toList(),
      'fee': fee,
      'fv': firstValid,
      'gen': genesisId,
      'gh': genesisHash,
      'lv': lastValid,
      'snd': senderPubkey,
      'type': 'appl',
    };
  }

  /// Public test seam: build the unsigned 2-txn group and return both fields
  /// + the computed group id, without signing or submitting.
  static ({
    Map<String, dynamic> escrowTxn,
    Map<String, dynamic> appCallTxn,
    Uint8List groupId,
  })
  debugBuildGroup({
    required Uint8List senderPubkey,
    required Uint8List escrowPubkey,
    required int sealedAppId,
    required Uint8List recipientTag,
    required Uint8List framedCiphertext,
    required int minFee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
  }) {
    final escrowTxn = _buildEscrowSelfPayTxn(
      escrowPubkey: escrowPubkey,
      fee: minFee * 2,
      firstValid: firstValid,
      lastValid: lastValid,
      genesisId: genesisId,
      genesisHash: genesisHash,
    );
    final appCallTxn = _buildAppCallTxn(
      senderPubkey: senderPubkey,
      appId: sealedAppId,
      methodSelector: sendMessageSelector,
      appArgs: [recipientTag, _encodeAbiDynamicBytes(framedCiphertext)],
      fee: 0,
      firstValid: firstValid,
      lastValid: lastValid,
      genesisId: genesisId,
      genesisHash: genesisHash,
    );
    final groupId = _computeGroupId([escrowTxn, appCallTxn]);
    final escrowGrouped = Map<String, dynamic>.from(escrowTxn)
      ..['grp'] = groupId;
    final appCallGrouped = Map<String, dynamic>.from(appCallTxn)
      ..['grp'] = groupId;
    return (
      escrowTxn: escrowGrouped,
      appCallTxn: appCallGrouped,
      groupId: groupId,
    );
  }

  // ---------------------------------------------------------------------------
  // Group ID + TxID computation (sha512_256 hashes over canonical msgpack)
  // ---------------------------------------------------------------------------

  /// Group ID = sha512_256("TG" || msgpack({"txlist": [rawTxID(t0), rawTxID(t1)]}))
  /// where rawTxID(t) = sha512_256("TX" || msgpack(t_without_grp)).
  static Uint8List _computeGroupId(List<Map<String, dynamic>> txns) {
    final txids = txns.map(_computeTxIdRaw).toList();
    final p = Packer();
    p.packMapLength(1);
    p.packString('txlist');
    p.packListLength(txids.length);
    for (final t in txids) {
      p.packBinary(t);
    }
    final tgPrefix = utf8.encode('TG');
    final body = p.takeBytes();
    final buf = Uint8List(tgPrefix.length + body.length)
      ..setRange(0, tgPrefix.length, tgPrefix)
      ..setRange(tgPrefix.length, tgPrefix.length + body.length, body);
    return Uint8List.fromList(pkg_crypto.sha512256.convert(buf).bytes);
  }

  /// rawTxID(t) = sha512_256("TX" || msgpack(t_without_grp)).
  static Uint8List _computeTxIdRaw(Map<String, dynamic> txn) {
    final stripped = Map<String, dynamic>.from(txn)..remove('grp');
    final encoded = _encodeTxForSigning(stripped);
    return Uint8List.fromList(pkg_crypto.sha512256.convert(encoded).bytes);
  }

  /// Base32-with-no-padding TxID for the (already-grouped) txn.
  static String _computeTxId(Map<String, dynamic> grouped) {
    final encoded = _encodeTxForSigning(grouped);
    final hash = pkg_crypto.sha512256.convert(encoded).bytes;
    return _base32NoPad(Uint8List.fromList(hash));
  }

  // ---------------------------------------------------------------------------
  // Msgpack helpers (canonical encoding: sorted keys, omit zero/empty/null)
  // ---------------------------------------------------------------------------

  static Uint8List _encodeTxForSigning(Map<String, dynamic> fields) {
    final txPrefix = utf8.encode('TX');
    final p = Packer();
    _packSortedMap(p, fields);
    final body = p.takeBytes();
    final buf = Uint8List(txPrefix.length + body.length)
      ..setRange(0, txPrefix.length, txPrefix)
      ..setRange(txPrefix.length, txPrefix.length + body.length, body);
    return buf;
  }

  static Uint8List _encodeSignedTxWithEd25519(
    Map<String, dynamic> txFields,
    Uint8List sig,
  ) {
    final p = Packer();
    p.packMapLength(2);
    p.packString('sig');
    p.packBinary(sig);
    p.packString('txn');
    _packSortedMap(p, txFields);
    return p.takeBytes();
  }

  /// Variant of [_packSortedMap] for SimulateRequest app-call txns. Algod's
  /// SimulateRequest struct decoder requires `apan` (OnComplete) to be present
  /// even when 0 (NoOp); _packSortedMap's zero-int stripping would drop it and
  /// cause the simulation to silently fail / return no logs. Force apan into
  /// the field set with value 0, then pack via the normal sorted-map rules.
  static void _packSimulateAppCallTxn(
    Packer p,
    Map<String, dynamic> appCallTxn,
  ) {
    final fields = Map<String, dynamic>.from(appCallTxn);
    // Sorted keys including apan even when 0.
    final keys = (fields.keys.toSet()..add('apan')).toList()..sort();
    // Filter: drop null/empty, but KEEP apan even if 0.
    final valid = keys.where((k) {
      if (k == 'apan') return true;
      final v = fields[k];
      if (v == null) return false;
      if (v is int && v == 0) return false;
      if (v is String && v.isEmpty) return false;
      if (v is List && v.isEmpty) return false;
      return true;
    }).toList();
    p.packMapLength(valid.length);
    for (final k in valid) {
      p.packString(k);
      if (k == 'apan') {
        p.packInt((fields['apan'] as int?) ?? 0);
        continue;
      }
      final v = fields[k]!;
      if (v is int) {
        p.packInt(v);
      } else if (v is String) {
        p.packString(v);
      } else if (v is Uint8List) {
        p.packBinary(v);
      } else if (v is List<Uint8List>) {
        p.packListLength(v.length);
        for (final item in v) {
          p.packBinary(item);
        }
      } else if (v is List<int>) {
        p.packBinary(Uint8List.fromList(v));
      } else if (v is List) {
        p.packListLength(v.length);
        for (final item in v) {
          if (item is Map<String, dynamic>) {
            _packSortedMap(p, item);
          } else if (item is Uint8List) {
            p.packBinary(item);
          } else {
            throw ArgumentError(
              'Unsupported list item type: ${item.runtimeType}',
            );
          }
        }
      } else {
        throw ArgumentError(
          'Unsupported field type for "$k": ${v.runtimeType}',
        );
      }
    }
  }

  static void _packSortedMap(Packer p, Map<String, dynamic> fields) {
    final keys = fields.keys.toList()..sort();
    final valid = keys.where((k) {
      final v = fields[k];
      if (v == null) return false;
      if (v is int && v == 0) return false;
      if (v is String && v.isEmpty) return false;
      if (v is List && v.isEmpty) return false;
      return true;
    }).toList();
    p.packMapLength(valid.length);
    for (final k in valid) {
      p.packString(k);
      final v = fields[k]!;
      if (v is int) {
        p.packInt(v);
      } else if (v is String) {
        p.packString(v);
      } else if (v is Uint8List) {
        p.packBinary(v);
      } else if (v is List<Uint8List>) {
        p.packListLength(v.length);
        for (final item in v) {
          p.packBinary(item);
        }
      } else if (v is List<int>) {
        p.packBinary(Uint8List.fromList(v));
      } else if (v is List) {
        // Generic list — e.g. apbx: List<Map<String, dynamic>>
        p.packListLength(v.length);
        for (final item in v) {
          if (item is Map<String, dynamic>) {
            _packSortedMap(p, item);
          } else if (item is Uint8List) {
            p.packBinary(item);
          } else {
            throw ArgumentError(
              'Unsupported list item type: ${item.runtimeType}',
            );
          }
        }
      } else {
        throw ArgumentError(
          'Unsupported field type for "$k": ${v.runtimeType}',
        );
      }
    }
  }

  static Uint8List _encodeAbiDynamicBytes(Uint8List data) {
    final out = Uint8List(2 + data.length);
    out[0] = (data.length >> 8) & 0xff;
    out[1] = data.length & 0xff;
    out.setRange(2, 2 + data.length, data);
    return out;
  }

  // ---------------------------------------------------------------------------
  // Address + base32 (no-pad)
  // ---------------------------------------------------------------------------

  static Uint8List _decodeAddress(String address) {
    // Algorand addr = base32(pubkey32 || checksum4). Strip last 4 chars worth
    // (7 chars in base32) — but we just use the package decoder via the
    // existing chain_address path. Since we accept arbitrary base32 inputs
    // here (including LogicSig hash pubkeys which are not curve points), use
    // a raw base32 decoder.
    final padded = address;
    final raw = _base32Decode(padded);
    if (raw.length < 36) {
      throw ArgumentError('Algorand address too short: ${raw.length} bytes');
    }
    return Uint8List.fromList(raw.sublist(0, 32));
  }

  static const String _b32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String _base32NoPad(Uint8List bytes) {
    final sb = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_b32Alphabet[(buffer >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      sb.write(_b32Alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return sb.toString();
  }

  static List<int> _base32Decode(String s) {
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final ch in s.split('')) {
      final i = _b32Alphabet.indexOf(ch);
      if (i < 0) continue; // skip padding / invalid
      buffer = (buffer << 5) | i;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Algod
  // ---------------------------------------------------------------------------

  Future<_AlgoParams> _getSuggestedParams() async {
    final resp = await _dio.get('$algodUrl/v2/transactions/params');
    final data = resp.data is String
        ? jsonDecode(resp.data as String) as Map<String, dynamic>
        : resp.data as Map<String, dynamic>;
    // Algod's /v2/transactions/params returns the network minimum fee in
    // `min-fee` (newer algod) or `fee` (older). Both can come back as 0 on
    // some node configs, which produced "group fee 0.0A too small (need
    // 1mA)" — we now floor at the protocol minimum of 1000 µA so every
    // group leg pays at least that.
    final reportedMin = (data['min-fee'] as int?) ?? (data['fee'] as int?) ?? 0;
    final minFee = reportedMin < 1000 ? 1000 : reportedMin;
    final lastRound = data['last-round'] as int;
    return _AlgoParams(
      minFee: minFee,
      firstValid: lastRound,
      lastValid: lastRound + 1000,
      genesisId: data['genesis-id'] as String,
      genesisHash: Uint8List.fromList(
        base64Decode(data['genesis-hash'] as String),
      ),
    );
  }

  Future<void> _submitGroup(Uint8List signedBlob) async {
    final resp = await _dio.post(
      '$algodUrl/v2/transactions',
      data: signedBlob,
      options: Options(
        contentType: 'application/x-binary',
        headers: {'Content-Type': 'application/x-binary'},
        // Capture body on 4xx so the caller sees the TEAL assert reason
        // rather than swallowing it as a bare DioException.
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    if (resp.statusCode == null || resp.statusCode! >= 300) {
      // Algod 4xx body includes the raw signed-txn dump — useless to users
      // and dwarfs the actual message. Extract just the "message:" line.
      final raw = '${resp.data}';
      // Flutter print truncates ~1024 chars; chunk it.
      const chunk = 800;
      for (var i = 0; i < raw.length; i += chunk) {
        final end = (i + chunk) > raw.length ? raw.length : (i + chunk);
        // ignore: avoid_print
        Log.d('[submit-debug] algod[$i..$end]: ${raw.substring(i, end)}');
      }
      // Prefer the TEAL assert tail (pc= / rejected by logic / logic eval error).
      String detail;
      final tealIdx =
          [
                raw.indexOf('logic eval error'),
                raw.indexOf('rejected by logic'),
                raw.indexOf('pc='),
                raw.indexOf('assert'),
              ]
              .where((i) => i >= 0)
              .fold<int>(-1, (a, b) => a < 0 ? b : (b < a ? b : a));
      if (tealIdx >= 0) {
        final endIdx = (tealIdx + 400).clamp(0, raw.length);
        detail = raw.substring(tealIdx, endIdx);
      } else {
        final msgIdx = raw.indexOf('message:');
        detail = msgIdx >= 0
            ? raw.substring(msgIdx, (msgIdx + 240).clamp(0, raw.length))
            : raw.substring(0, raw.length.clamp(0, 240));
      }
      // ignore: avoid_print
      Log.d('[submit-debug] TEAL detail: $detail');
      throw GenericSealedException(
        'algod rejected group (HTTP ${resp.statusCode}): $detail',
        details: detail,
      );
    }
  }

  ///
  /// Poll algod for confirmation of [txId].
  ///
  Future<int> waitForConfirmation(
    String txId, {
    Duration timeout = const Duration(seconds: 60),
    Duration interval = const Duration(milliseconds: 1500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final resp = await _dio.get('$algodUrl/v2/transactions/pending/$txId');
      final data = resp.data is String
          ? jsonDecode(resp.data as String) as Map<String, dynamic>
          : resp.data as Map<String, dynamic>;
      final confirmedRound = (data['confirmed-round'] as int?) ?? 0;
      final poolError = (data['pool-error'] as String?) ?? '';
      if (poolError.isNotEmpty) {
        throw GenericSealedException(
          'pool-error: $poolError',
          details: poolError,
        );
      }
      if (confirmedRound > 0) {
        return confirmedRound;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw ConfirmationTimeoutError(txId);
      }
      await Future<void>.delayed(interval);
    }
  }

  /// Algod account balance in microAlgos. Returns 0 on missing/unknown account.
  Future<int> getWalletBalance(String address) async {
    try {
      final resp = await _dio.get('$algodUrl/v2/accounts/$address');
      final data = resp.data is String
          ? jsonDecode(resp.data as String) as Map<String, dynamic>
          : resp.data as Map<String, dynamic>;
      return (data['amount'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }
}

class _AlgoParams {
  final int minFee;
  final int firstValid;
  final int lastValid;
  final String genesisId;
  final Uint8List genesisHash;

  _AlgoParams({
    required this.minFee,
    required this.firstValid,
    required this.lastValid,
    required this.genesisId,
    required this.genesisHash,
  });
}

/// Decoded fields of the on-chain UserState ARC4 tuple (v2 or v3).
class _DecodedUserState {
  final int version;
  final Uint8List username;
  final int batchCount;
  final List<_Batch> batches;
  final Uint8List encryptionPubkey;
  final Uint8List scanPubkey;
  final Uint8List pqPubkeyHash;

  /// UTF-8 bytes, ≤160. Always empty for v2 boxes (field appended in v3).
  final Uint8List bio;

  const _DecodedUserState({
    required this.version,
    required this.username,
    required this.batchCount,
    required this.batches,
    required this.encryptionPubkey,
    required this.scanPubkey,
    required this.pqPubkeyHash,
    required this.bio,
  });
}

class _Batch {
  final int amount;
  final int expiryRound;
  const _Batch({required this.amount, required this.expiryRound});
}
