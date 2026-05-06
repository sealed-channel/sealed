import 'package:flutter/material.dart';
import '../shared/widgets/theme.dart';

/// Shows an informational snackbar with primary color background
void showInfoSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  SnackBarAction? action,
}) {
  _showStyledSnackBar(
    context,
    message: message,
    icon: Icons.info_outline,
    backgroundColor: primaryColor,
    duration: duration ?? const Duration(seconds: 2),
    action: action,
  );
}

/// Shows a warning snackbar with orange background
void showWarningSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  SnackBarAction? action,
  VoidCallback? onRetry,
  String retryLabel = 'RETRY',
}) {
  SnackBarAction? finalAction = action;
  Duration finalDuration = duration ?? const Duration(seconds: 3);

  if (onRetry != null && action == null) {
    finalAction = SnackBarAction(
      label: retryLabel,
      textColor: Colors.white,
      onPressed: () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        onRetry();
      },
    );
    finalDuration = const Duration(seconds: 6);
  }

  _showStyledSnackBar(
    context,
    message: message,
    icon: Icons.warning_amber_rounded,
    backgroundColor: Colors.orange.shade700,
    duration: finalDuration,
    action: finalAction,
  );
}

/// Shows an error snackbar with red background
void showErrorSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  SnackBarAction? action,
  VoidCallback? onRetry,
  String retryLabel = 'RETRY',
}) {
  SnackBarAction? finalAction = action;
  Duration finalDuration = duration ?? const Duration(seconds: 4);

  if (onRetry != null && action == null) {
    finalAction = SnackBarAction(
      label: retryLabel,
      textColor: Colors.white,
      onPressed: () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        onRetry();
      },
    );
    finalDuration = const Duration(seconds: 6);
  }

  _showStyledSnackBar(
    context,
    message: message,
    icon: Icons.error_outline,
    backgroundColor: Colors.red.shade700,
    duration: finalDuration,
    action: finalAction,
  );
}

/// Internal helper to create styled floating snackbars
void _showStyledSnackBar(
  BuildContext context, {
  required String message,
  required IconData icon,
  required Color backgroundColor,
  required Duration duration,
  SnackBarAction? action,
}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();

  final snackBar = SnackBar(
    content: Row(
      children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
    backgroundColor: backgroundColor,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    duration: duration,
    action: action,
  );

  ScaffoldMessenger.of(context).showSnackBar(snackBar);
}
