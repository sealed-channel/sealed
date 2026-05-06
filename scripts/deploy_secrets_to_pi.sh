#!/usr/bin/env bash
#
# deploy_secrets_to_pi.sh — push gitignored secrets + infra config to the indexer Pi.
#
# Secrets are intentionally NOT in any git repo (public or private). This script
# is the only sanctioned transport. It rsyncs:
#
#   sealed-indexer/apns_keys/         → $REMOTE_SECRETS/apns_keys/
#   sealed-indexer/admin-account.json → $REMOTE_SECRETS/admin-account.json
#   sealed-indexer/.env               → $REMOTE_SECRETS/.env
#   sealed-indexer/docker/docker-compose.yml → $REMOTE_DEPLOY/docker-compose.yml
#
# On the Pi, docker-compose.yml mounts $REMOTE_SECRETS read-only into the
# indexer container. See sealed-indexer/docker/docker-compose.yml.example.
#
# Layout on the Pi:
#   /mnt/sealed-data/secrets/                          ← apns_keys/, admin-account.json, .env  (700)
#   /home/ify_move/sealed/sealed-indexer/docker/   ← docker-compose.yml             (755)
#
# The deploy dir lives *inside* a clone of the repo because docker-compose.yml's
# `build.context: ..` requires the parent directory to contain the indexer
# source (package.json, src/, scripts/, Dockerfile). Clone the repo on the Pi
# to /home/ify_move/sealed before first deploy:
#
#   ssh ify_move@<pi> 'git clone <repo-url> ~/sealed'
#
# Usage:
#   ./scripts/deploy_secrets_to_pi.sh                       # uses defaults below
#   PI_HOST=pi@1.2.3.4 ./scripts/deploy_secrets_to_pi.sh
#   ./scripts/deploy_secrets_to_pi.sh --dry-run             # show what would change
#   ./scripts/deploy_secrets_to_pi.sh --restart             # also `docker compose up -d` after sync
#
# Idempotent. Safe to re-run after rotating a key or editing the compose file.

set -euo pipefail

# ---- Config (override via env) ----------------------------------------------
PI_HOST="${PI_HOST:-pi@sealed-pi.local}"
REMOTE_SECRETS="${REMOTE_SECRETS:-/mnt/sealed-data/secrets}"
REMOTE_DEPLOY="${REMOTE_DEPLOY:-/home/ify_move/sealed/sealed-indexer/docker}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INDEXER_DIR="$REPO_ROOT/sealed-indexer"

DRY_RUN=""
RESTART=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="--dry-run"; echo "🌵 DRY RUN — nothing will actually be copied" ;;
        --restart) RESTART=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ---- Pre-flight -------------------------------------------------------------
echo "🔐 Sealed deploy → Pi"
echo "  source:  $INDEXER_DIR"
echo "  secrets: $PI_HOST:$REMOTE_SECRETS"
echo "  deploy:  $PI_HOST:$REMOTE_DEPLOY"
echo ""

# Verify all expected files exist locally before we ssh anywhere.
required=(
    "$INDEXER_DIR/apns_keys/prod.p8"
    "$INDEXER_DIR/apns_keys/dev.p8"
    "$INDEXER_DIR/admin-account.json"
    "$INDEXER_DIR/.env"
    "$INDEXER_DIR/docker/docker-compose.yml"
)
missing=0
for f in "${required[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "  ❌ missing: $f"
        missing=1
    fi
done
if [[ $missing -eq 1 ]]; then
    echo ""
    echo "Refusing to deploy with missing files. Populate them locally first."
    echo "(For first-time setup, copy *.example variants and fill them in.)"
    exit 1
fi

# Sanity: never let a .p8 / .env / service-account JSON ship with loose perms.
chmod 600 "$INDEXER_DIR/apns_keys/"*.p8 2>/dev/null || true
chmod 600 "$INDEXER_DIR/admin-account.json" 2>/dev/null || true
chmod 600 "$INDEXER_DIR/.env" 2>/dev/null || true

# Refuse to ship a docker-compose.yml that still mounts from the *repo* paths
# (`../apns_keys`, `../admin-account.json`). That layout only works when the Pi
# also has the gitignored secrets co-located in the source tree, which it
# shouldn't under this deployment model.
if grep -qE '^\s*-\s*"\.\./apns_keys' "$INDEXER_DIR/docker/docker-compose.yml" \
   || grep -qE '^\s*-\s*"\.\./admin-account\.json' "$INDEXER_DIR/docker/docker-compose.yml"; then
    echo "  ❌ docker-compose.yml mounts secrets from ../ (repo-relative paths)."
    echo "     It must mount from \${SECRETS_ROOT:-$REMOTE_SECRETS} instead."
    echo "     See docker-compose.yml.example for the correct pattern."
    exit 1
