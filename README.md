# Quota

Quota is a macOS menu bar app that shows how much of each AI subscription's quota is left: Claude, OpenAI (Codex), Antigravity (two pools), Kiro and Grok. Click the menu bar icon for the list. Click the list (or press ⌘C) to copy a shareable PNG of it.

It is a personal tool: plan labels match one person's subscriptions. Provider tools are found automatically, and [`config.json`](#configuration) overrides where they are and turns providers off.

## Requirements

- macOS 14 or later.
- Xcode 26 or later. `scripts/build.sh` uses `swiftc` and `actool`, and the app icon is an Icon Composer document.
- Node.js 22.15 or later; Homebrew `node@24` is preferred. The app runs its collector with the first of `/opt/homebrew/opt/node@24/bin/node`, `/usr/local/opt/node@24/bin/node`, then `node` in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and `PATH`, unless `config.json` sets `node`.
- The tools of the providers you use (see [Data sources](#data-sources)). Providers whose tool is not installed are hidden.

## Build, test, run

```bash
bash scripts/build.sh          # builds build/Quota.app (about 25 s)
scripts/test.sh                # all test suites and the Swift 6 typecheck
scripts/test.sh /tmp/quota     # also writes the shareable image fixtures there
open build/Quota.app --args --show   # --show opens the list at launch
node scripts/collect-usage.mjs       # the collector on its own; prints JSON, logs to stderr
```

`node scripts/collect-usage.mjs --providers claude,grok` queries only those providers.

There is no Xcode project or Swift package: `swiftc` compiles `Sources/*.swift` into one binary, and `build.sh` copies the collector scripts, `scripts/subscriptions.json`, `VERSION` and the image artwork into the bundle. To install, copy `build/Quota.app` to `~/Applications`.

`VERSION` holds the only version number. `build.sh` writes it to `CFBundleShortVersionString`, uses the commit count (`git rev-list --count HEAD`) as `CFBundleVersion`, and the collector sends it as `clientInfo.version`.

## How it works

`Sources/Quota.swift` runs `scripts/collect-usage.mjs` with the providers to query. The collector queries them in parallel (25 s limit each; the app stops the run after 35 s) and prints one JSON report that names the providers it covered.

`scripts/subscriptions.json` lists the rows: id, provider, display name, billing cycle, and optional plan, short plan label, bucket, and `local` (the provider reads local files instead of starting a tool). The collector and the app both read it, so it is the only place to add, remove or rename a row.

### When it refreshes

Nothing shows the values until the list opens, so background refreshes only keep the cache warm. Most refreshes happen when someone looks:

- Opening the list, copying the image and 刷新 refresh every provider. Opening and copying skip a provider refreshed less than a minute ago; 刷新 does not.
- 10 seconds after the Mac wakes (the network is often not back at once), every provider that has a background refresh under the current conditions.
- While the list stays open, every provider every 5 minutes.
- In the background (`RefreshPolicy` in `Sources/RefreshPolicy.swift`, checked once a minute):

  | Conditions | Claude (`local`) | Tools (OpenAI, Antigravity, Kiro, Grok) |
  | --- | --- | --- |
  | Power adapter | every 10 min | every hour |
  | Battery | every 20 min | every 3 hours |
  | Low Power Mode, or thermal state serious or critical | every hour | none; only the triggers above |

- A provider whose query failed retries after 5 minutes, then after 15, then waits its usual interval.

The Claude read costs about 0.05 s of CPU and starts no tool. A tools run starts `codex app-server`, `agy` and `grok` (and `container` for Kiro) and costs about 0.7 s of CPU and 5 to 7 s of wall time.

### Freshness

The app merges the report row by row, only for the providers the run covered:

- A successful row replaces the old one.
- A failed row keeps its last good value and records the error. It stays current until the freshness window passes (15 minutes; 30 minutes for Claude, whose cache only updates while Claude Desktop runs), then turns grey and moves to the bottom group.
- A row missing from the report is treated as failed. Rows of providers the run did not cover are unaffected.
- A row whose tool is not installed is hidden from the list and from the shareable image once its last good value is stale. Only a clear signal counts: no candidate executable exists, the Kiro container does not exist, or, for Claude, `plan-usage-history.json` does not exist. Every other failure keeps the row visible with its reason.
- A provider turned off in `config.json` is hidden at once.

The windows measure how old a value is, not how often the app asks, so background values are usually past their window when the list opens. While a refresh for such a row runs, it keeps its place and color and its ring pulses; when the refresh succeeds the row is current again, and when it fails the row turns grey. Copying the image waits for a refresh that may confirm a row the image would otherwise show as stale, for at most 10 seconds; when every row is current, it copies at once.

The last merged state is cached in `~/Library/Application Support/Quota/usage.json`, so the list is not empty after a restart.

## Configuration

`~/Library/Application Support/Quota/config.json` is optional; without it Quota uses the defaults below. 诊断 › 打开配置文件 creates an empty one and opens it. Every key is optional, and a path may start with `~`:

```json
{
  "node": "/opt/homebrew/opt/node@24/bin/node",
  "providers": {
    "claude": { "dataDir": "~/Library/Application Support/Claude" },
    "openai": { "executable": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "codexHome": "~/.codex" },
    "antigravity": { "executable": "~/.local/bin/agy", "dataDir": "~/.gemini" },
    "kiro": { "executable": "/usr/local/bin/container", "container": "kiro-docs", "user": "kiro", "workdir": "/home/kiro/workspace" },
    "grok": { "enabled": false }
  }
}
```

| Setting | Default |
| --- | --- |
| `node` | See [Requirements](#requirements). |
| `enabled` (any provider) | `true`. `false` hides the provider and never runs its tool; 诊断 lists it as 已停用. |
| `executable` | The first that exists of: the known app bundle (OpenAI: `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`, then the same in `~/Applications`), then `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, the directories in `PATH`, then a known install location (Grok: `~/Library/Application Support/Grok Build/bin/grok`). A configured path is the only candidate. |
| `claude.dataDir` | `~/Library/Application Support/Claude` |
| `openai.codexHome` | `CODEX_HOME` if set, else the first that exists of `~/.local/share/codex` and `~/Library/Application Support/Codex/home`, else Codex's own default. |
| `antigravity.dataDir` | Passed as `--gemini_dir`. Unset, `~/Library/Application Support/AntigravityCLI` is passed only if it exists, else agy uses its own default. agy creates the directory it is given. |
| `kiro.container`, `kiro.user`, `kiro.workdir` | `kiro-docs`, `kiro`, `/home/kiro/workspace` |
| `grok.grokHome` | `GROK_HOME` if set, else `~/Library/Application Support/Grok Build` if it exists. |

An app opened from Finder or at login gets neither your shell's `PATH` nor variables your shell profile exports, such as `CODEX_HOME` or `GROK_HOME`. That is why the search and the home defaults above do not depend on them; set the paths in `config.json` when a tool lives elsewhere.

Changes apply at the next refresh. A broken file or setting is ignored, the rest still applies, and 诊断 names the problem (`Collector config: providers.grok.enabled must be a boolean`).

## Data sources

| Row | Source | Depends on |
| --- | --- | --- |
| Claude | Claude Desktop's local data: `plan-usage-history.json` and the cached `claude.ai/api/organizations/<org>/usage` responses in its Chromium HTTP cache (`scripts/claude-cache-probe.mjs`) | Claude Desktop signed in and run recently. Read-only; no network, Keychain or cookie access. Without a cached response it falls back to the last history sample, which has no reset time. Not installed means `plan-usage-history.json` does not exist. The cache holds tens of thousands of files, so the files that held usage responses are remembered in `~/Library/Caches/Quota/claude-usage-files.json` and read alone; every file is scanned again when one of them is gone, or when their responses and the last scan are older than 30 minutes. |
| OpenAI | `codex app-server` (by default the one bundled in ChatGPT.app), JSON-RPC `account/rateLimits/read`, weekly window | Codex signed in, in the home described under [Configuration](#configuration). |
| Antigravity (Gemini, Claude + GPT) | `agy -p /usage`, the two "Weekly Limit Remaining" pools | The Antigravity CLI signed in. The CLI does not report the plan; Google AI Pro is set in `subscriptions.json`. |
| Kiro | `kiro-cli chat --no-interactive /usage`, run as user `kiro` in the `kiro-docs` container through `container exec` | Apple's `container` tool and a running `kiro-docs` container with Kiro signed in (all three configurable). Monthly cycle with a date-only reset. A missing `container` executable or Kiro container hides the row. A stopped container, or a container service that is not running, shows the row with an `exit` error. |
| Grok | `grok agent --no-leader stdio`, JSON-RPC `_x.ai/billing`, weekly period | The Grok CLI signed in. |

## Diagnostics

When a provider fails, its row says why:

- Hover over a row to see its last error. VoiceOver reads the error too.
- 诊断 in the right-click menu lists the current errors and `config.json` problems, names each hidden provider (未检测到：Grok, with every path that was checked in its submenu; 已停用：Grok for one turned off), and opens the log or `config.json`. A tool installed somewhere Quota does not look is hidden; this is where to notice it, and `config.json` is where to point Quota at it.

Errors read `<Provider> <stage>: <detail>`, for example `Grok spawn: grok is not installed (checked 7 paths)`. The stages are:

| Stage | Meaning |
| --- | --- |
| `spawn` | The tool could not start (missing executable, permissions). |
| `timeout` | No result within the time limit. |
| `exit` | The tool exited with a non-zero status. |
| `protocol` | The tool answered with an error or with unexpected output. |
| `read` | Claude Desktop's local data could not be read. |
| `parse` | The answer did not contain the expected quota. |
| `config` | A row in `subscriptions.json` has no collector, or (as `Collector config`) `config.json` has a problem. |

Failures of the collector as a whole are reported as `Collector <stage>: …`.

The collector's stderr goes to `~/Library/Logs/Quota/collector.log`: one line per failure (with the last lines of the tool's stderr) and a summary per run. The app adds its own failures. When the log passes 256 KB it moves to `collector.log.1`, so at most two files are kept.

## Privacy

- The app makes no network requests itself. The provider tools it runs contact their own services with their own credentials.
- The Claude probe reads Claude Desktop's files read-only and never touches credentials.
- The cache (`~/Library/Application Support/Quota/usage.json`) holds quota percentages, reset times, plan names and errors. It is readable only by you. `~/Library/Caches/Quota/claude-usage-files.json` holds only the names of Claude Desktop's cache files.
- The log (`~/Library/Logs/Quota/collector.log`, readable only by you) can contain the last lines of a provider tool's stderr, which may include account details. Delete it whenever you like.
- The shareable image goes to the clipboard only when you click the list or choose 复制用量图片.

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/Quota.swift` | Model, merge rules, the collector runner, the menu bar UI |
| `Sources/RefreshPolicy.swift` | When providers refresh, by power conditions |
| `Sources/Config.swift` | `config.json` for the app, and the Node lookup |
| `Sources/QuotaImage.swift` | The shareable image |
| `Sources/CollectorLog.swift` | The diagnostics log |
| `scripts/subscriptions.json` | The rows, shared by the app and the collector |
| `scripts/collect-usage.mjs` | The collector |
| `scripts/claude-cache-probe.mjs` | The Claude Desktop cache reader |
| `scripts/test*.mjs`, `Tests/` | Tests, run by `scripts/test.sh` |
| `Assets/` | App icon, menu bar icon, image artwork |
| `VERSION` | The version number |
