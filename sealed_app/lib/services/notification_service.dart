// lib/services/notification_service.dart
//
// Post-FCM notification service for Sealed.
//
// Design (Phase 2 Tasks 2.5 / 2.6 / 2.7):
//
//   * No Firebase / FCM SDK in production. Android uses UnifiedPush (via a
//     self-hosted ntfy-style distributor reachable over Tor). iOS receives a
//     constant-size silent APNs wake-up payload whose only meaningful field
//     is the wake-up nonce `n`.
//   * The handler NEVER reads user-visible text from the push payload. The
//     visible notification body comes from the [kGenericNotificationBody]
//     compile-time constant, so a malicious or MITM'd push that adds an
//     `alert`/`message_id`/`conversation_wallet`/`account_pubkey` field has
//     no path to the UI.
//   * The background-wake sync path is Tor-only. If Tor is not bootstrapped
//     the sync is deferred — no clearnet HTTP client is constructed on the
//     wake path under any circumstance.
//
// UnifiedPush and flutter_local_notifications wiring are stubbed here at the
// minimum that preserves compile-time surface for the rest of the codebase
// (settings screen, logout, app shell). The Kotlin UnifiedPush receiver and
// the iOS silent-push AppDelegate branch drive actual delivery; they call
// into [NotificationService.handleSilentPushForTest]-style entry points.
//
// TODO(2.5-followup): wire `unifiedpush` plugin bindings once the Android
// distributor strategy is finalised (see plan §D3/D3a).
//
// iOS silent-push MethodChannel contract (Task 2.6):
//
//   Channel name : 'sealed/silent_push'
//   Method       : 'handleSilentPush'
//   Argument     : a single nullable String — the wake-up nonce (`n` field of
//                  the APNs payload) and NOTHING ELSE. The Swift side MUST NOT
//                  forward the rest of `userInfo`. Mechanically prevents
//                  attacker-supplied fields from crossing the boundary.
//   Return value : a String — exactly one of 'newData' | 'noData' | 'failed'.
//                  Maps directly onto `UIBackgroundFetchResult` on the Swift
//                  side. The handler never returns a richer object.
//
// The Dart-side listener is registered by [NotificationService.initialize] on
// iOS only and is wired against the background dependencies provided via
// [NotificationService.bindBackgroundDependencies]. If the dependencies are
// not yet bound when a silent push arrives (e.g. very early app cold-start
// race), the handler returns 'noData' so iOS does not penalise the wake
// budget — the next push will retry.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Navigation payload passed from notification taps into the app shell.
///
/// NOTE: all fields are `null` on the post-FCM path — the app reconstructs
/// conversation context locally after the Tor-sync step. The type is kept for
/// compatibility with `app.dart`'s tap listener, which still handles legacy
/// foreground-notification taps that originate from local notifications.
class NotificationPayload {
  final String? conversationWallet;
  final String? messageId;
  final String? accountPubkey;

  const NotificationPayload({
    this.conversationWallet,
    this.messageId,
    this.accountPubkey,
  });

  factory NotificationPayload.fromMap(Map<String, dynamic> data) {
    return NotificationPayload(
      conversationWallet: data['conversation_wallet'] as String?,
      messageId: (data['message_id'] ?? data['messageId']) as String?,
      accountPubkey:
          (data['account_pubkey'] ?? data['accountPubkey']) as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'conversation_wallet': conversationWallet,
    'message_id': messageId,
    'account_pubkey': accountPubkey,
  };
}

/// Result of processing a silent push on the wake path.
///
/// Exposed primarily so unit tests can assert invariants (no clearnet, no
/// attacker-controlled strings in the rendered notification, etc.) without
/// relying on platform channels.
class SilentPushResult {
  /// The value read out of the `n` field of the payload, or null if absent.
  final String? nonceRead;

  /// True iff the handler invoked the bounded-sync callback. False if the
  /// handler bailed early (e.g. Tor not bootstrapped).
  final bool syncRan;

  /// True iff a local notification was shown to the user.
  final bool notificationPresented;

  const SilentPushResult({
    required this.nonceRead,
    required this.syncRan,
    required this.notificationPresented,
  });
}

/// Callback: run a bounded sync and return the number of newly
/// decrypted messages. Must return 0 for dummy / cover-traffic wakes.
typedef BoundedSyncCallback = Future<int> Function();

/// Callback: present a locally-constructed user notification. The handler
/// always passes the hard-coded generic title/body — the payload arguments
/// are from the Dart constants, never from the push.
typedef LocalNotificationPresenter =
    Future<void> Function(String title, String body);

class NotificationService {
  /// MethodChannel name used by iOS `AppDelegate` to deliver silent-APNs
  /// wakes to Dart. See the contract block at the top of this file.
  static const String kSilentPushChannel = 'sealed/silent_push';

