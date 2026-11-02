import AppKit
import Foundation

@main
struct QuotaImageTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let now = ISO8601DateFormatter().date(from: "2026-11-02T07:21:00Z")!
        let samples: [(String, Double, Double)] = [
            ("Ultra", 66, 46), ("Pro", 72, 83),
            ("Google AI Pro", 0, 53), ("Google AI Pro", 0, 167),
            ("Pro", 2, 0), ("SuperGrok", 100, 20),
        ]
        let quotas = Quota.placeholders.enumerated().map { index, value in
            var quota = value
            quota.plan = samples[index].0
            quota.usedPercent = samples[index].1
            quota.observedAt = now.timeIntervalSince1970
            quota.status = "ready"
            quota.resetsAt = quota.provider == "kiro" ? "2026-12-01" :
                ISO8601DateFormatter().string(from: now.addingTimeInterval(samples[index].2 * 3600))
            return quota
        }

        let reordered = [quotas[5], quotas[0], quotas[2], quotas[4], quotas[1], quotas[3]]
        let sorted = QuotaImageExporter.orderedQuotas(reordered, at: now)
        precondition(sorted.map(\.id) == Array(reordered.dropFirst()).map(\.id) + [quotas[5].id],
                     "Exhausted subscriptions must move last without reordering the other subscriptions")

        let bitmap = QuotaImageExporter.render(quotas, at: now)!
        precondition(bitmap.pixelsWide == 1440 && bitmap.pixelsHigh == 1280, "The export must be a 2x bitmap")
        let png = bitmap.representation(using: .png, properties: [:])!
        precondition(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        precondition(QuotaImageExporter.copy(quotas, at: now, to: pasteboard))
        precondition(pasteboard.data(forType: .png) != nil && pasteboard.data(forType: .tiff) != nil,
                     "The clipboard must offer both PNG and TIFF for native paste targets")
        precondition(NSImage(pasteboard: pasteboard) != nil, "Native image paste must decode the clipboard")
        let changeCount = pasteboard.changeCount
        precondition(!QuotaImageExporter.copy([], at: now, to: pasteboard))
        precondition(pasteboard.changeCount == changeCount, "A failed render must leave the clipboard intact")

        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("quota-image-fixture.png"))
            var unavailable = quotas
            unavailable[0].status = "unavailable"
            unavailable[1].observedAt = now.addingTimeInterval(-901).timeIntervalSince1970
            unavailable[4].usedPercent = 99.96
            let fallback = QuotaImageExporter.render(unavailable, at: now)!
            try fallback.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("quota-image-edge-cases.png"))
        }
        print("Quota image tests passed: stable exhausted ordering, 2x PNG rendering, native clipboard formats, failed-copy preservation.")
    }
}
