// lib/ui/shared/error_handler.dart
//
// UI-facing error presentation. Lives in ui/ (not core/) so that core/errors
// — the exception types imported across every feature — stays UI-blind and
// doesn't drag flutter/material + snackbars into the whole dependency graph.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// Centralized error handler with SnackBar display
class ErrorHandler {
  static final GlobalKey<ScaffoldMessengerState> scaffoldKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Show error SnackBar
  static void showError(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
    Duration duration = const Duration(seconds: 4),
  }) {
    showErrorSnackBar(context, message, duration: duration, onRetry: onRetry);
  }

  /// Show network error SnackBar
  static void showNetworkError(BuildContext context, {VoidCallback? onRetry}) {
    showWarningSnackBar(
      context,
      'Network error. Please check your connection.',
      onRetry: onRetry,
    );
  }

  /// Show send error with retry
  static void showSendError(
    BuildContext context,
    String message, {
    required VoidCallback onRetry,
  }) {
    showErrorSnackBar(context, message, onRetry: onRetry, retryLabel: 'RETRY');
  }

  /// Show sync error with retry
  static void showSyncError(
    BuildContext context, {
    required VoidCallback onRetry,
  }) {
    showWarningSnackBar(
      context,
      'Failed to sync messages',
      onRetry: onRetry,
      retryLabel: 'SYNC',
    );
  }

  /// Show registration error
  static void showRegistrationError(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
  }) {
    showErrorSnackBar(context, message, onRetry: onRetry);
  }

  /// Show success SnackBar
  static void showSuccess(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    showInfoSnackBar(context, message, duration: duration);
  }

  /// Show info SnackBar
  static void showInfo(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    showInfoSnackBar(context, message, duration: duration);
  }

  /// Handle any exception and show appropriate SnackBar
  static void handle(
    BuildContext context,
    dynamic error, {
    VoidCallback? onRetry,
  }) {
    if (error is NetworkException) {
      showNetworkError(context, onRetry: onRetry);
    } else if (error is RegistrationException) {
      showRegistrationError(
        context,
        error.message,
        onRetry: error.isRetryable ? onRetry : null,
      );
    } else if (error is SendMessageException) {
      if (onRetry != null && error.isRetryable) {
        showSendError(context, error.message, onRetry: onRetry);
      } else {
        showError(context, error.message);
      }
    } else if (error is SyncException) {
      showSyncError(context, onRetry: onRetry ?? () {});
    } else if (error is UserNotFoundException) {
      showError(context, error.message);
    } else if (error is SocketException ||
        error.toString().contains('SocketException') ||
        error.toString().contains('connection')) {
      showNetworkError(context, onRetry: onRetry);
    } else {
      showError(context, error.toString(), onRetry: onRetry);
    }
  }
}

extension ErrorHandlerExtension on BuildContext {
  void showError(String message, {VoidCallback? onRetry}) =>
      ErrorHandler.showError(this, message, onRetry: onRetry);

  void showNetworkError({VoidCallback? onRetry}) =>
      ErrorHandler.showNetworkError(this, onRetry: onRetry);

  void showSendError(String message, {required VoidCallback onRetry}) =>
      ErrorHandler.showSendError(this, message, onRetry: onRetry);

  void showSyncError({required VoidCallback onRetry}) =>
      ErrorHandler.showSyncError(this, onRetry: onRetry);

  void showRegistrationError(String message, {VoidCallback? onRetry}) =>
      ErrorHandler.showRegistrationError(this, message, onRetry: onRetry);

  void showSuccess(String message) => ErrorHandler.showSuccess(this, message);

  void showInfo(String message) => ErrorHandler.showInfo(this, message);

  void handleError(dynamic error, {VoidCallback? onRetry}) =>
      ErrorHandler.handle(this, error, onRetry: onRetry);
}