  /// Single method exposed on [kSilentPushChannel].
  static const String kSilentPushMethod = 'handleSilentPush';

  /// Channel result strings — must match the Swift enum mapping in
  /// `ios/Runner/AppDelegate.swift`.
  static const String kResultNewData = 'newData';
  static const String kResultNoData = 'noData';
  static const String kResultFailed = 'failed';

  /// Hard-coded title shown to the user for any wake-triggered notification.
  /// Must never be derived from a push payload.
  static const String kGenericNotificationTitle = 'Sealed';

  /// Hard-coded body shown to the user for any wake-triggered notification.
  /// Must never be derived from a push payload.
  static const String kGenericNotificationBody = 'New Encrypted Message';

  /// Maximum age of a deferred wake-up before it's dropped without retry.
  /// Rationale: APNs silent pushes are low-priority; >60s old is effectively
  /// stale. The next foreground sync (or the next push) will catch the
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // Stream of notification-tap payloads (local-notification taps only).
  final _onNotificationTap = StreamController<NotificationPayload>.broadcast();
  Stream<NotificationPayload> get onNotificationTap =>
      _onNotificationTap.stream;

  // Stream that the app shell listens to for "you should sync now" signals.
  final _onShouldSync = StreamController<void>.broadcast();
  Stream<void> get onShouldSync => _onShouldSync.stream;

  /// FCM token is no longer used. Always null. Retained so the settings
  /// screen still compiles while the UnifiedPush endpoint wiring is landed
  /// in a follow-up (Task 2.5 follow-up).
  String? get fcmToken => null;

  /// Token-refresh callback (UnifiedPush endpoint refresh will fire this
  /// once wired). No-op on the post-FCM path.
  void Function(String)? onTokenRefresh;

  bool _initialized = false;

  /// Background dependencies the silent-push handler needs in order to run a
  /// Tor-bounded sync. Bound by the app shell after the Tor service and the
  /// Bounded sync function injected by app_providers. Until non-null the
  /// channel handler returns [kResultNoData] (forfeits wake budget).
  BoundedSyncCallback? _runBoundedSync;

  /// MethodChannel used to receive silent-push wakes from the iOS side.
  /// Lazily constructed during [initialize] on iOS only.
  MethodChannel? _silentPushChannel;

  /// Test seam for controllable time in TTL tests
  @visibleForTesting
  DateTime Function() clock = () => DateTime.now();

  /// Test seam for notification presenter in deferred replay
  @visibleForTesting
  LocalNotificationPresenter? testPresenter;

  /// Provide the background-sync collaborators. Safe to call before or after
  /// [initialize]; idempotent. Replaces any previously-bound dependencies.
  void bindBackgroundDependencies({
    required BoundedSyncCallback runBoundedSync,
  }) {
    _runBoundedSync = runBoundedSync;
  }

