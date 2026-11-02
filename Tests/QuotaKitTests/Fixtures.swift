import Foundation
import Testing
@testable import QuotaKit

/// The repository's copies of the files `scripts/build.sh` bundles into Quota.app.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let resources = AppResources(subscriptions: repository.appendingPathComponent("scripts/subscriptions.json"),
                             collector: repository.appendingPathComponent("scripts/collect-usage.mjs"),
                             mascot: repository.appendingPathComponent("Assets/UsageImage/ShareMascot.png"))
let subscriptions = Subscription.load(from: resources.subscriptions)
/// The rows before any report, in list order.
let placeholders = subscriptions.map(Quota.init)

func placeholder(_ id: String) throws -> Quota {
    try row(id, in: placeholders)
}

func row(_ id: String, in quotas: [Quota]) throws -> Quota {
    try #require(quotas.first { $0.id == id })
}
