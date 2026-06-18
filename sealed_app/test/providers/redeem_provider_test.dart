// test/providers/redeem_provider_test.dart
//
// Unit tests for `redeemProvider`. Strategy: override the provider's three
// upstream deps with fakes:
//   - `creditsServiceProvider` → a `CreditsService` built from a fake
//     `SealedCreditOps` (and optional SnarkProver + IndexerClient).
//   - `walletProvider` → a `_FakeWalletNotifier` that supplies a ready
//     wallet address.
//   - `keyManagementProvider` → a `_FakeKeyManagement` that records calls so
//     we can assert orchestration (or skip orchestration on failure).
//
// Per CLAUDE.md: integration tests must not mock OHTTP/chain/indexer. These
// are unit tests of the notifier's own state-machine, so faking
// `CreditsService` at its service boundary is the right scope.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/features/wallet/credits_service.dart'
    hide RedeemPhase;
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/zk/merkle_path.dart' as mp;
import 'package:sealed_app/infra/zk/poseidon.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/providers/redeem_provider.dart';

// ============================================================================
// Fakes
// ============================================================================

class _FakeOps implements SealedCreditOps {
  _FakeOps({this.redeemError, this.redeemWithProofError});
  final Object? redeemError;
  final Object? redeemWithProofError;

  int redeemCalls = 0;
  int redeemWithProofCalls = 0;

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
    redeemCalls++;
    if (redeemError != null) throw redeemError!;
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
    redeemWithProofCalls++;
    if (redeemWithProofError != null) throw redeemWithProofError!;
    return 'TXID_SNARK';
  }

  int redeemWithProofAndPublishKeysCalls = 0;

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
    redeemWithProofAndPublishKeysCalls++;
    if (redeemWithProofError != null) throw redeemWithProofError!;
    return 'TXID_SNARK_PUBLISH';
  }

  @override
  Future<bool> rootBoxExists(Uint8List rootRef) async => true;
}

class _FakeIndexer extends IndexerClient {
  _FakeIndexer({required this.cache})
    : super(baseUrl: 'https://stub.invalid', rootCache: cache);
  final InMemoryRootCache cache;

  @override
  Future<RootHit?> findRootContaining(String leafHex) =>
      cache.findRootContaining(leafHex);

  @override
  Future<List<RootHit>> findAllRootsContaining(String leafHex) =>
      cache.findAllRootsContaining(leafHex);
}

class _FakeOkProver implements SnarkProver {
  @override
  Future<ProofResult> generateProof({
    required Uint8List zkeyBytes,
    Uint8List? wasmBytes,
    Uint8List? witnessDatBytes,
    required Map<String, dynamic> input,
    required CancelToken cancel,
  }) async {
    return ProofResult(
      proof: Uint8List(256),
      publicSignals: <BigInt>[
        BigInt.parse(input['root'] as String),
        BigInt.parse(input['nullifier'] as String),
        BigInt.parse(input['recipient'] as String),
        BigInt.parse(input['denomination'] as String),
      ],
    );
  }
}

class _FakeWalletNotifier extends WalletNotifier {
  _FakeWalletNotifier(this._address);
  final String? _address;

  @override
  Future<WalletState> build() async {
    return WalletState(
      phase: _address == null
          ? OnboardingPhase.noWallet
          : OnboardingPhase.ready,
      walletAddress: _address,
    );
  }

  @override
  Future<void> refreshBalance() async {}
}

class _FakeKeyManagement extends KeyManagementNotifier {
  int regenCalls = 0;
  int ensureCalls = 0;
  Object? throwOnRegen;

  @override
  KeyManagementState build() => const KeyManagementState();

