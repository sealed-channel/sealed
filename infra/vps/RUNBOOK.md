# Hetzner VPS Runbook — Sealed backend + LP

Target: one Hetzner **CCX13** (amd64 dedicated, 2 vCPU / 8 GB) running:

- OHTTP gateway + sealed-indexer + preimage-server (compose stack rebuilds for amd64 on the box)
- Landing page / top-up (Next.js) + Postgres (`infra/vps/lp/`)
- Caddy as the only public entry (`infra/vps/Caddyfile`)

User-IP privacy is protocol-level (OHTTP): the relay sees user IP + ciphertext,
this box sees plaintext + relay IP. Nothing here ever sees a user IP. Keep it
that way — see "Privacy invariants" at the bottom.

DNS: `sealed.channel`, `www.sealed.channel`, `gw.sealed.channel` → VPS IPv4/IPv6.
Relay: new slug `alter-ball-33` → `https://gw.sealed.channel`
(`https://relay.oblivious.network/alter-ball-33`; registered 2026-06-13). Old
slug `groovy-guide-67` keeps pointing at the Pi for the 2 testnet testers until
Pi retirement.

## 1. Provision (~30 min)

```bash
# Hetzner Cloud console: CCX13, Ubuntu 24.04, Falkenstein, add your SSH key.
ssh root@<ip>
adduser sealed && usermod -aG sudo sealed
rsync ~/.ssh root→sealed; then:
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/;s/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh
apt update && apt -y upgrade && apt -y install unattended-upgrades fail2ban ufw git sqlite3 age
# Docker (official repo) + compose plugin; Tailscale:
curl -fsSL https://get.docker.com | sh && usermod -aG docker sealed
curl -fsSL https://tailscale.com/install.sh | sh && tailscale up   # NO funnel
```

Firewall — SSH only over Tailscale:

```bash
ufw allow in on tailscale0 to any port 22 proto tcp
ufw allow 80/tcp && ufw allow 443/tcp
ufw default deny incoming && ufw enable
```

Data layout (mirrors the Pi so compose mounts work verbatim):

```bash
mkdir -p /mnt/sealed-data/{indexer,secrets,backups,lp-data,lp-postgres}
chown -R sealed:sealed /mnt/sealed-data && chmod 700 /mnt/sealed-data/secrets
```

## 2. Indexer stack (~1 h)

On the VPS as `sealed`:

```bash
git clone <repo-url> ~/sealed
# ohttp-gateway image — Cloudflare's published image is access-restricted;
# build from source for amd64 (Pi used arm64):
git clone https://github.com/cloudflare/privacy-gateway-server-go.git
docker build -t local/ohttp-gateway:latest privacy-gateway-server-go
```

The compose file is host-agnostic via two interpolated vars (Pi defaults
preserved, so Pi redeploys are unaffected):

- `platform: ${SEALED_PLATFORM:-linux/arm64}` — CX/CCX boxes are amd64.
- `ALLOWED_TARGET_ORIGINS` / `TARGET_REWRITES` keyed on
  `${GATEWAY_TARGET_ORIGIN:-sealed-pi.taile8602b.ts.net}` — the gateway only
  forwards to origins in this allow-list, so the VPS public host must be set
  or every OHTTP request 4xx's.

Create the override `.env` **in the deploy dir on the VPS** ($REMOTE_DEPLOY,
beside the rsynced compose — `docker compose` auto-loads it; the single-file
compose rsync has no `--delete`, so it survives redeploys):

```bash
# on the VPS, in $REMOTE_DEPLOY (e.g. ~/sealed/sealed-indexer/docker):
cat > .env <<'EOF'
SEALED_PLATFORM=linux/amd64
GATEWAY_TARGET_ORIGIN=gw.sealed.channel
EOF
```

On your machine:

```bash
cp scripts/deploy.vps.env.example scripts/deploy.vps.env   # fill DEPLOY_HOST etc.
./scripts/deploy_secrets_to_pi.sh --env-file scripts/deploy.vps.env --restart
```

Secrets policy for the parallel phase:

- **Copy from Pi as-is**: `DISPATCHER_*_KEY_BASE64` (clients encrypted push
  tokens to this pubkey), `SEED_SECRET_KEY` (gateway HPKE), APNs `.p8`, FCM
  `admin-account.json`.
