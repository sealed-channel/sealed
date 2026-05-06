// lib/core/errors.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sealed_app/shared/widgets/theme.dart';
import 'snackbars.dart';

// ============================================================================
// CUSTOM EXCEPTIONS
// ============================================================================

/// Base class for all Sealed app errors
abstract class SealedException implements Exception {
  final String message;
  final String? details;
  final bool isRetryable;

  const SealedException(this.message, {this.details, this.isRetryable = false});

  @override
  String toString() => message;
}

/// Network-related errors (no internet, timeout, etc.)
class NetworkException extends SealedException {
  const NetworkException([
    super.message = 'Network error. Please check your connection.',
  ]) : super(isRetryable: true);

  factory NetworkException.fromError(dynamic error) {
    if (error is SocketException) {
      return const NetworkException('No internet connection');
    }
    if (error.toString().contains('timeout')) {
      return const NetworkException('Request timed out. Please try again.');
    }
    if (error.toString().contains('connection refused')) {
      return const NetworkException(
        'Server unavailable. Please try again later.',
      );
    }
    return NetworkException(error.toString());
  }
}

/// Registration errors
class RegistrationException extends SealedException {
  const RegistrationException(super.message, {super.isRetryable = true});

  factory RegistrationException.fromError(dynamic error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('username') && msg.contains('taken')) {
      return const RegistrationException('Username is already taken');
    }
    if (msg.contains('insufficient')) {
      return const RegistrationException(
        'Insufficient SOL for registration',
        isRetryable: false,
      );
    }
    if (msg.contains('invalid username')) {
      return const RegistrationException(
        'Invalid username format',
        isRetryable: false,
      );
    }
    return RegistrationException('Registration failed: ${error.toString()}');
  }
}

/// Message send errors
class SendMessageException extends SealedException {
  const SendMessageException(super.message, {super.isRetryable = true});

  factory SendMessageException.fromError(dynamic error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('insufficient')) {
      return const SendMessageException(
        'Insufficient ALGO to send message',
        isRetryable: false,
      );
    }
    if (msg.contains('recipient not found') || msg.contains('user not found')) {
      return const SendMessageException(
        'Recipient not found',
        isRetryable: false,
      );
    }
    if (msg.contains('encryption')) {
      return const SendMessageException('Encryption failed', isRetryable: true);
    }
    return SendMessageException('Failed to send message');
  }
}

/// Sync errors
class SyncException extends SealedException {
  const SyncException([super.message = 'Failed to sync messages'])
    : super(isRetryable: true);
}

/// User lookup errors
class UserNotFoundException extends SealedException {
  const UserNotFoundException([super.message = 'User not found'])
    : super(isRetryable: false);
}

// ============================================================================
// ERROR HANDLER UTILITY
// ============================================================================

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

  static Future<void> showInsufficientBalanceDialog(
    BuildContext context, {
    required VoidCallback onTopUp,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Insufficient Balance',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          content: const Text(
            'You need ALGO to send messages. Please top up your wallet and try again.',
            style: TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onTopUp();
              },
              child: const Text(
                'Top Up',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
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

// ============================================================================
// EXTENSION FOR EASY ACCESS
// ============================================================================

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

  Future<void> showInsufficientBalanceDialog({required VoidCallback onTopUp}) =>
      ErrorHandler.showInsufficientBalanceDialog(this, onTopUp: onTopUp);

  void handleError(dynamic error, {VoidCallback? onRetry}) =>
      ErrorHandler.handle(this, error, onRetry: onRetry);
}
