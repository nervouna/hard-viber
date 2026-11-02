import Foundation

/// One row of `scripts/subscriptions.json`, which the collector reads too.
struct Subscription: Decodable, Sendable {
    let id: String
    let provider: String
    let name: String
    let cycle: String
    var plan: String?
    /// A shorter form of `plan` for the shareable image.
    var shortPlan: String?
    var bucket: String?
    /// The provider reads local files instead of starting a tool, so it is polled more often.
    var local: Bool?

    /// The list, or none when the file is missing or invalid, which 诊断 reports.
    static func load(from url: URL) -> [Subscription] {
        (try? JSONDecoder().decode([Subscription].self, from: Data(contentsOf: url))) ?? []
    }
}

extension [Subscription] {
    /// Providers in list order.
    var providers: [String] { map(\.provider).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    func isLocal(_ provider: String) -> Bool { contains { $0.provider == provider && $0.local == true } }
}

struct Quota: Codable, Identifiable, Sendable {
    let id: String
    let provider: String
    var name: String
    let cycle: String
    var plan: String?
    var shortPlan: String?
    var bucket: String?
    var usedPercent: Double?
    var resetsAt: String?
    var observedAt: Double?
    var status: Status
    var error: String?
    /// The executable or file that was checked when `status` is `.missing`.
    var missingPath: String?
    /// Every path that was checked when `status` is `.missing`.
    var checkedPaths: [String]?

    /// The collector's verdict on a row, written as its raw value in the report and the cache.
    enum Status: String, Codable, Sendable {
        case ready
        /// The query failed; `error` says why.
        case unavailable
        /// No candidate executable exists (nor Kiro's container, nor Claude's history file).
        case missing
        /// Turned off in config.json.
        case disabled

        /// A status this version does not know, from a newer collector or cache, reads as a failed
        /// query instead of failing the whole report.
        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unavailable
        }
    }

    /// Where a row sits in the list. The cases are declared in list order, top to bottom, which is
    /// also their `Comparable` order.
    enum Group: CaseIterable, Comparable, Sendable {
        /// A current value with quota left.
        case available
        /// A current value with none left.
        case exhausted
        /// Stale or failed: the value cannot be confirmed.
        case unconfirmed
    }

    /// Rows of a tool that is not installed, or that is turned off in config.json, are hidden.
    var isInstalled: Bool { status != .missing && status != .disabled }

    var subtitle: String {
        let label = plan?.isEmpty == false ? plan! : "—"
        return bucket.map { "\(label) / \($0)" } ?? label
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        if resetsAt.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: resetsAt)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }

    func resetText(at now: Date, english: Bool = false) -> String {
        guard let resetDate else { return "—" }
        if resetsAt?.count == 10 {
            // A date-only source cannot establish an hourly reset countdown.
            let calendar = Calendar.autoupdatingCurrent
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: resetDate).day ?? 0
            return english ? "\(max(0, days))d" : "\(max(0, days))天"
        }
        let remaining = resetDate.timeIntervalSince(now)
        guard remaining > 0 else { return english ? "0h" : "0小时" }
        if remaining < 3600 {
            let minutes = Int(ceil(remaining / 60))
            return english ? "\(minutes)m" : "\(minutes)分钟"
        }
        let hours = Int(remaining / 3600)
        if english { return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h" }
        return hours >= 24 ? "\(hours / 24)天\(hours % 24)小时" : "\(hours)小时"
    }

    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    var percentageText: String {
        guard let value = remainingPercent else { return "—" }
        if value > 0 && value < 0.1 { return "<0.1%" }
        if (value > 0 && value < 1) || (value >= 99.5 && value < 100) {
            return String(format: "%.1f%%", min(value, 99.9))
        }
        return String(format: "%.0f%%", value)
    }

    /// A value older than its freshness window is unconfirmed (the collector's Claude read uses the
    /// same 1800 s), except while `refreshing`: a refresh that may confirm it is under way, so it
    /// keeps its place instead of turning grey for a few seconds.
    func group(at date: Date, refreshing: Bool = false) -> Group {
        guard status == .ready, let value = usedPercent, value.isFinite, value >= 0,
              let observedAt, let resetDate, resetDate > date,
              refreshing || date.timeIntervalSince1970 - observedAt <= (provider == "claude" ? 1800 : 900)
        else { return .unconfirmed }
        return value >= 100 ? .exhausted : .available
    }

    func accessibilityText(at date: Date, refreshing: Bool = false) -> String {
        let reason = error.map { "，错误：\($0)" } ?? ""
        let freshness = refreshing ? "，正在刷新" : group(at: date) == .unconfirmed ? "，数据暂时无法确认" : ""
        let window = cycle == "monthly" ? "月度" : "每周"
        return "\(name)，\(subtitle)，\(window)剩余 \(percentageText)，重置倒计时 \(resetText(at: date))\(freshness)\(reason)"
    }
}

// In an extension so the memberwise initializer stays available.
extension Quota {
    init(_ subscription: Subscription) {
        self.init(id: subscription.id, provider: subscription.provider, name: subscription.name, cycle: subscription.cycle,
                  plan: subscription.plan, shortPlan: subscription.shortPlan, bucket: subscription.bucket, status: .unavailable)
    }

