#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Quota.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/build/module-cache"

xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$project_dir/build/module-cache" \
  "$project_dir"/Sources/*.swift \
  -o "$app_dir/Contents/MacOS/Quota"

cp "$project_dir/scripts/collect-usage.mjs" "$project_dir/scripts/claude-cache-probe.mjs" "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Quota</string>
  <key>CFBundleIdentifier</key><string>com.nervouna.quota</string>
  <key>CFBundleName</key><string>Quota</string>
  <key>CFBundleDisplayName</key><string>Quota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.9</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
