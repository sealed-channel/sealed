#!/usr/bin/env bash
# Copy SNARK redeem artifacts from circuits/ into the Flutter asset bundle.
#
# Run before `flutter build` or `flutter test --integration` whenever the
# zkey/wasm change. The targets are .gitignored — they live canonically
# under circuits/.
#
# Usage:
#   ./tool/copy-snark-assets.sh           # dev artifacts
#   SNARK_PROFILE=prod ./tool/copy-snark-assets.sh   # post-ceremony
#
# Wired in CI via the build job's pre-step; locally, Flutter's asset
# pipeline will fail with "asset not found" if you skip it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CIRCUITS_DIR="$REPO_ROOT/circuits"
DEST_DIR="$ROOT_DIR/assets/snark"

profile="${SNARK_PROFILE:-dev}"
case "$profile" in
  dev)  zkey_src="$CIRCUITS_DIR/keys/redeem_dev.zkey" ;;
  prod) zkey_src="$CIRCUITS_DIR/keys/redeem_prod.zkey" ;;
  *) echo "unknown SNARK_PROFILE=$profile (want dev|prod)"; exit 2 ;;
esac
wasm_src="$CIRCUITS_DIR/build/redeem_js/redeem.wasm"

for src in "$zkey_src" "$wasm_src"; do
  if [ ! -f "$src" ]; then
    echo "missing artifact: $src" >&2
    echo "build it from circuits/ first" >&2
    exit 1
  fi
done

mkdir -p "$DEST_DIR"
cp "$zkey_src" "$DEST_DIR/redeem_dev.zkey"
cp "$wasm_src" "$DEST_DIR/redeem.wasm"

echo "copied SNARK assets (profile=$profile) → $DEST_DIR"
