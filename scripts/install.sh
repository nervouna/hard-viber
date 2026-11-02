#!/bin/bash
set -euo pipefail

# The login item records the app's path, so install to a location that outlives worktrees and rebuilds.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
target="$HOME/Applications/Quota.app"

bash "$project_dir/scripts/build.sh" >/dev/null

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
ditto "$project_dir/build/Quota.app" "$target"
open "$target"
printf '%s\n' "$target"
