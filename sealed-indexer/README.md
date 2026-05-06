# sealed-tor-indexer

Fork of `indexer-service/` that runs behind a Tor v3 hidden service. Tracks plan in `../tasks/plan.md`.

**Current status:** Task 1.1 — scaffolding, `/health` endpoint only. No chain monitor, no push, no WebSocket yet. Those are added in Tasks 1.3–1.5.

**Scope removed vs. `indexer-service/`:**
- No HTTP polling / sync endpoints (decision D2 in the plan).
- Push will be OHTTP-wrapped (Task 1.5), not direct Firebase Admin.
- Token registry rekeyed on `view_key_hash` (Task 1.3), not on `user_id`.

## Commands

```bash
npm install
npm test
npm run build
npm run dev
```
