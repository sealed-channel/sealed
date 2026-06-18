// SNARK redeem routing tests for [CreditsService] (PLAN T11).
//
// The fakes here cover the prover + indexer surfaces; the indexer fake
// implements only [findRootContaining] (the one method T11's routing logic
// touches) and stubs everything else so we don't have to spin up Dio/OHTTP
// in a unit test.
//
// Test matrix:
//   1. both deps null              → legacy ops.redeem called
//   2. indexer hit + prover wired  → SNARK ops.redeemWithProof called
//   3. indexer miss                → legacy fallback
//   4. prover throws               → exception bubbles up (NO legacy fallback)

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/network/root_cache.dart';
import 'package:sealed_app/features/wallet/credits_service.dart';
import 'package:sealed_app/infra/zk/merkle_path.dart' as mp;
import 'package:sealed_app/infra/zk/poseidon.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeOps implements SealedCreditOps {
  Uint8List? legacyPreimage;
  String? legacyUsername;
  String? legacyFrom;

  Uint8List? snarkRoot;
  Uint8List? snarkNullifier;
  Uint8List? snarkProof;
  Uint8List? snarkPubInputs;
  String? snarkFrom;
  String? snarkUsername;

  /// Default true: in these routing tests the cached root is always the one
  /// posted to the configured app, so the on-chain pre-flight passes.
  bool rootBoxExistsResult = true;

  @override
  Future<bool> rootBoxExists(Uint8List rootRef) async => rootBoxExistsResult;

  @override
  Future<int> getCredits(String walletAddress) async => 0;

  @override
  Future<int> refetchCredits(String walletAddress) async => 0;

  @override
  Future<String> redeem({
    required Uint8List preimage,
    required String username,
    required String fromAddress,
  }) async {
    legacyPreimage = preimage;
    legacyUsername = username;
    legacyFrom = fromAddress;
    return 'TXID_LEGACY';
  }

  @override
  Future<String> redeemWithProof({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required String fromAddress,
    String? username,
  }) async {
    snarkRoot = rootRef;
    snarkNullifier = nullifier;
    snarkProof = proof;
    snarkPubInputs = pubInputs;
    snarkFrom = fromAddress;
    snarkUsername = username;
    return 'TXID_SNARK';
  }

  // Atomic SNARK-redeem + key-publish path.
  Uint8List? snarkPublishEncPub;
  Uint8List? snarkPublishScanPub;
  Uint8List? snarkPublishPqPub;

  @override
  Future<String> redeemWithProofAndPublishKeys({
    required Uint8List rootRef,
    required Uint8List nullifier,
    required Uint8List proof,
    required Uint8List pubInputs,
    required String fromAddress,
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    snarkRoot = rootRef;
    snarkNullifier = nullifier;
    snarkProof = proof;
    snarkPubInputs = pubInputs;
    snarkFrom = fromAddress;
    snarkPublishEncPub = encryptionPubkey;
    snarkPublishScanPub = scanPubkey;
    snarkPublishPqPub = pqPubkey;
    return 'TXID_SNARK_PUBLISH';
  }
}

class _FakeProver implements SnarkProver {
  _FakeProver({this.throwIt = false, this.publicSignals});
  final bool throwIt;
  final List<BigInt>? publicSignals;
  Map<String, dynamic>? lastInput;
  int callCount = 0;

  @override
  Future<ProofResult> generateProof({
    required Uint8List zkeyBytes,
    Uint8List? wasmBytes,
    Uint8List? witnessDatBytes,
    required Map<String, dynamic> input,
    required CancelToken cancel,
  }) async {
    callCount += 1;
    lastInput = input;
    if (throwIt) {
      throw SnarkProverException(SnarkProverErrorKind.generic, 'boom');
    }
    final signals =
        publicSignals ??
        <BigInt>[
          BigInt.parse(input['root'] as String),
          BigInt.parse(input['nullifier'] as String),
          BigInt.parse(input['recipient'] as String),
          BigInt.parse(input['denomination'] as String),
        ];
    return ProofResult(
      proof: Uint8List(256)..[0] = 0xAB,
      publicSignals: signals,
    );
  }
}

/// Indexer fake — backs onto [InMemoryRootCache] so we can exercise the real
/// [findRootContaining] semantics without hitting the network. [IndexerClient]
/// is a concrete class with many methods; we extend it and override only
/// what the routing logic calls.
class _FakeIndexer extends IndexerClient {
  _FakeIndexer({required this.cache})
    : super(baseUrl: 'https://stub.invalid', rootCache: cache);

  final InMemoryRootCache cache;

  @override
  Future<RootHit?> findRootContaining(String leafHex) {
    return cache.findRootContaining(leafHex);
  }

  @override
  Future<List<RootHit>> findAllRootsContaining(String leafHex) {
    return cache.findAllRootsContaining(leafHex);
  }
}

// ---------------------------------------------------------------------------
// Helpers — build a "real" root record from a preimage so the SNARK branch
// can build a Merkle path.
// ---------------------------------------------------------------------------

