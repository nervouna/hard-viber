import AppKit
import Combine
import SwiftUI

/// One row of `scripts/subscriptions.json`, which the collector reads too.
struct Subscription: Decodable {
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

    static let all: [Subscription] = {
        #if TESTING
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/subscriptions.json")
        #else
        guard let url = Bundle.main.url(forResource: "subscriptions", withExtension: "json") else { return [] }
        #endif
        return (try? JSONDecoder().decode([Subscription].self, from: Data(contentsOf: url))) ?? []
    }()

    /// Providers in list order.
    static var providers: [String] { all.map(\.provider).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    static func isLocal(_ provider: String) -> Bool { all.contains { $0.provider == provider && $0.local == true } }
}

struct Quota: Codable, Identifiable {
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
    var status: String
    var error: String?
    /// The executable or file that was checked when `status` is "missing".
    var missingPath: String?
    /// Every path that was checked when `status` is "missing".
    var checkedPaths: [String]?

    /// Rows of a tool that is not installed, or that is turned off in config.json, are hidden.
    var isInstalled: Bool { status != "missing" && status != "disabled" }

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

    /// 0 current, 1 exhausted, 2 stale or failed. A value older than its freshness window is stale
    /// (the collector's Claude read uses the same 1800 s), except while `refreshing`: a refresh that
    /// may confirm it is under way, so it keeps its place instead of turning grey for a few seconds.
    func group(at date: Date, refreshing: Bool = false) -> Int {
        guard status == "ready", let value = usedPercent, value.isFinite, value >= 0,
              let observedAt, let resetDate, resetDate > date,
              refreshing || date.timeIntervalSince1970 - observedAt <= (provider == "claude" ? 1800 : 900)
        else { return 2 }
        return value >= 100 ? 1 : 0
    }

    func accessibilityText(at date: Date, refreshing: Bool = false) -> String {
        let reason = error.map { "，错误：\($0)" } ?? ""
        let freshness = refreshing ? "，正在刷新" : group(at: date) == 2 ? "，数据暂时无法确认" : ""
        let window = cycle == "monthly" ? "月度" : "每周"
        return "\(name)，\(subtitle)，\(window)剩余 \(percentageText)，重置倒计时 \(resetText(at: date))\(freshness)\(reason)"
    }

    static let placeholders = Subscription.all.map(Quota.init)
}

// In an extension so the memberwise initializer stays available.
extension Quota {
    init(_ subscription: Subscription) {
        self.init(id: subscription.id, provider: subscription.provider, name: subscription.name, cycle: subscription.cycle,
                  plan: subscription.plan, shortPlan: subscription.shortPlan, bucket: subscription.bucket, status: "unavailable")
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
    func failed(_ status: String, error: String, missingPath: String? = nil, checkedPaths: [String]? = nil, at date: Date) -> Quota {
        var value = self
        value.error = error
        value.missingPath = missingPath
        value.checkedPaths = checkedPaths
        if group(at: date) == 2 { value.status = status }
        return value
    }

    static func restore(_ saved: [Quota], subscriptions: [Subscription] = Subscription.all) -> [Quota] {
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
                case "missing": Problem("未检测到：\(quota.name)", paths: quota.checkedPaths ?? quota.missingPath.map { [$0] } ?? [])
                case "disabled": Problem("已停用：\(quota.name)")
                default: quota.error.map { Problem($0) }
                }
            }
        return lines.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Whether copying should wait: a row would show as stale in the image, and a refresh that may
    /// confirm it is under way.
    static func awaitsConfirmation(_ quotas: [Quota], refreshing: Set<String>, at date: Date) -> Bool {
        quotas.contains { $0.isInstalled && refreshing.contains($0.provider) && $0.group(at: date) == 2 }
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
    func merged(into current: [Quota], subscriptions: [Subscription] = Subscription.all, at date: Date) -> [Quota] {
        subscriptions.map { subscription in
            let previous = current.first { $0.id == subscription.id } ?? Quota(subscription)
            if let providers, !providers.contains(subscription.provider) { return previous }
            guard let fresh = quotas.first(where: { $0.id == subscription.id }) else {
                return previous.failed("unavailable", error: "Collector protocol: no \(subscription.id) row in the report", at: date)
            }
            guard fresh.status != "ready", fresh.status != "disabled" else { return fresh.described(by: subscription) }
            return previous.failed(fresh.status, error: fresh.error ?? "\(subscription.name) failed without a reason",
                                   missingPath: fresh.missingPath, checkedPaths: fresh.checkedPaths, at: date)
        }
    }
}

struct CollectorFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var quotas = Quota.placeholders
    /// Providers whose refresh is under way.
    @Published private(set) var refreshing: Set<String> = []
    /// Collector-wide problems from the last run, such as a broken config.json.
    @Published private(set) var warnings: [String] = []
    private var runs: [Run] = []
    private var lastRun: [String: Date] = [:]
    /// Failed queries in a row, per provider.
    private var failures: [String: Int] = [:]
    private var timer: Timer?
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quota/usage.json")

