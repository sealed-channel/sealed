#!/usr/bin/env bash
#
# restore.sh — restore an age-encrypted sqlite snapshot back into place.
# Stops the indexer container first to avoid corruption.
#
# Usage:
#   sudo restore.sh /mnt/sealed-data/backups/indexer.20260505-040701.sqlite.age
#
# The age private key is read from $BACKUP_KEY (defaults to
# /mnt/sealed-data/secrets/backup.key, perms 600).

set -euo pipefail

SNAPSHOT="${1:-}"
BACKUP_KEY="${BACKUP_KEY:-/mnt/sealed-data/secrets/backup.key}"
DB_DST="${DB_DST:-/mnt/sealed-data/indexer/indexer.sqlite}"
COMPOSE_DIR="${COMPOSE_DIR:-/home/ify_move/sealed/sealed-indexer/docker}"

if [[ -z "$SNAPSHOT" ]]; then
    echo "Usage: $0 <snapshot.age>" >&2
    exit 2
fi
if [[ ! -f "$SNAPSHOT" ]]; then
    echo "ERROR: snapshot not found: $SNAPSHOT" >&2
    exit 1
fi
if [[ ! -f "$BACKUP_KEY" ]]; then
    echo "ERROR: age private key not found at $BACKUP_KEY" >&2
    exit 1
fi

echo "🛑 Stopping indexer container..."
(cd "$COMPOSE_DIR" && docker compose stop sealed-indexer)

echo "💾 Backing up current DB to $DB_DST.before-restore..."
if [[ -f "$DB_DST" ]]; then
    cp "$DB_DST" "$DB_DST.before-restore.$(date +%Y%m%d-%H%M%S)"
fi

echo "🔓 Decrypting + restoring $SNAPSHOT..."
age -d -i "$BACKUP_KEY" "$SNAPSHOT" > "$DB_DST"
chmod 644 "$DB_DST"

# Sanity check
sqlite3 "$DB_DST" 'PRAGMA integrity_check;'
sqlite3 "$DB_DST" 'SELECT COUNT(*) AS user_count FROM users;'

echo "🚀 Starting indexer..."
(cd "$COMPOSE_DIR" && docker compose start sealed-indexer)
sleep 2
docker logs --tail 20 sealed-indexer

echo "✅ Restore complete."
