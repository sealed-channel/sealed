// Production recipiency matcher + envelope source for the push pre-sync
// background pipeline (internal/docs/plan-push-prefetch-sync.md, T3-real).
//
// The background isolate only decides RECIPIENCY (is this on-chain message
// addressed to me?) — it never decrypts payloads or opens the DEK DB. Both
// checks are PIN-free:
//   • steady-state: CryptoService.checkRecipientTag (X25519 scan-key ECDH),
//   • KEM first-contact: recipientTag == kemDiscoveryTag(sender, me).
// Matched messages are staged whole; the main isolate decrypts them on unlock.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SimpleKeyPair;

import 'package:sealed_app/features/messaging/background_wake_sync.dart';
import 'package:sealed_app/features/messaging/message_kem_handshake.dart'
    show kemDiscoveryTag;
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/local/block_mirror.dart';
import 'package:sealed_app/infra/local/wake_stage_store.dart';

/// Decides recipiency via the SAME tag checks the live sync uses
/// (`_syncIncomingMessages`): primary HKDF scan-key tag, optional wallet-derived
/// scan-key fallback (legacy senders), and the KEM first-contact discovery tag.
/// All key material is PIN-free (secure storage); no DB, no decapsulation.
class CryptoWakeMatcher implements WakeMatcher {
  CryptoWakeMatcher({
    required CryptoService crypto,
    required SimpleKeyPair myScanKeyPair,
    required String myWalletAddress,
    SimpleKeyPair? walletDerivedScanKeyPair,
  }) : _crypto = crypto,
       _scan = myScanKeyPair,
       _myWallet = myWalletAddress,
       _walletDerivedScan = walletDerivedScanKeyPair;

  final CryptoService _crypto;
  final SimpleKeyPair _scan;
  final String _myWallet;
  final SimpleKeyPair? _walletDerivedScan;

  @override
  Future<bool> matches(StagedEnvelope c) async {
    // Never match our own outgoing copies.
    if (c.senderAddress == _myWallet) return false;

    // Steady-state: primary scan key, then the legacy wallet-derived fallback.
    if (await _crypto.checkRecipientTag(
      senderEncryptionPubkey: c.senderEncryptionPubkey,
      recipientTag: c.recipientTag,
      myScanKeyPair: _scan,
    )) {
      return true;
    }
    final wd = _walletDerivedScan;
    if (wd != null &&
        await _crypto.checkRecipientTag(
          senderEncryptionPubkey: c.senderEncryptionPubkey,
          recipientTag: c.recipientTag,
          myScanKeyPair: wd,
        )) {
      return true;
    }

    // KEM first-contact: deterministic discovery tag (shared source of truth).
    final kemTag = await kemDiscoveryTag(c.senderAddress, _myWallet);
    return _crypto.constantTimeEquals(c.recipientTag, kemTag);
  }
}

/// Wraps a recipiency [WakeMatcher] with the #17 block gate: a message that is
/// addressed to us BUT from a blocked sender is dropped — not staged, so it
/// raises no background notification (it still arrives via the next normal sync
/// into the Spam tab). Fail-safe: a mirror error ⇒ don't suppress (treat as
/// not-blocked), so a non-blocked message is never silently lost.
class BlockAwareWakeMatcher implements WakeMatcher {
  BlockAwareWakeMatcher({
    required WakeMatcher inner,
    required BlockMirror mirror,
  }) : _inner = inner,
       _mirror = mirror;

  final WakeMatcher _inner;
  final BlockMirror _mirror;

  @override
  Future<bool> matches(StagedEnvelope c) async {
    if (!await _inner.matches(c)) return false;
    try {
      if (await _mirror.contains(c.senderAddress)) return false;
    } catch (_) {
      // Mirror unavailable → fail-open (notify); never drop a real message.
    }
    return true;
  }
}

/// Fetches recent on-chain messages and maps them to [StagedEnvelope]s for the
/// matcher. The background isolate can't read the DEK-backed sync cursor, so it
/// fetches a fixed recent window (the push that woke us is recent); the main
/// isolate's cursor-based sync remains authoritative and reconciles the rest.
/// NEVER advances any cursor.
class ChainWakeEnvelopeSource implements WakeEnvelopeSource {
  ChainWakeEnvelopeSource({
    required Future<List<Map<String, dynamic>>> Function(int sinceTimestampSecs)
    fetch,
    this.lookback = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _fetch = fetch,
       _now = clock ?? DateTime.now;

  final Future<List<Map<String, dynamic>>> Function(int sinceTimestampSecs)
  _fetch;
  final Duration lookback;
  final DateTime Function() _now;

  @override
  Future<List<StagedEnvelope>> fetchSinceCursor() async {
    final since = _now().subtract(lookback).millisecondsSinceEpoch ~/ 1000;
    final raw = await _fetch(since);
    return [for (final m in raw) _fromRaw(m)];
  }

  static StagedEnvelope _fromRaw(Map<String, dynamic> m) => StagedEnvelope(
    round: m['timestamp'] as int,
    txid: m['accountPubkey'] as String,
    senderAddress: m['senderAddress'] as String,
    senderEncryptionPubkey: m['senderEncryptionPubkey'] as Uint8List,
    recipientTag: m['recipientTag'] as Uint8List,
    ciphertext: m['ciphertext'] as Uint8List,
  );
}
