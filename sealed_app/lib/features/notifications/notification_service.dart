// lib/services/notification_service.dart
//
// Push notification service for Sealed.
//
// Platform delivery:
//   Android — FCM (firebase_messaging). Foreground messages are handled via
//             FirebaseMessaging.onMessage in main.dart → handleFcmMessage.
//             Background messages arrive via the top-level
//             _firebaseBackgroundHandler in main.dart → WakeNonceQueue → drain
//             on next foreground resume.
//   iOS     — APNs silent push only. AppDelegate.swift forwards ONLY the
//             wake-up nonce `n` over the `sealed/silent_push` MethodChannel →
//             handleSilentPush → bounded sync.
//
// Privacy invariant (both platforms):
//   The handler NEVER reads user-visible text from the push payload. The
//   visible notification body is the [kGenericNotificationBody] compile-time
//   constant. A malicious or MITM'd push that adds an `alert`/`message_id`/
//   `conversation_wallet`/`account_pubkey` field has no path to the UI.
//
// iOS silent-push MethodChannel contract:
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
// The Dart-side iOS listener is registered by [NotificationService.initialize]
// and wired against the background dependencies provided via
// [NotificationService.bindBackgroundDependencies]. If the dependencies are
// not yet bound when a silent push arrives (e.g. very early app cold-start
// race), the handler returns 'noData' so iOS does not penalise the wake
// budget — the next push will retry.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
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
      settings: initSettings,
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

  /// Request OS notification permission.
  ///
  /// On Android this grants the POST_NOTIFICATIONS permission (required on
  /// API 33+). On iOS it requests alert/badge/sound via flutter_local_notifications.
  /// Push-token registration (FCM / APNs) is a separate opt-in via Settings.
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

  /// Deregister from push delivery.
  ///
  /// On Android, deletes the FCM registration token so the indexer can no
  /// longer target this device. On iOS, APNs token is device-managed; no
  /// Dart-side unregistration is needed — the indexer handles token expiry.
  Future<void> deleteToken() async {
    if (Platform.isAndroid) {
      await FirebaseMessaging.instance.deleteToken();
    }
    // iOS: no-op — APNs token lifecycle is managed by the OS.
  }

  /// Handle a silent iOS APNs wake.
  ///
  /// Instance-level entry point called by the iOS MethodChannel handler.
  /// Reads ONLY the `n` nonce; never uses any other payload field.
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

  /// Android FCM entry point for foreground and background-wakeup messages.
  ///
  /// Reads ONLY [RemoteMessage.data]`['n']` (the wake-up nonce). Every other
  /// field — including [RemoteMessage.notification], `message_id`,
  /// `conversation_wallet`, and `account_pubkey` — is intentionally ignored.
  /// This is the load-bearing privacy invariant: no attacker-supplied string
  /// can reach the UI through this path.
  ///
  /// On Android the visible notification is rendered by the FCM SDK from the
  /// `notification` block in the server payload — the app itself never passes
  /// payload text to the OS notification API. We drive only the bounded sync.
  ///
  /// If [_runBoundedSync] has not been bound yet (e.g. very early cold-start
  /// race), the call is a no-op — the next foreground open will catch up.
  Future<void> handleFcmMessage(RemoteMessage msg) async {
    final sync = _runBoundedSync;
    if (sync == null) {
      debugPrint(
        '[NotificationService] handleFcmMessage: deps not bound, skip',
      );
      return;
    }

    // Read ONLY the nonce. Never touch msg.notification or other data fields.
    final dynamic rawNonce = msg.data['n'];
    final String? nonce = rawNonce is String ? rawNonce : null;

    debugPrint('[NotificationService] handleFcmMessage n=$nonce');

    // Reuse the same bounded-sync plumbing as the iOS silent-push path.
    // Pass nonce-only payload — proves no other field crosses into the handler.
    // Use handleSilentPushForTest so the testPresenter seam is honoured in
    // tests; production code passes _presentViaLocalPlugin as the default.
    await handleSilentPushForTest(
      payload: <String, dynamic>{'n': nonce},
      runBoundedSync: sync,
      present: testPresenter ?? _presentViaLocalPlugin,
    );
  }

  /// Post the generic local notification from the FCM background isolate (the
  /// data-only path, after BackgroundWakeSync stages ≥1 non-blocked message).
  /// Initializes the plugin first (cold isolate) and uses constant text only.
  Future<void> presentGenericNotification() async {
    await initialize();
    await _presentViaLocalPlugin(
      kGenericNotificationTitle,
      kGenericNotificationBody,
    );
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
    await _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );

    // Also nudge the app shell to refresh its UI if the app is foreground.
    _onShouldSync.add(null);
  }

  /// Test-friendly variant with fully-injected collaborators. The production
  /// [handleSilentPush] and [handleFcmMessage] both funnel into this.
  ///
  /// Behaviour:
  ///   1. Read only `payload['n']` (the wake-up nonce). Never read any other
  ///      field. A malicious `alert`/`message_id`/… payload has no path to
  ///      the user-visible notification.
  ///   2. Run [runBoundedSync]. If it returns >= 1, call [present] with the
  ///      hard-coded generic title and body constants.
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
