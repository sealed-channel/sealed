# pi-gateway — Sealed OHTTP Gateway on Raspberry Pi 4B

This directory holds operator scripts and config for the Pi that fronts the
Sealed indexer with an RFC 9458 OHTTP gateway. The actual docker-compose for
the gateway + indexer lives in `sealed-indexer/docker/docker-compose.yml.example`
— this dir is just the runbook plus host-side scripts (Tailscale, backup).

## Architecture

```
  Flutter app
      │  (OHTTP-encapsulated request)
      ▼
  Oblivious.Network OHTTP relay  ← sees client IP, ciphertext only
      │  (forwards encapsulated body)
      ▼
  Tailscale Funnel (sealed-pi.<tailnet>.ts.net:443)
      │  (TLS terminates here; body is still OHTTP-encapsulated)
      ▼
  ohttp-gateway container (127.0.0.1:8080)
      │  (decapsulates with HPKE private key)
      ▼
  sealed-indexer container (sealed-net:3000)
      │  (plaintext request, applies normal indexer logic)
      ▼
  Response flows back the same way, encapsulated again.
```

The gateway operator (you) sees plaintext requests but NOT client IPs.
The relay operator (Oblivious.Network) sees client IPs but NOT requests.
Unlinkability holds as long as relay + gateway do not collude.

## One-time bring-up (assumes Pi already running, USB SSD mounted)

1. **Tailscale signup + auth** (browser)

   - Sign up: <https://login.tailscale.com/start>
   - Enable HTTPS Certificates + MagicDNS in admin console
   - Add Funnel to ACL (`nodeAttrs` → `funnel`)
   - Generate a reusable, pre-approved auth key (90-day) — save in your password manager

2. **Install Tailscale on Pi**

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up \
     --auth-key=<TSKEY-AUTH-...> \
     --hostname=sealed-pi \
     --accept-routes=false
   tailscale status
   ```

3. **Provision OHTTP gateway HPKE keypair**

   The gateway needs an HPKE keypair so the public key it serves at
   `/.well-known/ohttp-gateway` matches the private key it uses to
   decapsulate.

   Generate (on the Pi or any arm64 host with docker):

   ```bash
   docker run --rm ghcr.io/cloudflare/privacy-gateway-server:latest \
     ohttp-gateway-cli keygen
   ```

   Copy the printed seed + key id into the secrets `.env`:

   ```
   OHTTP_GATEWAY_SEED_BASE64=<seed>
   OHTTP_GATEWAY_KEY_ID=<id>
   ```

4. **Deploy secrets + compose**

   From a developer laptop with the secrets bundle (apns_keys/,
   admin-account.json, .env):

   ```bash
   ./scripts/deploy_secrets_to_pi.sh
   ```

5. **Bring the stack up**

   ```bash
   ssh ify_move@sealed-pi.<tailnet>.ts.net
   cd /home/ify_move/sealed/sealed-indexer/docker
   docker compose up -d
   docker compose ps
   docker compose logs --tail 30 ohttp-gateway sealed-indexer
   ```

6. **Wire Tailscale Funnel**

   Funnel runs on the host (not in docker) and proxies :443 → 127.0.0.1:8080
   (the gateway container's published port).

   ```bash
   sudo tailscale funnel --bg --https=443 http://localhost:8080
   tailscale funnel status
   ```

   Verify from off-tailnet:

   ```bash
   curl -sI https://sealed-pi.<tailnet>.ts.net/.well-known/ohttp-gateway
   # expect 200 OK with binary key config
   ```

## Backup

Local-only USB backup (no off-Pi target). Nightly cron at 04:07 (slightly off
the hour to avoid scheduler thundering herds).

```bash
sudo cp pi-gateway/scripts/backup.sh /usr/local/bin/sealed-backup
sudo chmod +x /usr/local/bin/sealed-backup
sudo crontab -e
# Add:
#   7 4 * * *  /usr/local/bin/sealed-backup >> /var/log/sealed-backup.log 2>&1
```

The backup writes encrypted snapshots to
`/mnt/sealed-data/backups/indexer.<date>.sqlite.age` and prunes older than
30 days. Restore: `pi-gateway/scripts/restore.sh <snapshot>`.

## Restore drill

Run quarterly. Brings up a throwaway indexer from a snapshot, verifies the
`users` and `legacy_directory` tables load, then tears it down.

```bash
sudo /usr/local/bin/sealed-restore-drill
```

## Recovery scenarios

- **Pi reboots**: docker compose restart policy (`unless-stopped`) brings
  containers back. Tailscale persists. Funnel persists. No manual action.
- **SSD failure**: replace SSD, restore most recent backup, redeploy
  secrets. Tailscale node identity survives if `/var/lib/tailscale` is on
  a different volume; otherwise re-auth with new key.
- **Pi itself dies**: provision new Pi, re-run this runbook from step 1.
  Same Tailscale hostname → same Funnel URL → no client config change.
- **Gateway HPKE key loss** (no backup of seed): clients with cached key
  config will fail until the indexer's signed config endpoint serves the
  new key and the app re-fetches. Plan a key rotation instead — never let
  the key just disappear.

## What this directory does NOT contain

- The compose file for the indexer + gateway — see
  `sealed-indexer/docker/docker-compose.yml.example`.
- Secrets — those live at `/mnt/sealed-data/secrets/` on the Pi only,
  pushed via `scripts/deploy_secrets_to_pi.sh`.
- The indexer source — see `sealed-indexer/`.
