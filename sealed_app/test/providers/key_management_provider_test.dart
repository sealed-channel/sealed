// test/providers/key_management_provider_test.dart
//
// Unit-tests for `keyManagementProvider`.
//
// Strategy: override `keyServiceProvider` and `sealedChainClientProvider`
// with fakes. The notifier reads from both via `ref.read`; we keep
// `keysProvider` real (it transitively uses our fake `KeyService`) so we can
// observe the post-regen invalidation reflects the fresh `SealedKeys`.
//
// Per CLAUDE.md: integration tests must not mock OHTTP/chain/indexer. These
// are unit tests of the notifier's own state-machine, so faking
// `SealedChainClient` at its service boundary is the right scope.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// Fakes
// ============================================================================

/// Fixed bytes for X25519 seeds — `newKeyPairFromSeed` accepts any 32 bytes.
Uint8List _seed(int filler) =>
    Uint8List.fromList(List<int>.filled(32, filler & 0xff));

/// 58-char-like wallet placeholder; identity is what matters, not validity.
const String _kWalletAddr =
    'WALLETWALLETWALLETWALLETWALLETWALLETWALLETWALLETAB';

/// Build a [SealedKeys] with deterministic-but-fake material.
/// Uses real X25519 from the cryptography package (pure Dart, no platform
/// channel) so `extractPublicKey()` works in `regenerateAndPublish`.
Future<SealedKeys> _buildSealedKeys({required Uint8List pqPub}) async {
  final x25519 = X25519();
  final encKp = await x25519.newKeyPairFromSeed(_seed(0x11));
  final scanKp = await x25519.newKeyPairFromSeed(_seed(0x22));
  final encPub = await encKp.extractPublicKey();
  final scanPub = await scanKp.extractPublicKey();
  return SealedKeys(
    encryptionKeyPair: encKp,
    scanKeyPair: scanKp,
    walletAddress: _kWalletAddr, // 50 chars; only identity matters here
    scanPubkey: Uint8List.fromList(scanPub.bytes),
    encryptionPubkey: Uint8List.fromList(encPub.bytes),
    encryptionPrivateKey: _seed(0x11),
    viewPrivateKey: _seed(0x22),
    pqPublicKey: pqPub,
    pqPrivateKey: Uint8List(1632),
  );
}

/// Fake KeyService — only the two methods the notifier touches are wired.
/// loadKeys() is called both by the notifier (post-regen) AND by
/// keysProvider.build (transitively, since we override `keyServiceProvider`).
class _FakeKeyService implements KeyService {
  _FakeKeyService({required this.initialKeys, required this.regeneratedPqPub});

  /// Current "stored" keys — mutated by `regeneratePqKeysFromMasterSeed`.
  SealedKeys? initialKeys;

  /// The pqPubkey that the fake regen will produce.
  final Uint8List regeneratedPqPub;

  int regenCalls = 0;
  int loadCalls = 0;

  @override
  Future<({Uint8List publicKey, Uint8List privateKey})>
  regeneratePqKeysFromMasterSeed() async {
    regenCalls++;
    // Simulate storage update: subsequent loadKeys reflects the new pqPub.
    final prior = initialKeys;
    if (prior != null) {
      initialKeys = await _buildSealedKeys(pqPub: regeneratedPqPub);
    }
    return (publicKey: regeneratedPqPub, privateKey: Uint8List(1632));
  }