- `.env` deltas on the VPS: `ALGORAND_START_ROUND` = current tip (scratch
  verification DB; testnet registrations stay on the Pi).
- Mainnet flip (launch day): `SEALED_APP_ID` = mainnet app id,
  `ALGOD_URL=https://mainnet-api.4160.nodely.io`, fresh `ALGORAND_START_ROUND`,
  `PREIMAGE_UPSTREAM_URL=http://sealed-preimage-server:4100`.

## 3. Caddy (~15 min)

```bash
apt -y install caddy
cp ~/sealed/infra/vps/Caddyfile /etc/caddy/Caddyfile && systemctl reload caddy
curl -sI https://gw.sealed.channel/ohttp-configs    # → 200, binary body
```

## 4. LP stack (~1 h)

```bash
git clone <lp-repo-url> ~/sealed-landing-page
# LP dev (additive): `output: "standalone"` in next.config.ts; env-ize APP_ID.
sudo install -m 600 ~/sealed/infra/vps/lp/lp.env.example /mnt/sealed-data/secrets/lp.env
$EDITOR /mnt/sealed-data/secrets/lp.env               # fill password, relay slug
cd ~/sealed/infra/vps/lp && docker compose --env-file /mnt/sealed-data/secrets/lp.env up -d --build
curl -sI https://sealed.channel                       # → 200
```

## 5. Verification

1. `https://gw.sealed.channel/ohttp-configs` → 200 binary.
2. OHTTP round-trip through the **new relay slug**: `GET /roots`,
   `GET /dispatcher/public-key` (reuse indexer's `ohttp-client.ts` in a script).
3. Mobile smoke build with `PI_OHTTP_GATEWAY_CONFIG_URL` /
   `PI_OHTTP_RELAY_URL` env overrides pointed at gw.sealed.channel.
4. LP testnet purchase E2E: buy 1 code → `CommitmentsSold` → poll
   `/api/delivery/<hex>` → decrypt → redeem in app. Golden vector test from
   `LP-INTEGRACJA-PL.md` must pass first.
5. Push: APNs heartbeat + FCM event push arrive with VPS as dispatcher.

## 6. Mainnet launch (day 2+)

1. **Fresh hot admin key** — `pnpm deploy -- --new-wallet` (programs/sealed).
   **Never** put the Ledger seed in any env/file; the Ledger address is the
   `withdrawTreasury` sweep destination only.
2. Deploy contract to mainnet, set price, seed pool
   (`gen-redeem-batch` → `load-codes` into preimage server on VPS).
3. Flip indexer `.env` + `lp.env` to mainnet (see §2/§4 notes); restart stacks.
4. App: mainnet constants (`sealed_app/lib/core/constants.dart`) — mainnet
   Nodely targets, mainnet app id, `gw.sealed.channel`, new relay slug.
5. Build release APK, host on LP with SHA-256 checksum printed next to the link.
6. One real-ALGO purchase E2E, then `withdrawTreasury` sweep → Ledger address.

## 7. Backups

`infra/vps/backup-vps.sh` (cron, nightly) — age-encrypted snapshots of
indexer.sqlite, preimage-server.sqlite (**unsold inventory = money**),
waitlist.sqlite, and `pg_dump` of the LP Postgres, with offsite rsync to a
Hetzner Storage Box. The age key is generated on the **local** machine; only the
public key (`BACKUP_RECIPIENT`) lives on the VPS. Weekly Hetzner snapshots on top.

Recipient (public, 2026-06-13):
`age17p2tq04uh04kkey73y050xcah2s93swv70fs4ytrmgzl5gfqdsjqkp2yv9`. Cron:

```cron
17 4 * * * BACKUP_RECIPIENT=age17p2tq04uh04kkey73y050xcah2s93swv70fs4ytrmgzl5gfqdsjqkp2yv9 /home/sealed/sealed/infra/vps/backup-vps.sh >> /var/log/sealed-backup.log 2>&1
```

## Privacy invariants

- All app containers bind 127.0.0.1; Caddy is the sole public entry.
- Gateway site: access logs **disabled** (Caddyfile). LP logs IP-stripped.
- Relay stays third-party (oblivious.network) — never self-host the relay.
- LP browser code calls only `/api/algod` + `/api/delivery`; route handlers do
  the OHTTP wrapping server-side.
- `APNS_DIRECT` stays unset.
