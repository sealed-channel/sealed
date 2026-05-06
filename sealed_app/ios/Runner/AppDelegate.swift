import Flutter
import UIKit
import UserNotifications

// Post-Task 2.5/2.6 AppDelegate.
//
// - Firebase / FCM imports removed: production does not bundle the FCM SDK
//   (see plan §D3a). APNs is used directly for silent wake-ups only.
// - The silent-push handler reads ONLY the `n` wake-up nonce field from the
//   payload; every other field (`alert`, `message_id`, `conversation_wallet`,
//   `account_pubkey`, …) is ignored. The visible notification that the app
//   may later render is constructed on the Dart side from a hard-coded
//   constant (`NotificationService.kGenericNotificationBody`) — no
//   payload-supplied string is ever rendered to the user.
// - TODO(2.6-followup): forward the nonce over a MethodChannel into
//   `NotificationService.handleSilentPush` so the Dart-side Tor-only
//   bounded-sync path runs. For now the handler calls the completion with
//   `.noData` to preserve background-wake budget.

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register only for silent remote notifications. Alert/badge/sound
    // permission is requested on-demand from the Dart side via
    // flutter_local_notifications.
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Plugin registration runs once the implicit Flutter engine is up.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Wire the APNs-token method channel as soon as the engine is up. Dart
    // calls `getApnsToken` and gets back the cached hex token, or nil if APNs
    // hasn't completed registration yet. `getLastApnsError` returns the last
    // `didFailToRegister...` error string, or nil. No payload data crosses
    // this boundary other than the token bytes and an error message.
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "ApnsTokenChannel")?
      .messenger()
    {
      let channel = FlutterMethodChannel(
        name: AppDelegate.apnsTokenChannelName,
        binaryMessenger: messenger
      )
      channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "getApnsToken":
          result(AppDelegate.cachedApnsToken)
        case "getLastApnsError":
          result(AppDelegate.lastApnsRegistrationError)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private static let apnsTokenChannelName = "sealed/apns_token"

  // APNs delivers the opaque device token here. We hex-encode it and cache
  // it for retrieval by the Dart side over the `sealed/apns_token` method
  // channel. The Dart side calls `getApnsToken` from `IndexerService` to
  // register the device with the Tor indexer under a blinded view-key hash.
  // Firebase / FCM is intentionally NOT in this path on iOS.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(
      application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    AppDelegate.cachedApnsToken = hex
    AppDelegate.lastApnsRegistrationError = nil
    NSLog("[AppDelegate] APNs token registered (len=\(hex.count))")
    #if DEBUG
      // Full token printed in DEBUG builds only — used to copy/paste into the
      // backend test script `sealed-tor-indexer/scripts/send_apns_test.ts`.
      // NEVER prints in Release / TestFlight builds.
      NSLog("[AppDelegate] APNS_TOKEN_DEBUG=\(hex)")
    #endif
  }

  // Surface registration failures so the Dart side can distinguish
  // "not yet registered" from "registration permanently failed".
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(
      application, didFailToRegisterForRemoteNotificationsWithError: error)
    AppDelegate.lastApnsRegistrationError = error.localizedDescription
    NSLog("[AppDelegate] APNs registration failed: \(error.localizedDescription)")
  }

  // Cached token + last error. Static because the AppDelegate instance is
  // a singleton and the channel handler closure must reach them.
  fileprivate static var cachedApnsToken: String?
  fileprivate static var lastApnsRegistrationError: String?

  // Silent push handler. Reads ONLY the wake-up nonce `n` and ignores every
  // other field. See plan §D3b and Task 2.6.
  //
  // Bridges to Dart over a single MethodChannel. Contract (mirrored in
  // `lib/services/notification_service.dart`):
  //
  //   Channel  : 'sealed/silent_push'
  //   Method   : 'handleSilentPush'
  //   Argument : the wake-up nonce String, or nil. NOTHING ELSE crosses the
  //              boundary — no userInfo, no aps dict, no alert, no
  //              message_id. This is the load-bearing privacy invariant.
  //   Response : a String — one of 'newData' | 'noData' | 'failed'. Mapped
  //              onto UIBackgroundFetchResult here.
  //
  // The Dart future is bounded by `silentPushTimeoutSeconds` so a stuck
  // sync can never starve the iOS 30 s wake budget.
  private static let silentPushChannelName = "sealed/silent_push"
  private static let silentPushMethodName = "handleSilentPush"
  private static let silentPushTimeoutSeconds: Double = 25.0

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Deliberately read only `n`. Any other field (including a malicious
    // `alert`, `message_id`, `conversation_wallet`, `account_pubkey`) is
    // never consulted here and never reaches the UI.
    let nonce = userInfo["n"] as? String

    guard let controller = window?.rootViewController as? FlutterViewController
    else {
      // Flutter engine not yet attached — forfeit this wake budget and
      // wait for the next push. No clearnet fallback path exists.
      completionHandler(.noData)
      return
    }

    let channel = FlutterMethodChannel(
      name: AppDelegate.silentPushChannelName,
      binaryMessenger: controller.binaryMessenger
    )

    // Ensure the completion handler fires exactly once even if the timeout
    // and the Dart response race.
    var didComplete = false
    let completeOnce: (UIBackgroundFetchResult) -> Void = { result in
      if didComplete { return }
      didComplete = true
      completionHandler(result)
    }

    // Hard timeout — Dart can't pin the wake budget. Mirrors the silent-push
    // budget guidance in `notification_service.dart`'s contract block.
    let timeoutItem = DispatchWorkItem {
      completeOnce(.failed)
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + AppDelegate.silentPushTimeoutSeconds,
      execute: timeoutItem
    )

    channel.invokeMethod(AppDelegate.silentPushMethodName, arguments: nonce) {
      response in
      timeoutItem.cancel()

      // Map Dart enum string back to UIBackgroundFetchResult. Any unexpected
      // shape is treated as `.failed` — never silently coerced to success.
      let result: UIBackgroundFetchResult
      switch response as? String {
      case "newData":
        result = .newData
      case "noData":
        result = .noData
      default:
        // Includes "failed", FlutterError, FlutterMethodNotImplemented, nil,
        // or any non-string return.
        result = .failed
      }
      completeOnce(result)
    }
  }
}
