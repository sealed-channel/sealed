# Sealed VPS — Operations Runbook

Day-to-day operator tasks for the Hetzner box: deploy, seed the top-up sale
pool, and read live metrics. For first-time provisioning see `RUNBOOK.md`.

## Box / network facts

| | |
|---|---|
| SSH | `ssh -i ~/.ssh/hetzner sealed@100.71.67.38` (Tailscale; public :22 firewalled) |
| Public IPv4 | `167.233.96.49` |
| Top-up contract (testnet) | app `763452863` |
| Preimage DB (host) | `/mnt/sealed-data/indexer/preimage-server.sqlite` |
| LP source on box | `~/sealed-landing-page` |
| Indexer/preimage source | `~/sealed/sealed-indexer` |
| LP compose | `~/sealed/infra/vps/lp/` |
| Indexer compose | `~/sealed/sealed-indexer/docker/` |
| Nodely testnet | algod `https://testnet-api.4160.nodely.dev` · indexer `https://testnet-idx.4160.nodely.dev` |

Global-state keys on the contract: `pr` price µAlgo · `ph` poolHead (**cumulative
codes sold**) · `pt` poolTail · depth = `pt − ph` · `r` roundsPerYear · `m` maxBatches.

---

## 1. Pull & build (redeploy)

### LP (landing page / top-up)
```bash
ssh -i ~/.ssh/hetzner sealed@100.71.67.38
cd ~/sealed-landing-page && git pull          # box must be a git checkout; see RUNBOOK §4
cd ~/sealed && git pull                        # infra (compose/Dockerfile)
cd ~/sealed/infra/vps/lp && \
  docker compose --env-file /mnt/sealed-data/secrets/lp.env up -d --build
curl -sI https://sealed.channel | head -1      # → HTTP 200
```

### Indexer + preimage-server
```bash
cd ~/sealed && git pull
cd ~/sealed/sealed-indexer/docker && \
  docker compose up -d --build
docker compose ps                              # all Up
```

---

## 2. Seed the top-up sale pool (3 steps, same JSON throughout)

`gen` only registers commitments; the pool the LP sells from needs `seed-sale-pool`;
delivery needs the preimage `import`. **Run all three or buyers get 404s.**

### 2a. Generate codes + register on-chain — on your Mac, in `programs/sealed`
```bash
SEALED_TREASURY_MNEMONIC="<admin 25-word>" TOPUP_APP_ID=763452863 \
  npm run gen-monetization-code:testnet -- \
    --denom 500 --count 4 --out sale-pool-testnet.json
```
Writes `sale-pool-testnet.json` (`code`, `preimageHex`, `commitmentHex`). **Keep private — any `code` is redeemable.**

### 2b. Enqueue into the FIFO pool — Mac, `programs/sealed`
```bash
SEALED_TREASURY_MNEMONIC="<admin 25-word>" TOPUP_APP_ID=763452863 \
  npm run seed-sale-pool:testnet -- --in sale-pool-testnet.json
```
Bumps `pt`. Batches of ≤4 per txn. `--dry-run` to preview.

### 2c. Import preimages into the VPS store — on the box
```bash
# from Mac:
scp -i ~/.ssh/hetzner sale-pool-testnet.json sealed@100.71.67.38:~/

# on box:
cd ~/sealed/sealed-indexer
npx tsx scripts/preimage-server-import.ts \
  --in ~/sale-pool-testnet.json \
  --db /mnt/sealed-data/indexer/preimage-server.sqlite
docker restart sealed-preimage-server
```
Importer aborts if a code's derived commitment ≠ its `commitmentHex` (drift guard).
Re-run safe with `--skip-duplicates`.

> **Stale-head note:** `purchaseCodes` consumes from `poolHead`. If old un-backed
> entries sit at the head (pool seeded on-chain but never imported here), the next
> buy still 404s. Drain them with throwaway buys (each advances `ph`), or import
> the original bundle that backs them. Check depth + head before selling (§3).

---

## 3. Metrics / health checks

### Current block (chain tip)
```bash
curl -s https://testnet-api.4160.nodely.dev/v2/status | \
  python3 -c "import sys,json;print('round',json.load(sys.stdin)['last-round'])"
```

### Pool state + total purchased codes (on-chain, authoritative)
```bash
curl -s https://testnet-api.4160.nodely.dev/v2/applications/763452863 | python3 -c "
import sys,json,base64
gs=json.load(sys.stdin)['params']['global-state']
g={base64.b64decode(k['key']).decode('latin1'):(k['value']['uint'] if k['value']['type']==2 else base64.b64decode(k['value']['bytes']).hex()) for k in gs}
ph,pt=g.get('ph',0),g.get('pt',0)
print('price (ALGO)      :', g.get('pr',0)/1e6)
print('codes purchased   :', ph)          # cumulative, lifetime
print('pool depth (avail):', pt-ph)
print('poolHead / poolTail:', ph,'/',pt)
"
```

### Preimage store status (off-chain delivery state)
```bash
ssh -i ~/.ssh/hetzner sealed@100.71.67.38 \
  'docker exec -w /app sealed-preimage-server node -e "
const D=require(\"better-sqlite3\");
const db=new D(\"/data/preimage-server.sqlite\",{readonly:true});
for(const r of db.prepare(\"select status,count(*) c from preimages group by status\").all())
  console.log(r.status, r.c);
"'
```
`available` = sellable & deliverable · `sold` = bought, awaiting fetch · `delivered` = fetched by buyer.

### Top-up purchases in the last 24h (on-chain calls to app 763452863)
```bash
ssh -i ~/.ssh/hetzner sealed@100.71.67.38
SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
node -e '
const since=process.argv[1], app=763452863;
(async()=>{let n=0,next="";do{
  const u=`https://testnet-idx.4160.nodely.dev/v2/transactions?application-id=${app}&after-time=${since}&limit=1000`+(next?`&next=${next}`:"");
  const j=await (await fetch(u)).json();
  n+=(j.transactions||[]).length; next=j["next-token"]||"";
}while(next); console.log("app 763452863 txns last 24h:",n);})();
' "$SINCE"
```

### Container health
```bash
ssh -i ~/.ssh/hetzner sealed@100.71.67.38 'docker ps --format "{{.Names}}: {{.Status}}"'
```

### Did the watcher see a specific purchase?
```bash
docker logs sealed-preimage-server --since 30m 2>&1 | \
  grep -iE 'subscribedTransactionsLength: [1-9]|commitment not found|deliver'
```
`commitment not found in store — skipping` ⇒ that pool entry was never imported (re-run §2c with the right bundle).

---

## Quick reference — full seed-and-verify cycle
```
gen-monetization-code  →  seed-sale-pool  →  import (box)  →  restart preimage
        ↓                       ↓                 ↓
   codes.json            pt bumps          preimages: available
verify: §3 pool depth rises, preimage `available` count rises, then test-buy → codes deliver
```
