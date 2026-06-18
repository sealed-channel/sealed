import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/background_wake_sync.dart';
import 'package:sealed_app/features/messaging/message_kem_handshake.dart'
    show kemDiscoveryTag;
import 'package:sealed_app/features/messaging/wake_matcher.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/local/block_mirror.dart';
import 'package:sealed_app/infra/local/wake_stage_store.dart';

CryptoService crypto() => CryptoService(
  x25519: X25519(),
  hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
  aesGcm: AesGcm.with256bits(),
  hmac: Hmac.sha256(),
);

StagedEnvelope envWith({
  required String sender,
  required Uint8List senderEncPub,
  required Uint8List recipientTag,
}) => StagedEnvelope(
  round: 1,
  txid: 'tx',
  senderAddress: sender,
  senderEncryptionPubkey: senderEncPub,
  recipientTag: recipientTag,
  ciphertext: Uint8List.fromList(List.filled(8, 0)),
);

void main() {
  const me = 'MY_WALLET';

  test('KEM first-contact discovery tag matches', () async {
    final tag = await kemDiscoveryTag('PEER', me);
    final m = CryptoWakeMatcher(
      crypto: crypto(),
      myScanKeyPair: await X25519().newKeyPair(),
      myWalletAddress: me,
    );
    expect(
      await m.matches(
        envWith(
          sender: 'PEER',
          senderEncPub: Uint8List.fromList(List.filled(32, 1)),
          recipientTag: tag,
        ),
      ),
      isTrue,
    );
  });

  test('steady-state scan-key tag matches', () async {
    final x = X25519();
    final myScan = await x.newKeyPair();
    final myScanPub = await myScan.extractPublicKey();
    final senderEph = await x.newKeyPair();
    final senderEphPub = await senderEph.extractPublicKey();

    // Build the tag the way checkRecipientTag verifies it: ECDH(sender, myScanPub)
    // → HMAC("sealed-recipient-tag-v1").
    final shared = await x.sharedSecretKey(
      keyPair: senderEph,
      remotePublicKey: myScanPub,
    );
    final mac = await Hmac.sha256().calculateMac(
      'sealed-recipient-tag-v1'.codeUnits,
      secretKey: shared,
    );

    final m = CryptoWakeMatcher(
      crypto: crypto(),
      myScanKeyPair: myScan,
      myWalletAddress: me,
    );
    expect(
      await m.matches(
        envWith(
          sender: 'PEER',
          senderEncPub: Uint8List.fromList(senderEphPub.bytes),
          recipientTag: Uint8List.fromList(mac.bytes),
        ),
      ),
      isTrue,
    );
  });

  test('non-matching tag → false', () async {
    final m = CryptoWakeMatcher(
      crypto: crypto(),
      myScanKeyPair: await X25519().newKeyPair(),
      myWalletAddress: me,
    );
    expect(
      await m.matches(
        envWith(
          sender: 'PEER',
          senderEncPub: Uint8List.fromList(List.filled(32, 2)),
          recipientTag: Uint8List.fromList(List.filled(32, 9)),
        ),
      ),
      isFalse,
    );
  });

  test('own outgoing copy (sender == me) → false', () async {
    // Even with a tag that would match KEM, a self-sender is skipped.
    final tag = await kemDiscoveryTag(me, me);
    final m = CryptoWakeMatcher(
      crypto: crypto(),
      myScanKeyPair: await X25519().newKeyPair(),
      myWalletAddress: me,
    );
    expect(
      await m.matches(
        envWith(
          sender: me,
          senderEncPub: Uint8List.fromList(List.filled(32, 1)),
          recipientTag: tag,
        ),
      ),
      isFalse,
    );
  });

  group('BlockAwareWakeMatcher', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('bam_test');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    BlockMirror mirror() => BlockMirror(
      mirrorKey: Uint8List.fromList(List.filled(32, 3)),
      filePathOverride: '${tmp.path}/bm.bin',
    );
    StagedEnvelope from(String sender) => envWith(
      sender: sender,
      senderEncPub: Uint8List.fromList(List.filled(32, 0)),
      recipientTag: Uint8List.fromList(List.filled(32, 0)),
    );

    test('matched + NOT blocked → true', () async {
      final m = BlockAwareWakeMatcher(inner: _AlwaysMatch(), mirror: mirror());
      expect(await m.matches(from('PEER')), isTrue);
    });

    test('matched + blocked → false (suppressed)', () async {
      final mir = mirror();
      await mir.add('PEER');
      final m = BlockAwareWakeMatcher(inner: _AlwaysMatch(), mirror: mir);
      expect(await m.matches(from('PEER')), isFalse);
    });

    test('not matched → false (block gate not reached)', () async {
      final m = BlockAwareWakeMatcher(inner: _NeverMatch(), mirror: mirror());
      expect(await m.matches(from('PEER')), isFalse);
    });
  });
}

class _AlwaysMatch implements WakeMatcher {
  @override
  Future<bool> matches(StagedEnvelope c) async => true;
}

class _NeverMatch implements WakeMatcher {
  @override
  Future<bool> matches(StagedEnvelope c) async => false;
}
