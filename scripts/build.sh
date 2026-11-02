#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Quota.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/build/module-cache"
# VERSION is the only version number; the build number counts commits, so it only grows.
version="$(tr -d '[:space:]' < "$project_dir/VERSION")"
build="$(git -C "$project_dir" rev-list --count HEAD 2>/dev/null || echo 0)"

xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$project_dir/build/module-cache" \
  "$project_dir"/Sources/*.swift \
  -o "$app_dir/Contents/MacOS/Quota"

cp "$project_dir/scripts/collect-usage.mjs" "$project_dir/scripts/claude-cache-probe.mjs" "$project_dir/scripts/subscriptions.json" \
  "$project_dir/VERSION" "$app_dir/Contents/Resources/"
cp "$project_dir/Assets/UsageImage/SharePaper.png" "$project_dir/Assets/UsageImage/ShareMascot.png" "$app_dir/Contents/Resources/"
xcrun actool "$project_dir/Assets/Icon/Quota.icon" "$project_dir/Assets/MenuBar.xcassets" \
  --compile "$app_dir/Contents/Resources" \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon Quota --output-partial-info-plist "$project_dir/build/icon-info.plist" \
  --output-format human-readable-text --warnings --errors

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Quota</string>
  <key>CFBundleIdentifier</key><string>com.nervouna.quota</string>
  <key>CFBundleName</key><string>Quota</string>
  <key>CFBundleDisplayName</key><string>Quota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/libexec/PlistBuddy -c "Merge $project_dir/build/icon-info.plist" "$app_dir/Contents/Info.plist"

codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
