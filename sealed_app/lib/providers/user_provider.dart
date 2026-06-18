import 'dart:async';
import 'package:sealed_app/core/log.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/identity/user_service.dart';
import 'package:sealed_app/features/identity/username_validator.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';

// ============================================================================
// USER SERVICE
// ============================================================================

final userServiceProvider = FutureProvider<UserService>((ref) async {
  Log.d('🔧 userServiceProvider: Starting...');
  final sealedClient = await ref.watch(sealedChainClientProvider.future);
  Log.d('🔧 userServiceProvider: sealedChainClient ready');
  final keyService = await ref.watch(keyServiceProvider.future);
  Log.d('🔧 userServiceProvider: keyService ready');

  return UserService(
    sealedClient: sealedClient,
    keyService: keyService,
    localUser: ref.watch(localUserRepositoryProvider),
    contacts: ref.watch(contactRepositoryProvider),
  );
});

// ============================================================================
// USER STATE
// ============================================================================

enum UserPhase { idle, loading, ready, updatingUsername }

class UserState {
  final UserPhase phase;
  final UserProfile? profile;
  final String? error;

  const UserState({this.phase = UserPhase.loading, this.profile, this.error});

  /// Derived: true when user can use app
  bool get isReady => phase == UserPhase.ready && profile != null;

  /// Derived: true while username update is pending
  bool get isUpdatingUsername => phase == UserPhase.updatingUsername;

  /// Derived: true during any loading operation
  bool get isLoading =>
      phase == UserPhase.loading || phase == UserPhase.updatingUsername;

  UserState copyWith({UserPhase? phase, UserProfile? profile, String? error}) {
    return UserState(
      phase: phase ?? this.phase,
      profile: profile ?? this.profile,
      error: error,
    );
  }

  @override
  String toString() =>
      'UserState(phase: $phase, profile: ${profile?.username ?? profile?.walletAddress}, error: $error)';
}

// ============================================================================
// USER NOTIFIER
// ============================================================================

class UserNotifier extends AsyncNotifier<UserState> {
  late UserService _userService;
  late SealedChainClient _chainClient;

  @override
  Future<UserState> build() async {
    Log.d('🔵 UserNotifier.build() STARTED');

    // Wait for user service to be ready
    Log.d('🔵 UserNotifier: Waiting for userServiceProvider...');
    _userService = await ref.watch(userServiceProvider.future);
    Log.d('🔵 UserNotifier: userServiceProvider ready');

    Log.d('🔵 UserNotifier: Waiting for sealedChainClientProvider...');
    _chainClient = await ref.watch(sealedChainClientProvider.future);
    Log.d('🔵 UserNotifier: sealedChainClientProvider ready');

    // No wallet = no user
    final walletAddress = _chainClient.wallet.walletAddress;
    if (walletAddress == null) {
      Log.d('🔵 UserNotifier: No wallet address, skipping auto-login');
      return const UserState(phase: UserPhase.idle);
    }

    // Set loading state while we attempt auto-login
    state = const AsyncData(UserState(phase: UserPhase.loading));

    // Try to restore session from cache first
    final restored = await _userService.restoreSession();

    if (restored && _userService.currentUser != null) {
      Log.d(
        '🔵 UserNotifier: Session restored: ${_userService.currentUser?.username ?? _userService.currentUser?.walletAddress}',
      );
      // T1 PROBE
      // ignore: avoid_print
      Log.d(
        '[UserNotifier.build] FIRST restore returning ready, '
        'profile.username=${_userService.currentUser?.username}',
      );
      return UserState(
        phase: UserPhase.ready,
        profile: _userService.currentUser,
      );
    }

    // Try wallet-first auto-login: derive keys then restore/create local wallet profile
    try {
      Log.d(
        '🔵 UserNotifier: Attempting auto-login with wallet: $walletAddress...',
      );

      // Derive keys from local wallet
      await ref.read(keysProvider.notifier).deriveKeysFromLocalWallet();

      final walletReady = await _userService.restoreSession();
      if (walletReady && _userService.currentUser != null) {
        final profile = _userService.currentUser!;
        Log.d('🔵 UserNotifier: Wallet-ready: ${profile.walletAddress}');
        // T1 PROBE
        // ignore: avoid_print
        Log.d(
          '[UserNotifier.build] SECOND restore returning ready, '
          'profile.username=${profile.username}',
        );
        // Kick off the initial sync but do NOT block on it. Awaiting a full
        // network sync here delayed first paint of the chat list on every
        // launch; the list renders from cache and updates as messages arrive.
        unawaited(ref.read(messagesNotifierProvider.notifier).syncMessages());
        return UserState(phase: UserPhase.ready, profile: profile);
      }
    } catch (e) {
      Log.d('🔵 UserNotifier: Auto-login failed: $e');
    }

    Log.d('🔵 UserNotifier: No existing user session, idle');
    return const UserState(phase: UserPhase.idle);
  }

