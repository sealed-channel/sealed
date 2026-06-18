/// Credit balance + redemption service (M22 + SPEC-snark-redeem-B T11).
///
/// Two surfaces:
///   • [getCredits] — read-only ABI simulation against the Sealed contract.
///   • [redeem]     — derive preimage from a 16-char Crockford-b32 code,
///                    optionally claim a username, post the `redeem` group.
///
/// `redeem` routes between two on-chain paths:
///   1. **SNARK**  (privacy-preserving, SPEC-snark-redeem-B §5.2). Picked when
///      both a [SnarkProver] and an [IndexerClient] are wired AND the leaf
///      derived from the code is found in some cached/indexed Merkle root.
///   2. **Legacy** (`redeem(preimage, username)`). Picked when either dep is
///      null, or the indexer has no root containing the freshly-derived leaf.
///
/// **Fall-through policy:** prover errors bubble up — we do NOT silently fall
/// back to the legacy path on prover failure. Burning the same code via the
/// public legacy path after a SNARK attempt would link the preimage to the
/// sender wallet on-chain, defeating the whole purpose of the SNARK redeem.
/// Callers (UI) should surface the error and let the user retry, not switch
/// paths automatically.
///
/// Code grammar matches `programs/sealed/src/lib/code.ts`:
///   • alphabet = `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (Crockford, no I/L/O/U)
///   • normalize: uppercase, drop dashes/spaces, I→1, L→1, O→0
///   • preimage  = sha256(utf8(normalized code))[0..16]
///   • commitment= sha256(preimage)                       (admin-posted)
///
/// The chain side (group construction, escrow, ABI encoding) is owned by
/// `sealed_chain_client.dart` and reached through [SealedCreditOps] — the
/// concrete impl is added in M17.
library;

import 'dart:async';
import 'package:sealed_app/core/log.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:sealed_app/infra/chain/chain_address.dart';
import 'package:sealed_app/infra/network/indexer_client.dart' hide frModulus;
import 'package:sealed_app/infra/zk/merkle_path.dart' as mp;
import 'package:sealed_app/infra/zk/poseidon.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';

/// On-chain credit operations the service depends on. Concrete impl lives in
/// `sealed_chain_client.dart` (M17).
abstract class SealedCreditOps {
  /// `getCredits(address) → uint64`, simulated. Returns 0 if no `w:` box.
  Future<int> getCredits(String walletAddress);

  /// Bypass any cache for one read and refresh the cached entry. Used by send
  /// pre-flights to confirm a "no credits" verdict against the chain before
  /// refusing — guards against a stale cached 0 after an out-of-band redeem.
  Future<int> refetchCredits(String walletAddress);

  /// `redeem(preimage, username)`. `preimage` is 16 bytes; `username` may be
  /// the empty string to skip username claim.
  Future<String> redeem({
    required Uint8List preimage,
    required String username,
    required String fromAddress,
  });

  /// SNARK-anchored credit redemption (SPEC-snark-redeem-B §5.2).
  ///
  /// Posts `redeemWithProof(byte[32],byte[32],byte[],byte[],byte[])void` as a
  /// 2-txn fee-pool group (escrow self-pay + app-call). All bytes are passed
  /// straight to the contract — caller is responsible for the proof, pubInputs
  /// encoding (4 Fr's, BE-32B each, concatenated = 128B) and matching
  /// recipient/nullifier/root layout.
  ///
  /// `username` may be null/empty to skip co-claim. Returns the app-call txid.
  Future<String> redeemWithProof({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required String fromAddress,
    String? username,
  });

  /// SNARK redeem that also publishes the caller's key triple atomically
  /// (`redeemWithProofAndPublishKeys`). Same proof/pubInputs contract as
  /// [redeemWithProof]; folds the publishKeys so the buyer keeps the full
  /// denomination. Claims no username. Returns the app-call txid.
  Future<String> redeemWithProofAndPublishKeys({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required String fromAddress,
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  });

  /// True iff the Merkle-root box `r:<rootRef>` exists on the configured app.
  /// Used to reject a root the indexer surfaced from a different/older app
  /// (the `/roots` table is cumulative) before building a proof against it.
  Future<bool> rootBoxExists(Uint8List rootRef);
}

/// Loader for the SNARK proving artifacts. Defaults to the Flutter asset
/// bundle in production wiring (see `app_providers.dart`); tests pass a
/// closure returning in-memory bytes.
///
/// The zkey is large (~30 MB for redeem_dev.zkey); production wiring may
/// stream it once at app start and keep the [Uint8List] alive, or re-load
/// per redeem and let the OS page-cache do its work.
typedef SnarkArtifactLoader = Future<Uint8List> Function(String assetKey);

