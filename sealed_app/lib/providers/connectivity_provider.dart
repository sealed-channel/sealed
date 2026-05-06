import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides a live stream of whether the device has internet connectivity.
/// Emits `true` when online, `false` when offline.
final connectivityStatusProvider = StreamProvider<bool>((ref) {
  final connectivity = Connectivity();

  // Controller to merge initial check + ongoing stream
  final controller = StreamController<bool>();

  // Check initial state
  connectivity.checkConnectivity().then((results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    controller.add(online);
  });

  // Listen for changes
  final subscription = connectivity.onConnectivityChanged.listen((results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    controller.add(online);
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});