    /// Keeps the observed values and takes everything else from the subscription list.
    func described(by subscription: Subscription) -> Quota {
        var value = Quota(subscription)
        value.plan = plan ?? subscription.plan
        // The short label belongs to the listed plan, not to a plan the provider reports.
        value.shortPlan = value.plan == subscription.plan ? subscription.shortPlan : nil
        value.usedPercent = usedPercent
        value.resetsAt = resetsAt
        value.observedAt = observedAt
        value.status = status
        value.error = error
        value.missingPath = missingPath
        value.checkedPaths = checkedPaths
        return value
    }

    /// Records a failed query. A good value stays ready until the freshness window in
    /// `group(at:)` expires, so one failed cycle does not grey out the row.
    func failed(_ status: Status, error: String, missingPath: String? = nil, checkedPaths: [String]? = nil, at date: Date) -> Quota {
        var value = self
        value.error = error
        value.missingPath = missingPath
        value.checkedPaths = checkedPaths
        if group(at: date) == .unconfirmed { value.status = status }
        return value
    }

    static func restore(_ saved: [Quota], subscriptions: [Subscription]) -> [Quota] {
        subscriptions.map { subscription in
            guard var value = saved.first(where: { $0.id == subscription.id }) else { return Quota(subscription) }
            // Caches written before plan metadata kept Kiro's tier in the name.
            if value.plan == nil, value.provider == "kiro", value.name.hasPrefix("Kiro ") {
                value.plan = String(value.name.dropFirst(5))
            }
            return value.described(by: subscription)
        }
    }

    /// Distinct problems across rows, for the diagnostics menu. A hidden row lists every path that
    /// was checked, because a tool installed somewhere else would otherwise vanish silently.
    static func problems(in quotas: [Quota], warnings: [String] = []) -> [Problem] {
        let lines = (quotas.isEmpty ? [Problem("subscriptions.json is missing or invalid")] : []) + warnings.map { Problem($0) }
            + quotas.compactMap { quota -> Problem? in
                switch quota.status {
                case .missing: Problem("未检测到：\(quota.name)", paths: quota.checkedPaths ?? quota.missingPath.map { [$0] } ?? [])
                case .disabled: Problem("已停用：\(quota.name)")
                default: quota.error.map { Problem($0) }
                }
            }
        return lines.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Whether copying should wait: a row would show as stale in the image, and a refresh that may
    /// confirm it is under way.
    static func awaitsConfirmation(_ quotas: [Quota], refreshing: Set<String>, at date: Date) -> Bool {
        quotas.contains { $0.isInstalled && refreshing.contains($0.provider) && $0.group(at: date) == .unconfirmed }
    }
}

/// One line under 诊断, with the paths checked for a tool that is not installed.
struct Problem: Equatable {
    let text: String
    var paths: [String] = []

    init(_ text: String, paths: [String] = []) {
        self.text = text
        self.paths = paths
    }
}

struct UsageReport: Decodable {
    let fetchedAt: Double
    let quotas: [Quota]
    /// The providers the run covered; nil means all.
    var providers: [String]? = nil
    /// Collector-wide problems, such as a broken config.json.
    var warnings: [String]? = nil

    static let timeout: TimeInterval = 35

    /// Classifies a finished collector run. A run the app stopped exits 0 with no
    /// output, so the timeout flag must be checked before the status and the output.
    static func decode(_ data: Data, terminationStatus: Int32, timedOut: Bool) -> Result<UsageReport, CollectorFailure> {
        if timedOut { return .failure(CollectorFailure("Collector timeout: no result within \(Int(timeout)) s")) }
        guard terminationStatus == 0 else {
            return .failure(CollectorFailure("Collector exit: node exited with status \(terminationStatus)"))
        }
        guard let report = try? JSONDecoder().decode(UsageReport.self, from: data) else {
            return .failure(CollectorFailure("Collector parse: the output is not a usage report (\(data.count) bytes)"))
        }
        return .success(report)
    }

    /// Merges per row: a failed or missing row keeps its last good value and records the error.
    /// Rows of providers the run did not cover stay as they are; a disabled row is hidden at once.
    func merged(into current: [Quota], subscriptions: [Subscription], at date: Date) -> [Quota] {
        subscriptions.map { subscription in
            let previous = current.first { $0.id == subscription.id } ?? Quota(subscription)
            if let providers, !providers.contains(subscription.provider) { return previous }
            guard let fresh = quotas.first(where: { $0.id == subscription.id }) else {
                return previous.failed(.unavailable, error: "Collector protocol: no \(subscription.id) row in the report", at: date)
            }
            guard fresh.status != .ready, fresh.status != .disabled else { return fresh.described(by: subscription) }
            return previous.failed(fresh.status, error: fresh.error ?? "\(subscription.name) failed without a reason",
                                   missingPath: fresh.missingPath, checkedPaths: fresh.checkedPaths, at: date)
        }
    }
}

struct CollectorFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
