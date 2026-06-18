// test/models/user_profile_test.dart

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/models/user_profile.dart';

UserProfile _makeProfile({Uint8List? pqPubkeyHash}) => UserProfile(
  walletAddress: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  encryptionPubkey: Uint8List(32),
  scanPubkey: Uint8List(32),
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  pqPubkeyHash: pqPubkeyHash,
);

void main() {
  group('UserProfile.verifyPqPubkey', () {
    final pq = Uint8List.fromList(List.generate(800, (i) => i % 256));
    final correctHash = Uint8List.fromList(sha256.convert(pq).bytes);

    test('accepts matching pq + hash', () {
      expect(UserProfile.verifyPqPubkey(pq, correctHash), isTrue);
    });

    test('rejects tampered pq (one byte flipped)', () {
      final tampered = Uint8List.fromList(pq);
      tampered[0] ^= 0x01;
      expect(UserProfile.verifyPqPubkey(tampered, correctHash), isFalse);
    });

    test('rejects wrong hash', () {
      final wrongHash = Uint8List(32); // all zeros
      expect(UserProfile.verifyPqPubkey(pq, wrongHash), isFalse);
    });

    test('rejects hash with length != 32', () {
      final shortHash = Uint8List(16);
      expect(UserProfile.verifyPqPubkey(pq, shortHash), isFalse);
    });

    test('rejects empty hash', () {
      expect(UserProfile.verifyPqPubkey(pq, Uint8List(0)), isFalse);
    });
  });

  group('UserProfile toMap / fromMap round-trip', () {
    test('round-trips pqPubkeyHash correctly', () {
      final hash = Uint8List.fromList(List.generate(32, (i) => i));
      final profile = _makeProfile(pqPubkeyHash: hash);
      final map = profile.toMap();
      final restored = UserProfile.fromMap({
        ...map,
        // fromMap expects wallet_address key
        'wallet_address': map['wallet_address'],
      });
      expect(restored.pqPubkeyHash, equals(hash));
    });

    test('round-trips null pqPubkeyHash (old row)', () {
      final profile = _makeProfile(pqPubkeyHash: null);
      final map = profile.toMap();
      // simulate old row: no pq_pubkey_hash key at all
      map.remove('pq_pubkey_hash');
      final restored = UserProfile.fromMap(map);
      expect(restored.pqPubkeyHash, isNull);
    });

    test('round-trips null pqPubkeyHash (explicit null in map)', () {
      final profile = _makeProfile(pqPubkeyHash: null);
      final map = profile.toMap();
      final restored = UserProfile.fromMap(map);
      expect(restored.pqPubkeyHash, isNull);
    });
  });

  group('UserProfile.copyWith', () {
    test('copies pqPubkeyHash', () {
      final hash = Uint8List(32)..fillRange(0, 32, 0xAB);
      final profile = _makeProfile();
      final updated = profile.copyWith(pqPubkeyHash: hash);
      expect(updated.pqPubkeyHash, equals(hash));
      expect(updated.walletAddress, equals(profile.walletAddress));
    });

    test('preserves existing pqPubkeyHash when not overridden', () {
      final hash = Uint8List(32)..fillRange(0, 32, 0xCD);
      final profile = _makeProfile(pqPubkeyHash: hash);
      final updated = profile.copyWith(username: 'alice');
      expect(updated.pqPubkeyHash, equals(hash));
    });
  });

  group('UserProfile.pqPubkeyHashHex', () {
    test('returns hex string for set hash', () {
      final hash = Uint8List.fromList(List.generate(32, (i) => i));
      final profile = _makeProfile(pqPubkeyHash: hash);
      expect(profile.pqPubkeyHashHex, hasLength(64));
      expect(profile.pqPubkeyHashHex, startsWith('00010203'));
    });

    test('returns null when hash is null', () {
      expect(_makeProfile().pqPubkeyHashHex, isNull);
    });
  });

  group('UserProfile equality', () {
    test('differs when username changes (drives currentUserProvider refresh)', () {
      final before = _makeProfile();
      final after = before.copyWith(username: 'alice');
      expect(after == before, isFalse);
      expect(after.hashCode == before.hashCode, isFalse);
    });

    test('differs when alias changes', () {
      final before = _makeProfile();
      final after = before.copyWith(alias: 'wonderland');
      expect(after == before, isFalse);
    });

    test('equal when wallet/username/alias all match', () {
      expect(_makeProfile() == _makeProfile(), isTrue);
      expect(_makeProfile().hashCode == _makeProfile().hashCode, isTrue);
    });
  });
}
