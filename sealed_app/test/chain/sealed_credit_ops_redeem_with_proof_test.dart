// Group composition tests for `redeemWithProof` (PLAN-snark-redeem-B T10).
//
// We exercise the static `SealedChainClient.debugBuildRedeemWithProofGroup`
// seam — same code path the live submitter uses, minus algod params + the
// signing/submit step. Asserts:
//   • 2-txn group (escrow pay txn 0, app-call txn 1)
//   • Escrow self-pay: amt=0, snd==rcv==escrow, fee == 220_000 µAlgo
//   • App-call ABI selector + 5 ABI args (rootRef, nullifier, length-prefixed
//     proof / pubInputs / username bytes)
//   • Box refs: r:<rootRef>, nb:<nullifier>, w:<wallet pubkey>, optional
//     n:<sha256(username)>

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';

Uint8List _bytes(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xff));

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  group('redeemWithProof — group composition (T10)', () {
    final senderPubkey = _bytes(0xA0, 32);
    final escrowPubkey = _bytes(0xE0, 32);
    final rootRef = _bytes(0x10, 32);
    final nullifier = _bytes(0x20, 32);
    final proof = _bytes(0x30, 256);
    final pubInputs = _bytes(0x40, 128);
    final genesisHash = _bytes(0x99, 32);

    test('2-txn group: escrow self-pay txn 0 + app-call txn 1', () {
      final out = SealedChainClient.debugBuildRedeemWithProofGroup(
        senderPubkey: senderPubkey,
        escrowPubkey: escrowPubkey,
        sealedAppId: 4242,
        rootRef: rootRef,
        nullifier: nullifier,
        proof: proof,
        pubInputs: pubInputs,
        firstValid: 100,
        lastValid: 1100,
        genesisId: 'dockernet-v1',
        genesisHash: genesisHash,
      );

      // Txn 0 = escrow self-pay.
      expect(out.escrowTxn['type'], 'pay');
      expect(out.escrowTxn['snd'], escrowPubkey);
      expect(out.escrowTxn['rcv'], escrowPubkey);
      // 'amt' omitted in canonical encoding when zero.
      expect(out.escrowTxn['amt'], isNull);
      expect(out.escrowTxn['fee'], SealedChainClient.redeemWithProofFeePool);
      expect(out.escrowTxn['fee'], 220000);

      // Txn 1 = app call.
      expect(out.appCallTxn['type'], 'appl');
      expect(out.appCallTxn['apid'], 4242);
      expect(out.appCallTxn['fee'], 0);
      expect(out.appCallTxn['snd'], senderPubkey);

      // Group binding.
      expect(out.escrowTxn['grp'], out.groupId);
      expect(out.appCallTxn['grp'], out.groupId);
    });

    test('ABI selector matches contract: redeemWithProof(...)void', () {
      // sha512_256("redeemWithProof(byte[32],byte[32],byte[],byte[],byte[])void")[0..4]
      // computed from algosdk JS: be 2a d9 ef.
      expect(
        SealedChainClient.redeemWithProofSelector,
        orderedEquals([0xbe, 0x2a, 0xd9, 0xef]),
      );

      final out = SealedChainClient.debugBuildRedeemWithProofGroup(
        senderPubkey: senderPubkey,
        escrowPubkey: escrowPubkey,
        sealedAppId: 1,
        rootRef: rootRef,
        nullifier: nullifier,
        proof: proof,
        pubInputs: pubInputs,
        firstValid: 1,
        lastValid: 1000,
        genesisId: 'g',
        genesisHash: genesisHash,
      );
      final apaa = (out.appCallTxn['apaa'] as List).cast<Uint8List>();
      // [selector, rootRef, nullifier, abi(proof), abi(pubInputs), abi(name)]
      expect(apaa.length, 6);
      expect(apaa[0], SealedChainClient.redeemWithProofSelector);
      expect(_eq(apaa[1], rootRef), isTrue);
      expect(_eq(apaa[2], nullifier), isTrue);

      // ABI dynamic bytes = 2B BE length + payload.
      expect(apaa[3].length, 2 + proof.length);
      expect((apaa[3][0] << 8) | apaa[3][1], proof.length);
      expect(_eq(apaa[3].sublist(2), proof), isTrue);

      expect(apaa[4].length, 2 + pubInputs.length);
      expect((apaa[4][0] << 8) | apaa[4][1], pubInputs.length);
      expect(_eq(apaa[4].sublist(2), pubInputs), isTrue);

      // No username → empty length-prefixed bytes.
      expect(apaa[5].length, 2);
      expect(apaa[5][0], 0);
      expect(apaa[5][1], 0);
    });

    test('without username: box refs are r:, nb:, w: (3 refs, no n:)', () {
      final out = SealedChainClient.debugBuildRedeemWithProofGroup(
        senderPubkey: senderPubkey,
        escrowPubkey: escrowPubkey,
        sealedAppId: 1,
        rootRef: rootRef,
        nullifier: nullifier,
        proof: proof,
        pubInputs: pubInputs,
        firstValid: 1,
        lastValid: 1000,
        genesisId: 'g',
        genesisHash: genesisHash,
      );
      final boxes = (out.appCallTxn['apbx'] as List)
          .cast<Map<String, dynamic>>();
      expect(boxes.length, 3);

      final keys = boxes.map((b) => b['n'] as Uint8List).toList();
      // r: prefix
      expect(keys[0].sublist(0, 2), orderedEquals([0x72, 0x3a]));
      expect(_eq(keys[0].sublist(2), rootRef), isTrue);
      // nb: prefix
      expect(keys[1].sublist(0, 3), orderedEquals([0x6e, 0x62, 0x3a]));
      expect(_eq(keys[1].sublist(3), nullifier), isTrue);
      // w: prefix + sender pubkey (NOT sha256-wrapped — wallet key is raw).
      expect(keys[2].sublist(0, 2), orderedEquals([0x77, 0x3a]));
      expect(_eq(keys[2].sublist(2), senderPubkey), isTrue);

      // App index 0 (self) for all box refs.
      for (final b in boxes) {
        expect(b['i'], 0);
      }
    });

    test('with username: 4 box refs including n:<sha256(name)>', () {
      const username = 'alice_t10';
      final out = SealedChainClient.debugBuildRedeemWithProofGroup(
        senderPubkey: senderPubkey,
        escrowPubkey: escrowPubkey,
        sealedAppId: 1,
        rootRef: rootRef,
        nullifier: nullifier,
        proof: proof,
        pubInputs: pubInputs,
        username: username,
        firstValid: 1,
        lastValid: 1000,
        genesisId: 'g',
        genesisHash: genesisHash,
      );
      final boxes = (out.appCallTxn['apbx'] as List)
          .cast<Map<String, dynamic>>();
      expect(boxes.length, 4);
      final nameBox = boxes[3]['n'] as Uint8List;
      // n: prefix
      expect(nameBox.sublist(0, 2), orderedEquals([0x6e, 0x3a]));
      final expectedHash = pkg_crypto.sha256
          .convert(utf8.encode(username))
          .bytes;
      expect(_eq(nameBox.sublist(2), Uint8List.fromList(expectedHash)), isTrue);

      // App-call last ABI arg = abi-encoded username bytes.
      final apaa = (out.appCallTxn['apaa'] as List).cast<Uint8List>();
      final nameArg = apaa[5];
      expect((nameArg[0] << 8) | nameArg[1], username.length);
      expect(utf8.decode(nameArg.sublist(2)), username);
    });
  });
}
