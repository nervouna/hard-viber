import Foundation
import Testing
@testable import QuotaKit

struct QuotaTests {
    let now = Date(timeIntervalSince1970: 1_793_595_000)

    @Test("Remaining balances, exhaustion, staleness, countdown boundaries, date-only precision")
    func quotaState() throws {
        var quota = Quota(id: "grok", provider: "grok", name: "Grok", cycle: "weekly", usedPercent: 99.6, resetsAt: "2026-11-03T03:16:35Z", observedAt: now.timeIntervalSince1970, status: .ready)
        #expect(quota.subtitle == "—", "Missing plan metadata must not become an invented tier")
        quota.plan = "SuperGrok"
        #expect(quota.subtitle == "SuperGrok")
        let antigravity = try placeholder("antigravity-claude")
        #expect(antigravity.name == "Antigravity" && antigravity.subtitle == "Google AI Pro / Claude + GPT")
        #expect(antigravity.compactSubtitle == "AI Pro / Claude + GPT", "The image uses the short plan label")
        #expect(quota.group(at: now) == .available)
        #expect(quota.percentageText == "0.4%", "The displayed balance must be remaining rather than consumed")
        quota.usedPercent = 99.96
        #expect(quota.percentageText == "<0.1%", "A nonzero balance must not appear exhausted")
        quota.usedPercent = 65
        #expect(quota.remainingPercent == 35 && quota.percentageText == "35%")
        quota.usedPercent = 0
        #expect(quota.remainingPercent == 100 && quota.percentageText == "100%")
        quota.usedPercent = nil
        #expect(quota.remainingPercent == nil && quota.percentageText == "—", "Unknown usage must not become full remaining quota")
        quota.usedPercent = 120
        #expect(quota.remainingPercent == 0 && quota.percentageText == "0%", "Overages must not create a negative balance")
        quota.usedPercent = 100
        #expect(quota.group(at: now) == .exhausted)
        #expect(quota.remainingPercent == 0 && quota.percentageText == "0%")
        #expect(quota.accessibilityText(at: now).contains("剩余 0%"))
        quota.status = .unavailable
        #expect(quota.group(at: now) == .unconfirmed, "Failed queries must not be classified as available or exhausted")
        quota.status = .ready
        quota.observedAt = now.addingTimeInterval(-901).timeIntervalSince1970
        #expect(quota.group(at: now) == .unconfirmed, "Old snapshots must not appear current")
        quota.observedAt = now.timeIntervalSince1970
        quota.resetsAt = "2026-10-01T00:00:00Z"
        #expect(quota.group(at: now) == .unconfirmed, "Passing a reset deadline does not establish zero usage")
        quota.resetsAt = nil
        #expect(quota.resetText(at: now) == "—")
        quota.resetsAt = "2026-12-01"
        #expect(quota.resetText(at: now) == "29天", "A date-only source must not invent reset hours")
        #expect(quota.resetText(at: now, english: true) == "29d")
        for (seconds, expected) in [(49 * 3600, "2天1小时"), (23 * 3600, "23小时"), (45 * 60, "45分钟"), (1, "1分钟"), (0, "0小时"), (-1, "0小时")] {
            quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(seconds)))
            #expect(quota.resetText(at: now) == expected, "Incorrect countdown at \(seconds) seconds")
        }
        for (seconds, expected) in [(49 * 3600, "2d 1h"), (24 * 3600, "1d 0h"), (23 * 3600, "23h"), (45 * 60, "45m"), (1, "1m"), (0, "0h")] {
            quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(seconds)))
            #expect(quota.resetText(at: now, english: true) == expected, "Incorrect English countdown at \(seconds) seconds")
        }
    }

    @Test("Statuses keep the collector's wire format; groups sort in list order")
    func statusAndGroup() throws {
        let rows = #"[{"id":"a","provider":"a","name":"A","cycle":"weekly","status":"disabled"},{"id":"b","provider":"b","name":"B","cycle":"weekly","status":"paused"}]"#
        let decoded = try JSONDecoder().decode([Quota].self, from: Data(rows.utf8))
        #expect(decoded.map(\.status) == [.disabled, .unavailable], "An unknown status reads as a failed query, not a broken report")
        #expect(decoded[1].isInstalled && decoded[1].group(at: now) == .unconfirmed)
        let encoded = try JSONEncoder().encode(Quota.Status.missing)
        #expect(String(decoding: encoded, as: UTF8.self) == #""missing""#, "The cache keeps the collector's strings")
        let missingStatus = #"[{"id":"a","provider":"a","name":"A","cycle":"weekly"}]"#
        #expect(throws: DecodingError.self, "A row without a status is not a row") {
            try JSONDecoder().decode([Quota].self, from: Data(missingStatus.utf8))
        }
        #expect(Quota.Group.allCases.sorted() == [.available, .exhausted, .unconfirmed])
    }

    @Test("The subscription list, cache restore, short plan labels")
    func subscriptionList() throws {
        let ids = subscriptions.map(\.id)
        #expect(!ids.isEmpty && Set(ids).count == ids.count, "subscriptions.json must load with unique ids")
        #expect(placeholders.map(\.id) == ids, "Rows must follow the subscription list order")
        #expect(subscriptions.providers == ["claude", "openai", "antigravity", "kiro", "grok"], "Providers are listed once, in order")
        #expect(subscriptions.isLocal("claude") && !subscriptions.isLocal("grok"), "Only Claude reads local files")
        let antigravity = try placeholder("antigravity-gemini")
        #expect(antigravity.plan == "Google AI Pro" && antigravity.shortPlan == "AI Pro" && antigravity.bucket == "Gemini")
        #expect(Subscription.load(from: repository.appendingPathComponent("missing.json")).isEmpty, "A missing list loads as none")

        // Display metadata comes from the list; observed values come from the row.
        var stale = Quota(id: "kiro", provider: "kiro", name: "Kiro Pro", cycle: "weekly", usedPercent: 40, status: .ready)
        stale.bucket = "Old"
        let restored = Quota.restore([stale, Quota(id: "retired", provider: "retired", name: "Retired", cycle: "weekly", status: .ready)],
                                     subscriptions: subscriptions)
        #expect(restored.map(\.id) == ids, "Restoring a cache must not add or drop rows")
        let kiro = try row("kiro", in: restored)
        #expect(kiro.name == "Kiro" && kiro.plan == "Pro" && kiro.cycle == "monthly" && kiro.bucket == nil && kiro.usedPercent == 40,
                "Old Kiro caches keep their tier and take labels from the list")
        #expect(try row("grok", in: restored).status == .unavailable, "Rows absent from the cache start unavailable")

        var reported = antigravity
        #expect(reported.described(by: subscriptions[2]).compactSubtitle == "AI Pro / Gemini")
        reported.plan = "Google AI Ultra"
        #expect(reported.described(by: subscriptions[2]).compactSubtitle == "Google AI Ultra / Gemini",
                "The short label applies only to the listed plan")
    }

    func ready(_ id: String, used: Double, at date: Date) throws -> Quota {
        var quota = try placeholder(id)
        quota.usedPercent = used
        quota.resetsAt = ISO8601DateFormatter().string(from: date.addingTimeInterval(86_400))
        quota.observedAt = date.timeIntervalSince1970
        quota.status = .ready
        return quota
    }

    func failure(_ id: String, _ status: Quota.Status, _ error: String, missingPath: String? = nil) throws -> Quota {
        var quota = try placeholder(id)
        quota.status = status
        quota.error = error
        quota.missingPath = missingPath
        return quota
    }

    @Test("Per-row merge, missing ids, no flapping, freshness-driven staleness, not-installed state, recovery, partial runs, disabled rows")
    func merge() throws {
        // One missing id affects only its own row.
        let partial = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [try ready("claude", used: 30, at: now), try ready("grok", used: 50, at: now)])
        let merged = partial.merged(into: placeholders, subscriptions: subscriptions, at: now)
        #expect(merged.map(\.id) == placeholders.map(\.id))
        #expect(try row("claude", in: merged).group(at: now) == .available && row("grok", in: merged).usedPercent == 50,
                "Rows present in a partial report must update")
        let openai = try row("openai", in: merged)
        #expect(openai.status == .unavailable && openai.error == "Collector protocol: no openai row in the report")

        // A failed cycle keeps the last good value ready and records why.
        let good = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [try ready("openai", used: 20, at: now)])
            .merged(into: placeholders, subscriptions: subscriptions, at: now)
        let timeout = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [try failure("openai", .unavailable, "OpenAI timeout: no reply")])
        let soon = now.addingTimeInterval(300)
        let flapped = try row("openai", in: timeout.merged(into: good, subscriptions: subscriptions, at: soon))
        #expect(flapped.status == .ready && flapped.group(at: soon) == .available && flapped.usedPercent == 20,
                "One failed cycle must not grey out a fresh value")
        #expect(flapped.error == "OpenAI timeout: no reply", "The failure must still be recorded")
        #expect(flapped.accessibilityText(at: soon).contains("错误：OpenAI timeout: no reply"))

        // The freshness window, not the failure, decides when the row goes stale.
        let later = now.addingTimeInterval(901)
        #expect(flapped.group(at: later) == .unconfirmed, "A value past the freshness window must go stale")
        let demoted = try row("openai", in: timeout.merged(into: [flapped], subscriptions: subscriptions, at: later))
        #expect(demoted.status == .unavailable && demoted.group(at: later) == .unconfirmed)

        // A tool that is not installed is hidden, and success clears errors.
        let notInstalled = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [
            try failure("grok", .missing, "Grok spawn: /opt/homebrew/bin/grok is not installed", missingPath: "/opt/homebrew/bin/grok"),
        ])
        let grok = try row("grok", in: notInstalled.merged(into: placeholders, subscriptions: subscriptions, at: now))
        #expect(grok.status == .missing && !grok.isInstalled && grok.missingPath == "/opt/homebrew/bin/grok")
        let vanished = try row("grok", in: notInstalled.merged(into: [try ready("grok", used: 10, at: now)], subscriptions: subscriptions, at: soon))
        #expect(vanished.isInstalled && vanished.group(at: soon) == .available && vanished.error?.hasSuffix("is not installed") == true,
                "A fresh value stays visible with the reason until it goes stale")
        let uninstalled = try row("grok", in: notInstalled.merged(into: [try ready("grok", used: 10, at: now)], subscriptions: subscriptions, at: later))
        #expect(!uninstalled.isInstalled, "A stale row whose tool disappeared must be hidden")
        let recovered = try row("grok", in: UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [try ready("grok", used: 10, at: now)])
            .merged(into: [grok], subscriptions: subscriptions, at: now))
        #expect(recovered.isInstalled && recovered.error == nil && recovered.missingPath == nil, "A successful query must clear the error")
        let timedOut = try row("grok", in: UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [try failure("grok", .unavailable, "Grok timeout: no reply")])
            .merged(into: [grok], subscriptions: subscriptions, at: now))
        #expect(timedOut.isInstalled && timedOut.missingPath == nil, "Only a clear not-installed signal hides a row")

        // A run that covers some providers leaves the other rows alone.
        let start = [try ready("claude", used: 30, at: now), try ready("grok", used: 10, at: now)]
        let claudeOnly = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [try ready("claude", used: 35, at: soon)], providers: ["claude"])
            .merged(into: start, subscriptions: subscriptions, at: soon)
        #expect(try row("claude", in: claudeOnly).usedPercent == 35)
        let untouched = try row("grok", in: claudeOnly)
        #expect(untouched.usedPercent == 10 && untouched.error == nil && untouched.observedAt == now.timeIntervalSince1970,
                "Rows outside the run must not be marked failed")
        #expect(try row("openai", in: claudeOnly).error == nil, "Uncovered rows absent from the report are not an error")

        // A provider turned off in config.json is hidden at once, even with a fresh value.
        var off = try failure("grok", .disabled, "")
        off.error = nil
        let disabled = try row("grok", in: UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [off], providers: ["grok"])
            .merged(into: start, subscriptions: subscriptions, at: soon))
        #expect(disabled.status == .disabled && !disabled.isInstalled && disabled.usedPercent == nil)

        // With hourly background refreshes the last good value is past its window when a refresh
        // fails, so the row turns grey; the policy retries it five minutes later.
        let hourLater = now.addingTimeInterval(3600)
        let failedLate = try row("openai", in: timeout.merged(into: good, subscriptions: subscriptions, at: hourLater))
        #expect(failedLate.status == .unavailable && failedLate.group(at: hourLater) == .unconfirmed)
        #expect(!RefreshPolicy.isDue(local: false, lastRun: hourLater, failures: 1, conditions: PowerConditions(), at: hourLater.addingTimeInterval(299)))
        #expect(RefreshPolicy.isDue(local: false, lastRun: hourLater, failures: 1, conditions: PowerConditions(), at: hourLater.addingTimeInterval(300)))
    }

    @Test("Run classification, problem list, bounded log rotation")
    func diagnostics() throws {
        let report = #"{"fetchedAt":1,"quotas":[{"id":"grok","provider":"grok","name":"Grok","cycle":"weekly","status":"missing","error":"Grok spawn: x"}]}"#
        let decoded = try UsageReport.decode(Data(report.utf8), terminationStatus: 0, timedOut: false).get()
        #expect(decoded.quotas.first?.status == .missing && decoded.providers == nil, "Reports without a scope cover every provider")
        let scoped = #"{"fetchedAt":1,"providers":["grok"],"warnings":["Collector config: x"],"quotas":[{"id":"grok","provider":"grok","name":"Grok","cycle":"weekly","status":"missing","checkedPaths":["/a/grok","/b/grok"]}]}"#
        let partial = try UsageReport.decode(Data(scoped.utf8), terminationStatus: 0, timedOut: false).get()
        #expect(partial.providers == ["grok"] && partial.warnings == ["Collector config: x"])
        let merged = partial.merged(into: placeholders, subscriptions: subscriptions, at: now)
        #expect(try row("grok", in: merged).checkedPaths == ["/a/grok", "/b/grok"])
        #expect(merged.filter { $0.provider != "grok" }.allSatisfy { $0.error == nil }, "A decoded scope keeps other rows untouched")
        // A collector the app stopped exits 0 with no output; that is a timeout, not a parse error.
        for (data, status, timedOut, expected) in [(Data(), Int32(0), true, "Collector timeout:"), (Data(report.utf8), 1, false, "Collector exit:"),
                                                   (Data("{}".utf8), 0, false, "Collector parse:")] {
            let failure = try #require(throws: CollectorFailure.self, "\(expected) must be a failure") {
                try UsageReport.decode(data, terminationStatus: status, timedOut: timedOut).get()
            }
            #expect(failure.message.hasPrefix(expected), "Expected \(expected), got \(failure.message)")
        }

        var quotas = placeholders
        #expect(Quota.problems(in: quotas).isEmpty && Quota.problems(in: []) == [Problem("subscriptions.json is missing or invalid")])
        for index in [2, 3] {
            quotas[index].status = .missing
            quotas[index].error = "Antigravity spawn: agy is not installed (checked 2 paths)"
            quotas[index].missingPath = "/opt/homebrew/bin/agy"
            quotas[index].checkedPaths = ["/opt/homebrew/bin/agy", "~/.local/bin/agy"]
        }
        quotas[4].status = .missing
        quotas[4].missingPath = "/opt/homebrew/bin/container"
        quotas[1].status = .disabled
        quotas[5].error = "Grok timeout: no reply"
        #expect(Quota.problems(in: quotas, warnings: ["Collector config: unknown provider gork"]) == [
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
        #expect((try? String(contentsOf: log, encoding: .utf8))?.hasSuffix(" second\n") == true)
        CollectorLog.append("third", at: log, limit: 40)
        let current = try? String(contentsOf: log, encoding: .utf8)
        let previous = try? String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8)
        #expect(current?.hasSuffix(" third\n") == true && current?.contains("first") == false && previous?.contains("second") == true,
                "A full log must rotate to collector.log.1")
        #expect((try? FileManager.default.attributesOfItem(atPath: log.path))?[.posixPermissions] as? Int == 0o600)
    }

    @Test("Power-aware intervals, retries, refreshing rows, copy confirmation")
    func refresh() throws {
        // Background intervals: local reads more often than tools; both back off, tools stop.
        let ac = PowerConditions(), battery = PowerConditions(onBattery: true)
        let lowPower = PowerConditions(lowPower: true), hot = PowerConditions(onBattery: true, thermalPressure: true)
        #expect(RefreshPolicy.interval(local: true, ac) == 600 && RefreshPolicy.interval(local: false, ac) == 3600)
        #expect(RefreshPolicy.interval(local: true, battery) == 1200 && RefreshPolicy.interval(local: false, battery) == 10_800)
        for conditions in [lowPower, hot] {
            #expect(RefreshPolicy.interval(local: true, conditions) == 3600 && RefreshPolicy.interval(local: false, conditions) == nil)
        }
        func due(_ local: Bool, after seconds: TimeInterval, failures: Int = 0, _ conditions: PowerConditions = PowerConditions()) -> Bool {
            RefreshPolicy.isDue(local: local, lastRun: now, failures: failures, conditions: conditions, at: now.addingTimeInterval(seconds))
        }
        #expect(RefreshPolicy.isDue(local: false, lastRun: nil, failures: 0, conditions: ac, at: now), "A provider never refreshed is due")
        #expect(!RefreshPolicy.isDue(local: false, lastRun: nil, failures: 0, conditions: lowPower, at: now), "Tools wait for the panel in Low Power Mode")
        #expect(!due(true, after: 599) && due(true, after: 600) && !due(false, after: 3599) && due(false, after: 3600))
        #expect(!due(false, after: 899, failures: 2) && due(false, after: 900, failures: 2), "The second retry waits 15 minutes")
        #expect(!due(false, after: 3599, failures: 3) && due(false, after: 3600, failures: 3), "After two retries the usual interval applies")
        #expect(!due(true, after: 299, failures: 1) && due(true, after: 300, failures: 1))
        #expect(!due(false, after: 3 * 3600, failures: 1, lowPower), "Retries never run where there is no background refresh")
        for conditions in [ac, battery, lowPower, hot] {
            #expect(RefreshPolicy.interval(local: false, conditions, panelOpen: true) == 300, "An open panel refreshes every 5 minutes")
        }
        #expect(RefreshPolicy.isDue(local: false, lastRun: now, failures: 0, conditions: lowPower, panelOpen: true, at: now.addingTimeInterval(300)))

        // A value past its window stays in place, unconfirmed, while a refresh may confirm it.
        var quota = try placeholder("grok")
        quota.usedPercent = 40
        quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
        quota.observedAt = now.addingTimeInterval(-3600).timeIntervalSince1970
        quota.status = .ready
        #expect(quota.group(at: now) == .unconfirmed && quota.group(at: now, refreshing: true) == .available)
        #expect(quota.accessibilityText(at: now, refreshing: true).contains("正在刷新") && quota.accessibilityText(at: now).contains("无法确认"))
        var failed = quota
        failed.status = .unavailable
        #expect(failed.group(at: now, refreshing: true) == .unconfirmed, "A failed row stays grey while it retries")
        var expired = quota
        expired.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        #expect(expired.group(at: now, refreshing: true) == .unconfirmed, "A passed reset is not current while refreshing")

        // Copying waits only for a refresh that may confirm a row the image would show as stale.
        var fresh = quota
        fresh.observedAt = now.timeIntervalSince1970
        #expect(Quota.awaitsConfirmation([quota], refreshing: ["grok"], at: now))
        #expect(!Quota.awaitsConfirmation([quota], refreshing: [], at: now), "Nothing to wait for")
        #expect(!Quota.awaitsConfirmation([fresh], refreshing: ["grok"], at: now), "A current value is copied at once")
        var hidden = quota
        hidden.status = .missing
        #expect(!Quota.awaitsConfirmation([hidden], refreshing: ["grok"], at: now), "Hidden rows are not in the image")
    }

    @Test("Node candidates and overrides, config.json loading")
    func config() throws {
        let home = "/Users/me"
        let defaults = NodeLocator.candidates(configured: nil, path: "/usr/bin:/bin:relative:/opt/homebrew/bin", home: home)
        #expect(defaults == ["/opt/homebrew/opt/node@24/bin/node", "/usr/local/opt/node@24/bin/node", "/opt/homebrew/bin/node",
                             "/usr/local/bin/node", "/Users/me/.local/bin/node", "/usr/bin/node", "/bin/node"],
                "node@24 first, then the usual directories, then PATH, each once")
        #expect(NodeLocator.candidates(configured: "~/n/node", path: "/usr/bin", home: home) == ["/Users/me/n/node"], "A configured Node is the only candidate")
        #expect(NodeLocator.candidates(configured: "", path: nil, home: home) == Array(defaults.prefix(5)), "An empty setting means the default")
        let node = try NodeLocator.locate(configured: nil, path: nil, home: home, isExecutable: { $0 == "/usr/local/bin/node" }).get()
        #expect(node == "/usr/local/bin/node")
        let missing = try #require(throws: CollectorFailure.self, "A missing Node must fail") {
            try NodeLocator.locate(configured: nil, path: "/usr/bin", home: home, isExecutable: { _ in false }).get()
        }
        let configured = try #require(throws: CollectorFailure.self, "A missing configured Node must fail") {
            try NodeLocator.locate(configured: "/x/node", path: nil, home: home, isExecutable: { _ in false }).get()
        }
        #expect(missing.message.hasPrefix("Collector spawn: Node.js is not installed (checked /opt/homebrew/opt/node@24/bin/node, ")
                && missing.message.hasSuffix("~/.local/bin/node, /usr/bin/node)"), "The error lists every path checked")
        #expect(configured.message == "Collector spawn: /x/node is not installed (set in config.json)")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        #expect(UserConfig.load(from: file).node == nil, "A missing file means defaults")
        try Data(#"{"node": "~/node", "providers": {"grok": {"enabled": false}}}"#.utf8).write(to: file)
        #expect(UserConfig.load(from: file).node == "~/node", "Provider settings are the collector's")
        try Data(#"{"node": 24}"#.utf8).write(to: file)
        #expect(UserConfig.load(from: file).node == nil, "A broken file means defaults")
    }
}
