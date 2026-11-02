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
    }

    static func subscriptionTests() {
        let ids = Subscription.all.map(\.id)
        precondition(!ids.isEmpty && Set(ids).count == ids.count, "subscriptions.json must load with unique ids")
        precondition(Quota.placeholders.map(\.id) == ids, "Rows must follow the subscription list order")
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
        func failure(_ id: String, _ status: String, _ error: String) -> Quota {
            var quota = Quota.placeholders.first { $0.id == id }!
            quota.status = status
            quota.error = error
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

        // A tool that is not installed has its own state, and success clears errors.
        let notInstalled = UsageReport(fetchedAt: now.timeIntervalSince1970,
                                       quotas: [failure("grok", "missing", "Grok spawn: /opt/homebrew/bin/grok is not installed")])
        let grok = notInstalled.merged(into: Quota.placeholders, at: now).first { $0.id == "grok" }!
        precondition(grok.status == "missing" && grok.group(at: now) == 2)
        precondition(grok.accessibilityText(at: now).contains("未安装") && grok.accessibilityText(at: now).contains("is not installed"))
        let uninstalled = notInstalled.merged(into: [ready("grok", used: 10, at: now)], at: later).first { $0.id == "grok" }!
        precondition(uninstalled.status == "missing", "A stale row whose tool disappeared must show as not installed")
        let recovered = UsageReport(fetchedAt: now.timeIntervalSince1970, quotas: [ready("grok", used: 10, at: now)])
            .merged(into: [grok], at: now).first { $0.id == "grok" }!
        precondition(recovered.status == "ready" && recovered.error == nil, "A successful query must clear the error")
        print("Merge tests passed: per-row merge, missing ids, no flapping, freshness-driven staleness, not-installed state, recovery.")
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
        precondition(Quota.problems(in: quotas).isEmpty && Quota.problems(in: []) == ["subscriptions.json is missing or invalid"])
        quotas[2].error = "Antigravity spawn: /opt/homebrew/bin/agy is not installed"
        quotas[3].error = quotas[2].error
        quotas[5].error = "Grok timeout: no reply"
        precondition(Quota.problems(in: quotas) == [quotas[2].error!, "Grok timeout: no reply"], "Shared errors are listed once")

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
}
