# sealed-indexer

Algorand chain indexer for Sealed. Clients reach it **only through an OHTTP gateway** — no Tor, no WebSocket, and intentionally no HTTP polling/sync routes (plan decision D2). Outbound push is OHTTP-wrapped as well, so push providers never see the indexer's origin IP.

## Layout (`src/`)

| Path | Purpose |
|---|---|
| `app.ts`, `index.ts` | Express app (helmet, JSON body only); mounts `/user`, `/username`, and roots routes |
| `chain/` | Algorand chain subscription (`algokit-subscriber`) + ABI app-call decoding |
| `users/` | User/username routes, store, chain watcher |
| `roots/` | Merkle root routes |
| `notifications/` | Push pipeline: iOS silent heartbeat via APNs (2048B fixed payload, uniform cadence via `push-scheduler`) and Android targeted alerts via raw FCM HTTP v1 (frozen constant body, no Google/Firebase SDKs) — both through the OHTTP relay |
| `push/` | Dispatcher seal + opt-in targeted-push registry |
| `preimage-server/` | Redeem-code preimage server + purchase tooling |
| `legacy/` | Pre-OHTTP watcher/directory code, kept for reference |

## Docs

- [`docs/PUSH_PROVIDER_METADATA.md`](docs/PUSH_PROVIDER_METADATA.md) — exactly what Apple/Google can observe in the push pipeline
- [`docs/PREIMAGE_SERVER_DEPLOY.md`](docs/PREIMAGE_SERVER_DEPLOY.md) — preimage server deployment
- [`docker/docker-compose.yml`](docker/docker-compose.yml) — container setup

## Commands

```bash
npm install
npm run dev        # nodemon + ts-node
npm run build      # tsc
npm start          # node dist/index.js
npm test           # jest
npm run lint       # eslint src/

# Preimage server
npm run preimage-server
npm run load-codes
npm run smoke-buy
npm run gen-golden-vector
```
