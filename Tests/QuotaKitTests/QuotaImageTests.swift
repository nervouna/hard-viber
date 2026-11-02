import AppKit
import Foundation
import Testing
@testable import QuotaKit

/// `QUOTA_IMAGE_FIXTURES=<directory> swift test` (or `scripts/test.sh <directory>`) also writes the
/// shareable images there.
private let fixtureDirectory = ProcessInfo.processInfo.environment["QUOTA_IMAGE_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 }

@MainActor
struct QuotaImageTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-02T09:22:00Z")!
    let exporter = QuotaImageExporter(mascot: resources.mascot)
    /// One ready row per subscription, in list order: one exhausted (Grok) and one on fumes (Kiro).
    let quotas: [Quota]

    init() {
        _ = NSApplication.shared
        let samples: [(String, Double, Double)] = [
            ("Ultra", 68, 43), ("Pro", 80, 81),
            ("Google AI Pro", 0, 51), ("Google AI Pro", 0, 167),
            ("Pro", 14, 0), ("SuperGrok", 100, 18),
        ]
        let now = now
        quotas = placeholders.enumerated().map { index, value in
            var quota = value
            quota.plan = samples[index].0
            quota.usedPercent = samples[index].1
            quota.observedAt = now.timeIntervalSince1970
            quota.status = .ready
            quota.resetsAt = quota.provider == "kiro" ? "2026-12-01" :
                ISO8601DateFormatter().string(from: now.addingTimeInterval(samples[index].2 * 3600))
            return quota
        }
    }

    func with(_ quotas: [Quota], _ change: (inout Quota) -> Void) -> [Quota] {
        quotas.map { quota in var quota = quota; change(&quota); return quota }
    }

    /// Two rows gone unknown, plus a nonzero balance below 0.1%.
    var stale: [Quota] {
        var stale = quotas
        stale[0].status = .unavailable
        stale[1].observedAt = now.addingTimeInterval(-901).timeIntervalSince1970
        stale[4].usedPercent = 99.96
        return stale
    }

    /// Four installed tools, then two.
    var fourRows: [Quota] {
        var installed = quotas
        installed[3].status = .missing
        installed[4].status = .missing
        return installed
    }

    var twoRows: [Quota] {
        var installed = fourRows
        installed[2].status = .missing
        installed[5].status = .missing
        return installed
    }

    /// Every image the fixtures option writes, by name.
    var renders: [(String, [Quota])] {
        [("fixture", quotas), ("edge-cases", stale), ("four-rows", fourRows), ("two-rows", twoRows),
         ("three-rows", [quotas[0], quotas[1], quotas[4]]), ("single", [quotas[0]]),
         ("full", with(quotas) { $0.usedPercent = 0 }), ("silent", with(quotas) { $0.status = .unavailable })]
    }

    func bitmap(_ quotas: [Quota]) throws -> NSBitmapImageRep {
        let bitmap = try #require(exporter.render(quotas, at: now))
        #expect(bitmap.pixelsWide == 1600 && bitmap.pixelsHigh == 1024, "The export must be a 2x landscape bitmap")
        return bitmap
    }

    @Test("Exhausted subscriptions move last, the rest keep their order")
    func ordering() {
        let reordered = [quotas[5], quotas[0], quotas[2], quotas[4], quotas[1], quotas[3]]
        let sorted = QuotaImageExporter.orderedQuotas(reordered, at: now)
        #expect(sorted.map(\.id) == Array(reordered.dropFirst()).map(\.id) + [quotas[5].id],
                "Exhausted subscriptions must move last without reordering the other subscriptions")
    }

    @Test("The cover copy counts what the data shows; the headline rotates within a situation")
    func coverCopy() {
        let reordered = [quotas[5], quotas[0], quotas[2], quotas[4], quotas[1], quotas[3]]
        let normal = QuotaImageSummary(QuotaImageExporter.orderedQuotas(reordered, at: now), at: now)
        #expect(normal.mood == .exhausted)
        #expect(normal.deck == "One plan is dead. One is on fumes.")
        #expect(normal.headline(variant: 0) == "Somebody vibed too hard.")
        #expect(normal.headline(variant: 1) != normal.headline(variant: 0) && normal.headline(variant: 3) == normal.headline(variant: 0))

        let staleSummary = QuotaImageSummary(QuotaImageExporter.orderedQuotas(stale, at: now), at: now)
        #expect(staleSummary.deck == "One plan is dead. One is on fumes. Two didn't report back.")

        // Unknown rows are never reported as dead, whatever their last value was.
        let unknownOnly = with(quotas) { $0.usedPercent = $0.id == "grok" ? 100 : 30 }
            .enumerated().map { index, quota in var quota = quota; if index == 5 { quota.status = .unavailable }; return quota }
        let unknownSummary = QuotaImageSummary(unknownOnly, at: now)
        #expect(unknownSummary.mood == .healthy && unknownSummary.exhausted.isEmpty)
        #expect(unknownSummary.deck == "One plan didn't report back.")
        #expect(!(0..<3).map(unknownSummary.headline).contains { $0.contains("dead") || $0.contains("fried") })
        let silent = QuotaImageSummary(with(quotas) { $0.status = .unavailable }, at: now)
        #expect(silent.mood == .unknown && silent.deck == "None of the six plans reported back.")
        let quietClaude = QuotaImageSummary([with(quotas) { $0.status = .unavailable }[0]], at: now)
        #expect(quietClaude.deck == "No fresh numbers. Unknown, not dead." && quietClaude.headline(variant: 0) == "Claude went quiet.")

        let full = QuotaImageSummary(with(quotas) { $0.usedPercent = 0 }, at: now)
        #expect(full.mood == .healthy && full.deck == "Six plans, all at 100%." && full.headline(variant: 1) == "Not a single token spent.")
        let three = QuotaImageSummary([quotas[0], quotas[1], quotas[4]], at: now)
        #expect(three.mood == .low && three.deck == "One plan is on fumes." && three.headline(variant: 0) == "Something's running on fumes.")
        let healthy = QuotaImageSummary([quotas[0], quotas[2], quotas[4]], at: now)
        #expect(healthy.mood == .healthy && healthy.deck == "Three plans. Lowest: Claude at 32%.")
        let single = QuotaImageSummary([quotas[0]], at: now)
        #expect(single.deck == "32% left. Resets in 1d 19h.")
        let cooked = QuotaImageSummary([quotas[5]], at: now)
        #expect(cooked.headline(variant: 0) == "Grok is cooked." && cooked.deck == "0% left. Back in 18h.")
    }

    @Test("Every row count renders on the same landscape canvas, with the cover color set by state")
    func coverColor() throws {
        // Raw sRGB samples: `colorAt` reports them as calibrated RGB, which converts wrongly.
        func cover(_ quotas: [Quota]) throws -> [Int] {
            var pixel = [Int](repeating: 0, count: 4)
            try bitmap(quotas).getPixel(&pixel, atX: 16, y: 1008)
            return Array(pixel.prefix(3))
        }
        func near(_ color: [Int], _ expected: [Int]) -> Bool { zip(color, expected).allSatisfy { abs($0 - $1) <= 3 } }
        let six = try cover(quotas)
        #expect(near(six, [255, 91, 26]), "An exhausted plan turns the cover orange: \(six)")
        let three = try cover([quotas[0], quotas[1], quotas[4]])
        #expect(near(three, [255, 210, 31]), "A plan on fumes turns the cover yellow: \(three)")
        let full = try cover(with(quotas) { $0.usedPercent = 0 })
        #expect(near(full, [198, 244, 58]), "Healthy plans turn the cover lime: \(full)")
        let silent = try cover(with(quotas) { $0.status = .unavailable })
        #expect(near(silent, [204, 204, 204]), "No data leaves the cover grey: \(silent)")
        for (_, quotas) in renders { _ = try bitmap(quotas) }
        let png = try #require(try bitmap(quotas).representation(using: .png, properties: [:]))
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    }

    @Test("Tools that are not installed are left out")
    func hiddenTools() {
        #expect(QuotaImageExporter.orderedQuotas(fourRows, at: now).map(\.id) == ["claude", "openai", "antigravity-gemini", "grok"])
        #expect(exporter.render(with(quotas) { $0.status = .missing }, at: now) == nil, "Nothing to export when no tool is installed")
        #expect(QuotaImageExporter(mascot: repository.appendingPathComponent("missing.png")).render(quotas, at: now) == nil,
                "Nothing to export without the artwork")
    }

    @Test("The clipboard gets native formats, and a failed copy leaves it intact")
    func clipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(exporter.copy(quotas, at: now, to: pasteboard))
        #expect(pasteboard.data(forType: .png) != nil && pasteboard.data(forType: .tiff) != nil,
                "The clipboard must offer both PNG and TIFF for native paste targets")
        #expect(NSImage(pasteboard: pasteboard) != nil, "Native image paste must decode the clipboard")
        let changeCount = pasteboard.changeCount
        #expect(!exporter.copy([], at: now, to: pasteboard))
        #expect(pasteboard.changeCount == changeCount, "A failed render must leave the clipboard intact")
    }

    @Test("Writes the shareable images", .enabled(if: fixtureDirectory != nil))
    func fixtures() throws {
        let directory = URL(fileURLWithPath: try #require(fixtureDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, quotas) in renders {
            let png = try #require(try bitmap(quotas).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("quota-image-\(name).png"))
        }
    }
}