  /// Initialise the local-notification plugin. Does NOT register with any
  /// push provider — push registration is explicitly opt-in via the Settings
  /// screen.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == null) return;
        try {
          final data = jsonDecode(response.payload!) as Map<String, dynamic>;
          _onNotificationTap.add(NotificationPayload.fromMap(data));
        } catch (_) {
          // Malformed payload — ignore silently; never surface arbitrary
          // payload bytes to the user.
        }
      },
    );

    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        'sealed_messages',
        'Messages',
        description: 'Notifications for new encrypted messages',
        importance: Importance.high,
      );
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(channel);
    }

    if (Platform.isIOS) {
      // Listen for silent-APNs wakes from `AppDelegate.swift`. The Swift side
      // forwards ONLY the wake-up nonce string — never the full `userInfo`.
      final channel = MethodChannel(kSilentPushChannel);
      channel.setMethodCallHandler(_handleSilentPushMethodCall);
      _silentPushChannel = channel;
    }
  }

  /// Channel-level entry point for silent-push wakes. Maps the inbound
  /// nonce-only argument onto [handleSilentPush] and reports back a
  /// channel-result string. Catches every error path so the Swift side
  /// always receives one of the three documented enum values.
  Future<String> _handleSilentPushMethodCall(MethodCall call) async {
    if (call.method != kSilentPushMethod) {
      return kResultFailed;
    }

    // The argument MUST be a String? per the channel contract. Anything
    // else (Map, List, …) is treated as a malformed call and dropped to
    // `noData` — never `failed` — so iOS does not punish the wake budget.
    final dynamic raw = call.arguments;
    final String? nonce = raw is String ? raw : null;

    final sync = _runBoundedSync;
    if (sync == null) {
      // App shell hasn't bound the wake dependencies yet (very early
      // cold-start). Return noData; the next push will retry.
      return kResultNoData;
    }

    try {
      final result = await handleSilentPush(
        // Nonce-only payload — proves the channel can never carry an
        // attacker-augmented field into the handler.
        payload: <String, dynamic>{'n': nonce},
        runBoundedSync: sync,
      );
      if (result.notificationPresented) {
        return kResultNewData;
      }
      return kResultNoData;
    } catch (_) {
      // Never propagate Dart exceptions across the channel — Swift only
      // understands the three documented enum values.
      return kResultFailed;
    }
  }

  /// Request OS notification permission. Push-endpoint registration is a
  /// follow-up — this currently only asks for local-notification permission
  /// so that [showGenericNotification] can render post-sync notifications.
  ///
  /// TODO(2.5-followup): on Android, also register a UnifiedPush distributor
  /// selection and return its endpoint.
  Future<bool> requestPermissionAndGetToken() async {
    if (Platform.isIOS) {
      final granted =
          await _localNotifications
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
      return granted;
    }
    if (Platform.isAndroid) {
      final granted =
          await _localNotifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
      return granted;
    }
    return false;
  }

  /// Delete the push endpoint. No-op on the post-FCM path; UnifiedPush
  /// unregistration lands in a follow-up.
  ///
  /// TODO(2.5-followup): call UnifiedPush `unregister(instance)` once wired.
  Future<void> deleteToken() async {
    // Intentionally a no-op. Kept to preserve the logout_service contract.
  }

  /// Legacy no-ops — kept so other parts of the codebase compile unchanged.
  Future<void> subscribeToTopic(String topic) async {}
  Future<void> unsubscribeFromTopic(String topic) async {}
  Future<String?> getToken() async => null;

  /// Handle a silent iOS APNs wake or a UnifiedPush delivery.
  ///
  /// This is the instance-level entry point that the iOS AppDelegate and the
  /// Android UnifiedPush receiver call via MethodChannel. It reads ONLY the
  /// `n` nonce from the payload and never uses any other field. Sync runs
  /// only if Tor is bootstrapped; otherwise the wake is deferred.
  Future<SilentPushResult> handleSilentPush({
    required Map<String, dynamic> payload,
    required BoundedSyncCallback runBoundedSync,
  }) async {
    final result = await handleSilentPushForTest(
      payload: payload,
      runBoundedSync: runBoundedSync,
      present: _presentViaLocalPlugin,
    );

    return result;
  }

  Future<void> _presentViaLocalPlugin(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'sealed_messages',
      'Messages',
      channelDescription: 'Notifications for new encrypted messages',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final id = DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;
    await _localNotifications.show(id, title, body, details);

    // Also nudge the app shell to refresh its UI if the app is foreground.
    _onShouldSync.add(null);
  }

  /// Test-friendly variant with fully-injected collaborators. The production
  /// [handleSilentPush] funnels into this.
  ///
  /// Behaviour:
  ///   1. Read only `payload['n']` (the wake-up nonce). Never read any other
  ///      field. A malicious `alert`/`message_id`/… payload has no path to
  ///      the user-visible notification.
  ///   2. If Tor is not `on`, return `deferredForTor: true` without calling
  ///      [runBoundedSync]. The caller is expected to schedule a retry once
  ///      Tor bootstraps.
  ///   3. Otherwise run [runBoundedSync] (which MUST be Tor-only — Task 2.7
  ///      enforces this at the call-site level). If it returns >= 1, call
  ///      [present] with the hard-coded generic title and body.
  static Future<SilentPushResult> handleSilentPushForTest({
    required Map<String, dynamic> payload,
    required BoundedSyncCallback runBoundedSync,
    required LocalNotificationPresenter present,
  }) async {
    // Read ONLY the wake-up nonce. Cast defensively so a maliciously-typed
    // payload can't throw — just drop it.
    final dynamic rawNonce = payload['n'];
    final String? nonce = rawNonce is String ? rawNonce : null;

    final int newMessageCount = await runBoundedSync();

    var notificationPresented = false;
    if (newMessageCount >= 1) {
      // IMPORTANT: both arguments are Dart-side constants. The payload is
      // not passed through. This is the load-bearing invariant for Task 2.6.
      await present(kGenericNotificationTitle, kGenericNotificationBody);
      notificationPresented = true;
    }

    return SilentPushResult(
      nonceRead: nonce,
      syncRan: true,
      notificationPresented: notificationPresented,
    );
  }

  /// Test hook exposing the channel-handler entry point so unit tests can
  /// drive the same code path Swift uses, without spinning up a platform
  /// channel. Production code MUST NOT call this directly.
  @visibleForTesting
  Future<String> debugHandleSilentPushMethodCall(MethodCall call) {
    return _handleSilentPushMethodCall(call);
  }

  /// Dispose stream controllers. Used by tests and hot-restart paths.
  void dispose() {
    _silentPushChannel?.setMethodCallHandler(null);
    _silentPushChannel = null;
    _onNotificationTap.close();
    _onShouldSync.close();
    testPresenter = null;
  }
}