  Future<UserProfile> setUsername({required String username}) async {
    final currentState = state.value ?? const UserState(phase: UserPhase.idle);

    // Set updating state
    state = AsyncData(
      currentState.copyWith(phase: UserPhase.updatingUsername, error: null),
    );

    try {
      Log.d('🔵 UserNotifier: Setting username: $username ');
      final profile = await _userService.setUsername(username: username);

      state = AsyncData(UserState(phase: UserPhase.ready, profile: profile));

      // Claiming a username spends 1 credit on-chain; refresh the balance the
      // settings UI watches so it ticks down immediately instead of next poll.
      ref.invalidate(creditsBalanceProvider);

      // The chat list + open-thread header cache display names; bump the message
      // refresh counter so they re-resolve the new nickname without a restart.
      ref.read(messagesNotifierProvider.notifier).bumpRefresh();

      Log.d('🔵 UserNotifier: Username updated: ${profile.username}');
      return profile;
    } catch (e) {
      state = AsyncData(UserState(phase: UserPhase.idle, error: e.toString()));
      rethrow;
    }
  }

  /// Set or clear (empty string) the on-chain profile bio. Costs 1 credit.
  Future<UserProfile> setBio({required String bio}) async {
    final currentState = state.value ?? const UserState(phase: UserPhase.idle);

    state = AsyncData(
      currentState.copyWith(phase: UserPhase.updatingUsername, error: null),
    );

    try {
      final profile = await _userService.setBio(bio: bio);
      state = AsyncData(UserState(phase: UserPhase.ready, profile: profile));

      // Setting a bio spends 1 credit on-chain; refresh the watched balance.
      ref.invalidate(creditsBalanceProvider);

      return profile;
    } catch (e) {
      state = AsyncData(
        currentState.copyWith(phase: UserPhase.ready, error: e.toString()),
      );
      rethrow;
    }
  }

  /// Logout - clear user state
  Future<void> logout() async {
    await _userService.logout();
    state = const AsyncData(UserState(phase: UserPhase.idle));
  }

  /// Login with an existing profile (for auto-login scenarios)
  Future<void> loginWithProfile(UserProfile profile) async {
    state = const AsyncData(UserState(phase: UserPhase.loading));

    try {
      await _userService.loginWithProfile(profile);
      state = AsyncData(UserState(phase: UserPhase.ready, profile: profile));
      Log.d(
        '🔵 UserNotifier: Auto-logged in: ${profile.username ?? profile.walletAddress}',
      );
    } catch (e) {
      state = AsyncData(UserState(phase: UserPhase.idle, error: e.toString()));
      rethrow;
    }
  }
}

// ============================================================================
// PROVIDERS
// ============================================================================

/// Main user provider using AsyncNotifier
final userProvider = AsyncNotifierProvider<UserNotifier, UserState>(
  UserNotifier.new,
);

/// Convenience: get current user profile (null if unavailable)
final currentUserProvider = Provider<UserProfile?>((ref) {
  final userState = ref.watch(userProvider);
  return userState.value?.profile;
});

/// Convenience: check if user is ready and has keys
final isUserReadyProvider = Provider<bool>((ref) {
  final userState = ref.watch(userProvider);
  final keys = ref.watch(currentKeysProvider);
  return (userState.value?.isReady ?? false) && keys != null;
});

