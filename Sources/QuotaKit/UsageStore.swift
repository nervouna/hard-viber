import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var quotas: [Quota]
    /// Providers whose refresh is under way.
    @Published private(set) var refreshing: Set<String> = []
    /// Collector-wide problems from the last run, such as a broken config.json.
    @Published private(set) var warnings: [String] = []
    private var runs: [Run] = []
    private var lastRun: [String: Date] = [:]
    /// Failed queries in a row, per provider.
    private var failures: [String: Int] = [:]
    private var timer: Timer?
    /// Set while the popover is shown.
    var panelOpen = false
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quota/usage.json")
    private let collector: URL
    private let subscriptions: [Subscription]

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

    init(resources: AppResources) {
        collector = resources.collector
        subscriptions = Subscription.load(from: resources.subscriptions)
        quotas = subscriptions.map(Quota.init)
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([Quota].self, from: data) {
            quotas = Quota.restore(saved, subscriptions: subscriptions)
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
        run(Set(subscriptions.providers.filter {
            RefreshPolicy.isDue(local: subscriptions.isLocal($0), lastRun: lastRun[$0], failures: failures[$0] ?? 0,
                                conditions: conditions, panelOpen: panelOpen, at: now)
        }))
    }

    /// After a wake, refreshes the providers that refresh in the background under the current
    /// power conditions.
    func refreshAfterWake() {
        let conditions = PowerConditions.current()
        refresh(Set(subscriptions.providers.filter { RefreshPolicy.interval(local: subscriptions.isLocal($0), conditions) != nil }))
    }

    /// Refreshes the given providers (default: all) that were not refreshed in the last minute;
    /// `force` skips that limit.
    func refresh(_ providers: Set<String>? = nil, force: Bool = false) {
        let now = Date()
        run((providers ?? Set(subscriptions.providers)).filter { provider in
            force || lastRun[provider].map { now.timeIntervalSince($0) >= RefreshPolicy.throttle } ?? true
        })
    }

    private func run(_ requested: Set<String>) {
        let providers = requested.subtracting(refreshing)
        guard !providers.isEmpty else { return }
        let now = Date()
        for provider in providers { lastRun[provider] = now }
        guard FileManager.default.fileExists(atPath: collector.path) else {
            fail("Collector spawn: \(collector.path) is missing", providers: providers)
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
        task.arguments = [collector.path, "--providers", providers.sorted().joined(separator: ",")]
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
            quotas = report.merged(into: quotas, subscriptions: subscriptions, at: Date())
            warnings = report.warnings ?? []
            for provider in run.providers {
                let rows = report.quotas.filter { $0.provider == provider }
                failures[provider] = rows.isEmpty || rows.contains { $0.status == .unavailable } ? (failures[provider] ?? 0) + 1 : 0
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
        quotas = quotas.map { providers.contains($0.provider) ? $0.failed(.unavailable, error: message, at: Date()) : $0 }
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
