# @sealed/topup

Algorand TypeScript smart contract — top-up credits + username for Sealed messenger. v1 TestNet only.

Spec: `../../SPEC.md`. Plan: `../../tasks/plan.md`.

## Setup

```
pnpm install
cp .env.example .env   # fill SEALED_TREASURY_MNEMONIC for deploy
```

## Commands

```
pnpm --filter topup build       # Puya TS → ARC-56 in ./out
pnpm --filter topup test        # vitest unit + integration
pnpm --filter topup lint
```

See SPEC §3 for full command list.
