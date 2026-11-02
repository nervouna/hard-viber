# Quota

macOS menu bar app (Swift/SwiftUI + AppKit) plus a Node 24 collector. See README.md for what it does and where its data comes from.

## Commands

- Build: `bash scripts/build.sh` → `build/Quota.app` (about 25 s). It signs ad hoc; `CODESIGN_IDENTITY="Developer ID Application: …"` signs with the hardened runtime and a secure timestamp for notarization.
- Test: `scripts/test.sh` runs the Node suites and `swift test`, and exits non-zero on any failure. Run it before committing. `swift build` / `swift test` work on their own; `scripts/test.sh <dir>` (or `QUOTA_IMAGE_FIXTURES=<dir> swift test`) also writes the shareable image fixtures.
- Release: `scripts/release.sh` tests, builds with Developer ID, notarizes, staples, archives to `build/release/` and installs into `~/Applications`. It reads `~/.config/quota/signing.env` (README.md › Release), needs a clean tree, and uploads to Apple, so run it only when the user asks for a release.
- Run: `open build/Quota.app --args --show`. The user's own copy may be running from `~/Applications/Quota.app`; both share the cache in `~/Library/Application Support/Quota/` and the log in `~/Library/Logs/Quota/`.

## Conventions

- A Swift package in the Swift 6 language mode, no Xcode project: the `QuotaKit` library (`Sources/QuotaKit/`) holds the logic and views and stays `internal` except the entry point (`QuotaApp.run`, `AppResources`); the `Quota` executable (`Sources/Quota/main.swift`) only starts it. Tests in `Tests/QuotaKitTests/` use Swift Testing with `@testable import QuotaKit`.
- `build.sh` assembles `build/Quota.app` around the `swift build -c release` binary and copies the files the app reads into `Contents/Resources`. The app finds them through `AppResources`, injected into `UsageStore` and `QuotaImageExporter`; tests point it at the repository (`Tests/QuotaKitTests/Fixtures.swift`). Never read them through `Bundle.main` or `#filePath` in `QuotaKit`: in `swift test`, `Bundle.main` is the test runner.
- `scripts/subscriptions.json` is the only list of rows and their display labels. The collector and the app both read it; never hard-code row ids, names or plans in Swift or JS.
- Row `status` is `Quota.Status`, written as the collector's strings: `ready`, `unavailable`, `missing` (no candidate executable exists: hidden, `checkedPaths` listed under 诊断) or `disabled` (turned off in `config.json`: hidden at once). An unknown string decodes as `unavailable`. `Quota.group(at:)` returns `Quota.Group` (`available`, `exhausted`, `unconfirmed`), declared in list order. Collector errors read `<Provider> <stage>: <detail>`; README.md lists the stages.
- Tool locations and settings come from `~/Library/Application Support/Quota/config.json` (README.md › Configuration). The collector validates it; the app reads only `node`. Without it, tools are searched, never assumed at one path. An app opened from Finder or at login gets neither the shell's `PATH` nor its exported variables, so test discovery with `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin node scripts/collect-usage.mjs`.
- A run covers a set of providers (`--providers`); merges and failures touch only those rows. `RefreshPolicy` decides when each provider refreshes; changing an interval also changes how often rows are past their freshness window when the list opens, which the refreshing state covers.
- `VERSION` is the only version number: `build.sh` feeds `Info.plist`, the collector sends it as `clientInfo.version`.
- Keep the merge rules in `Quota`/`UsageReport` and `RefreshPolicy` pure functions; tests must not create `UsageStore`, which reads the real cache.
- UI text is Chinese. Code, comments, docs and commit messages are English.
