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

    static let all: [Subscription] = {
        #if TESTING
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/subscriptions.json")
        #else
        guard let url = Bundle.main.url(forResource: "subscriptions", withExtension: "json") else { return [] }
        #endif
        return (try? JSONDecoder().decode([Subscription].self, from: Data(contentsOf: url))) ?? []
    }()
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

    /// Rows of a tool that is not installed are hidden.
    var isInstalled: Bool { status != "missing" }

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

    func group(at date: Date) -> Int {
        guard status == "ready", let value = usedPercent, value.isFinite, value >= 0,
              let observedAt, let resetDate, resetDate > date,
              date.timeIntervalSince1970 - observedAt <= (provider == "claude" ? 1800 : 900)
        else { return 2 }
        return value >= 100 ? 1 : 0
    }

    func accessibilityText(at date: Date) -> String {
        let reason = error.map { "，错误：\($0)" } ?? ""
        let freshness = group(at: date) == 2 ? "，数据暂时无法确认" : ""
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
        return value
    }

    /// Records a failed query. A good value stays ready until the freshness window in
    /// `group(at:)` expires, so one failed cycle does not grey out the row.
    func failed(_ status: String, error: String, missingPath: String? = nil, at date: Date) -> Quota {
        var value = self
        value.error = error
        value.missingPath = missingPath
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

    /// Distinct errors across rows, for the diagnostics menu. Hidden rows name the path that
    /// was checked, because a tool installed somewhere else would otherwise vanish silently.
    static func problems(in quotas: [Quota]) -> [String] {
        let lines = (quotas.isEmpty ? ["subscriptions.json is missing or invalid"] : []) + quotas.compactMap { quota in
            quota.isInstalled ? quota.error : "未检测到：\(quota.name)" + (quota.missingPath.map { "（\($0)）" } ?? "")
        }
        return lines.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

struct UsageReport: Decodable {
    let fetchedAt: Double
    let quotas: [Quota]

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
    func merged(into current: [Quota], subscriptions: [Subscription] = Subscription.all, at date: Date) -> [Quota] {
        subscriptions.map { subscription in
            let previous = current.first { $0.id == subscription.id } ?? Quota(subscription)
            guard let fresh = quotas.first(where: { $0.id == subscription.id }) else {
                return previous.failed("unavailable", error: "Collector protocol: no \(subscription.id) row in the report", at: date)
            }
            guard fresh.status != "ready" else { return fresh.described(by: subscription) }
            return previous.failed(fresh.status, error: fresh.error ?? "\(subscription.name) failed without a reason",
                                   missingPath: fresh.missingPath, at: date)
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
    private var process: Process?
    private var timedOut = false
    private var timer: Timer?
    private var lastRefresh: Date?
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quota/usage.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([Quota].self, from: data) {
            quotas = Quota.restore(saved)
        }
    }

    var problems: [String] { Quota.problems(in: quotas) }
    var installedQuotas: [Quota] { quotas.filter(\.isInstalled) }

    func start() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh(force: Bool = false) {
        guard process == nil else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        lastRefresh = Date()
        guard let helper = Bundle.main.url(forResource: "collect-usage", withExtension: "mjs") else {
            fail("Collector spawn: collect-usage.mjs is missing from Quota.app")
            return
        }
        let node = ["/opt/homebrew/opt/node@24/bin/node", "/usr/local/opt/node@24/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { fail("Collector spawn: Homebrew node@24 is not installed"); return }
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [helper.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = CollectorLog.handle() ?? FileHandle.nullDevice
        timedOut = false
        do {
            try task.run()
            process = task
        } catch {
            fail("Collector spawn: could not start \(node): \(error.localizedDescription)")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.process = nil
                switch UsageReport.decode(data, terminationStatus: task.terminationStatus, timedOut: self.timedOut) {
                case .success(let report):
                    self.quotas = report.merged(into: self.quotas, at: Date())
                    for problem in Quota.problems(in: self.quotas) where problem.hasPrefix("Collector ") {
                        CollectorLog.append(problem)
                    }
                    self.save()
                case .failure(let failure):
                    self.fail(failure.message)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + UsageReport.timeout) { [weak self, weak task] in
            guard let task, self?.process === task, task.isRunning else { return }
            self?.timedOut = true
            task.terminate()
        }
    }

    private func fail(_ message: String) {
        CollectorLog.append(message)
        quotas = quotas.map { $0.failed("unavailable", error: message, at: Date()) }
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
        if let process, process.isRunning { process.terminate() }
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
        .accessibilityHidden(true)
    }
}

struct QuotaRow: View {
    let quota: Quota
    let now: Date

    var body: some View {
        let group = quota.group(at: now)
        HStack(spacing: 8) {
            QuotaRing(quota: quota, group: group)
            VStack(alignment: .leading, spacing: 1) {
                Text(quota.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(group == 0 ? .primary : .secondary)
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
                    .foregroundStyle(group == 0 ? .primary : .secondary)
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
        .accessibilityLabel(quota.accessibilityText(at: now))
    }
}

struct QuotaPanel: View {
    @ObservedObject var store: UsageStore
    let onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let quotas = store.installedQuotas
            let groups = (0...2).map { group in quotas.filter { $0.group(at: timeline.date) == group } }.filter { !$0.isEmpty }
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, quotas in
                    if index > 0 {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    ForEach(quotas) { quota in QuotaRow(quota: quota, now: timeline.date) }
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
    private var observation: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?

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
        observation = store.$quotas.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resize() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        store.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.show() }
        }
    }

    private func resize() {
        let quotas = store.installedQuotas
        let groups = Set(quotas.map { $0.group(at: Date()) }).count
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
        for problem in problems.isEmpty ? ["没有错误"] : problems {
            let line = menu.addItem(withTitle: problem.count > 90 ? problem.prefix(89) + "…" : problem, action: nil, keyEquivalent: "")
            line.toolTip = problem
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "").target = self
    }

    @objc private func openLog() {
        if !NSWorkspace.shared.open(CollectorLog.url) { NSSound.beep() }
    }

    @objc private func copyUsageImage() {
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
