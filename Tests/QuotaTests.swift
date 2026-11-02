import Foundation

@main
struct QuotaTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_793_595_000)
        var quota = Quota(id: "grok", provider: "grok", name: "Grok", cycle: "weekly", usedPercent: 99.6, resetsAt: "2026-11-03T03:16:35Z", observedAt: now.timeIntervalSince1970, status: "ready")
        precondition(quota.subtitle == "—", "Missing plan metadata must not become an invented tier")
        quota.plan = "SuperGrok"
        precondition(quota.subtitle == "SuperGrok")
        let antigravity = Quota.placeholders.first { $0.id == "antigravity-claude" }!
        precondition(antigravity.name == "Antigravity" && antigravity.subtitle == "Google AI Pro / Claude + GPT")
        precondition(antigravity.compactSubtitle == "AI Pro / Claude + GPT", "The image uses the short plan label")
        precondition(quota.group(at: now) == 0)
        precondition(quota.percentageText == "0.4%", "The displayed balance must be remaining rather than consumed")
        quota.usedPercent = 99.96
        precondition(quota.percentageText == "<0.1%", "A nonzero balance must not appear exhausted")
        quota.usedPercent = 65
        precondition(quota.remainingPercent == 35 && quota.percentageText == "35%")
        quota.usedPercent = 0
        precondition(quota.remainingPercent == 100 && quota.percentageText == "100%")
        quota.usedPercent = nil
        precondition(quota.remainingPercent == nil && quota.percentageText == "—", "Unknown usage must not become full remaining quota")
        quota.usedPercent = 120
        precondition(quota.remainingPercent == 0 && quota.percentageText == "0%", "Overages must not create a negative balance")
        quota.usedPercent = 100
        precondition(quota.group(at: now) == 1)
        precondition(quota.remainingPercent == 0 && quota.percentageText == "0%")
        precondition(quota.accessibilityText(at: now).contains("剩余 0%"))
        quota.status = "unavailable"
        precondition(quota.group(at: now) == 2, "Failed queries must not be classified as available or exhausted")
        quota.status = "ready"
        quota.observedAt = now.addingTimeInterval(-901).timeIntervalSince1970
        precondition(quota.group(at: now) == 2, "Old snapshots must not appear current")
        quota.observedAt = now.timeIntervalSince1970
        quota.resetsAt = "2026-10-01T00:00:00Z"
        precondition(quota.group(at: now) == 2, "Passing a reset deadline does not establish zero usage")
        quota.resetsAt = nil
        precondition(quota.resetText(at: now) == "—")
        quota.resetsAt = "2026-12-01"
        precondition(quota.resetText(at: now) == "29天", "A date-only source must not invent reset hours")
        precondition(quota.resetText(at: now, english: true) == "29d")
        for (seconds, expected) in [(49 * 3600, "2天1小时"), (23 * 3600, "23小时"), (45 * 60, "45分钟"), (1, "1分钟"), (0, "0小时"), (-1, "0小时")] {
            quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(seconds)))
            precondition(quota.resetText(at: now) == expected, "Incorrect countdown at \(seconds) seconds")
        }
        for (seconds, expected) in [(49 * 3600, "2d 1h"), (24 * 3600, "1d 0h"), (23 * 3600, "23h"), (45 * 60, "45m"), (1, "1m"), (0, "0h")] {
            quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(seconds)))
            precondition(quota.resetText(at: now, english: true) == expected, "Incorrect English countdown at \(seconds) seconds")
        }
        print("Quota state tests passed: remaining balances, exhaustion, staleness, countdown boundaries, date-only precision.")
        subscriptionTests()
        mergeTests(now: now)
        diagnosticsTests(now: now)
        refreshTests(now: now)
        configTests()
    }

    static func subscriptionTests() {
        let ids = Subscription.all.map(\.id)
        precondition(!ids.isEmpty && Set(ids).count == ids.count, "subscriptions.json must load with unique ids")
        precondition(Quota.placeholders.map(\.id) == ids, "Rows must follow the subscription list order")
        precondition(Subscription.providers == ["claude", "openai", "antigravity", "kiro", "grok"], "Providers are listed once, in order")
        precondition(Subscription.isLocal("claude") && !Subscription.isLocal("grok"), "Only Claude reads local files")
        let antigravity = Quota.placeholders.first { $0.id == "antigravity-gemini" }!
        precondition(antigravity.plan == "Google AI Pro" && antigravity.shortPlan == "AI Pro" && antigravity.bucket == "Gemini")

        // Display metadata comes from the list; observed values come from the row.
        var stale = Quota(id: "kiro", provider: "kiro", name: "Kiro Pro", cycle: "weekly", usedPercent: 40, status: "ready")
        stale.bucket = "Old"
        let restored = Quota.restore([stale, Quota(id: "retired", provider: "retired", name: "Retired", cycle: "weekly", status: "ready")])
        precondition(restored.map(\.id) == ids, "Restoring a cache must not add or drop rows")
        let kiro = restored.first { $0.id == "kiro" }!
        precondition(kiro.name == "Kiro" && kiro.plan == "Pro" && kiro.cycle == "monthly" && kiro.bucket == nil && kiro.usedPercent == 40,
                     "Old Kiro caches keep their tier and take labels from the list")
        precondition(restored.first { $0.id == "grok" }!.status == "unavailable", "Rows absent from the cache start unavailable")

        var reported = antigravity
        precondition(reported.described(by: Subscription.all[2]).compactSubtitle == "AI Pro / Gemini")
        reported.plan = "Google AI Ultra"
        precondition(reported.described(by: Subscription.all[2]).compactSubtitle == "Google AI Ultra / Gemini",
                     "The short label applies only to the listed plan")
    }

    static func mergeTests(now: Date) {
        func ready(_ id: String, used: Double, at date: Date) -> Quota {
            var quota = Quota.placeholders.first { $0.id == id }!
            quota.usedPercent = used
            quota.resetsAt = ISO8601DateFormatter().string(from: date.addingTimeInterval(86_400))
            quota.observedAt = date.timeIntervalSince1970
            quota.status = "ready"
            return quota
        }
        func failure(_ id: String, _ status: String, _ error: String, missingPath: String? = nil) -> Quota {
            var quota = Quota.placeholders.first { $0.id == id }!
            quota.status = status
            quota.error = error
            quota.missingPath = missingPath
            return quota
        }

        // One missing id affects only its own row.
        let partial = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [ready("claude", used: 30, at: now), ready("grok", used: 50, at: now)])
        let merged = partial.merged(into: Quota.placeholders, at: now)
        precondition(merged.map(\.id) == Quota.placeholders.map(\.id))
        precondition(merged.first { $0.id == "claude" }!.group(at: now) == 0 && merged.first { $0.id == "grok" }!.usedPercent == 50,
                     "Rows present in a partial report must update")
        let openai = merged.first { $0.id == "openai" }!
        precondition(openai.status == "unavailable" && openai.error == "Collector protocol: no openai row in the report")

        // A failed cycle keeps the last good value ready and records why.
        let good = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [ready("openai", used: 20, at: now)]).merged(into: Quota.placeholders, at: now)
        let timeout = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [failure("openai", "unavailable", "OpenAI timeout: no reply")])
        let soon = now.addingTimeInterval(300)
        let flapped = timeout.merged(into: good, at: soon).first { $0.id == "openai" }!
        precondition(flapped.status == "ready" && flapped.group(at: soon) == 0 && flapped.usedPercent == 20,
                     "One failed cycle must not grey out a fresh value")
        precondition(flapped.error == "OpenAI timeout: no reply", "The failure must still be recorded")
        precondition(flapped.accessibilityText(at: soon).contains("错误：OpenAI timeout: no reply"))

        // The freshness window, not the failure, decides when the row goes stale.
        let later = now.addingTimeInterval(901)
        precondition(flapped.group(at: later) == 2, "A value past the freshness window must go stale")
        let demoted = timeout.merged(into: [flapped], at: later).first { $0.id == "openai" }!
        precondition(demoted.status == "unavailable" && demoted.group(at: later) == 2)

        // A tool that is not installed is hidden, and success clears errors.
        let notInstalled = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [
            failure("grok", "missing", "Grok spawn: /opt/homebrew/bin/grok is not installed", missingPath: "/opt/homebrew/bin/grok"),
        ])
        let grok = notInstalled.merged(into: Quota.placeholders, at: now).first { $0.id == "grok" }!
        precondition(grok.status == "missing" && !grok.isInstalled && grok.missingPath == "/opt/homebrew/bin/grok")
        let vanished = notInstalled.merged(into: [ready("grok", used: 10, at: now)], at: soon).first { $0.id == "grok" }!
        precondition(vanished.isInstalled && vanished.group(at: soon) == 0 && vanished.error!.hasSuffix("is not installed"),
                     "A fresh value stays visible with the reason until it goes stale")
        let uninstalled = notInstalled.merged(into: [ready("grok", used: 10, at: now)], at: later).first { $0.id == "grok" }!
        precondition(!uninstalled.isInstalled, "A stale row whose tool disappeared must be hidden")
        let recovered = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [ready("grok", used: 10, at: now)])
            .merged(into: [grok], at: now).first { $0.id == "grok" }!
        precondition(recovered.isInstalled && recovered.error == nil && recovered.missingPath == nil, "A successful query must clear the error")
        let timedOut = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [failure("grok", "unavailable", "Grok timeout: no reply")])
            .merged(into: [grok], at: now).first { $0.id == "grok" }!
        precondition(timedOut.isInstalled && timedOut.missingPath == nil, "Only a clear not-installed signal hides a row")

        // A run that covers some providers leaves the other rows alone.
        let start = [ready("claude", used: 30, at: now), ready("grok", used: 10, at: now)]
        let claudeOnly = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [ready("claude", used: 35, at: soon)], providers: ["claude"])
            .merged(into: start, at: soon)
        precondition(claudeOnly.first { $0.id == "claude" }!.usedPercent == 35)
        let untouched = claudeOnly.first { $0.id == "grok" }!
        precondition(untouched.usedPercent == 10 && untouched.error == nil && untouched.observedAt == now.timeIntervalSince1970,
                     "Rows outside the run must not be marked failed")
        precondition(claudeOnly.first { $0.id == "openai" }!.error == nil, "Uncovered rows absent from the report are not an error")

        // A provider turned off in config.json is hidden at once, even with a fresh value.
        let disabled = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [failure("grok", "disabled", "")].map { var quota = $0; quota.error = nil; return quota },
                                   providers: ["grok"]).merged(into: start, at: soon).first { $0.id == "grok" }!
        precondition(disabled.status == "disabled" && !disabled.isInstalled && disabled.usedPercent == nil)

        // With hourly background refreshes the last good value is past its window when a refresh
        // fails, so the row turns grey; the policy retries it five minutes later.
        let hourLater = now.addingTimeInterval(3600)
        let failedLate = timeout.merged(into: good, at: hourLater).first { $0.id == "openai" }!
        precondition(failedLate.status == "unavailable" && failedLate.group(at: hourLater) == 2)
        precondition(!RefreshPolicy.isDue(local: false, lastRun: hourLater, failures: 1, conditions: PowerConditions(), at: hourLater.addingTimeInterval(299))
                     && RefreshPolicy.isDue(local: false, lastRun: hourLater, failures: 1, conditions: PowerConditions(), at: hourLater.addingTimeInterval(300)))
        print("Merge tests passed: per-row merge, missing ids, no flapping, freshness-driven staleness, not-installed state, recovery, partial runs, disabled rows.")
    }

    static func diagnosticsTests(now: Date) {
        let report = #"{"fetchedAt":1,"quotas":[{"id":"grok","provider":"grok","name":"Grok","cycle":"weekly","status":"missing","error":"Grok spawn: x"}]}"#
        guard case .success(let decoded) = UsageReport.decode(Data(report.utf8), terminationStatus: 0, timedOut: false) else {
            preconditionFailure("A valid report must decode")
        }
        precondition(decoded.quotas.first?.status == "missing")
        // A collector the app stopped exits 0 with no output; that is a timeout, not a parse error.
        for (data, status, timedOut, expected) in [(Data(), Int32(0), true, "Collector timeout:"), (Data(report.utf8), 1, false, "Collector exit:"),
                                                   (Data("{}".utf8), 0, false, "Collector parse:")] {
            guard case .failure(let failure) = UsageReport.decode(data, terminationStatus: status, timedOut: timedOut) else {
                preconditionFailure("\(expected) must be a failure")
            }
            precondition(failure.message.hasPrefix(expected), "Expected \(expected), got \(failure.message)")
        }

        var quotas = Quota.placeholders
        precondition(Quota.problems(in: quotas).isEmpty && Quota.problems(in: []) == [Problem("subscriptions.json is missing or invalid")])
        for index in [2, 3] {
            quotas[index].status = "missing"
            quotas[index].error = "Antigravity spawn: agy is not installed (checked 2 paths)"
            quotas[index].missingPath = "/opt/homebrew/bin/agy"
            quotas[index].checkedPaths = ["/opt/homebrew/bin/agy", "~/.local/bin/agy"]
        }
        quotas[4].status = "missing"
        quotas[4].missingPath = "/opt/homebrew/bin/container"
        quotas[1].status = "disabled"
        quotas[5].error = "Grok timeout: no reply"
        precondition(Quota.problems(in: quotas, warnings: ["Collector config: unknown provider gork"]) == [
            Problem("Collector config: unknown provider gork"),
            Problem("已停用：OpenAI"),
            Problem("未检测到：Antigravity", paths: ["/opt/homebrew/bin/agy", "~/.local/bin/agy"]),
            Problem("未检测到：Kiro", paths: ["/opt/homebrew/bin/container"]),
            Problem("Grok timeout: no reply"),
        ], "Hidden rows list every checked path, caches from before keep their one path, and shared lines are listed once")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("collector.log")
        CollectorLog.append("first", at: log, limit: 40)
        CollectorLog.append("second", at: log, limit: 40)
        precondition((try? String(contentsOf: log, encoding: .utf8))?.hasSuffix(" second\n") == true)
        CollectorLog.append("third", at: log, limit: 40)
        let current = try? String(contentsOf: log, encoding: .utf8)
        let previous = try? String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8)
        precondition(current?.hasSuffix(" third\n") == true && current?.contains("first") == false && previous?.contains("second") == true,
                     "A full log must rotate to collector.log.1")
        precondition((try? FileManager.default.attributesOfItem(atPath: log.path))?[.posixPermissions] as? Int == 0o600)
        print("Diagnostics tests passed: run classification, problem list, bounded log rotation.")
    }

    static func refreshTests(now: Date) {
        // Background intervals: local reads more often than tools; both back off, tools stop.
        let ac = PowerConditions(), battery = PowerConditions(onBattery: true)
        let lowPower = PowerConditions(lowPower: true), hot = PowerConditions(onBattery: true, thermalPressure: true)
        precondition(RefreshPolicy.interval(local: true, ac) == 600 && RefreshPolicy.interval(local: false, ac) == 3600)
        precondition(RefreshPolicy.interval(local: true, battery) == 1200 && RefreshPolicy.interval(local: false, battery) == 10_800)
        for conditions in [lowPower, hot] {
            precondition(RefreshPolicy.interval(local: true, conditions) == 3600 && RefreshPolicy.interval(local: false, conditions) == nil)
        }
        func due(_ local: Bool, after seconds: TimeInterval, failures: Int = 0, _ conditions: PowerConditions = PowerConditions()) -> Bool {
            RefreshPolicy.isDue(local: local, lastRun: now, failures: failures, conditions: conditions, at: now.addingTimeInterval(seconds))
        }
        precondition(RefreshPolicy.isDue(local: false, lastRun: nil, failures: 0, conditions: ac, at: now), "A provider never refreshed is due")
        precondition(!RefreshPolicy.isDue(local: false, lastRun: nil, failures: 0, conditions: lowPower, at: now), "Tools wait for the panel in Low Power Mode")
        precondition(!due(true, after: 599) && due(true, after: 600) && !due(false, after: 3599) && due(false, after: 3600))
        precondition(!due(false, after: 899, failures: 2) && due(false, after: 900, failures: 2), "The second retry waits 15 minutes")
        precondition(!due(false, after: 3599, failures: 3) && due(false, after: 3600, failures: 3), "After two retries the usual interval applies")
        precondition(!due(true, after: 299, failures: 1) && due(true, after: 300, failures: 1))
        precondition(!due(false, after: 3 * 3600, failures: 1, lowPower), "Retries never run where there is no background refresh")
        for conditions in [ac, battery, lowPower, hot] {
            precondition(RefreshPolicy.interval(local: false, conditions, panelOpen: true) == 300, "An open panel refreshes every 5 minutes")
        }
        precondition(RefreshPolicy.isDue(local: false, lastRun: now, failures: 0, conditions: lowPower, panelOpen: true, at: now.addingTimeInterval(300)))

        // A value past its window stays in place, unconfirmed, while a refresh may confirm it.
        var quota = Quota.placeholders.first { $0.id == "grok" }!
        quota.usedPercent = 40
        quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
        quota.observedAt = now.addingTimeInterval(-3600).timeIntervalSince1970
        quota.status = "ready"
        precondition(quota.group(at: now) == 2 && quota.group(at: now, refreshing: true) == 0)
        precondition(quota.accessibilityText(at: now, refreshing: true).contains("正在刷新") && quota.accessibilityText(at: now).contains("无法确认"))
        var failed = quota
        failed.status = "unavailable"
        precondition(failed.group(at: now, refreshing: true) == 2, "A failed row stays grey while it retries")
        var expired = quota
        expired.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        precondition(expired.group(at: now, refreshing: true) == 2, "A passed reset is not current while refreshing")

        // Copying waits only for a refresh that may confirm a row the image would show as stale.
        var fresh = quota
        fresh.observedAt = now.timeIntervalSince1970
        precondition(Quota.awaitsConfirmation([quota], refreshing: ["grok"], at: now))
        precondition(!Quota.awaitsConfirmation([quota], refreshing: [], at: now), "Nothing to wait for")
        precondition(!Quota.awaitsConfirmation([fresh], refreshing: ["grok"], at: now), "A current value is copied at once")
        var hidden = quota
        hidden.status = "missing"
        precondition(!Quota.awaitsConfirmation([hidden], refreshing: ["grok"], at: now), "Hidden rows are not in the image")
        print("Refresh tests passed: power-aware intervals, retries, refreshing rows, copy confirmation.")
    }

    static func configTests() {
        let home = "/Users/me"
        let defaults = NodeLocator.candidates(configured: nil, path: "/usr/bin:/bin:relative:/opt/homebrew/bin", home: home)
        precondition(defaults == ["/opt/homebrew/opt/node@24/bin/node", "/usr/local/opt/node@24/bin/node", "/opt/homebrew/bin/node",
                                  "/usr/local/bin/node", "/Users/me/.local/bin/node", "/usr/bin/node", "/bin/node"],
                     "node@24 first, then the usual directories, then PATH, each once")
        precondition(NodeLocator.candidates(configured: "~/n/node", path: "/usr/bin", home: home) == ["/Users/me/n/node"], "A configured Node is the only candidate")
        precondition(NodeLocator.candidates(configured: "", path: nil, home: home) == Array(defaults.prefix(5)), "An empty setting means the default")
        guard case .success(let node) = NodeLocator.locate(configured: nil, path: nil, home: home, isExecutable: { $0 == "/usr/local/bin/node" }) else {
            preconditionFailure("An installed Node must be found")
        }
        precondition(node == "/usr/local/bin/node")
        guard case .failure(let missing) = NodeLocator.locate(configured: nil, path: "/usr/bin", home: home, isExecutable: { _ in false }),
              case .failure(let configured) = NodeLocator.locate(configured: "/x/node", path: nil, home: home, isExecutable: { _ in false }) else {
            preconditionFailure("A missing Node must fail")
        }
        precondition(missing.message.hasPrefix("Collector spawn: Node.js is not installed (checked /opt/homebrew/opt/node@24/bin/node, ")
                     && missing.message.hasSuffix("~/.local/bin/node, /usr/bin/node)"), "The error lists every path checked")
        precondition(configured.message == "Collector spawn: /x/node is not installed (set in config.json)")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        precondition(UserConfig.load(from: file).node == nil, "A missing file means defaults")
        try? Data(#"{"node": "~/node", "providers": {"grok": {"enabled": false}}}"#.utf8).write(to: file)
        precondition(UserConfig.load(from: file).node == "~/node", "Provider settings are the collector's")
        try? Data(#"{"node": 24}"#.utf8).write(to: file)
        precondition(UserConfig.load(from: file).node == nil, "A broken file means defaults")
        print("Config tests passed: Node candidates and overrides, config.json loading.")
    }
}
