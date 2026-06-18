import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/infra/local/repositories/contact_keys.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/providers/contact_keys_provider.dart';

class _FakeContactRepo implements ContactRepository {
  _FakeContactRepo(this._keys, {this.throws = false});

  final ContactKeys _keys;
  final bool throws;

  @override
  Future<ContactKeys> getContactKeys(String walletAddress) async {
    if (throws) throw StateError('repo broken');
    return _keys;
  }

  // Unused — throw to surface accidental usage.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not stubbed');
}

void main() {
  group('hasCachedPqSecretProvider', () {
    test('true when a KEM shared secret is cached', () async {
      final fake = _FakeContactRepo(
        ContactKeys(pqSharedSecret: Uint8List.fromList([1, 2, 3])),
      );
      final container = ProviderContainer(
        overrides: [contactRepositoryProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final result = await container.read(
        hasCachedPqSecretProvider('addr').future,
      );
      expect(result, isTrue);
    });

    test(
      'false when no secret cached (first-send handshake pending)',
      () async {
        final fake = _FakeContactRepo(const ContactKeys());
        final container = ProviderContainer(
          overrides: [contactRepositoryProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          hasCachedPqSecretProvider('addr').future,
        );
        expect(result, isFalse);
      },
    );

    test(
      'true when repo throws (defensive default — no false cost warning)',
      () async {
        final fake = _FakeContactRepo(const ContactKeys(), throws: true);
        final container = ProviderContainer(
          overrides: [contactRepositoryProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          hasCachedPqSecretProvider('addr').future,
        );
        expect(result, isTrue);
      },
    );
  });
}
