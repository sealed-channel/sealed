// Tests for MigrationNoticeService — the one-shot post-login informational
// dialog that warns legacy 12-word BIP39 restorers about wiped on-chain
// usernames after the new Algorand `app id` migration.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/identity/migration_notice_service.dart';

void main() {
  group('MigrationNoticeService', () {
    late _InMemorySecureStorage storage;
    late MigrationNoticeService service;

    setUp(() {
      storage = _InMemorySecureStorage();
      service = MigrationNoticeService(storage: storage);
    });

    test('fresh install: shouldShow is false', () async {
      expect(await service.shouldShow(), isFalse);
    });

    test('markPending arms the trigger; shouldShow becomes true', () async {
      await service.markPending();
      expect(await service.shouldShow(), isTrue);
    });

    test('markShown consumes pending and persists shown flag', () async {
      await service.markPending();
      await service.markShown();
      expect(await service.shouldShow(), isFalse);

      // pending was consumed
      expect(
        await storage.read(key: MigrationNoticeService.pendingKey),
        isNull,
      );
      // shown flag persisted
      expect(await storage.read(key: MigrationNoticeService.shownKey), '1');
    });

    test(
      'once shown, re-arming markPending does NOT cause re-display',
      () async {
        await service.markPending();
        await service.markShown();
        await service.markPending();
        expect(await service.shouldShow(), isFalse);
      },
    );

    test('markShown is idempotent', () async {
      await service.markPending();
      await service.markShown();
      await service.markShown();
      expect(await service.shouldShow(), isFalse);
      expect(await storage.read(key: MigrationNoticeService.shownKey), '1');
    });

    test('survives a fresh service instance against same storage', () async {
      await service.markPending();
      final other = MigrationNoticeService(storage: storage);
      expect(await other.shouldShow(), isTrue);
      await other.markShown();
      final third = MigrationNoticeService(storage: storage);
      expect(await third.shouldShow(), isFalse);
    });

    test('reset clears both flags', () async {
      await service.markPending();
      await service.markShown();
      await service.reset();
      expect(
        await storage.read(key: MigrationNoticeService.pendingKey),
        isNull,
      );
      expect(await storage.read(key: MigrationNoticeService.shownKey), isNull);
    });
  });
}

/// In-memory FlutterSecureStorage stub for tests.
class _InMemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> _mem = {};

  @override
  AndroidOptions get aOptions => const AndroidOptions();
  @override
  IOSOptions get iOptions => const IOSOptions();
  @override
  LinuxOptions get lOptions => const LinuxOptions();
  @override
  MacOsOptions get mOptions => const MacOsOptions();
  @override
  WindowsOptions get wOptions => const WindowsOptions();
  @override
  WebOptions get webOptions => const WebOptions();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _mem[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _mem.remove(key);
    } else {
      _mem[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _mem.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _mem.clear();
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _mem.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_mem);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
