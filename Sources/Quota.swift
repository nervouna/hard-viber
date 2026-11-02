import AppKit
import Combine
import SwiftUI

struct Quota: Codable, Identifiable {
    let id: String
    let provider: String
    var name: String
    let cycle: String
    var plan: String?
    var bucket: String?
    var usedPercent: Double?
    var resetsAt: String?
    var observedAt: Double?
    var status: String
    var error: String?

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

    func resetText(at now: Date) -> String {
        guard let resetDate else { return "—" }
        if resetsAt?.count == 10 {
            // A date-only source cannot establish an hourly reset countdown.
            let calendar = Calendar.autoupdatingCurrent
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: resetDate).day ?? 0
            return "\(max(0, days))天"
        }
        let remaining = resetDate.timeIntervalSince(now)
        guard remaining > 0 else { return "0小时" }
        if remaining < 3600 { return "\(Int(ceil(remaining / 60)))分钟" }
        let hours = Int(remaining / 3600)
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
        let freshness = group(at: date) == 2 ? "，数据暂时无法确认" : ""
        let window = cycle == "monthly" ? "月度" : "每周"
        return "\(name)，\(subtitle)，\(window)剩余 \(percentageText)，重置倒计时 \(resetText(at: date))\(freshness)"
    }

    static let placeholders: [Quota] = [
        ("claude", "claude", "Claude", "weekly"),
        ("openai", "openai", "OpenAI", "weekly"),
        ("antigravity-gemini", "antigravity", "Antigravity", "weekly"),
        ("antigravity-claude", "antigravity", "Antigravity", "weekly"),
        ("kiro", "kiro", "Kiro", "monthly"),
        ("grok", "grok", "Grok", "weekly"),
    ].map { item in
        let bucket = item.0 == "antigravity-gemini" ? "Gemini" : item.0 == "antigravity-claude" ? "Claude + GPT" : nil
        return Quota(id: item.0, provider: item.1, name: item.2, cycle: item.3,
                     plan: item.1 == "antigravity" ? "Google AI Pro" : nil, bucket: bucket, status: "unavailable")
    }
}

struct UsageReport: Decodable {
    let fetchedAt: Double
    let quotas: [Quota]
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var quotas = Quota.placeholders
    private var process: Process?
    private var timer: Timer?
    private var lastRefresh: Date?
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quota/usage.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([Quota].self, from: data) {
            quotas = Quota.placeholders.map { placeholder in
                var value = saved.first { $0.id == placeholder.id } ?? placeholder
                if value.plan == nil, value.provider == "kiro", value.name.hasPrefix("Kiro ") {
                    value.plan = String(value.name.dropFirst(5))
                }
                value.name = placeholder.name
                value.bucket = placeholder.bucket
                value.plan = value.plan ?? placeholder.plan
                return value
            }
        }
    }

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
            fail("Missing collect-usage.mjs in Quota.app")
            return
        }
        let node = ["/opt/homebrew/opt/node@24/bin/node", "/usr/local/opt/node@24/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { fail("Node 24 was not found in the existing Homebrew installation"); return }
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [helper.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            process = task
        } catch {
            fail("Could not start \(node): \(error.localizedDescription)")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.process = nil
                guard task.terminationStatus == 0,
                      let report = try? JSONDecoder().decode(UsageReport.self, from: data),
                      Set(report.quotas.map(\.id)) == Set(Quota.placeholders.map(\.id)) else {
                    self.fail("The usage collector did not return a complete result")
                    return
                }
                self.quotas = report.quotas.map { fresh in
                    guard fresh.status != "ready", var previous = self.quotas.first(where: { $0.id == fresh.id }) else { return fresh }
                    previous.status = "unavailable"
                    previous.error = fresh.error
                    return previous
                }
                self.save()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self, weak task] in
            guard let task, self?.process === task, task.isRunning else { return }
            task.terminate()
        }
    }

    private func fail(_ message: String) {
        quotas = quotas.map { item in
            var item = item
            item.status = "unavailable"
            item.error = message
            return item
        }
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

private func quotaColor(for group: Int, remaining: Double?) -> Color {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quota.accessibilityText(at: now))
    }
}

struct QuotaPanel: View {
    @ObservedObject var store: UsageStore
    let onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let groups = (0...2).map { group in store.quotas.filter { $0.group(at: timeline.date) == group } }.filter { !$0.isEmpty }
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, quotas in
                    if index > 0 {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    ForEach(quotas) { quota in QuotaRow(quota: quota, now: timeline.date) }
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var copyFeedback: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "chart.donut", accessibilityDescription: "Quota")
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
        let groups = Set(store.quotas.map { $0.group(at: Date()) }).count
        popover.contentSize = NSSize(width: 336, height: 10 + store.quotas.count * 36 + max(0, groups - 1) * 9)
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
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "退出 Quota", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { show() }
    }

    @objc private func copyUsageImage() {
        let copied = QuotaImageExporter.copy(store.quotas, at: Date())
        copyFeedback?.cancel()
        setStatusImage(copied ? "checkmark" : "xmark", label: copied ? "用量图片已复制" : "用量图片复制失败")
        if !copied { NSSound.beep() }
        let restore = DispatchWorkItem { [weak self] in
            self?.setStatusImage("chart.donut", label: "Quota")
        }
        copyFeedback = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: restore)
    }

    private func setStatusImage(_ symbol: String, label: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        item.button?.image = image
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
    }

    @objc private func refresh() { store.refresh(force: true) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        copyFeedback?.cancel()
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
