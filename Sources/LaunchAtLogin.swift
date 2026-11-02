import AppKit
import ServiceManagement

/// The "开机时启动" menu item, backed by `SMAppService.mainApp`.
@MainActor
final class LaunchAtLogin: NSObject, NSMenuItemValidation {
    static let shared = LaunchAtLogin()

    private let title = "开机时启动"

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggle), keyEquivalent: "")
        item.target = self
        return item
    }

    // Menus validate their items each time they open, so the item follows changes made in System Settings.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggle) else { return true }
        // Every SMAppService call, even a status read, points the login item at the calling bundle,
        // so a build in a worktree or build/ must not make one.
        guard isInApplicationsFolder else {
            menuItem.state = .off
            menuItem.toolTip = "运行 scripts/install.sh 把 Quota 安装到 ~/Applications 后可用"
            return false
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            menuItem.state = .on
            menuItem.title = title
        case .requiresApproval:
            menuItem.state = .mixed
            menuItem.title = "\(title)（需在系统设置中允许）"
        default:
            // A bundle that was never registered reports .notFound rather than .notRegistered.
            menuItem.state = .off
            menuItem.title = title
        }
        return true
    }

    @objc private func toggle() {
        // Let the status item menu finish closing before any alert runs.
        DispatchQueue.main.async { self.apply() }
    }

    private func apply() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                askForApproval()
                return
            default:
                try service.register()
            }
        } catch {
            if service.status == .requiresApproval { askForApproval() } else { report(error) }
            return
        }
        if service.status == .requiresApproval { askForApproval() }
    }

    private var isInApplicationsFolder: Bool {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        return FileManager.default.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask])
            .contains { $0.resolvingSymlinksInPath() == folder }
    }

    private func askForApproval() {
        let alert = NSAlert()
        alert.messageText = "需要在系统设置中允许 Quota"
        alert.informativeText = "Quota 已添加为登录项，但在「系统设置 › 通用 › 登录项」中被关闭了。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if run(alert) == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
    }

    private func report(_ error: Error) {
        let error = error as NSError
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法更改开机时启动"
        alert.informativeText = "\(error.localizedDescription)（\(error.domain) \(error.code)）"
        run(alert)
    }

    @discardableResult
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // An accessory app's alert stays behind other windows unless the app comes forward first.
        NSApplication.shared.activate()
        return alert.runModal()
    }
}
