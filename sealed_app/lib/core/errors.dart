// lib/core/errors.dart
//
// Pure exception types — UI-blind so every feature can import them without
// pulling flutter/material. The SnackBar-based ErrorHandler + BuildContext
// extension live in ui/shared/error_handler.dart.

import 'dart:io';

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

/// Raised when the sender's on-chain credit balance is zero (or below the
/// per-message cost). UI listens for this and surfaces a "redeem code" CTA.
///
/// `isRetryable=false` — user must redeem before retrying.
class NoCreditsError extends SealedException {
  const NoCreditsError([
    super.message = 'No credits available. Redeem a code to send messages.',
  ]) : super(isRetryable: false);
}

/// Generic sealed exception for contract errors without a dedicated type.
class GenericSealedException extends SealedException {
  const GenericSealedException(super.message, {super.details})
    : super(isRetryable: false);
}

/// Polling for transaction confirmation exceeded the allotted timeout.
class ConfirmationTimeoutError extends SealedException {
  final String txId;
  const ConfirmationTimeoutError(this.txId)
    : super('Confirmation timeout for $txId', isRetryable: true);
}

/// No UserState box exists — user must redeem first. TEAL: `NO_BOX`.
class NoBoxError extends SealedException {
  const NoBoxError([
    super.message = 'No account box found. Redeem a code first.',
  ]) : super(isRetryable: false);
}

/// Exposes the credit cost of an action to the UI before submission.
///
/// Returned from dry-run paths so the UI can surface
/// "This action costs 1 credit (balance N → N-1)" without coupling the
/// chain client to a specific UI widget.
class CreditCost {
  final int current;
  final int after;
  const CreditCost({required this.current, required this.after});
}

/// Username already claimed by another wallet. TEAL: `TAKEN`.
class NameTakenError extends SealedException {
  const NameTakenError([super.message = 'Username already taken.'])
    : super(isRetryable: false);
}

/// Username format violation. TEAL: `BAD_LEN`, `BAD_CHAR`, `LEADING_*`,
/// `TRAILING_UNDERSCORE`.
class BadUsernameFormatError extends SealedException {
  final String code;
  const BadUsernameFormatError(
    this.code, [
    super.message = 'Username format invalid.',
  ]) : super(isRetryable: false);
}

/// Bio exceeds the on-chain byte cap. TEAL: `BIO_TOO_LONG`.
/// Cap is 160 UTF-8 BYTES (multibyte chars count as encoded width).
class BioTooLongError extends SealedException {
  const BioTooLongError([super.message = 'Bio must be at most 160 bytes.'])
    : super(isRetryable: false);
}

/// Preimage does not match any live commitment. TEAL: `BAD_CODE`.
///
/// On the live `redeemAndPublish` path the commitment box is deleted on
/// successful redeem, so a spent code and a never-existed code both surface
/// as `BAD_CODE` — the contract cannot distinguish them. The default message
/// therefore covers both cases rather than implying the code was always bogus.
class BadRedeemCodeError extends SealedException {
  const BadRedeemCodeError([
    super.message = 'This code is invalid or has already been used.',
  ]) : super(isRetryable: false);
}

/// Commitment already spent (box no longer exists). TEAL: `BAD_CODE` post-delete.
class RedeemSpentError extends SealedException {
  const RedeemSpentError([super.message = 'Redeem code already used.'])
    : super(isRetryable: false);
}

/// SNARK-redeem contract assert (SPEC-snark-redeem-B T5). Carries the raw
/// assert code (`BAD_PROOF`, `BAD_ROOT`, `DOUBLE_SPEND`, `BAD_RECIPIENT`,
/// `BAD_DENOM`) so UI can map to a user-visible string via
/// `redeemMessageForCode`. The `message` field already carries the mapped
/// string for callers that don't want to consult the map directly.
class RedeemContractError extends SealedException {
  final String code;
  const RedeemContractError(this.code, String mappedMessage)
    : super(mappedMessage, isRetryable: false);
}

/// MBR shortfall (treasury / caller can't cover box MBR). algod: `overspend`.
class MbrShortfallError extends SealedException {
  const MbrShortfallError([super.message = 'Insufficient balance for MBR.'])
    : super(isRetryable: true);
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

/// Categories of message send failure. Stable, programmatic switch surface so
/// UI can branch on cause without inspecting `.toString()`.
enum SendMessageErrorKind {
  insufficientBalance,
  recipientNotFound,
  encryptionFailed,
  unknown,
}

/// Message send errors
class SendMessageException extends SealedException {
  const SendMessageException(
    super.message, {
    this.kind = SendMessageErrorKind.unknown,
    super.isRetryable = true,
  });

  final SendMessageErrorKind kind;

  factory SendMessageException.fromError(dynamic error) {
    // If the inner cause is already a SealedException with a known category,
    // promote without re-parsing strings.
    if (error is NoCreditsError) {
      return const SendMessageException(
        'Insufficient ALGO to send message',
        kind: SendMessageErrorKind.insufficientBalance,
        isRetryable: false,
      );
    }
    if (error is UserNotFoundException) {
      return const SendMessageException(
        'Recipient not found',
        kind: SendMessageErrorKind.recipientNotFound,
        isRetryable: false,
      );
    }

    final msg = error.toString().toLowerCase();
    if (msg.contains('insufficient') ||
        msg.contains('overspend') ||
        msg.contains('below min') ||
        msg.contains('balance')) {
      return const SendMessageException(
        'Insufficient ALGO to send message',
        kind: SendMessageErrorKind.insufficientBalance,
        isRetryable: false,
      );
    }
    if (msg.contains('recipient not found') || msg.contains('user not found')) {
      return const SendMessageException(
        'Recipient not found',
        kind: SendMessageErrorKind.recipientNotFound,
        isRetryable: false,
      );
    }
    if (msg.contains('encryption')) {
      return const SendMessageException(
        'Encryption failed',
        kind: SendMessageErrorKind.encryptionFailed,
        isRetryable: true,
      );
    }
    return const SendMessageException(
      'Failed to send message',
      kind: SendMessageErrorKind.unknown,
    );
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
