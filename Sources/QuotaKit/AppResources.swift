import Foundation

/// The files the app reads besides its own code. `scripts/build.sh` copies them flat into
/// Quota.app's Contents/Resources; tests point at the repository's copies instead.
public struct AppResources: Sendable {
    /// `scripts/subscriptions.json`, the rows and their labels.
    var subscriptions: URL
    /// `scripts/collect-usage.mjs`, which reads `subscriptions.json` and `VERSION` next to itself.
    var collector: URL
    /// `Assets/UsageImage/ShareMascot.png`, for the shareable image.
    var mascot: URL

    init(subscriptions: URL, collector: URL, mascot: URL) {
        self.subscriptions = subscriptions
        self.collector = collector
        self.mascot = mascot
    }

    /// The layout of Quota.app's Contents/Resources.
    public init(directory: URL) {
        self.init(subscriptions: directory.appendingPathComponent("subscriptions.json"),
                  collector: directory.appendingPathComponent("collect-usage.mjs"),
                  mascot: directory.appendingPathComponent("ShareMascot.png"))
    }
}