/// Phases the redeem flow can be in. Emitted via [CreditsService.redeem]'s
/// optional `onPhase` callback so UI can show a SNARK-specific spinner only
/// when the SNARK path is actually taken.
///
///   legacy           — legacy `redeem(preimage, username)` path picked
///   snarkProbing     — indexer hit; about to load assets / build path
///   snarkProving     — native prover running (longest phase, 1–15s)
///   snarkSubmitting  — proof generated; submitting on-chain group
///   done             — terminal (success). Errors do NOT emit `done`.
enum RedeemPhase { legacy, snarkProbing, snarkProving, snarkSubmitting, done }

class CreditsServiceException implements Exception {
  final String message;
  final String? code;
  CreditsServiceException(this.message, {this.code});
  @override
  String toString() =>
      'CreditsServiceException: $message${code != null ? ' ($code)' : ''}';
}

class CreditsService {
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const int codeLen = 16;
  static const int preimageLen = 16;

  /// Asset keys for the SNARK redeem circuit artifacts. `app_providers.dart`
  /// resolves these through `rootBundle.load`; the `tool/copy-snark-assets.sh`
  /// helper copies the raw files out of `circuits/` at build time so the
  /// large binaries never enter git.
  static const String zkeyAssetKey = 'assets/snark/redeem_dev.zkey';
  static const String wasmAssetKey = 'assets/snark/redeem.wasm';

  final SealedCreditOps _ops;
  final SnarkProver? _prover;
  final IndexerClient? _indexer;
  final SnarkArtifactLoader? _loadAsset;

  CreditsService(
    this._ops, {
    SnarkProver? prover,
    IndexerClient? indexer,
    SnarkArtifactLoader? loadAsset,
  }) : _prover = prover,
       _indexer = indexer,
       _loadAsset = loadAsset;

  // ---------------------------------------------------------------------------
  // Code normalization
  // ---------------------------------------------------------------------------

  /// Normalize a user-entered code: uppercase, strip dashes/spaces, I→1, L→1,
  /// O→0. Throws [CreditsServiceException] on bad length or stray characters.
  static String normalizeCode(String code) {
    var s = code.toUpperCase();
    s = s.replaceAll(RegExp(r'[\s\-]'), '');
    s = s.replaceAll('I', '1').replaceAll('L', '1').replaceAll('O', '0');
    if (s.length != codeLen) {
      throw CreditsServiceException(
        'redeem code must be $codeLen chars after normalize (got ${s.length})',
        code: 'BAD_CODE_LEN',
      );
    }
    for (final c in s.codeUnits) {
      if (!_alphabet.contains(String.fromCharCode(c))) {
        throw CreditsServiceException(
          'invalid char in redeem code: ${String.fromCharCode(c)}',
          code: 'BAD_CODE_CHAR',
        );
      }
    }
    return s;
  }

  /// Display form with dashes: `XXXX-XXXX-XXXX-XXXX`.
  static String formatCode(String code) {
    final n = normalizeCode(code);
    return '${n.substring(0, 4)}-${n.substring(4, 8)}-${n.substring(8, 12)}-${n.substring(12, 16)}';
  }

  /// First 16 bytes of `sha256(utf8(normalize(code)))`.
  static Uint8List preimageFromCode(String code) {
    final n = normalizeCode(code);
    final digest = pkg_crypto.sha256.convert(n.codeUnits).bytes;
    return Uint8List.fromList(digest.sublist(0, preimageLen));
  }

