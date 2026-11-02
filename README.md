# Quota

Quota is a macOS menu bar app that shows how much of each AI subscription's quota is left: Claude, OpenAI (Codex), Antigravity (two pools), Kiro and Grok. Click the menu bar icon for the list. Click the list (or press ⌘C) to copy a shareable PNG of it.

It is a personal tool: provider paths and plan labels match one Mac's setup.

## Requirements

- macOS 14 or later.
- Xcode 26 or later. `scripts/build.sh` uses `swiftc` and `actool`, and the app icon is an Icon Composer document.
- Homebrew `node@24` at `/opt/homebrew/opt/node@24` or `/usr/local/opt/node@24`. The app runs its collector with this Node.
- The tools of the providers you use (see [Data sources](#data-sources)). Providers whose tool is not installed are hidden.

## Build, test, run

```bash
bash scripts/build.sh          # builds build/Quota.app (about 25 s)
scripts/test.sh                # all test suites and the Swift 6 typecheck
scripts/test.sh /tmp/quota     # also writes the shareable image fixtures there
open build/Quota.app --args --show   # --show opens the list at launch
node scripts/collect-usage.mjs       # the collector on its own; prints JSON, logs to stderr
```

There is no Xcode project or Swift package: `swiftc` compiles `Sources/*.swift` into one binary, and `build.sh` copies the collector scripts, `scripts/subscriptions.json` and the image artwork into the bundle. To install, copy `build/Quota.app` to `~/Applications`.

## How it works

`Sources/Quota.swift` runs `scripts/collect-usage.mjs` every 5 minutes, after the Mac wakes, and when the list opens (at most once a minute). The collector queries all providers in parallel (25 s limit each; the app stops the whole run after 35 s) and prints one JSON report.

`scripts/subscriptions.json` lists the rows: id, provider, display name, billing cycle, and optional plan, short plan label and bucket. The collector and the app both read it, so it is the only place to add, remove or rename a row.

The app merges the report row by row:

- A successful row replaces the old one.
- A failed row keeps its last good value and records the error. It stays current until the freshness window passes (15 minutes; 30 minutes for Claude, whose cache only updates while Claude Desktop runs), then turns grey and moves to the bottom group.
- A row missing from the report is treated as failed. Other rows are unaffected.
- A row whose tool is not installed is hidden from the list and from the shareable image once its last good value is stale. Only a clear signal counts: the executable does not exist, the `kiro-docs` container does not exist, or, for Claude, `plan-usage-history.json` does not exist. Every other failure keeps the row visible with its reason.

The last merged state is cached in `~/Library/Application Support/Quota/usage.json`, so the list is not empty after a restart.

## Data sources

| Row | Source | Depends on |
| --- | --- | --- |
| Claude | Claude Desktop's local data: `plan-usage-history.json` and the cached `claude.ai/api/organizations/<org>/usage` responses in its Chromium HTTP cache (`scripts/claude-cache-probe.mjs`) | Claude Desktop signed in and run recently. Read-only; no network, Keychain or cookie access. Without a cached response it falls back to the last history sample, which has no reset time. Not installed means `~/Library/Application Support/Claude/plan-usage-history.json` does not exist. |
| OpenAI | `codex app-server` bundled in `/Applications/ChatGPT.app`, JSON-RPC `account/rateLimits/read`, weekly window | Codex signed in. Uses `~/.local/share/codex` as `CODEX_HOME` when it exists and `CODEX_HOME` is unset. |
| Antigravity (Gemini, Claude + GPT) | `/opt/homebrew/bin/agy -p /usage`, the two "Weekly Limit Remaining" pools | The Antigravity CLI signed in, with its data in `~/Library/Application Support/AntigravityCLI`. The CLI does not report the plan; Google AI Pro is set in `subscriptions.json`. |
| Kiro | `kiro-cli chat --no-interactive /usage`, run as user `kiro` in the `kiro-docs` container through `/opt/homebrew/bin/container exec` | Apple's `container` tool and a running `kiro-docs` container with Kiro signed in. Monthly cycle with a date-only reset. A missing `container` executable or `kiro-docs` container hides the row. A stopped container, or a container service that is not running, shows the row with an `exit` error. |
| Grok | `/opt/homebrew/bin/grok agent --no-leader stdio`, JSON-RPC `_x.ai/billing`, weekly period | The Grok CLI signed in. |

## Diagnostics

When a provider fails, its row says why:

- Hover over a row to see its last error. VoiceOver reads the error too.
- 诊断 in the right-click menu lists the current errors, names each hidden provider with the path that was checked (for example 未检测到：Grok（/opt/homebrew/bin/grok）), and opens the log. Paths are fixed for now, so a tool installed elsewhere is hidden; this is where to notice it.

Errors read `<Provider> <stage>: <detail>`, for example `Grok spawn: /opt/homebrew/bin/grok is not installed`. The stages are:

| Stage | Meaning |
| --- | --- |
| `spawn` | The tool could not start (missing executable, permissions). |
| `timeout` | No result within the time limit. |
| `exit` | The tool exited with a non-zero status. |
| `protocol` | The tool answered with an error or with unexpected output. |
| `read` | Claude Desktop's local data could not be read. |
| `parse` | The answer did not contain the expected quota. |
| `config` | A row in `subscriptions.json` has no collector. |

Failures of the collector as a whole are reported as `Collector <stage>: …`.

The collector's stderr goes to `~/Library/Logs/Quota/collector.log`: one line per failure (with the last lines of the tool's stderr) and a summary per run. The app adds its own failures. When the log passes 256 KB it moves to `collector.log.1`, so at most two files are kept.

## Privacy

- The app makes no network requests itself. The provider tools it runs contact their own services with their own credentials.
- The Claude probe reads Claude Desktop's files read-only and never touches credentials.
- The cache (`~/Library/Application Support/Quota/usage.json`) holds quota percentages, reset times, plan names and errors. It is readable only by you.
- The log (`~/Library/Logs/Quota/collector.log`, readable only by you) can contain the last lines of a provider tool's stderr, which may include account details. Delete it whenever you like.
- The shareable image goes to the clipboard only when you click the list or choose 复制用量图片.

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/Quota.swift` | Model, merge rules, the collector runner, the menu bar UI |
| `Sources/QuotaImage.swift` | The shareable image |
| `Sources/CollectorLog.swift` | The diagnostics log |
| `scripts/subscriptions.json` | The rows, shared by the app and the collector |
| `scripts/collect-usage.mjs` | The collector |
| `scripts/claude-cache-probe.mjs` | The Claude Desktop cache reader |
| `scripts/test*.mjs`, `Tests/` | Tests, run by `scripts/test.sh` |
| `Assets/` | App icon, menu bar icon, image artwork |