    /// One collector process and the providers it queries.
    private final class Run {
        let task: Process
        let providers: Set<String>
        var timedOut = false

        init(task: Process, providers: Set<String>) {
            self.task = task
            self.providers = providers
        }
    }

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([Quota].self, from: data) {
            quotas = Quota.restore(saved)
        }
    }

    var problems: [Problem] { Quota.problems(in: quotas, warnings: warnings) }
    var installedQuotas: [Quota] { quotas.filter(\.isInstalled) }
    var awaitsConfirmation: Bool { Quota.awaitsConfirmation(quotas, refreshing: refreshing, at: Date()) }

    func start() {
        refresh(force: true)
        // A cheap check each minute; the policy decides what is due. The tolerance lets macOS
        // coalesce the wake-ups.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs the providers whose background interval has passed.
    private func poll() {
        let conditions = PowerConditions.current()
        let now = Date()
        run(Set(Subscription.providers.filter {
            RefreshPolicy.isDue(local: Subscription.isLocal($0), lastRun: lastRun[$0], failures: failures[$0] ?? 0, conditions: conditions, at: now)
        }))
    }

    /// After a wake, refreshes the providers that refresh in the background under the current
    /// power conditions.
    func refreshAfterWake() {
        let conditions = PowerConditions.current()
        refresh(Set(Subscription.providers.filter { RefreshPolicy.interval(local: Subscription.isLocal($0), conditions) != nil }))
    }

    /// Refreshes the given providers (default: all) that were not refreshed in the last minute;
    /// `force` skips that limit.
    func refresh(_ providers: Set<String>? = nil, force: Bool = false) {
        let now = Date()
        run((providers ?? Set(Subscription.providers)).filter { provider in
            force || lastRun[provider].map { now.timeIntervalSince($0) >= RefreshPolicy.throttle } ?? true
        })
    }

    private func run(_ requested: Set<String>) {
        let providers = requested.subtracting(refreshing)
        guard !providers.isEmpty else { return }
        let now = Date()
        for provider in providers { lastRun[provider] = now }
        guard let helper = Bundle.main.url(forResource: "collect-usage", withExtension: "mjs") else {
            fail("Collector spawn: collect-usage.mjs is missing from Quota.app", providers: providers)
            return
        }
        let node: String
        switch NodeLocator.locate(configured: UserConfig.load().node) {
        case .success(let path): node = path
        case .failure(let failure): fail(failure.message, providers: providers); return
        }
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [helper.path, "--providers", providers.sorted().joined(separator: ",")]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = CollectorLog.handle() ?? FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            fail("Collector spawn: could not start \(node): \(error.localizedDescription)", providers: providers)
            return
        }
        runs.append(Run(task: task, providers: providers))
        refreshing.formUnion(providers)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            DispatchQueue.main.async { self?.finish(task, data: data) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + UsageReport.timeout) { [weak self, weak task] in
            guard let task, task.isRunning, let run = self?.runs.first(where: { $0.task === task }) else { return }
            run.timedOut = true
            task.terminate()
        }
    }

