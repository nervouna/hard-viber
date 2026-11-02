# Quota

macOS menu bar app (Swift/SwiftUI + AppKit) plus a Node 24 collector. See README.md for what it does and where its data comes from.

## Commands

- Build: `bash scripts/build.sh` → `build/Quota.app` (about 25 s).
- Test: `scripts/test.sh` runs every suite and the Swift 6 strict-concurrency typecheck, and exits non-zero on any failure. Run it before committing.
- Run: `open build/Quota.app --args --show`. The user's own copy may be running from `~/Applications/Quota.app`; both share the cache in `~/Library/Application Support/Quota/` and the log in `~/Library/Logs/Quota/`.

## Conventions

- No Xcode project or Swift package: `swiftc` compiles `Sources/*.swift` together, so a new source file is picked up by the build, the tests and the typecheck. Tests compile the same sources with `-D TESTING` and check with `precondition`.
- `scripts/subscriptions.json` is the only list of rows and their display labels. The collector and the app both read it; never hard-code row ids, names or plans in Swift or JS.
- Row `status` is `"ready"`, `"unavailable"`, `"missing"` (no candidate executable exists: hidden, `checkedPaths` listed under 诊断) or `"disabled"` (turned off in `config.json`: hidden at once). Collector errors read `<Provider> <stage>: <detail>`; README.md lists the stages.
- Tool locations and settings come from `~/Library/Application Support/Quota/config.json` (README.md › Configuration). The collector validates it; the app reads only `node`. Without it, tools are searched, never assumed at one path. An app opened from Finder or at login gets neither the shell's `PATH` nor its exported variables, so test discovery with `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin node scripts/collect-usage.mjs`.
- A run covers a set of providers (`--providers`); merges and failures touch only those rows. `RefreshPolicy` decides when each provider refreshes; changing an interval also changes how often rows are past their freshness window when the list opens, which the refreshing state covers.
- `VERSION` is the only version number: `build.sh` feeds `Info.plist`, the collector sends it as `clientInfo.version`.
- Keep the merge rules in `Quota`/`UsageReport` and `RefreshPolicy` pure functions; tests must not create `UsageStore`, which reads the real cache.
- UI text is Chinese. Code, comments, docs and commit messages are English.
