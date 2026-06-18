# Sealed — Project Context

## Docs (read first, before code changes in matching area)

Authoritative product/architecture docs live at `docs/`. Read the relevant file BEFORE editing code in that area; do not infer behavior from code alone when a doc covers it.

- `docs/Core Functionality.md` — top-level overview
- `docs/sendMessages.md`, `docs/syncMessages.md` — messaging flows
- `docs/core/` — backend service contracts (live as Dart code under `sealed_app/lib/features/<x>/` and `sealed_app/lib/infra/<x>/`)
  - `Indexer Service.md`, `OHTTP.md`, `Key Service.md`, `Message Service.md`,
    `Contacts Service.md`, `User Service.md`, `Wallet Service.md`,
    `PIN Service.md`, `Credits Service.md`, `Sealed Chain Client.md`
- `docs/notifiers/` — Riverpod providers (Contacts, Keys, Message, PIN, Settings, User, Wallet)
- `docs/screens/` — UI screens (Chat, Home/Chat List, Onboarding, Settings)

Internal engineering docs: `internal/docs/`
- `internal/docs/adr/` — Architecture Decision Records. Read before changing decisions they cover.
- `internal/docs/refactor-plan-architecture.md` — folder restructure plan (completed 2026-05-22; kept for history).
- `internal/docs/refactor-baseline.md` — pre-refactor analyze/test/format baseline.
- `programs/sealed/MOBILE-INTEGRATION.md` — contract ↔ mobile contract surface
- `sealed-indexer/docs/PUSH_PROVIDER_METADATA.md` — push pipeline

**Rule:** if your change touches a service/notifier/screen/chain-program that has a doc, open the doc first. If the doc disagrees with code, flag it — don't silently pick one.

## Stack

| Path | Stack | Notes |
|---|---|---|
| `sealed_app/` | Flutter / Dart, Riverpod | Mobile client. State via providers (see `docs/notifiers/`). |
| `sealed-indexer/` | Node / TypeScript, Jest | Reached via OHTTP gateway. No Tor, no WebSocket. Outbound push via OHTTP. |
| `programs/sealed/` | Algorand TS contract (puya-ts), Vitest | Credits + username top-up. ARC56. |
| `circuits/` | Circom | `redeem.circom` — ZK redeem snark. Keys in `circuits/keys/`. |
| `pi-gateway/` | Shell scripts | Pi-based OHTTP gateway tooling. |
| `internal/` | Internal-only docs/tools | Not shipped. |

## Flutter app layout (`sealed_app/lib/`)

Three top-level concerns, feature-first organization. New files MUST go into one of these — do not recreate the legacy folders.

```
sealed_app/lib/
├── app.dart, main.dart
├── core/           constants, errors, extensions, service_locator
├── models/         data classes, no behavior
├── providers/      Riverpod surface (kept flat for now — separate refactor planned)
├── features/       user-facing capabilities (one folder per capability)
│   ├── auth/              PIN auth, wipe
│   ├── identity/          user_service, username_validator, migration_notice_service
│   ├── messaging/         message_service + alias/ subdir for alias handshake
│   ├── notifications/     notification_service
│   ├── search/            search_service, scopes
│   ├── settings/          app_settings_service
│   └── wallet/            algorand_wallet, chain client, credit ops, treasury escrow, credits_service, qr_address_validator
├── infra/          cross-cutting primitives (UI-blind, feature-blind)
│   ├── crypto/            crypto_service, key_service, key_format_converter
│   ├── local/             database, dek_manager, repositories
│   ├── network/           indexer_client, indexer_service, root_cache, ohttp/
│   └── zk/                snark_prover, poseidon, merkle_path
└── ui/             widgets, organized by Figma section
    ├── onboarding/        screens (pin setup/confirm, wallet setup, lock, splash) + widgets
    ├── chat_list/         screens
    ├── chat/              screens/chat_detail.dart + alias/screens/ for alias-handshake screens
    ├── settings/          screens + widgets
    ├── navigation/        nav_tab.dart + screens (main_shell, coming_soon) + widgets (bottom nav)
    ├── qr/                screens + widgets
    └── shared/            theme.dart + widgets (snackbars, shimmer, styled_dialog)
```

**Rules:**
- `features/<x>/` may import `infra/`, `core/`, `models/`. Features do NOT import each other (yet) — go through a notifier if needed.
- `infra/<x>/` is UI-blind and feature-blind. Pure primitives.
- `ui/` may import anything. Widgets live here only.
- `core/` is tiny — only truly cross-cutting (no UI, no services).
- `providers/` is the Riverpod surface. Layered reorganization is a separate refactor (out of scope for now).

## Conventions

- **Privacy primitives are load-bearing.** OHTTP, ZK redeem, sealed messaging — never weaken for convenience (logging, debug endpoints, plaintext fallbacks). If a change reduces privacy, call it out explicitly.
- **No mocks of OHTTP / chain / indexer in integration tests** unless test name says `unit`. Integration tests hit the real client paths.
- **Flutter:** Riverpod providers in `sealed_app/lib/providers/`. Match the notifier docs.
- **TS (indexer + contract):** strict mode. Prettier + ESLint configured per-package — use `pnpm run lint` / `format` before commit.
- **Dart formatting:** `dart format .` in `sealed_app/` before commit.
- **Contracts:** never edit deployed ARC56 artifacts in `out/` by hand. Rebuild via `pnpm build` in `programs/sealed/`.
- **Circuits:** if `redeem.circom` changes, trusted setup artifacts in `keys/` must be regenerated — never reuse old keys with a changed circuit.

## Common commands

```bash
# Flutter app
cd sealed_app && flutter run
cd sealed_app && flutter test
cd sealed_app && flutter analyze
cd sealed_app && dart format .

# Indexer
cd sealed-indexer && npm run dev
cd sealed-indexer && npm test
cd sealed-indexer && npm run lint

# Algorand contract
cd programs/sealed && pnpm build
cd programs/sealed && pnpm test
cd programs/sealed && pnpm deploy:testnet

# Circuits
cd circuits && npm run <see package.json scripts>
```

## When unsure

1. Check `docs/` for the touched area.
2. Check `internal/docs/adr/` for prior decisions.
3. Ask before introducing a new dependency, a new network endpoint, or anything that touches the OHTTP/ZK/sealed-message path.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