fi

# ---- Ensure target dirs exist on Pi -----------------------------------------
echo "📁 Ensuring $REMOTE_SECRETS and $REMOTE_DEPLOY exist on Pi..."
ssh -i "$SSH_KEY" "$PI_HOST" "
    set -e

    # Secrets dir lives outside any home — needs sudo to create the first time.
    if [ ! -d '$REMOTE_SECRETS' ]; then
        sudo mkdir -p '$REMOTE_SECRETS/apns_keys'
        sudo chown -R \$(id -u):\$(id -g) '$REMOTE_SECRETS'
    fi
    chmod 700 '$REMOTE_SECRETS' '$REMOTE_SECRETS/apns_keys'

    # Deploy dir lives inside the cloned repo. We do NOT auto-create the
    # parent — if it doesn't exist, you haven't cloned the repo on the Pi yet.
    deploy_parent=\"\$(dirname '$REMOTE_DEPLOY')\"
    if [ ! -d \"\$deploy_parent\" ]; then
        echo \"❌ Parent dir \$deploy_parent does not exist on Pi.\" >&2
        echo \"   Clone the repo first, e.g.:\" >&2
        echo \"     git clone <repo-url> ~/sealed\" >&2
        exit 1
    fi
    mkdir -p '$REMOTE_DEPLOY'
    chmod 755 '$REMOTE_DEPLOY'
"

# ---- Rsync ------------------------------------------------------------------
# --chmod forces tight perms on the receiving side regardless of local perms.
RSYNC_SECRETS_OPTS=(
    -avz $DRY_RUN
    -e "ssh -i $SSH_KEY"
    --chmod=F600,D700
)
RSYNC_DEPLOY_OPTS=(
    -avz $DRY_RUN
    -e "ssh -i $SSH_KEY"
    --chmod=F644,D755
)

echo "📦 Syncing apns_keys/ ..."
rsync "${RSYNC_SECRETS_OPTS[@]}" --delete \
    "$INDEXER_DIR/apns_keys/" \
    "$PI_HOST:$REMOTE_SECRETS/apns_keys/"

echo "📦 Syncing admin-account.json ..."
rsync "${RSYNC_SECRETS_OPTS[@]}" \
    "$INDEXER_DIR/admin-account.json" \
    "$PI_HOST:$REMOTE_SECRETS/admin-account.json"

echo "📦 Syncing .env ..."
rsync "${RSYNC_SECRETS_OPTS[@]}" \
    "$INDEXER_DIR/.env" \
    "$PI_HOST:$REMOTE_SECRETS/.env"

echo "📦 Syncing docker-compose.yml ..."
rsync "${RSYNC_DEPLOY_OPTS[@]}" \
    "$INDEXER_DIR/docker/docker-compose.yml" \
    "$PI_HOST:$REMOTE_DEPLOY/docker-compose.yml"

if [[ -n "$DRY_RUN" ]]; then
    echo ""
    echo "🌵 dry run done — re-run without --dry-run to actually deploy"
    exit 0
fi

# ---- Verify on Pi -----------------------------------------------------------
echo ""
echo "🔍 Verifying on Pi..."
ssh -i "$SSH_KEY" "$PI_HOST" "
    echo '--- $REMOTE_SECRETS ---'
    ls -la '$REMOTE_SECRETS' '$REMOTE_SECRETS/apns_keys'
    echo '--- $REMOTE_DEPLOY ---'
    ls -la '$REMOTE_DEPLOY'
"

# ---- Optional: restart the stack --------------------------------------------
if [[ $RESTART -eq 1 ]]; then
    echo ""
    echo "🔄 Restarting docker compose stack..."
    ssh -i "$SSH_KEY" "$PI_HOST" "
        set -e
        cd '$REMOTE_DEPLOY'
        docker compose pull || true
        docker compose up -d
        docker compose ps
    "
fi

echo ""
echo "✅ Deploy complete."
if [[ $RESTART -eq 0 ]]; then
    echo ""
    echo "To apply changes, restart the indexer:"
    echo "  ssh $PI_HOST 'cd $REMOTE_DEPLOY && docker compose up -d'"
    echo "Or re-run with --restart next time."
fi
