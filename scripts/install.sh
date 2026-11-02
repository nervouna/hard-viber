#!/bin/bash
# Usage: scripts/install.sh [app]
# Without an argument it builds build/Quota.app first (CODESIGN_IDENTITY passes through to build.sh);
# with one it installs that bundle, as scripts/release.sh does with the notarized build.
set -euo pipefail

# The login item records the app's path, so install to a location that outlives worktrees and rebuilds.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
target="$HOME/Applications/Quota.app"

app="${1:-}"
if [ -z "$app" ]; then
  bash "$project_dir/scripts/build.sh" >/dev/null
  app="$project_dir/build/Quota.app"
fi
[ -d "$app/Contents/MacOS" ] || { echo "No app bundle at $app" >&2; exit 1; }

if pgrep -x Quota >/dev/null; then
  pkill -x Quota
  for _ in {1..50}; do
    pgrep -x Quota >/dev/null || break
    sleep 0.1
  done
  if pgrep -x Quota >/dev/null; then
    echo "Quota did not quit" >&2
    exit 1
  fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$target"
ditto "$app" "$target"
open "$target"
printf '%s\n' "$target"
