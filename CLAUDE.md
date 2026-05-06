# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This is a multi-component monorepo for **Sealed**, an end-to-end encrypted messaging app that uses a blockchain as its message bus.

- `sealed_app/` — Flutter client (iOS/Android, primary target). All UI, key management, and crypto runs here. This is the directory most development happens in.
- `sealed-indexer/` — TypeScript/Node service intended to run behind a Tor v3 hidden service. Provides WebSocket real-time sync and OHTTP-wrapped push notifications. **No HTTP polling** — that's an explicit design decision (see its README). Token registry is keyed by `view_key_hash`, not `user_id`.
- `programs/sealed_message/`, `programs/alias_channel/` — Algorand TEAL smart contracts (PyTeal sources + compiled `.teal` + ABI JSON). Algorand is the primary chain.
- `programs/sealed_protocol/` — Legacy Solana/Anchor program (Rust). Kept for migration support; new work targets Algorand.
- `internal/` — Private plans, design handoffs, and release tooling. Stripped from public mirrors by `scripts/release_public.sh`.
- `scripts/release_public.sh` — Builds a sanitized public mirror (strips `internal/`, secrets, etc.). Run with `--dry-run` first.

## Common Commands

### Flutter app (`sealed_app/`)
```bash
flutter pub get
flutter analyze                          # must pass with no errors
dart format --set-exit-if-changed .      # must exit clean
flutter test                             # all unit tests
flutter test test/services/crypto_service_test.dart   # single file
flutter test test/integration/           # integration tests (sends real chain messages)
flutter run -d ios | -d macos | -d chrome
```

### OHTTP indexer (`sealed-indexer/`)
```bash
npm install
npm run dev          # nodemon + ts-node on src/index.ts
npm run build        # tsc → dist/
npm test             # jest
npm run lint         # eslint src/
```

### Algorand contracts (`programs/sealed_message/`, `programs/alias_channel/`)
- PyTeal sources compile to the checked-in `*_approval.teal` / `*_clear.teal` / `*_contract.json`.
- `deploy.py` in each program directory deploys to TestNet.
- `programs/sealed_message/test_sealed_message.py` is the contract test.

### Solana program (`programs/sealed_protocol/`)
- Anchor project; `anchor build` / `anchor test`. Devnet is the configured cluster. Treat as legacy.

## Architecture: the three realms

Sealed splits responsibilities across three realms — understanding this split is essential before changing anything that crosses a boundary:

1. **Device realm** (`sealed_app/lib/`): private keys, SQLite cache (`local/`), all encryption/decryption. Keys never leave the device. Decryption works fully offline.
2. **Blockchain realm** (Algorand TestNet, `programs/`): immutable storage of encrypted, padded message blobs. The chain is the canonical message bus — the indexer is optional acceleration.
3. **Indexer realm** (`sealed-indexer/`): optional. Receives only metadata sufficient to route push notifications (`view_key_hash`-keyed); cannot decrypt. Reached via OHTTP gateway on Pi.

Outbound network from the app — both Algorand RPC and indexer calls — flows through OHTTP encapsulation to hide the user's IP from RPC nodes and indexers. Algorand calls use the Foundation's OHTTP gateway; indexer calls use the Pi gateway.

## Flutter app internal structure

The app uses **Riverpod** for state. Layering is enforced informally — keep changes within the right layer:

| Layer | Path | Role |
|---|---|---|
| `services/` | business logic, no Flutter/UI imports | crypto, keys, message send/recv, indexer client, Tor, notifications |
| `chain/` | blockchain client abstraction | `chain_client.dart` is the interface; `algorand_chain_client.dart` is the live impl |
| `local/` | SQLite (`sqflite`) caches | message cache, key cache |
| `remote/` | HTTP/WebSocket transport | indexer transport |
| `providers/` | Riverpod providers wiring services to UI | |
| `features/` | screens & widgets, organized by feature | `auth`, `chat`, `qr`, `settings`, etc. |
| `models/` | plain data classes | |

### Crypto invariants — do not casually modify

These three files contain the crypto core. **Do not weaken or refactor them without expert review** (per `CONTRIBUTING.md`):

- `lib/services/crypto_service.dart` — hybrid ML-KEM-512 + X25519 KEM, AES-GCM, HKDF, **1 KB padding** of every message, recipient-tag computation.
- `lib/services/key_service.dart` — BIP39-derived identity, secure-storage persistence.
- `lib/services/key_format_converter.dart` — key encoding conversions.

The 1 KB padding is load-bearing: it defends against size-based traffic analysis. Any change to plaintext encoding must preserve `padTo1KB`/`unpadFrom1KB` round-tripping.

### Error handling

`sealed_app/ERROR_HANDLING.md` is the authoritative catalog of custom exceptions and error codes (`CryptoException`, `KeyServiceException`, etc., each with `code` strings like `VALIDATION_ERROR`, `OPERATION_ERROR`, `DERIVATION_ERROR`). When adding a new exception class or code, update that doc.

## Conventions

- **Conventional Commits**, signed (`git commit -S -m "feat(crypto): ..."`). Scopes follow the layer names above (`crypto`, `indexer`, `chain`, `chat`, `security`, `docs`).
- Quality gates that CI enforces, in order: `flutter analyze` (errors fail), `dart format --set-exit-if-changed .`, `flutter test`.
- Never commit real keys, mnemonics, addresses, Firebase config (use the `.example` templates), or APNs keys. The release script assumes `internal/` and similar directories stay out of the public mirror.
- New dependencies — especially crypto-adjacent — need review before merge.

## Useful pointers

- Threat model & what is/isn't protected: `SECURITY.md`.
- Privacy guarantees and data flows: `PRIVACY_POLICY.md`.
- Indexer roadmap & task tracking: `internal/tasks/` and `sealed-indexer/README.md`.
- Public-release sanitization rules: `scripts/release_public.sh`.
