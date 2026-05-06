import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/app.dart';
import 'package:sealed_app/services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase init for Android FCM push delivery (UnifiedPush is deprecated).
  // iOS continues to use APNs; Firebase is benign on iOS without an APNs cert.
  await Firebase.initializeApp();

  // ignore: discarded_futures
  NotificationService().initialize();

  runApp(const ProviderScope(child: SealedApp()));
}
