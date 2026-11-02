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
        for (seconds, expected) in [(49 * 3600, "2天1小时"), (23 * 3600, "23小时"), (45 * 60, "45分钟"), (1, "1分钟"), (0, "0小时"), (-1, "0小时")] {
            quota.resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(seconds)))
            precondition(quota.resetText(at: now) == expected, "Incorrect countdown at \(seconds) seconds")
        }
        print("Quota state tests passed: remaining balances, exhaustion, staleness, countdown boundaries, date-only precision.")
    }
}
