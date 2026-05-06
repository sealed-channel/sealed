import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/chain/chain_client.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/services/user_service.dart';

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
      'UserState(phase: $phase, profile: ${profile?.username ?? profile?.owner}, error: $error)';
}

// ============================================================================
// USER NOTIFIER
// ============================================================================

class UserNotifier extends AsyncNotifier<UserState> {
  late UserService _userService;
  late ChainClient _chainClient;

  @override
  Future<UserState> build() async {
    print('🔵 UserNotifier.build() STARTED');

    // Wait for user service to be ready
    print('🔵 UserNotifier: Waiting for userServiceProvider...');
    _userService = await ref.watch(userServiceProvider.future);
    print('🔵 UserNotifier: userServiceProvider ready');

    print('🔵 UserNotifier: Waiting for chainClientProvider...');
    _chainClient = await ref.watch(chainClientProvider.future);
    print('🔵 UserNotifier: chainClientProvider ready');

    // No wallet = no user
    final walletAddress = _chainClient.activeWalletAddress;
    if (walletAddress == null) {
      print('🔵 UserNotifier: No wallet address, skipping auto-login');
      return const UserState(phase: UserPhase.idle);
    }

    // Set loading state while we attempt auto-login
    state = const AsyncData(UserState(phase: UserPhase.loading));

    // Try to restore session from cache first
    final restored = await _userService.restoreSession();

    if (restored && _userService.currentUser != null) {
      print(
        '🔵 UserNotifier: Session restored: ${_userService.currentUser?.username ?? _userService.currentUser?.owner}',
      );
      return UserState(
        phase: UserPhase.ready,
        profile: _userService.currentUser,
      );
    }

    // Try wallet-first auto-login: derive keys then restore/create local wallet profile
    try {
      print(
        '🔵 UserNotifier: Attempting auto-login with wallet: $walletAddress...',
      );

      // Derive keys from local wallet
      await ref.read(keysProvider.notifier).deriveKeysFromLocalWallet();

      final walletReady = await _userService.restoreSession();
      if (walletReady && _userService.currentUser != null) {
        final profile = _userService.currentUser!;
        print('🔵 UserNotifier: Wallet-ready: ${profile.owner}');
        await ref.read(messagesNotifierProvider.notifier).syncMessages();
        return UserState(phase: UserPhase.ready, profile: profile);
      }
    } catch (e) {
      print('🔵 UserNotifier: Auto-login failed: $e');
    }

    print('🔵 UserNotifier: No existing user session, idle');
    return const UserState(phase: UserPhase.idle);
  }

  Future<UserProfile> setUsername({required String username}) async {
    final currentState = state.value ?? const UserState(phase: UserPhase.idle);

    // Set updating state
    state = AsyncData(
      currentState.copyWith(phase: UserPhase.updatingUsername, error: null),
    );

    try {
      print('🔵 UserNotifier: Setting username: $username ');
      final profile = await _userService.setUsername(username: username);

      state = AsyncData(UserState(phase: UserPhase.ready, profile: profile));

      print('🔵 UserNotifier: Username updated: ${profile.username}');
      return profile;
    } catch (e) {
      state = AsyncData(UserState(phase: UserPhase.idle, error: e.toString()));
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
      print(
        '🔵 UserNotifier: Auto-logged in: ${profile.username ?? profile.owner}',
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

final searchUsersProvider = FutureProvider.family<List<UserProfile>, String>((
  ref,
  query,
) async {
  if (query.trim().isEmpty) return [];
  final userService = await ref.watch(userServiceProvider.future);
  return userService.searchUsers(query.trim());
});

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
// USER LOOKUP (by username or wallet)
// ============================================================================

final userByUsernameProvider = FutureProvider.family<UserProfile?, String>((
  ref,
  username,
) async {
  final userService = await ref.watch(userServiceProvider.future);
  return userService.getUserByUsername(username);
});

final userByWalletProvider = FutureProvider.family<UserProfile?, String>((
  ref,
  walletAddress,
) async {
  final userService = await ref.watch(userServiceProvider.future);
  return userService.getUserByWallet(walletAddress);
});