  @override
  Future<void> regenerateAndPublish() async {
    regenCalls++;
    if (throwOnRegen != null) {
      // Mirror the real notifier: it stashes the error in its own state
      // rather than rethrowing. The redeem notifier therefore should never
      // see this throw — credits are already on-chain at this point. We
      // model that by storing-and-swallowing here.
      state = KeyManagementState(
        phase: KeyPhase.error,
        lastError: throwOnRegen.toString(),
      );
      return;
    }
    state = const KeyManagementState(phase: KeyPhase.done);
  }

  @override
  Future<void> ensurePublished() async {
    ensureCalls++;
  }
}

// ============================================================================
// Helpers
// ============================================================================

const _validCode = '0123456789ABCDEF';
const _validWallet =
    'EFJPRUM3PEOSIRJSILQV6LVLNS3476T3NJPNGAEXSYHANGEB3MJIDPXWVI';

RootRecord _recordContaining(Uint8List preimage) {
  final preFr = bytesToFr(preimage);
  final leaf = poseidonHash1(preFr);
  final leaves = <BigInt>[leaf];
  final path = mp.build(leaves: leaves, targetIdx: 0);
  final root = mp.computeRoot(leaf: leaf, path: path);
  return RootRecord(
    root: frToHex(root),
    denomination: 100,
    postedRound: 1,
    leaves: [frToHex(leaf)],
  );
}

Future<_FakeIndexer> _indexerWithCode(String code) async {
  final preimage = CreditsService.preimageFromCode(code);
  final cache = InMemoryRootCache();
  await cache.replaceAll([_recordContaining(preimage)]);
  return _FakeIndexer(cache: cache);
}

