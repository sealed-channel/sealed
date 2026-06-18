// Tests for SealedUsernameOps.isAvailable.
//
// Verifies:
//   1. Length-bounds checks (<3, >20) short-circuit without a chain call.
//   2. Null profile → available.
//   3. Profile owned by selfWallet → available (rename-to-self).
//   4. Profile owned by someone else → taken.
//   5. Profile exists + no selfWallet → taken.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/sealed_username_ops.dart';
import 'package:sealed_app/models/user_profile.dart';

/// Manual fake of [SealedChainClient]. Only [getUserByUsername] is exercised
/// by [SealedUsernameOps.isAvailable]; everything else throws via
/// [noSuchMethod] so unintended calls fail loudly.
class _FakeChainClient implements SealedChainClient {
  _FakeChainClient({this.profile});

  final UserProfile? profile;
  int callCount = 0;
  String? lastName;

  @override
  Future<UserProfile?> getUserByUsername(String name) async {
    callCount++;
    lastName = name;
    return profile;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

UserProfile _profile(String wallet) => UserProfile(
  walletAddress: wallet,
  encryptionPubkey: Uint8List(32),
  scanPubkey: Uint8List(32),
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  group('SealedUsernameOps.isAvailable', () {
    test('returns false for length 2 without calling chain', () async {
      final fake = _FakeChainClient();
      final ops = SealedUsernameOps(fake);

      expect(await ops.isAvailable('ab'), isFalse);
      expect(fake.callCount, 0);
    });

    test('returns false for length 21 without calling chain', () async {
      final fake = _FakeChainClient();
      final ops = SealedUsernameOps(fake);

      expect(await ops.isAvailable('a' * 21), isFalse);
      expect(fake.callCount, 0);
    });

    test('returns true when chain reports no profile', () async {
      final fake = _FakeChainClient(profile: null);
      final ops = SealedUsernameOps(fake);

      expect(await ops.isAvailable('alice'), isTrue);
      expect(fake.callCount, 1);
      expect(fake.lastName, 'alice');
    });

    test(
      'returns true when profile owner == selfWallet (rename-to-self)',
      () async {
        const wallet = 'WALLETSELF';
        final fake = _FakeChainClient(profile: _profile(wallet));
        final ops = SealedUsernameOps(fake);

        expect(await ops.isAvailable('alice', selfWallet: wallet), isTrue);
      },
    );

    test('returns false when profile owner != selfWallet (taken)', () async {
      final fake = _FakeChainClient(profile: _profile('WALLETOTHER'));
      final ops = SealedUsernameOps(fake);

      expect(await ops.isAvailable('alice', selfWallet: 'WALLETSELF'), isFalse);
    });

    test('returns false when profile exists and selfWallet is null', () async {
      final fake = _FakeChainClient(profile: _profile('WALLETOTHER'));
      final ops = SealedUsernameOps(fake);

      expect(await ops.isAvailable('alice'), isFalse);
    });

    test('normalizes name (trim + lowercase) before chain lookup', () async {
      final fake = _FakeChainClient();
      final ops = SealedUsernameOps(fake);

      await ops.isAvailable('  Alice  ');
      expect(fake.lastName, 'alice');
    });
  });
}
