package com.kamryy.sealed

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 'sealed/screen_secure' — toggled by Dart ScreenCaptureGuard while a
        // SecureScreen (chat, alias handshake) is mounted. FLAG_SECURE blocks
        // screenshots and blanks recordings + the recents thumbnail.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sealed/screen_secure",
        ).setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                val secure = call.arguments as? Boolean ?: false
                runOnUiThread {
                    if (secure) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