  /// `sha256(preimage)` — what the admin posts on-chain.
  static Uint8List commitmentFromCode(String code) {
    final pre = preimageFromCode(code);
    final digest = pkg_crypto.sha256.convert(pre).bytes;
    return Uint8List.fromList(digest);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Current credit balance for [walletAddress]. Returns 0 for unfunded users.
  Future<int> getCredits(String walletAddress) {
    return _ops.getCredits(walletAddress);
  }

  /// Force a fresh chain read of [walletAddress]'s balance, bypassing the cache.
  Future<int> refetchCredits(String walletAddress) {
    return _ops.refetchCredits(walletAddress);
  }

  /// True when [code]'s leaf is committed in a Merkle root that exists on the
  /// configured app — i.e. the code is SNARK-sold and MUST be redeemed via the
  /// proof path, not the legacy `c:`-commitment path. False when the SNARK deps
  /// (prover + indexer) are absent or no on-chain root holds the leaf.
  ///
  /// Lets orchestration layers (e.g. the redeem notifier) pick between the
  /// atomic legacy `redeemAndPublish` flow and the SNARK [redeem] flow before
  /// committing to either — a legacy redeem of a SNARK-sold code always fails
  /// (BAD_CODE: no commitment box), and vice-versa.
  Future<bool> isSnarkRedeemable(String code) async {
    final indexer = _indexer;
    if (_prover == null || indexer == null) return false;
    final preimage = preimageFromCode(code);
    final leafHex = frToHex(poseidonHash1(bytesToFr(preimage)));
    final hit = await _pickOnChainRoot(
      await indexer.findAllRootsContaining(leafHex),
    );
    return hit != null;
  }

  /// Redeem a code. If [username] is non-empty, attempts to claim it in the
  /// same group. Returns the app-call txid.
  ///
  /// Throws [CreditsServiceException] on bad code; chain errors bubble up
  /// from the underlying [SealedCreditOps]. Prover errors bubble up — see
  /// the fall-through policy in this file's library doc.
  /// When [encryptionPubkey], [scanPubkey] and [pqPubkey] are all supplied AND
  /// the code routes to the SNARK path, the key triple is published atomically
  /// inside the redeem (via `redeemWithProofAndPublishKeys`) — the buyer keeps
  /// the full denomination instead of paying a separate publishKeys credit.
  /// They are ignored on the legacy fallback path.
  Future<String> redeem({
    required String code,
    required String fromAddress,
    String username = '',
    CancelToken? cancel,
    void Function(RedeemPhase phase)? onPhase,
    Uint8List? encryptionPubkey,
    Uint8List? scanPubkey,
    Uint8List? pqPubkey,
  }) async {
    final preimage = preimageFromCode(code);

    final prover = _prover;
    final indexer = _indexer;
    if (prover == null || indexer == null) {
      Log.d('[CreditsService] redeem path=legacy reason=deps_null');
      onPhase?.call(RedeemPhase.legacy);
      final txid = await _redeemViaLegacy(preimage, username, fromAddress);
      onPhase?.call(RedeemPhase.done);
      return txid;
    }

    final leafFr = poseidonHash1(bytesToFr(preimage));
    final leafHex = frToHex(leafFr);

    // The indexer's /roots table is cumulative across every app it has watched
    // and old batches can reuse a preimage, so a leaf may match more than one
    // root — only one of which was posted to THIS app. Pick the candidate whose
    // `r:<root>` box actually exists on-chain; submitting a foreign-app root
    // fails with BAD_ROOT (surfaced to the user as "code invalid or used").
    final hit = await _pickOnChainRoot(
      await indexer.findAllRootsContaining(leafHex),
    );
    if (hit == null) {
      Log.d('[CreditsService] redeem path=legacy reason=no_onchain_root');
      onPhase?.call(RedeemPhase.legacy);
      final txid = await _redeemViaLegacy(preimage, username, fromAddress);
      onPhase?.call(RedeemPhase.done);
      return txid;
    }

    final rootPrefix = hit.record.root.substring(0, 8);
    Log.d(
      '[CreditsService] redeem path=snark hit=true '
      'denomination=${hit.record.denomination} rootPrefix=$rootPrefix',
    );
    final txid = await _redeemViaSnark(
      hit: hit,
      preimage: preimage,
      fromAddress: fromAddress,
      username: username,
      prover: prover,
      cancel: cancel ?? CancelToken(),
      onPhase: onPhase,
      encryptionPubkey: encryptionPubkey,
      scanPubkey: scanPubkey,
      pqPubkey: pqPubkey,
    );
    onPhase?.call(RedeemPhase.done);
    return txid;
  }

  Future<String> _redeemViaLegacy(
    Uint8List preimage,
    String username,
    String fromAddress,
  ) {
    return _ops.redeem(
      preimage: preimage,
      username: username,
      fromAddress: fromAddress,
    );
  }

  Future<String> _redeemViaSnark({
    required RootHit hit,
    required Uint8List preimage,
    required String fromAddress,
    required String username,
    required SnarkProver prover,
    required CancelToken cancel,
    void Function(RedeemPhase phase)? onPhase,
    Uint8List? encryptionPubkey,
    Uint8List? scanPubkey,
    Uint8List? pqPubkey,
  }) async {
    onPhase?.call(RedeemPhase.snarkProbing);
    // 1. Reconstruct the leaf set from the hit so we can build a path.
    final leafFrs = <BigInt>[
      for (final hex in hit.record.leaves) frFromHex(hex),
    ];

    // 2. Build the authentication path. Cross-check the leaf-index the
    //    indexer reported by recomputing it locally — defends against a
    //    malicious indexer that hands us the wrong index for a matching
    //    leaf-hash collision domain (very narrow surface, but cheap).
    final preimageFr = bytesToFr(preimage);
    final targetIdx = mp.findLeaf(preimage: preimageFr, leaves: leafFrs);
    if (targetIdx == null || targetIdx != hit.leafIndex) {
      throw CreditsServiceException(
        'indexer leaf index mismatch — refusing SNARK redeem',
        code: 'BAD_LEAF_INDEX',
      );
    }
    final path = mp.build(leaves: leafFrs, targetIdx: targetIdx);

    // 3. Witness inputs. Order/shape must match
    //    `circuits/circuits/redeem.circom` and `gen-vectors.mjs`.
    final pubkeyBytes = ChainAddress.decode(fromAddress, 'algorand');
    BigInt recipient = bytesToFr(pubkeyBytes);
    if (recipient == BigInt.zero) recipient = BigInt.one;
    final nullifierFr = poseidonHash2(preimageFr, nullTag);
    final denominationFr = BigInt.from(hit.record.denomination);
    final rootFr = frFromHex(hit.record.root);

    final input = <String, dynamic>{
      'root': rootFr.toString(),
      'nullifier': nullifierFr.toString(),
      'recipient': recipient.toString(),
      'denomination': denominationFr.toString(),
      'preimage': preimageFr.toString(),
      'pathElements': [for (final e in path.elements) e.toString()],
      'pathIndices': [for (final i in path.indices) i.toString()],
    };

    // 4. Load proving artifacts. Loader injection lets tests skip the
    //    Flutter asset bundle entirely.
    final loader = _loadAsset;
    if (loader == null) {
      throw CreditsServiceException(
        'SNARK assets not wired — prover present without loader',
        code: 'PROVER_MISCONFIGURED',
      );
    }
    final zkeyBytes = await loader(zkeyAssetKey);
    final wasmBytes = await loader(wasmAssetKey);

    // 5. Prove. Errors bubble up — do NOT fall back to legacy (see policy).
    onPhase?.call(RedeemPhase.snarkProving);
    final t0 = DateTime.now();
    final result = await prover.generateProof(
      zkeyBytes: zkeyBytes,
      wasmBytes: wasmBytes,
      input: input,
      cancel: cancel,
    );
    final latencyMs = DateTime.now().difference(t0).inMilliseconds;
    Log.d('[CreditsService] redeem prover_latency_ms=$latencyMs');

    // 6. Serialize public signals: 4 Fr's, big-endian 32B each, concatenated.
    final pubInputs = Uint8List(128);
    for (var i = 0; i < 4; i++) {
      _writeFrBE32(pubInputs, i * 32, result.publicSignals[i]);
    }
    final rootRef = Uint8List(32);
    _writeFrBE32(rootRef, 0, rootFr);
    final nullifierBytes = Uint8List(32);
    _writeFrBE32(nullifierBytes, 0, result.nullifier);

    onPhase?.call(RedeemPhase.snarkSubmitting);

    // Atomic key-publish variant: when a full key triple is supplied, fold the
    // publishKeys into the redeem so the buyer keeps the full denomination
    // (no separate publishKeys credit). The combined contract method claims no
    // username — callers wanting a co-claim must use the plain path below.
    if (encryptionPubkey != null && scanPubkey != null && pqPubkey != null) {
      return _ops.redeemWithProofAndPublishKeys(
        rootRef: rootRef,
        nullifier: nullifierBytes,
        proof: result.proof,
        pubInputs: pubInputs,
        fromAddress: fromAddress,
        encryptionPubkey: encryptionPubkey,
        scanPubkey: scanPubkey,
        pqPubkey: pqPubkey,
      );
    }

    return _ops.redeemWithProof(
      rootRef: rootRef,
      nullifier: nullifierBytes,
      proof: result.proof,
      pubInputs: pubInputs,
      fromAddress: fromAddress,
      username: username.isEmpty ? null : username,
    );
  }

  /// Write a BN254 Fr into 32 bytes big-endian at [offset] in [out].
  static void _writeFrBE32(Uint8List out, int offset, BigInt fr) {
    var v = fr % frModulus;
    if (v.isNegative) v += frModulus;
    for (var i = 31; i >= 0; i--) {
      out[offset + i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
  }

  /// 32-byte big-endian `rootRef` for [rootHex] — the exact bytes that key the
  /// on-chain `r:` box and get submitted in `redeemWithProof`.
  static Uint8List _rootRefBytes(String rootHex) {
    final out = Uint8List(32);
    _writeFrBE32(out, 0, frFromHex(rootHex));
    return out;
  }

  /// From [candidates] (all roots whose leaf-set holds the target leaf), return
  /// the first whose `r:<root>` box exists on the configured app. Returns
  /// `null` when none do — the leaf belongs only to roots posted to other apps,
  /// so SNARK redeem is impossible here and the caller falls back to legacy.
  Future<RootHit?> _pickOnChainRoot(List<RootHit> candidates) async {
    for (final h in candidates) {
      if (await _ops.rootBoxExists(_rootRefBytes(h.record.root))) return h;
    }
    return null;
  }
}