    private func finish(_ task: Process, data: Data) {
        guard let index = runs.firstIndex(where: { $0.task === task }) else { return }
        let run = runs.remove(at: index)
        refreshing.subtract(run.providers)
        switch UsageReport.decode(data, terminationStatus: task.terminationStatus, timedOut: run.timedOut) {
        case .success(let report):
            quotas = report.merged(into: quotas, at: Date())
            warnings = report.warnings ?? []
            for provider in run.providers {
                let rows = report.quotas.filter { $0.provider == provider }
                failures[provider] = rows.isEmpty || rows.contains { $0.status == "unavailable" } ? (failures[provider] ?? 0) + 1 : 0
            }
            for problem in Quota.problems(in: quotas.filter { run.providers.contains($0.provider) }) where problem.text.hasPrefix("Collector ") {
                CollectorLog.append(problem.text)
            }
            save()
        case .failure(let failure):
            fail(failure.message, providers: run.providers)
        }
    }

    private func fail(_ message: String, providers: Set<String>) {
        CollectorLog.append(message)
        quotas = quotas.map { providers.contains($0.provider) ? $0.failed("unavailable", error: message, at: Date()) : $0 }
        for provider in providers { failures[provider, default: 0] += 1 }
    }

    private func save() {
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(quotas)
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* A read-only home directory must not interrupt the menu. */ }
    }

    func stop() {
        timer?.invalidate()
        for run in runs where run.task.isRunning { run.task.terminate() }
    }
}

func quotaColor(for group: Int, remaining: Double?) -> Color {
    guard group == 0, let remaining, remaining > 0 else { return .secondary }
    if remaining > 50 { return Color(red: 0.23, green: 0.53, blue: 0.43) }
    if remaining > 20 { return Color(red: 0.62, green: 0.42, blue: 0.10) }
    return Color(red: 0.78, green: 0.36, blue: 0.29)
}

struct QuotaRing: View {
    let quota: Quota
    let group: Int
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var hidesUnconfirmed = false
    var refreshing = false

