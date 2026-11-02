#!/bin/bash
# Runs the Node suites and the Swift package's tests. Pass a directory to also write the shareable
# image fixtures there.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"

# The app runs the collector with Homebrew's node@24; the probe needs zlib zstd support.
node=""
for candidate in /opt/homebrew/opt/node@24/bin/node /usr/local/opt/node@24/bin/node; do
  if [ -x "$candidate" ]; then node="$candidate"; break; fi
done
node="${node:-$(command -v node)}"

"$node" "$project_dir/scripts/test-usage.mjs"
"$node" "$project_dir/scripts/test-claude-cache-probe.mjs"

fixtures=""
if [ $# -gt 0 ]; then fixtures="$(mkdir -p "$1" && cd "$1" && pwd)"; fi
# The package builds in the Swift 6 language mode, so the tests also check strict concurrency.
QUOTA_IMAGE_FIXTURES="$fixtures" swift test --package-path "$project_dir"