// ============================================================================
// USERNAME AVAILABILITY
// ============================================================================
//
// State machine consumed by `UsernameField`:
//   - typing → validate format → debounce 300ms → SealedUsernameOps.isAvailable
//   - emits NameInvalid / NameAvailable / NameTaken / AvailabilityUnknown

// ---------------------------------------------------------------------------
// Result types (sealed)
// ---------------------------------------------------------------------------

sealed class AvailabilityResult {
  const AvailabilityResult();
}

class NameAvailable extends AvailabilityResult {
  const NameAvailable();
}

class NameTaken extends AvailabilityResult {
  const NameTaken({this.suggestions = const []});
  final List<String> suggestions;
}

class NameInvalid extends AvailabilityResult {
  const NameInvalid(this.code);
  final UsernameErrorCode code;
}

class AvailabilityUnknown extends AvailabilityResult {
  const AvailabilityUnknown();
}

// ---------------------------------------------------------------------------
// Controller state
// ---------------------------------------------------------------------------

class UsernameCheckState {
  const UsernameCheckState({
    this.input = '',
    this.isChecking = false,
    this.availabilityResult,
  });

  final String input;
  final bool isChecking;
  final AvailabilityResult? availabilityResult;

  UsernameCheckState copyWith({
    String? input,
    bool? isChecking,
    AvailabilityResult? availabilityResult,
    bool clearResult = false,
  }) {
    return UsernameCheckState(
      input: input ?? this.input,
      isChecking: isChecking ?? this.isChecking,
      availabilityResult: clearResult
          ? null
          : (availabilityResult ?? this.availabilityResult),
    );
  }
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class UsernameController extends AsyncNotifier<UsernameCheckState> {
  Timer? _debounce;
  int _seq = 0;

  static const Duration _debounceWindow = Duration(milliseconds: 300);

  @override
  Future<UsernameCheckState> build() async {
    ref.onDispose(() => _debounce?.cancel());
    return const UsernameCheckState();
  }

  /// Caller — TextField onChanged. Lowercased + trimmed expected.
  void onInputChanged(String raw) {
    final input = raw.trim().toLowerCase();
    _debounce?.cancel();

    if (input.isEmpty) {
      state = AsyncData(const UsernameCheckState());
      return;
    }

    // Synchronous format validation.
    final v = validateUsername(input);
    if (!v.isValid) {
      state = AsyncData(
        UsernameCheckState(
          input: input,
          isChecking: false,
          availabilityResult: NameInvalid(v.code!),
        ),
      );
      return;
    }

    // Valid format → show "checking" + schedule chain probe.
    state = AsyncData(UsernameCheckState(input: input, isChecking: true));
    final mySeq = ++_seq;
    _debounce = Timer(_debounceWindow, () => _probe(input, mySeq));
  }

  Future<void> _probe(String name, int seq) async {
    try {
      final ops = await ref.read(sealedUsernameOpsProvider.future);
      final selfWallet = ref.read(
        currentUserWalletProvider,
      ); // optional helper, null OK
      final available = await ops.isAvailable(name, selfWallet: selfWallet);
      if (seq != _seq) return; // stale — newer input in flight
      state = AsyncData(
        UsernameCheckState(
          input: name,
          isChecking: false,
          availabilityResult: available
              ? const NameAvailable()
              : NameTaken(suggestions: _suggestions(name)),
        ),
      );
    } catch (_) {
      if (seq != _seq) return;
      state = AsyncData(
        UsernameCheckState(
          input: name,
          isChecking: false,
          availabilityResult: const AvailabilityUnknown(),
        ),
      );
    }
  }

  List<String> _suggestions(String name) {
    // Cheap deterministic alternates — UI only, no chain check.
    return [
      '${name}_',
      '${name}1',
      '${name}2',
    ].where((s) => s.length <= kUsernameMaxLen).toList();
  }
}

final usernameControllerProvider =
    AsyncNotifierProvider<UsernameController, UsernameCheckState>(
      UsernameController.new,
    );

/// Convenience — current wallet address from SealedChainClient, or null.
final currentUserWalletProvider = Provider<String?>((ref) {
  final asyncClient = ref.watch(sealedChainClientProvider);
  return asyncClient.maybeWhen(
    data: (c) => c.wallet.walletAddress,
    orElse: () => null,
  );
});
