#!/usr/bin/env bash
# Capture a screenshot of the currently-booted iOS simulator for design handoff.
#
# Usage:
#   ./scripts/capture_screen.sh <screen-name> [state]
#
# Examples:
#   ./scripts/capture_screen.sh splash
#   ./scripts/capture_screen.sh chat_list empty
#   ./scripts/capture_screen.sh chat_list populated
#
# Output: design-handoff/screenshots/<screen-name>[-<state>].png
#
# Requirements:
#   - iPhone 17 Pro simulator booted (run `xcrun simctl boot "iPhone 17 Pro"` first)
#   - App running on the simulator, navigated to the target screen
#
# iPhone 17 Pro native resolution: 1206 x 2622 px (402 x 874 pt @ 3x)
# The PNG is captured at native resolution; Figma import preserves pixel dims.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <screen-name> [state]" >&2
  echo "Example: $0 chat_list populated" >&2
  exit 1
fi

SCREEN="$1"
STATE="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../design-handoff/screenshots"
mkdir -p "$OUT_DIR"

if [[ -n "$STATE" ]]; then
  OUT_FILE="$OUT_DIR/${SCREEN}-${STATE}.png"
else
  OUT_FILE="$OUT_DIR/${SCREEN}.png"
fi

# Verify a simulator is booted
if ! xcrun simctl list devices booted | grep -q "Booted"; then
  echo "Error: no iOS simulator is booted." >&2
  echo "Boot one with: xcrun simctl boot \"iPhone 17 Pro\" && open -a Simulator" >&2
  exit 1
fi

xcrun simctl io booted screenshot "$OUT_FILE"
echo "Saved: $OUT_FILE"