RootRecord _recordContaining(Uint8List preimage, {int denomination = 100}) {
  final preFr = bytesToFr(preimage);
  final leaf = poseidonHash1(preFr);
  // One real leaf, rest of the tree padded by MerklePath.build.
  final leaves = <BigInt>[leaf];
  final path = mp.build(leaves: leaves, targetIdx: 0);
  // Re-derive root from leaf + path so it matches what the prover input
  // would commit to.
  final root = mp.computeRoot(leaf: leaf, path: path);
  return RootRecord(
    root: frToHex(root),
    denomination: denomination,
    postedRound: 1,
    leaves: [frToHex(leaf)],
  );
}

// Real 58-char Algorand address used elsewhere in this test suite.
const String _addr =
    'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI';

void main() {
  group('CreditsService.redeem routing (PLAN T11)', () {
    test('both deps null → legacy path', () async {
      final ops = _FakeOps();
      final svc = CreditsService(ops);
      final txid = await svc.redeem(
        code: '1234-5678-90AB-CDEF',
        fromAddress: _addr,
      );
      expect(txid, 'TXID_LEGACY');
      expect(ops.legacyPreimage, isNotNull);
      expect(ops.snarkRoot, isNull);
    });

    test('indexer miss → legacy even when prover present', () async {
      final ops = _FakeOps();
      final prover = _FakeProver();
      final cache = InMemoryRootCache(); // empty
      final indexer = _FakeIndexer(cache: cache);

      final svc = CreditsService(
        ops,
        prover: prover,
        indexer: indexer,
        loadAsset: (_) async => Uint8List(1),
      );
      final txid = await svc.redeem(
        code: '1234-5678-90AB-CDEF',
        fromAddress: _addr,
      );
      expect(txid, 'TXID_LEGACY');
      expect(prover.callCount, 0);
      expect(ops.snarkRoot, isNull);
    });

    test(
      'indexer hit + prover wired → SNARK path with expected args',
      () async {
        final ops = _FakeOps();
        final prover = _FakeProver();

        final preimage = CreditsService.preimageFromCode('1234-5678-90AB-CDEF');
        final record = _recordContaining(preimage, denomination: 250);
        final cache = InMemoryRootCache();
        await cache.replaceAll([record]);
        final indexer = _FakeIndexer(cache: cache);

        Uint8List? zkeyAsked;
        Uint8List? wasmAsked;
        final svc = CreditsService(
          ops,
          prover: prover,
          indexer: indexer,
          loadAsset: (key) async {
            if (key == CreditsService.zkeyAssetKey) {
              zkeyAsked = Uint8List.fromList([1, 2, 3]);
              return zkeyAsked!;
            }
            if (key == CreditsService.wasmAssetKey) {
              wasmAsked = Uint8List.fromList([4, 5, 6]);
              return wasmAsked!;
            }
            throw StateError('unexpected asset key $key');
          },
        );

        final txid = await svc.redeem(
          code: '1234-5678-90AB-CDEF',
          fromAddress: _addr,
          username: 'alice',
        );

        expect(txid, 'TXID_SNARK');
        expect(prover.callCount, 1);
        expect(zkeyAsked, isNotNull);
        expect(wasmAsked, isNotNull);

        // Witness input cross-checks.
        final input = prover.lastInput!;
        expect(input['root'], frFromHex(record.root).toString());
        expect(input['denomination'], '250');
        expect(input['pathElements'], hasLength(16));
        expect(input['pathIndices'], hasLength(16));

        // Chain call shape.
        expect(ops.snarkRoot, isNotNull);
        expect(ops.snarkRoot!.length, 32);
        expect(ops.snarkNullifier!.length, 32);
        expect(ops.snarkPubInputs!.length, 128);
        expect(ops.snarkProof!.length, 256);
        expect(ops.snarkFrom, _addr);
        expect(ops.snarkUsername, 'alice');
        // Legacy path must NOT have run.
        expect(ops.legacyPreimage, isNull);
      },
    );

    test('empty username collapses to null on the SNARK path', () async {
      final ops = _FakeOps();
      final prover = _FakeProver();
      final preimage = CreditsService.preimageFromCode('1234-5678-90AB-CDEF');
      final cache = InMemoryRootCache();
      await cache.replaceAll([_recordContaining(preimage)]);
      final indexer = _FakeIndexer(cache: cache);
      final svc = CreditsService(
        ops,
        prover: prover,
        indexer: indexer,
        loadAsset: (_) async => Uint8List(1),
      );
      await svc.redeem(code: '1234-5678-90AB-CDEF', fromAddress: _addr);
      expect(ops.snarkUsername, isNull);
    });

    test('prover error bubbles up (NO silent legacy fallback)', () async {
      final ops = _FakeOps();
      final prover = _FakeProver(throwIt: true);
      final preimage = CreditsService.preimageFromCode('1234-5678-90AB-CDEF');
      final cache = InMemoryRootCache();
      await cache.replaceAll([_recordContaining(preimage)]);
      final indexer = _FakeIndexer(cache: cache);
      final svc = CreditsService(
        ops,
        prover: prover,
        indexer: indexer,
        loadAsset: (_) async => Uint8List(1),
      );

      await expectLater(
        svc.redeem(code: '1234-5678-90AB-CDEF', fromAddress: _addr),
        throwsA(isA<SnarkProverException>()),
      );
      // Critical: legacy MUST NOT have been called. Burning the same code
      // through the public legacy path after a prover error would link the
      // preimage to the wallet on-chain.
      expect(ops.legacyPreimage, isNull);
      expect(ops.snarkRoot, isNull);
    });
  });
}
