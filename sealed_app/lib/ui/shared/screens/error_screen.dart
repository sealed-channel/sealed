import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/shared/theme.dart';

class ErrorScreen extends ConsumerWidget {
  final Object error;

  const ErrorScreen({super.key, required this.error});

  bool get _isSecureStorageCorruption {
    final msg = error.toString().toLowerCase();
    // Tighten the heuristic: only treat the error as secure-storage corruption
    // when the actual platform-channel/keystore signatures show up. SQLCipher
    // database errors (which contain "sqlcipher"/"cipher") are NOT keystore
    // corruption and must not match here.
    return msg.contains('bad_decrypt') ||
        msg.contains('badpaddingexception') ||
        msg.contains('keystoreexception') ||
        (msg.contains('platformexception') && msg.contains('secure'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Something went wrong',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _isSecureStorageCorruption
                    ? 'Your device\'s secure storage was reset. '
                          'Please set up your wallet again using your recovery phrase.'
                    : error.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  final storage = ref.read(flutterSecureStorageProvider);
                  await storage.deleteAll();
                  // Also delete the SQLCipher DB file — otherwise the
                  // next bootstrap creates a fresh DEK that does NOT
                  // match the stale on-disk DB, and writes silently
                  // fail with "attempt to write a readonly database".
                  await LocalDatabase.closeAndDelete();
                  ref.invalidate(walletProvider);
                  ref.invalidate(keysProvider);
                  ref.invalidate(userProvider);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Reset & Start Fresh'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white.withValues(alpha: 0.9),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