ProviderContainer _container({
  required CreditsService credits,
  _FakeKeyManagement? keyManagement,
  String? wallet = _validWallet,
}) {
  final km = keyManagement ?? _FakeKeyManagement();
  final c = ProviderContainer(
    overrides: [
      creditsServiceProvider.overrideWith((_) async => credits),
      walletProvider.overrideWith(() => _FakeWalletNotifier(wallet)),
      keyManagementProvider.overrideWith(() => km),
    ],
  );
  // Warm the wallet provider so the redeem notifier can read it synchronously.
  return c;
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('redeemProvider · happy path (SNARK)', () {
    test('phase progression idle → proving → submitting → publishing → done; '
        'keyManagement.regenerateAndPublish invoked exactly once', () async {
      final ops = _FakeOps();
      final prover = _FakeOkProver();
      final indexer = await _indexerWithCode(_validCode);
      final credits = CreditsService(
        ops,
        prover: prover,
        indexer: indexer,
        loadAsset: (_) async => Uint8List(1),
      );
      final km = _FakeKeyManagement();
      final c = _container(credits: credits, keyManagement: km);
      addTearDown(c.dispose);

      // Pre-warm walletProvider so wallet read inside the notifier is
      // already resolved when redeem() runs.
      await c.read(walletProvider.future);

      final phases = <RedeemPhase>[];
      final sub = c.listen<RedeemState>(
        redeemProvider,
        (_, next) => phases.add(next.phase),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(phases, [RedeemPhase.idle]);

      await c.read(redeemProvider.notifier).redeem(_validCode);

      // Must observe the full SNARK phase sequence in order. We use
      // containsAllInOrder because Riverpod may collapse identical
      // adjacent states (proving emitted twice → de-duped).
      expect(
        phases,
        containsAllInOrder([
          RedeemPhase.idle,
          RedeemPhase.proving,
          RedeemPhase.submitting,
          RedeemPhase.publishing,
          RedeemPhase.done,
        ]),
      );
      expect(c.read(redeemProvider).phase, RedeemPhase.done);
      expect(c.read(redeemProvider).lastTxId, 'TXID_SNARK');
      expect(c.read(redeemProvider).lastError, isNull);
      expect(km.regenCalls, 1);
      expect(ops.redeemWithProofCalls, 1);
    });
  });

  group('redeemProvider · happy path (legacy, no SNARK deps)', () {
    test('prover unavailable → legacy path completes; phases may skip proving '
        'but still transition through to done', () async {
      // No prover, no indexer → CreditsService takes the legacy path.
      final ops = _FakeOps();
      final credits = CreditsService(ops);
      final km = _FakeKeyManagement();
      final c = _container(credits: credits, keyManagement: km);
      addTearDown(c.dispose);

      await c.read(walletProvider.future);

      final phases = <RedeemPhase>[];
      final sub = c.listen<RedeemState>(
        redeemProvider,
        (_, next) => phases.add(next.phase),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      await c.read(redeemProvider.notifier).redeem(_validCode);

      // Legacy: skips `proving`; must still hit submitting → publishing → done.
      expect(
        phases,
        containsAllInOrder([
          RedeemPhase.idle,
          RedeemPhase.submitting,
          RedeemPhase.publishing,
          RedeemPhase.done,
        ]),
      );
      expect(
        phases.contains(RedeemPhase.proving),
        isFalse,
        reason: 'legacy path must NOT emit proving phase',
      );
      expect(c.read(redeemProvider).phase, RedeemPhase.done);
      expect(c.read(redeemProvider).lastTxId, 'TXID_LEGACY');
      expect(km.regenCalls, 1);
      expect(ops.redeemCalls, 1);
    });
  });

  group('redeemProvider · failure modes', () {
    test('CreditsService.redeem throws → phase=error, lastError populated, '
        'regenerateAndPublish NOT called', () async {
      final ops = _FakeOps(redeemError: const BadRedeemCodeError('bad code'));
      final credits = CreditsService(ops);
      final km = _FakeKeyManagement();
      final c = _container(credits: credits, keyManagement: km);
      addTearDown(c.dispose);

      await c.read(walletProvider.future);

      await c.read(redeemProvider.notifier).redeem(_validCode);

      final s = c.read(redeemProvider);
      expect(s.phase, RedeemPhase.error);
      expect(s.lastError, isNotNull);
      expect(s.lastError, contains('bad code'));
      expect(s.lastException, isA<BadRedeemCodeError>());
      expect(
        km.regenCalls,
        0,
        reason: 'must not republish keys when redeem itself failed',
      );
    });

    test(
      'wallet not ready → phase=error, redeem NOT called, regen NOT called',
      () async {
        final ops = _FakeOps();
        final credits = CreditsService(ops);
        final km = _FakeKeyManagement();
        final c = _container(credits: credits, keyManagement: km, wallet: null);
        addTearDown(c.dispose);

        await c.read(walletProvider.future);

        await c.read(redeemProvider.notifier).redeem(_validCode);

        final s = c.read(redeemProvider);
        expect(s.phase, RedeemPhase.error);
        expect(s.lastError, contains('Wallet not ready'));
        expect(ops.redeemCalls, 0);
        expect(km.regenCalls, 0);
      },
    );

    test(
      'network error during redeem → error state, prover/regen not advanced',
      () async {
        final ops = _FakeOps(redeemError: NetworkException('network down'));
        final credits = CreditsService(ops);
        final km = _FakeKeyManagement();
        final c = _container(credits: credits, keyManagement: km);
        addTearDown(c.dispose);

        await c.read(walletProvider.future);

        await c.read(redeemProvider.notifier).redeem(_validCode);

        final s = c.read(redeemProvider);
        expect(s.phase, RedeemPhase.error);
        expect(s.lastError, contains('network down'));
        expect(s.lastException, isA<NetworkException>());
        expect(km.regenCalls, 0);
      },
    );
  });

  group('redeemProvider · cancel', () {
    test(
      'cancel() before any redeem call is a no-op (does not throw)',
      () async {
        final ops = _FakeOps();
        final credits = CreditsService(ops);
        final c = _container(credits: credits);
        addTearDown(c.dispose);

        // Should not throw.
        c.read(redeemProvider.notifier).cancel();

        expect(c.read(redeemProvider).phase, RedeemPhase.idle);
      },
    );
  });
}
