# Spec: QR Code Conversation Starter

Status: Phase 1 (Specify) — APPROVED
Owner: TBD
Last updated: 2026-04-27

## Objective

Let users start conversations by scanning a contact's QR code. QR payload =
bare Algorand wallet address (58 chars), nothing else. Two entry points in
Settings: **My QR Code** (display) and **Scan QR** (camera). After a valid
scan, a bottom sheet offers Normal chat or Alias chat; selecting routes to the
corresponding chat screen.

## Tech Stack

- Flutter (existing)
- `qr_flutter` — render QR
- `mobile_scanner` — camera + decode
- Existing services: `LocalWalletService`, `AlgorandWallet`, `MessageService`,
  `AliasChatService`, Riverpod

## Commands

```
Install:  cd sealed_app && flutter pub get
Analyze:  cd sealed_app && flutter analyze
Format:   cd sealed_app && dart format --set-exit-if-changed .
Test:     cd sealed_app && flutter test
Run iOS:  cd sealed_app && flutter run -d ios
Run And:  cd sealed_app && flutter run -d android
```

## Project Structure

```
sealed_app/lib/features/qr/
  ├── qr_display_screen.dart
  ├── qr_scan_screen.dart
  └── chat_type_picker_sheet.dart
sealed_app/lib/features/settings/   # +2 list rows in existing settings screen
sealed_app/test/features/qr/
  └── qr_address_validator_test.dart
```

## Code Style

Match existing: `ConsumerWidget` / `ConsumerStatefulWidget`, AsyncValue `.when`,
`withValues(alpha:)`, theme tokens from `theme.dart`, DexaPro via
`Theme.of(context).textTheme`.

## Testing Strategy

- **Unit:** Algorand address validator (length 58, base32 charset).
- **Widget:** `chat_type_picker_sheet` shows Normal + Alias options and emits
  the right callback.
- **Manual:** iOS scan→pick→chat end-to-end with a known address.
- Skip widget tests for camera screen.

## Resolved Decisions

| # | Decision |
|---|---|
| QR payload | Bare Algorand wallet address only |
| Platforms | iOS + Android (no web/desktop) |
| Camera permissions | Add to `Info.plist` + `AndroidManifest.xml` |
| Permission copy | *"Sealed needs camera access to scan a contact's QR code so you can start a conversation."* |
| Alias name after scan | Auto-generated as `alias_<last4>` (last 4 chars of scanned address) |
| Self-scan (own wallet) | **BLOCK** with error toast |
| Existing `sealed://alias?...` URI flow | **Untouched** — keeps working in in-chat invite path |
| Scanned `sealed://alias?...` in QR feature | Treat as invalid QR (show error toast) |
| Invalid scan | Error toast, stay on scan screen |

## Boundaries

**Always**
- Validate scanned strings as Algorand addresses before routing.
- Reuse `MessageService.sendMessage(...)` and
  `AliasChatService.createInvitation(alias, contactWallet)` — no new chat-start
  logic.
- Match existing theme/typography.
- Use existing provider for own wallet address (self-scan guard).

**Ask first**
- Any new dependency beyond `qr_flutter` + `mobile_scanner`.
- Any change to `LocalWalletService`, crypto, DB, or alias-chat shared-secret
  derivation.
- Any change to `generateInviteUri` / `parseInviteUri`.

**Never**
- Encode anything beyond the wallet address in the new QR.
- Touch `lib/services/crypto_*` or `lib/services/key_*`.
- Modify the legacy `sealed://alias?...` URI flow.
- Auto-start a chat without the user picking Normal vs Alias.

## Success Criteria

- [ ] Settings → "My QR Code" shows scannable QR of current user's Algorand
  address + the address as selectable text below.
- [ ] Settings → "Scan QR" opens camera, decodes, validates address.
- [ ] Scanning own wallet → blocked with toast "You can't start a chat with
  yourself."
- [ ] Scanning invalid string → toast "Invalid QR — expected a wallet address."
- [ ] Valid scan → bottom sheet with "Normal chat" / "Alias chat".
- [ ] Normal → routes to existing chat detail with recipient pre-filled.
- [ ] Alias → calls
  `AliasChatService.createInvitation(alias: "alias_<last4>", contactWallet: scanned)`,
  then routes to alias chat detail.
- [ ] Camera permission strings present in iOS + Android manifests.
- [ ] `flutter analyze` clean.
- [ ] `dart format --set-exit-if-changed .` clean.
- [ ] Manual iOS run confirms full flow.

## Out of Scope

- Web, macOS, Linux, Windows
- Deep-link / universal-link handling
- QR import from gallery (camera-live only)
- Editing the alias name after auto-generation
- Modifying `sealed://alias?...` legacy URI handling
