import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messagepack/messagepack.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';

/// Golden vector — compiled TEAL of `programs/sealed/out/TreasuryEscrow.teal`
/// via algod (TestNet), then base64-encoded. Address derived via
/// `algosdk.LogicSigAccount(prog).address()` (JS). Determinism is sha512_256.
const _escrowProgB64 =
    'CzEQgQESQQA3MQcxABJBAC8xCEAAKjEBgZChDw5BACAxIDIDEkEAGDEJMgMSQQAQMRZAAAsyBIECEkEAA4EBQ4EAQw==';
const _expectedAddress =
    'V3RW2DEEOBKA7KMWMHP5MDSJMFNINEY4IC755WV6VN54JJJBPSNLWOSLAE';

void main() {
  group('TreasuryEscrowSigner — address derivation (golden vector)', () {
    test('matches algosdk-js LogicSigAccount.address()', () {
      final prog = Uint8List.fromList(base64.decode(_escrowProgB64));
      final signer = TreasuryEscrowSigner(prog);
      expect(signer.address, equals(_expectedAddress));
    });

    test('address byte-pubkey is 32 bytes', () {
      final prog = Uint8List.fromList(base64.decode(_escrowProgB64));
      final signer = TreasuryEscrowSigner(prog);
      expect(signer.addressPubkey.length, equals(32));
    });
  });

  group('TreasuryEscrowSigner — signed-txn msgpack envelope', () {
    test('produces {lsig:{l:prog}, txn:{...}} canonical map', () {
      final prog = Uint8List.fromList(base64.decode(_escrowProgB64));
      final signer = TreasuryEscrowSigner(prog);

      final txnFields = <String, dynamic>{
        'fee': 1000,
        'fv': 1_000_000,
        'lv': 1_001_000,
        'snd': signer.addressPubkey,
        'rcv': signer.addressPubkey,
        'amt': 0, // canonical encoding omits
        'type': 'pay',
      };

      final blob = signer.encodeSignedTxn(txnFields);
      // Spot-check: msgpack map of size 2, first key "lsig", second "txn".
      // 0x82 = fixmap with 2 entries.
      expect(blob[0], equals(0x82));
      // Round-trip via Unpacker.
      final u = Unpacker(blob);
      final outer = u.unpackMap();
      expect(outer.keys, containsAll(['lsig', 'txn']));
      final lsig = outer['lsig'] as Map;
      expect(lsig.keys, equals(['l']));
      expect(List<int>.from(lsig['l'] as List), equals(prog));
      final txn = outer['txn'] as Map;
      // amt=0 omitted (canonical).
      expect(txn.containsKey('amt'), isFalse);
      expect(txn['fee'], equals(1000));
      expect(txn['type'], equals('pay'));
    });

    test('rejects unsupported field type', () {
      final prog = Uint8List.fromList(base64.decode(_escrowProgB64));
      final signer = TreasuryEscrowSigner(prog);
      expect(() => signer.encodeSignedTxn({'bad': 3.14}), throwsArgumentError);
    });
  });
}
