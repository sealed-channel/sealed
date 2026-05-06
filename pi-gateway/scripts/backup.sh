#!/usr/bin/env bash
#
# backup.sh — nightly snapshot of the indexer sqlite db, age-encrypted, to
# the local USB volume. Runs from cron on the Pi:
#
#   7 4 * * *  /usr/local/bin/sealed-backup >> /var/log/sealed-backup.log 2>&1
#
# Encryption: age (https://age-encryption.org/) — single recipient,
# operator's key. Generate the key once with `age-keygen -o /mnt/sealed-data/secrets/backup.key`
# and put the matching public key in BACKUP_RECIPIENT below (or in an env
# var sourced before this script runs).
#
# Retention: keep last 30 nightly + last 4 weekly (Sunday).

set -euo pipefail

DB_SRC="${DB_SRC:-/mnt/sealed-data/indexer/indexer.sqlite}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/sealed-data/backups}"
BACKUP_RECIPIENT="${BACKUP_RECIPIENT:-}"  # age public key, e.g. age1xxxx...

if [[ -z "$BACKUP_RECIPIENT" ]]; then
    echo "ERROR: BACKUP_RECIPIENT env var not set; refusing to write plaintext backup" >&2
    exit 2
fi

if [[ ! -f "$DB_SRC" ]]; then
    echo "ERROR: source DB not found at $DB_SRC" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

DATE=$(date +%Y%m%d-%H%M%S)
DOW=$(date +%u)  # 1=Mon..7=Sun

# Use sqlite's online .backup so we don't lock writers.
SNAPSHOT_TMP=$(mktemp /tmp/indexer-snapshot.XXXXXX.sqlite)
trap 'rm -f "$SNAPSHOT_TMP" "$SNAPSHOT_TMP.age"' EXIT

sqlite3 "$DB_SRC" ".backup '$SNAPSHOT_TMP'"

OUT="$BACKUP_DIR/indexer.$DATE.sqlite.age"
age -r "$BACKUP_RECIPIENT" -o "$OUT" "$SNAPSHOT_TMP"
chmod 600 "$OUT"

echo "[$(date -Iseconds)] backup ok: $OUT ($(stat -c %s "$OUT") bytes)"

# Weekly snapshot: keep one age file dated Sunday, longer retention.
if [[ "$DOW" == "7" ]]; then
    WEEKLY="$BACKUP_DIR/weekly/indexer.$DATE.sqlite.age"
    mkdir -p "$BACKUP_DIR/weekly"
    cp "$OUT" "$WEEKLY"
    echo "[$(date -Iseconds)] weekly snapshot: $WEEKLY"
fi

# Prune
find "$BACKUP_DIR" -maxdepth 1 -name "indexer.*.sqlite.age" -mtime +30 -delete
find "$BACKUP_DIR/weekly" -maxdepth 1 -name "indexer.*.sqlite.age" -mtime +28 -delete 2>/dev/null || true
