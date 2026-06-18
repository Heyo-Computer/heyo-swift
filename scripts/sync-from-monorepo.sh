#!/bin/bash
# Mirror the HeyoSDK package from the heyo monorepo's `sdk-swift/` into this
# standalone distribution repo. Only the package sources are synced — repo-local
# files (README, LICENSE, CHANGELOG, .github, scripts) are preserved.
#
# Usage:
#   scripts/sync-from-monorepo.sh [--commit]
#   HEYO_MONOREPO=/path/to/heyo scripts/sync-from-monorepo.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MONOREPO="${HEYO_MONOREPO:-$(cd "$HERE/../heyo" 2>/dev/null && pwd || true)}"
SRC="$MONOREPO/sdk-swift"

if [ ! -f "$SRC/Package.swift" ]; then
  echo "error: could not find the SDK at '$SRC'." >&2
  echo "       set HEYO_MONOREPO to your heyo monorepo checkout." >&2
  exit 1
fi

echo "Syncing HeyoSDK from $SRC"
rsync -a --delete "$SRC/Sources/" "$HERE/Sources/"
rsync -a --delete "$SRC/Tests/"   "$HERE/Tests/"
cp "$SRC/Package.swift" "$HERE/Package.swift"
cp "$SRC/.gitignore"    "$HERE/.gitignore"

SRC_SHA="$(git -C "$MONOREPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "Synced from heyo@$SRC_SHA"

if [ "${1:-}" = "--commit" ]; then
  git -C "$HERE" add -A Sources Tests Package.swift .gitignore
  if git -C "$HERE" diff --cached --quiet; then
    echo "No changes to commit."
  else
    git -C "$HERE" commit -m "Sync HeyoSDK from heyo@$SRC_SHA"
    echo "Committed."
  fi
else
  echo "Review changes, then commit. (Re-run with --commit to auto-commit.)"
fi
