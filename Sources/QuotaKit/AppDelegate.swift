import AppKit
import Combine
import SwiftUI

/// Starts the menu bar app.
public enum QuotaApp {
    @MainActor public static func run(resources: AppResources) {
        let app = NSApplication.shared
        let delegate = AppDelegate(resources: resources)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let resources: AppResources
    private let store: UsageStore
    /// Loaded at the first copy.
    private lazy var exporter = QuotaImageExporter(mascot: resources.mascot)
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var observations: [AnyCancellable] = []
    private var wakeObserver: NSObjectProtocol?
    /// When a copy waiting for a refresh gives up and copies what it has.
    private var copyDeadline: Date?

    init(resources: AppResources) {
        self.resources = resources
        store = UsageStore(resources: resources)
    }

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
        popover.delegate = self
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
        store.panelOpen = true
        store.refresh()
        resize()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { store.panelOpen = false }

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
        if exporter.copy(store.quotas, at: Date()) {
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
