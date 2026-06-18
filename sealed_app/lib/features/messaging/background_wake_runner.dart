// Production entry for the push pre-sync background pipeline (T9/T10). Runs in
// the FCM background isolate: constructs the minimal service graph WITHOUT
// Riverpod, fetches recent on-chain messages, matches recipiency (PIN-free
// tag-check), drops blocked senders via the BlockMirror, stages the rest to the
// device-secret WakeStageStore, and posts ONE generic local notification if any
// non-blocked message was staged. Never opens the DEK DB, never advances the
// cursor — the main isolate decrypts staged envelopes on unlock.
library;

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/features/messaging/background_wake_sync.dart';
import 'package:sealed_app/features/messaging/wake_matcher.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_program.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/block_mirror.dart';
import 'package:sealed_app/infra/local/dek_manager.dart';
import 'package:sealed_app/infra/network/ohttp/ohttp_interceptor.dart';
import 'package:sealed_app/infra/local/wake_stage_store.dart';

/// Run the background pre-sync. Returns the number of non-blocked messages
/// staged (and, if ≥1, posts the generic notification). Fail-safe: any missing
/// prerequisite (no wallet, locked keys, no device secret) is a quiet 0.
Future<int> runBackgroundWakeSync() async {
  const storage = FlutterSecureStorage();

  final wallet = AlgorandWallet(storage);
  await wallet.loadExistingWallet();
  final myWallet = wallet.walletAddress;
  if (myWallet == null) return 0;

  final prefs = await SharedPreferences.getInstance();
  final keyService = KeyService(
    storage: storage,
    prefs: prefs,
    x25519: X25519(),
    hkdf: DartHkdf(hmac: DartHmac.sha256(), outputLength: 32),
    chainWallet: wallet,
  );
  final myKeys = await keyService.loadKeys();
  if (myKeys == null) return 0; // locked / missing keys

  final crypto = CryptoService(
    x25519: X25519(),
    hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
    aesGcm: AesGcm.with256bits(),
    hmac: Hmac.sha256(),
  );

  final dek = DekManager(storage: storage);
  final WakeStageStore store;
  final BlockMirror mirror;
  try {
    store = WakeStageStore(stagingKey: await dek.deriveStagingKey());
    mirror = BlockMirror(mirrorKey: await dek.deriveBlockMirrorKey());
  } catch (e) {
    debugPrint('[BackgroundWake] key derivation failed: $e');
    return 0; // scan seed unavailable
  }

  final walletDerived = await keyService.getWalletDerivedX25519KeyPair();
  final matcher = BlockAwareWakeMatcher(
    inner: CryptoWakeMatcher(
      crypto: crypto,
      myScanKeyPair: myKeys.scanKeyPair,
      myWalletAddress: myWallet,
      walletDerivedScanKeyPair: walletDerived,
    ),
    mirror: mirror,
  );

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  )..interceptors.add(OhttpInterceptor.algo());
  final chain = SealedChainClient(
    sealedAppId: SEALED_APP_ID,
    algodUrl: ALGO_ALGOD_URL,
    indexerUrl: ALGO_INDEXER_URL,
    wallet: wallet,
    escrow: buildTreasuryEscrowSigner(),
    dio: dio,
  );
  final source = ChainWakeEnvelopeSource(
    fetch: (since) => chain.fetchMessages(sinceTimestamp: since),
  );

  final staged = await BackgroundWakeSync(
    source: source,
    matcher: matcher,
    store: store,
  ).run();

  if (staged >= 1) {
    try {
      await NotificationService().presentGenericNotification();
    } catch (e) {
      debugPrint('[BackgroundWake] notification failed: $e');
    }
  }
  debugPrint('[BackgroundWake] staged=$staged');
  return staged;
}
