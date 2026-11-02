#!/bin/bash
# Runs every test suite and the Swift 6 typecheck. Pass a directory to also write
# the shareable image fixtures there.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# The app runs the collector with Homebrew's node@24; the probe needs zlib zstd support.
node=""
for candidate in /opt/homebrew/opt/node@24/bin/node /usr/local/opt/node@24/bin/node; do
  if [ -x "$candidate" ]; then node="$candidate"; break; fi
done
node="${node:-$(command -v node)}"

"$node" "$project_dir/scripts/test-usage.mjs"
"$node" "$project_dir/scripts/test-claude-cache-probe.mjs"

swift_flags=(-module-cache-path "$work_dir/module-cache")
xcrun swiftc -swift-version 5 -D TESTING "${swift_flags[@]}" \
  "$project_dir"/Sources/*.swift "$project_dir/Tests/QuotaTests.swift" -o "$work_dir/QuotaTests"
"$work_dir/QuotaTests"
xcrun swiftc -swift-version 5 -D TESTING "${swift_flags[@]}" \
  "$project_dir"/Sources/*.swift "$project_dir/Tests/QuotaImageTests.swift" -o "$work_dir/QuotaImageTests"
"$work_dir/QuotaImageTests" "$@"

xcrun swiftc -swift-version 6 -parse-as-library -typecheck "${swift_flags[@]}" "$project_dir"/Sources/*.swift
echo "Swift 6 typecheck passed."