    var body: some View {
        let color = quotaColor(for: group, remaining: quota.remainingPercent)
        ZStack {
            Circle().stroke(color.opacity(group == 2 ? 0.15 : 0.2), lineWidth: lineWidth)
            if let value = quota.remainingPercent, value > 0, !(hidesUnconfirmed && group == 2) {
                let fraction = min(1, value / 100)
                // Round caps must not fill the final gap of a nearly full ring.
                let cap = lineWidth / (2 * .pi * size)
                let start = fraction == 1 ? 0 : min(cap, fraction / 2)
                let end = fraction == 1 ? 1 : max(start + 0.00001, fraction - cap)
                Circle()
                    .trim(from: start, to: end)
                    .stroke(color.opacity(group == 2 ? 0.4 : 1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .phaseAnimator(refreshing ? [1, 0.3] : [1]) { ring, opacity in ring.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.7) }
        .accessibilityHidden(true)
    }
}

struct QuotaRow: View {
    let quota: Quota
    let now: Date
    var refreshing = false

    var body: some View {
        let group = quota.group(at: now, refreshing: refreshing)
        // A value past its freshness window stays in place while its refresh runs, but in grey.
        let confirmed = group != 2 && quota.group(at: now) == group
        HStack(spacing: 8) {
            QuotaRing(quota: quota, group: confirmed ? group : 2, refreshing: refreshing)
            VStack(alignment: .leading, spacing: 1) {
                Text(quota.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(group == 0 && confirmed ? .primary : .secondary)
                Text(quota.subtitle)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(quota.percentageText)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(group == 0 && confirmed ? .primary : .secondary)
                    .minimumScaleFactor(0.85)
                Text(quota.resetText(at: now))
                    .font(.system(size: 10.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .contentShape(Rectangle())
        .help(quota.error ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quota.accessibilityText(at: now, refreshing: refreshing))
    }
}

struct QuotaPanel: View {
    @ObservedObject var store: UsageStore
    let onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let quotas = store.installedQuotas
            let refreshing = store.refreshing
            let groups = (0...2).map { group in
                quotas.filter { $0.group(at: timeline.date, refreshing: refreshing.contains($0.provider)) == group }
            }.filter { !$0.isEmpty }
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, quotas in
                    if index > 0 {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    ForEach(quotas) { quota in
                        QuotaRow(quota: quota, now: timeline.date, refreshing: refreshing.contains(quota.provider))
                    }
                }
                if quotas.isEmpty {
                    Text("未检测到已安装的服务")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .padding(.vertical, 5)
            .frame(width: 336)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .accessibilityAction(named: Text("复制用量图片"), onCopy)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = UsageStore()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var observations: [AnyCancellable] = []
    private var wakeObserver: NSObjectProtocol?
    /// When a copy waiting for a refresh gives up and copies what it has.
    private var copyDeadline: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Quota")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.toolTip = "Quota"
            button.setAccessibilityLabel("Quota")
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: QuotaPanel(store: store, onCopy: { [weak self] in self?.copyUsageImage() }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        let applicationMenu = NSMenu()
        let applicationItem = applicationMenu.addItem(withTitle: "Quota", action: nil, keyEquivalent: "")
        let commands = NSMenu()
        let copyCommand = commands.addItem(withTitle: "复制用量图片", action: #selector(copyUsageImage), keyEquivalent: "c")
        copyCommand.target = self
        let refreshCommand = commands.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshCommand.target = self
        commands.addItem(diagnosticsItem())
        commands.addItem(LaunchAtLogin.shared.menuItem())
        let quitCommand = commands.addItem(withTitle: "退出 Quota", action: #selector(quit), keyEquivalent: "q")
        quitCommand.target = self
        applicationItem.submenu = commands
        NSApplication.shared.mainMenu = applicationMenu
        resize()
        // The publishers fire before the value changes, so read the store on the next turn.
        observations = [store.$quotas.map { _ in () }.eraseToAnyPublisher(), store.$refreshing.map { _ in () }.eraseToAnyPublisher()].map {
            $0.sink { [weak self] in
                DispatchQueue.main.async {
                    self?.resize()
                    self?.copyWhenConfirmed()
                }
            }
        }
        // The network is often not back the moment the Mac wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.store.refreshAfterWake() }
        }
        store.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.show() }
        }
    }

    private func resize() {
        let quotas = store.installedQuotas
        let groups = Set(quotas.map { $0.group(at: Date(), refreshing: store.refreshing.contains($0.provider)) }).count
        // An empty list shows one row-high message.
        popover.contentSize = NSSize(width: 336, height: 10 + max(1, quotas.count) * 36 + max(0, groups - 1) * 9)
    }

    private func show() {
        guard let button = item.button else { return }
        store.refresh()
        resize()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func toggle() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let copy = menu.addItem(withTitle: "复制用量图片", action: #selector(copyUsageImage), keyEquivalent: "c")
            copy.target = self
            let refresh = menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(diagnosticsItem())
            menu.addItem(.separator())
            menu.addItem(LaunchAtLogin.shared.menuItem())
            let quit = menu.addItem(withTitle: "退出 Quota", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { show() }
    }

    private func diagnosticsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "诊断", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        item.submenu?.delegate = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let problems = store.problems
        // Items without an action render disabled, which suits read-only error lines.
        for problem in problems.isEmpty ? [Problem("没有错误")] : problems {
            let text = problem.text
            let line = menu.addItem(withTitle: text.count > 90 ? text.prefix(89) + "…" : text, action: nil, keyEquivalent: "")
            line.toolTip = text
            if !problem.paths.isEmpty {
                line.submenu = NSMenu()
                for path in problem.paths { line.submenu?.addItem(withTitle: path, action: nil, keyEquivalent: "") }
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开配置文件", action: #selector(openConfig), keyEquivalent: "").target = self
    }

    @objc private func openLog() {
        if !NSWorkspace.shared.open(CollectorLog.url) { NSSound.beep() }
    }

    /// Creates an empty config.json first, which changes nothing, so there is a file to edit.
    @objc private func openConfig() {
        let url = UserConfig.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("{\n  \"providers\": {}\n}\n".utf8).write(to: url, options: .withoutOverwriting)
        }
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }

    /// Copies the image once no row that would show as stale is still being refreshed, waiting
    /// at most 10 s; values younger than a minute are copied at once.
    @objc private func copyUsageImage() {
        store.refresh()
        let deadline = Date().addingTimeInterval(10)
        copyDeadline = deadline
        copyWhenConfirmed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.copyWhenConfirmed() }
    }

    private func copyWhenConfirmed() {
        guard let copyDeadline, !store.awaitsConfirmation || Date() >= copyDeadline else { return }
        self.copyDeadline = nil
        if QuotaImageExporter.copy(store.quotas, at: Date()) {
            popover.performClose(nil)
        } else {
            NSSound.beep()
        }
    }

    @objc private func refresh() { store.refresh(force: true) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

#if !TESTING
@main
struct QuotaApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
