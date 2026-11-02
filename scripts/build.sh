#!/bin/bash
# Builds the Swift package and assembles build/Quota.app around the release binary.
# CODESIGN_IDENTITY names a signing identity, such as "Developer ID Application: …"; with one the app
# is signed with the hardened runtime and a secure timestamp, ready to notarize. Without it the
# app is signed ad hoc.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Quota.app"
identity="${CODESIGN_IDENTITY:--}"
# VERSION is the only version number; the build number counts commits, so it only grows.
version="$(tr -d '[:space:]' < "$project_dir/VERSION")"
build="$(git -C "$project_dir" rev-list --count HEAD 2>/dev/null || echo 0)"

swift build -c release --package-path "$project_dir" --product Quota
bin_dir="$(swift build -c release --package-path "$project_dir" --show-bin-path)"

# Start from an empty bundle, so no file of an earlier build gets signed into this one.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Quota" "$app_dir/Contents/MacOS/Quota"
# AppResources reads these from Contents/Resources; the collector finds subscriptions.json and VERSION next to itself.
cp "$project_dir/scripts/collect-usage.mjs" "$project_dir/scripts/claude-cache-probe.mjs" "$project_dir/scripts/subscriptions.json" \
  "$project_dir/VERSION" "$app_dir/Contents/Resources/"
cp "$project_dir/Assets/UsageImage/ShareMascot.png" "$app_dir/Contents/Resources/"
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

# Signing without --entitlements leaves none, so the app never carries get-task-allow.
if [ "$identity" = "-" ]; then
  codesign --force --sign - "$app_dir"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app_dir"
fi
printf '%s\n' "$app_dir"
