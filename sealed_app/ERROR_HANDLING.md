# Error Handling Documentation

This document outlines all custom exceptions and error codes used throughout the Sealed application. Update this whenever adding new exceptions or modifying error behavior.

---

## Exception Hierarchy

All custom exceptions extend a base exception class with standard fields:
- `message: String` - Human-readable error message
- `code: String?` - Machine-readable error code (uppercase with underscores)
- `stackTrace: StackTrace?` - Optional stack trace for debugging

---

## Services & Error Codes

### 1. CryptoService (`lib/services/crypto_service.dart`)

#### Base Exception
```dart
class CryptoException implements Exception
```

#### Error Codes

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `VALIDATION_ERROR` | `CryptoValidationException` | Invalid input parameters (empty keys, wrong lengths) | Validate inputs before calling |
| `OPERATION_ERROR` | `CryptoOperationException` | Cryptographic operation fails (ECDH, AES-GCM, HKDF) | Check key formats, retry operation |

#### Methods & Exceptions

| Method | Throws | Error Codes |
|--------|--------|------------|
| `computeRecipientTag()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `isMessageForMe()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `encodePayload()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `decodePayload()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `padTo1KB()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `unpadFrom1KB()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `encrypt()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |
| `decrypt()` | `CryptoOperationException`, `CryptoValidationException` | `VALIDATION_ERROR`, `OPERATION_ERROR` |

---

### 2. KeyService (`lib/services/key_service.dart`)

#### Base Exception
```dart
class KeyServiceException implements Exception
```

#### Error Codes

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `DERIVATION_ERROR` | `KeyDerivationException` | Key derivation fails (HKDF, keypair generation) | Retry with valid signature |
| `STORAGE_ERROR` | `KeyStorageException` | Secure storage read/write fails | Check device storage permissions |
| `VALIDATION_ERROR` | `KeyValidationException` | Invalid wallet address, signature, or stored keys | Provide valid inputs, clear keys if corrupted |

#### Methods & Exceptions

| Method | Throws | Error Codes |
|--------|--------|------------|
| `deriveKeys()` | `KeyDerivationException`, `KeyValidationException` | `DERIVATION_ERROR`, `VALIDATION_ERROR` |
| `_saveKeys()` | `KeyStorageException`, `KeyValidationException` | `STORAGE_ERROR`, `VALIDATION_ERROR` |
| `deleteKeys()` | `KeyStorageException` | `STORAGE_ERROR` |
| `hasKeys()` | `KeyStorageException` | `STORAGE_ERROR` |
| `loadKeys()` | `KeyDerivationException`, `KeyValidationException` | `DERIVATION_ERROR`, `VALIDATION_ERROR` |
| `getViewKey()` | `KeyStorageException`, `KeyValidationException` | `STORAGE_ERROR`, `VALIDATION_ERROR` |

---

### 3. LocalDatabase (`lib/local/database.dart`)

#### Base Exception
```dart
class DatabaseException implements Exception
```

#### Error Codes

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `INIT_ERROR` | `DatabaseInitException` | Schema creation, table creation, or initial data insertion fails | Check DB file permissions, clear DB and reinit |
| `OPERATION_ERROR` | `DatabaseOperationException` | Database open/close fails | Check device storage, close other connections |

#### Methods & Exceptions

| Method | Throws | Error Codes |
|--------|--------|------------|
| `init()` | `DatabaseInitException` | `INIT_ERROR` |
| `_onCreate()` | `DatabaseInitException` | `INIT_ERROR` |
| `database` (getter) | `DatabaseOperationException` | `OPERATION_ERROR` |
| `close()` | `DatabaseOperationException` | `OPERATION_ERROR` |

---

### 4. SyncState (`lib/local/sync_state.dart`)

#### Base Exception
```dart
class SyncStateException implements Exception
```

#### Error Codes

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `QUERY_ERROR` | `SyncStateQueryException` | Sync state query from DB fails | Check DB connection, verify table exists |
| `UPDATE_ERROR` | `SyncStateUpdateException` | Sync state update fails | Check DB connection, verify row exists |
| `VALIDATION_ERROR` | `SyncStateException` | Invalid timestamp (negative) | Provide valid DateTime object |
| `NOT_FOUND` | `SyncStateException` | sync_state row doesn't exist | Ensure DB was properly initialized |

#### Methods & Exceptions

| Method | Throws | Error Codes |
|--------|--------|------------|
| `lastSyncTime` (getter) | `SyncStateQueryException` | `QUERY_ERROR` |
| `updateLastSyncTime()` | `SyncStateUpdateException`, `SyncStateException` | `UPDATE_ERROR`, `VALIDATION_ERROR`, `NOT_FOUND` |
| `reset()` | `SyncStateUpdateException`, `SyncStateException` | `UPDATE_ERROR`, `NOT_FOUND` |

---

### 5. MessageCache (`lib/local/message_cache.dart`)

#### Base Exception
```dart
class MessageCacheException implements Exception
```

#### Error Codes

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `EMPTY_LIST` | `MessageCacheException` | Empty messages list passed to `saveMessages()` | Validate list before calling |
| `INVALID_WALLETS` | `MessageCacheException` | Empty wallet addresses in `getConversationMessages()` | Provide valid wallet addresses |
| `INVALID_ID` | `MessageCacheException` | Empty message ID in `messageExists()` | Provide valid message ID |
| `SAVE_ERROR` | `MessageCacheException` | Single message insertion fails | Check DB connection, valid message data |
| `BATCH_SAVE_ERROR` | `MessageCacheException` | Batch message insertion fails | Check DB connection, roll back transaction |
| `QUERY_ERROR` | `MessageCacheException` | Message query fails | Check DB query syntax, verify tables exist |
| `CONVERSATIONS_ERROR` | `MessageCacheException` | Conversation list query fails | Check DB query syntax, rebuild index |
| `EXISTS_ERROR` | `MessageCacheException` | Message existence check fails | Check DB connection |
| `COUNT_ERROR` | `MessageCacheException` | Message count query fails | Check DB connection |
| `CLEAR_ERROR` | `MessageCacheException` | Message deletion fails | Check DB write permissions |

#### Methods & Exceptions

| Method | Throws | Error Codes |
|--------|--------|------------|
| `saveMessage()` | `MessageCacheException` | `SAVE_ERROR` |
| `saveMessages()` | `MessageCacheException` | `EMPTY_LIST`, `BATCH_SAVE_ERROR` |
| `getConversationMessages()` | `MessageCacheException` | `INVALID_WALLETS`, `QUERY_ERROR` |
| `getConversations()` | `MessageCacheException` | `CONVERSATIONS_ERROR` |
| `messageExists()` | `MessageCacheException` | `INVALID_ID`, `EXISTS_ERROR` |
| `getTotalMessageCount()` | `MessageCacheException` | `COUNT_ERROR` |
| `clearMessages()` | `MessageCacheException` | `CLEAR_ERROR` |

---

## Handling Patterns

### Pattern 1: Re-throw Custom Exceptions
Always re-throw custom exceptions to preserve context:

```dart
try {
  // operation
} on MyCustomException {
  rethrow;
} catch (e, stackTrace) {
  throw MyCustomException('Failed: $e', stackTrace);
}
```

### Pattern 2: Validation Before Operation
Always validate inputs at method entry:

```dart
Future<void> myMethod(String param) async {
  try {
    if (param.isEmpty) {
      throw MyValidationException('param cannot be empty');
    }
    // operation
  } catch (e) {
    // handle
  }
}
```

### Pattern 3: Base64 Decoding
Always wrap in try-catch:

```dart
try {
  final bytes = base64.decode(encoded);
} catch (e) {
  throw MyValidationException('Invalid base64 format: $e');
}
```

---

## Testing Error Handling

When writing tests, verify:
1. ✅ Correct exception type is thrown
2. ✅ Error code matches expected value
3. ✅ Message is descriptive
4. ✅ Stack trace is preserved for debugging

```dart
test('throws ValidationException on empty input', () {
  expect(
    () => service.method(''),
    throwsA(isA<MyValidationException>()
      .having((e) => e.code, 'code', 'VALIDATION_ERROR')
    ),
  );
});
```

---

## Common Errors & Solutions

| Error | Likely Cause | Solution |
|-------|-------------|----------|
| `VALIDATION_ERROR: walletAddress cannot be empty` | Missing wallet parameter | Ensure wallet is loaded before calling |
| `STORAGE_ERROR: Failed to save keys` | Permission denied | Check app permissions on device |
| `INIT_ERROR: Failed to create database schema` | DB file locked or corrupted | Close all connections, delete DB file, reinit |
| `OPERATION_ERROR: Failed to encrypt message` | Invalid key size | Verify keys are 32 bytes |
| `CONVERSATIONS_ERROR: Failed to fetch conversations` | Index missing | Drop index and recreate it via schema upgrade |

---

## Future Additions

Add new exceptions here when implementing:
- [ ] Network service (HTTP errors, timeouts)
- [ ] Blockchain service (RPC errors, contract failures)
- [ ] File service (permissions, I/O errors)
- [ ] Push notification service (token errors, delivery failures)

---

## PIN Lock & Termination

### PinService (`lib/services/pin_service.dart`)

#### Base Exception
```dart
class PinException implements Exception
```

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `VALIDATION_ERROR` | `PinException` | PIN is not exactly 6 digits | Re-prompt user |
| `PIN_INCORRECT` | `PinIncorrectException` | DEK unwrap fails (wrong PIN) | Increment attempt counter, show error, back off |
| `PIN_NOT_SET` | `PinNotSetException` | `verifyAndUnwrap` called before `setPin` | Send user to PIN setup |
| `PIN_ALREADY_SET` | `PinException` | `setPin` called when PIN exists | Use `changePin` instead |
| `KDF_ERROR` | `PinKdfException` | Argon2id derivation failed | Surface as fatal; check entropy / memory |

### DekManager (`lib/local/dek_manager.dart`)

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `NOT_BOOTSTRAPPED` | `DekException` | DEK accessed before `bootstrapIfNeeded` | Call bootstrap first |
| `WRAP_MISSING` | `DekException` | Asked to unwrap a wrap that doesn't exist | Re-key path |
| `DEK_UNWRAP_ERROR` | `DekException` | AES-GCM tag failure (wrong KEK) | Caller maps to `PIN_INCORRECT` |
| `PIN_REQUIRED` | `DekException` | Device-secret unwrap requested when PIN is configured | Show LockScreen |

### TerminationService (`lib/services/termination_service.dart`)

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `VALIDATION_ERROR` | `TerminationException` | Code is not 6 digits | Re-prompt |

### BiometricService (`lib/services/biometric_service.dart`)

| Code | Exception Class | When Thrown | Recovery |
|------|-----------------|-------------|----------|
| `NOT_AVAILABLE` | `BiometricException` | Device lacks biometric capability | Hide biometric option |
| `NOT_ENABLED` | `BiometricException` | `unlock` called without setup | Fall back to PIN |
| `KEY_MISSING` | `BiometricException` | Biometric KEK missing from secure storage | Re-onboard biometrics |
| `CANCELLED` | `BiometricException` | User cancelled the prompt | No-op; user can retry |

### WipeService (`lib/services/wipe_service.dart`)

`WipeService` is best-effort — every step is wrapped, and `silentWipe` never
throws. Failures are logged but do not propagate.

---

**Last Updated:** 2026-04-30
**Maintainer:** Development Team
