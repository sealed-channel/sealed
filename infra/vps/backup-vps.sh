#!/usr/bin/env bash
#
# backup-vps.sh — nightly age-encrypted snapshots on the Hetzner VPS.
#
# Extends pi-gateway/scripts/backup.sh to cover everything on the box:
#   - indexer.sqlite           (push registrations, watcher cursors)
#   - preimage-server.sqlite   (UNSOLD CODE INVENTORY — this is money)
#   - waitlist.sqlite          (LP waitlist)
#   - LP Postgres              (b2b/b2c/contact forms, via pg_dump)
# plus optional offsite rsync to a Hetzner Storage Box.
#
# Cron (as the sealed user):
#   17 4 * * *  BACKUP_RECIPIENT=age17p2tq04uh04kkey73y050xcah2s93swv70fs4ytrmgzl5gfqdsjqkp2yv9 /home/sealed/sealed/infra/vps/backup-vps.sh >> /var/log/sealed-backup.log 2>&1
#
# Generate the age keypair on your LOCAL machine (age-keygen); only the public
# key (BACKUP_RECIPIENT) belongs on the VPS. Retention: 30 nightly + 4 weekly.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/mnt/sealed-data/backups}"
BACKUP_RECIPIENT="${BACKUP_RECIPIENT:-}"          # age public key
INDEXER_DB="${INDEXER_DB:-/mnt/sealed-data/indexer/indexer.sqlite}"
PREIMAGE_DB="${PREIMAGE_DB:-/mnt/sealed-data/indexer/preimage-server.sqlite}"
WAITLIST_DB="${WAITLIST_DB:-/mnt/sealed-data/lp-data/waitlist.sqlite}"
PG_CONTAINER="${PG_CONTAINER:-lp-postgres}"
# Offsite (optional): Hetzner Storage Box, e.g. u123456@u123456.your-storagebox.de:backups
OFFSITE_DEST="${OFFSITE_DEST:-}"
OFFSITE_SSH_KEY="${OFFSITE_SSH_KEY:-$HOME/.ssh/id_ed25519_backup}"

if [[ -z "$BACKUP_RECIPIENT" ]]; then
    echo "ERROR: BACKUP_RECIPIENT not set; refusing to write plaintext backups" >&2
    exit 2
fi

mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
DATE=$(date +%Y%m%d-%H%M%S)
DOW=$(date +%u)
TMP=$(mktemp -d /tmp/sealed-backup.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

snapshot_sqlite() { # src label
    local src="$1" label="$2"
    if [[ ! -f "$src" ]]; then
        echo "[$(date -Iseconds)] skip $label: $src not found"
        return 0
    fi
    sqlite3 "$src" ".backup '$TMP/$label.sqlite'"
    age -r "$BACKUP_RECIPIENT" -o "$BACKUP_DIR/$label.$DATE.sqlite.age" "$TMP/$label.sqlite"
    chmod 600 "$BACKUP_DIR/$label.$DATE.sqlite.age"
    echo "[$(date -Iseconds)] backup ok: $label.$DATE.sqlite.age"
}

snapshot_sqlite "$INDEXER_DB"  indexer
snapshot_sqlite "$PREIMAGE_DB" preimage
snapshot_sqlite "$WAITLIST_DB" waitlist

# LP Postgres — pg_dump inside the container; skip silently if LP stack absent.
if docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    docker exec "$PG_CONTAINER" pg_dump -U lp -d lp --format=custom > "$TMP/lp-pg.dump"
    age -r "$BACKUP_RECIPIENT" -o "$BACKUP_DIR/lp-pg.$DATE.dump.age" "$TMP/lp-pg.dump"
    chmod 600 "$BACKUP_DIR/lp-pg.$DATE.dump.age"
    echo "[$(date -Iseconds)] backup ok: lp-pg.$DATE.dump.age"
else
    echo "[$(date -Iseconds)] skip lp-pg: container $PG_CONTAINER not running"
fi

# Weekly copies (Sunday), longer retention.
if [[ "$DOW" == "7" ]]; then
    mkdir -p "$BACKUP_DIR/weekly"
    cp "$BACKUP_DIR"/*."$DATE".*.age "$BACKUP_DIR/weekly/" 2>/dev/null || true
    echo "[$(date -Iseconds)] weekly snapshots copied"
fi

# Prune: 30 days nightly, 28 days weekly (weekly survives via fewer files/day).
find "$BACKUP_DIR" -maxdepth 1 -name "*.age" -mtime +30 -delete
find "$BACKUP_DIR/weekly" -maxdepth 1 -name "*.age" -mtime +28 -delete 2>/dev/null || true

# Offsite sync (encrypted blobs only — Storage Box never sees plaintext).
if [[ -n "$OFFSITE_DEST" ]]; then
    rsync -az -e "ssh -i $OFFSITE_SSH_KEY -p 23" "$BACKUP_DIR/" "$OFFSITE_DEST/"
    echo "[$(date -Iseconds)] offsite sync ok: $OFFSITE_DEST"
fi
