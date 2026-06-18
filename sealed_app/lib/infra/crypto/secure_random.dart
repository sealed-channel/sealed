import 'dart:math';
import 'dart:typed_data';

/// Process-wide CSPRNG. `Random.secure()` draws from the OS entropy source
/// (`getrandom`/`/dev/urandom` on Linux+Android, `SecRandomCopyBytes` on
/// Apple, `BCryptGenRandom` on Windows), so a single shared instance is both
/// correct and avoids re-seeding a fresh generator on every draw.
final Random _secureRng = Random.secure();

/// Cryptographically-secure random bytes.
///
/// Canonical Dart pattern: there is no stdlib bulk-fill, so bytes are drawn
/// one at a time via `nextInt(256)` (uniform over 0..255). This is the single
/// source of truth — do **not** hand-roll `List.generate(n, (_) =>
/// Random.secure().nextInt(256))` at call sites; that re-seeds a new generator
/// per byte and scatters the same loop across the codebase.
Uint8List secureRandomBytes(int n) {
  final bytes = Uint8List(n);
  for (var i = 0; i < n; i++) {
    bytes[i] = _secureRng.nextInt(256);
  }
  return bytes;
}