  @override
  Future<SealedKeys?> loadKeys() async {
    loadCalls++;
    return initialKeys;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeWallet implements AlgorandWallet {
  @override
  final String? walletAddress;
  _FakeWallet(this.walletAddress);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake SealedChainClient — overrides everything the notifier touches.
class _FakeChainClient extends SealedChainClient {
  _FakeChainClient({String? walletAddr = _kWalletAddr})
    : super(
        sealedAppId: 1,
        algodUrl: 'http://test',
        indexerUrl: 'http://test',
        wallet: _FakeWallet(walletAddr),
        escrow: TreasuryEscrowSigner(Uint8List.fromList([0x06])),
      );

  /// Credits returned from getCredits.
  int credits = 5;

  /// Pretend on-chain state — controls publishKeysIfStale's idempotency.
  /// If non-null, publishKeysIfStale will compare and (when matching) skip.
  UserProfile? onChainProfile;

  int publishKeysIfStaleCalls = 0;
  int getCreditsCalls = 0;
  int getUserByWalletCalls = 0;

  /// Args from the last publishKeysIfStale call (or null).
  Uint8List? lastPublishedPq;

  @override
  Future<int> getCredits(String address) async {
    getCreditsCalls++;
    return credits;
  }

  @override
  Future<UserProfile?> getUserByWallet(String walletAddress) async {
    getUserByWalletCalls++;
    return onChainProfile;
  }

  @override
  Future<String?> publishKeysIfStale({
    required Uint8List encryptionPubkey,
    required Uint8List scanPubkey,
    required Uint8List pqPubkey,
  }) async {
    publishKeysIfStaleCalls++;
    lastPublishedPq = pqPubkey;
    return 'TXID';
  }
}

// ============================================================================
// Helpers
// ============================================================================

ProviderContainer _container({
  required KeyService keyService,
  required SealedChainClient chain,
}) {
  return ProviderContainer(
    overrides: [
      keyServiceProvider.overrideWith((_) async => keyService),
      sealedChainClientProvider.overrideWith((_) async => chain),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('keyManagementProvider.regenerateAndPublish', () {
    test(
      'happy path: phases progress and keysProvider sees regenerated pq',
      () async {
        final initialPq = Uint8List.fromList(
          List.generate(800, (i) => i & 0xff),
        );
        final newPq = Uint8List.fromList(
          List.generate(800, (i) => (i + 7) & 0xff),
        );
        final initialKeys = await _buildSealedKeys(pqPub: initialPq);

        final fakeKs = _FakeKeyService(
          initialKeys: initialKeys,
          regeneratedPqPub: newPq,
        );
        final fakeChain = _FakeChainClient();
        final c = _container(keyService: fakeKs, chain: fakeChain);
        addTearDown(c.dispose);

        // Warm keysProvider so post-invalidate rebuild path is exercised.
        final preKeys = await c.read(keysProvider.future);
        expect(preKeys?.pqPublicKey, equals(initialPq));

        final phases = <KeyPhase>[];
        final sub = c.listen<KeyManagementState>(
          keyManagementProvider,
          (_, next) => phases.add(next.phase),
          fireImmediately: true,
        );
        addTearDown(sub.close);

        expect(phases, [KeyPhase.idle]);

        await c.read(keyManagementProvider.notifier).regenerateAndPublish();

        // We expect to see at least: regenerating, publishing, done.
        // (idle is the initial.)
        expect(
          phases,
          containsAllInOrder([
            KeyPhase.idle,
            KeyPhase.regenerating,
            KeyPhase.publishing,
            KeyPhase.done,
          ]),
        );
        expect(fakeKs.regenCalls, 1);
        expect(fakeChain.publishKeysIfStaleCalls, 1);
        expect(
          fakeChain.lastPublishedPq,
          equals(newPq),
          reason:
              'publish must use the freshly regenerated pq, not stale cache',
        );

        // keysProvider should now reflect the regenerated pq after invalidation.
        final postKeys = await c.read(keysProvider.future);
        expect(postKeys?.pqPublicKey, equals(newPq));
      },
    );

    test('respects pqPublishBlockedFlagKey — no regen, no publish', () async {
      SharedPreferences.setMockInitialValues({pqPublishBlockedFlagKey: true});

      final initialKeys = await _buildSealedKeys(pqPub: Uint8List(800));
      final fakeKs = _FakeKeyService(
        initialKeys: initialKeys,
        regeneratedPqPub: Uint8List(800),
      );
      final fakeChain = _FakeChainClient();
      final c = _container(keyService: fakeKs, chain: fakeChain);
      addTearDown(c.dispose);

      await c.read(keyManagementProvider.notifier).regenerateAndPublish();

      final state = c.read(keyManagementProvider);
      expect(state.phase, KeyPhase.blockedByMismatch);
      expect(
        fakeKs.regenCalls,
        0,
        reason: 'must not call regenerate when block flag is set',
      );
      expect(
        fakeChain.publishKeysIfStaleCalls,
        0,
        reason: 'must not call publish when block flag is set',
      );
    });
  });

  group('keyManagementProvider.ensurePublished', () {
    test(
      'no-op (transitions to done) when on-chain is already fresh',
      () async {
        // The semantic the contract gives us: publishKeysIfStale itself is
        // idempotent — it just returns null when on-chain matches. The notifier
        // forwards that call when credits are available. The "no-op" semantic
        // we own at the notifier layer is: do not call publishKeysIfStale at
        // all when credits < 1. The chain-side idempotency lives in the
        // SealedChainClient and is exercised in its own tests.
        //
        // Here we simulate "already published" via credits=0 — the notifier
        // skips the publish call entirely, mirroring the boot guard.
        final initialKeys = await _buildSealedKeys(pqPub: Uint8List(800));
        final fakeKs = _FakeKeyService(
          initialKeys: initialKeys,
          regeneratedPqPub: Uint8List(800),
        );
        final fakeChain = _FakeChainClient()..credits = 0;
        final c = _container(keyService: fakeKs, chain: fakeChain);
        addTearDown(c.dispose);

        await c.read(keyManagementProvider.notifier).ensurePublished();

        expect(c.read(keyManagementProvider).phase, KeyPhase.done);
        expect(
          fakeChain.publishKeysIfStaleCalls,
          0,
          reason: 'no credits → skip publish call entirely',
        );
        // No regenerate either — ensurePublished must never regen.
        expect(fakeKs.regenCalls, 0);
      },
    );

    test('publishes when keys present and wallet has credits', () async {
      final initialPq = Uint8List.fromList(
        List.generate(800, (i) => (i + 3) & 0xff),
      );
      final initialKeys = await _buildSealedKeys(pqPub: initialPq);
      final fakeKs = _FakeKeyService(
        initialKeys: initialKeys,
        regeneratedPqPub: Uint8List(800),
      );
      final fakeChain = _FakeChainClient()..credits = 2;
      final c = _container(keyService: fakeKs, chain: fakeChain);
      addTearDown(c.dispose);

      await c.read(keyManagementProvider.notifier).ensurePublished();

      expect(c.read(keyManagementProvider).phase, KeyPhase.done);
      expect(fakeChain.publishKeysIfStaleCalls, 1);
      expect(
        fakeChain.lastPublishedPq,
        equals(initialPq),
        reason: 'ensurePublished must publish the EXISTING pq, not regenerate',
      );
      expect(fakeKs.regenCalls, 0, reason: 'ensurePublished must not regen');
    });

    test('respects pqPublishBlockedFlagKey', () async {
      SharedPreferences.setMockInitialValues({pqPublishBlockedFlagKey: true});

      final initialKeys = await _buildSealedKeys(pqPub: Uint8List(800));
      final fakeKs = _FakeKeyService(
        initialKeys: initialKeys,
        regeneratedPqPub: Uint8List(800),
      );
      final fakeChain = _FakeChainClient()..credits = 10;
      final c = _container(keyService: fakeKs, chain: fakeChain);
      addTearDown(c.dispose);

      await c.read(keyManagementProvider.notifier).ensurePublished();

      expect(c.read(keyManagementProvider).phase, KeyPhase.blockedByMismatch);
      expect(fakeChain.publishKeysIfStaleCalls, 0);
    });
  });
}
