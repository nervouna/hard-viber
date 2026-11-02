import AppKit
import Foundation

@main
struct QuotaImageTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let now = ISO8601DateFormatter().date(from: "2026-11-02T09:22:00Z")!
        let samples: [(String, Double, Double)] = [
            ("Ultra", 68, 43), ("Pro", 80, 81),
            ("Google AI Pro", 0, 51), ("Google AI Pro", 0, 167),
            ("Pro", 14, 0), ("SuperGrok", 100, 18),
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
        func with(_ quotas: [Quota], _ change: (inout Quota) -> Void) -> [Quota] {
            quotas.map { quota in var quota = quota; change(&quota); return quota }
        }

        let reordered = [quotas[5], quotas[0], quotas[2], quotas[4], quotas[1], quotas[3]]
        let sorted = QuotaImageExporter.orderedQuotas(reordered, at: now)
        precondition(sorted.map(\.id) == Array(reordered.dropFirst()).map(\.id) + [quotas[5].id],
                     "Exhausted subscriptions must move last without reordering the other subscriptions")

        // The cover copy counts what the data shows; the headline rotates within a situation.
        let normal = QuotaImageSummary(sorted, at: now)
        precondition(normal.mood == .exhausted)
        precondition(normal.deck == "One plan is dead. One is on fumes.", normal.deck)
        precondition(normal.headline(variant: 0) == "Somebody vibed too hard.")
        precondition(normal.headline(variant: 1) != normal.headline(variant: 0) && normal.headline(variant: 3) == normal.headline(variant: 0))

        var stale = quotas
        stale[0].status = "unavailable"
        stale[1].observedAt = now.addingTimeInterval(-901).timeIntervalSince1970
        stale[4].usedPercent = 99.96
        let staleSummary = QuotaImageSummary(QuotaImageExporter.orderedQuotas(stale, at: now), at: now)
        precondition(staleSummary.deck == "One plan is dead. One is on fumes. Two didn't report back.", staleSummary.deck)

        // Unknown rows are never reported as dead, whatever their last value was.
        let unknownOnly = with(quotas) { $0.usedPercent = $0.id == "grok" ? 100 : 30 }
            .enumerated().map { index, quota in var quota = quota; if index == 5 { quota.status = "unavailable" }; return quota }
        let unknownSummary = QuotaImageSummary(unknownOnly, at: now)
        precondition(unknownSummary.mood == .healthy && unknownSummary.exhausted.isEmpty)
        precondition(unknownSummary.deck == "One plan didn't report back.", unknownSummary.deck)
        precondition(!(0..<3).map(unknownSummary.headline).contains { $0.contains("dead") || $0.contains("fried") })
        let silent = QuotaImageSummary(with(quotas) { $0.status = "unavailable" }, at: now)
        precondition(silent.mood == .unknown && silent.deck == "None of the six plans reported back.", silent.deck)
        let quietClaude = QuotaImageSummary([with(quotas) { $0.status = "unavailable" }[0]], at: now)
        precondition(quietClaude.deck == "No fresh numbers. Unknown, not dead." && quietClaude.headline(variant: 0) == "Claude went quiet.")

        let full = QuotaImageSummary(with(quotas) { $0.usedPercent = 0 }, at: now)
        precondition(full.mood == .healthy && full.deck == "Six plans, all at 100%." && full.headline(variant: 1) == "Not a single token spent.")
        let three = QuotaImageSummary([quotas[0], quotas[1], quotas[4]], at: now)
        precondition(three.mood == .low && three.deck == "One plan is on fumes." && three.headline(variant: 0) == "Something's running on fumes.")
        let healthy = QuotaImageSummary([quotas[0], quotas[2], quotas[4]], at: now)
        precondition(healthy.mood == .healthy && healthy.deck == "Three plans. Lowest: Claude at 32%.", healthy.deck)
        let single = QuotaImageSummary([quotas[0]], at: now)
        precondition(single.deck == "32% left. Resets in 1d 19h.", single.deck)
        let cooked = QuotaImageSummary([quotas[5]], at: now)
        precondition(cooked.headline(variant: 0) == "Grok is cooked." && cooked.deck == "0% left. Back in 18h.", cooked.deck)

        // Every row count renders on the same landscape canvas, with the cover color set by state.
        func bitmap(_ quotas: [Quota]) -> NSBitmapImageRep {
            let bitmap = QuotaImageExporter.render(quotas, at: now)!
            precondition(bitmap.pixelsWide == 1600 && bitmap.pixelsHigh == 1024, "The export must be a 2x landscape bitmap")
            return bitmap
        }
        // Raw sRGB samples: `colorAt` reports them as calibrated RGB, which converts wrongly.
        func cover(_ bitmap: NSBitmapImageRep) -> [Int] {
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: 16, y: 1008)
            return Array(pixel.prefix(3))
        }
        func near(_ color: [Int], _ expected: [Int]) -> Bool { zip(color, expected).allSatisfy { abs($0 - $1) <= 3 } }
        let six = bitmap(quotas)
        precondition(near(cover(six), [255, 91, 26]), "An exhausted plan turns the cover orange: \(cover(six))")
        let threeImage = bitmap([quotas[0], quotas[1], quotas[4]])
        precondition(near(cover(threeImage), [255, 210, 31]), "A plan on fumes turns the cover yellow: \(cover(threeImage))")
        let fullImage = bitmap(with(quotas) { $0.usedPercent = 0 })
        precondition(near(cover(fullImage), [198, 244, 58]), "Healthy plans turn the cover lime: \(cover(fullImage))")
        let silentImage = bitmap(with(quotas) { $0.status = "unavailable" })
        precondition(near(cover(silentImage), [204, 204, 204]), "No data leaves the cover grey: \(cover(silentImage))")
        let singleImage = bitmap([quotas[0]])
        let staleImage = bitmap(stale)
        let png = six.representation(using: .png, properties: [:])!
        precondition(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])

        // Tools that are not installed are left out, and fewer rows still fill the canvas.
        var installed = quotas
        installed[3].status = "missing"
        installed[4].status = "missing"
        precondition(QuotaImageExporter.orderedQuotas(installed, at: now).map(\.id) == ["claude", "openai", "antigravity-gemini", "grok"])
        let fourRows = bitmap(installed)
        installed[2].status = "missing"
        installed[5].status = "missing"
        let twoRows = bitmap(installed)
        precondition(QuotaImageExporter.render(with(quotas) { $0.status = "missing" }, at: now) == nil,
                     "Nothing to export when no tool is installed")

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
            let fixtures = [("fixture", six), ("edge-cases", staleImage), ("four-rows", fourRows), ("two-rows", twoRows),
                            ("three-rows", threeImage), ("single", singleImage), ("full", fullImage), ("silent", silentImage)]
            for (name, image) in fixtures {
                try image.representation(using: .png, properties: [:])!
                    .write(to: directory.appendingPathComponent("quota-image-\(name).png"))
            }
        }
        print("Quota image tests passed: stable exhausted ordering, cover copy and color by state, hidden tools, every row count on one canvas, 2x PNG rendering, native clipboard formats, failed-copy preservation.")
    }
}
