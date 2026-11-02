import AppKit
import CoreImage
import SwiftUI

@MainActor
struct QuotaImageExporter {
    /// The mascot as a die-cut sticker; nothing renders without it.
    let mascot: NSImage?

    init(mascot url: URL) {
        mascot = QuotaImageArtwork.sticker(contentsOf: url)
    }

    /// Drops tools that are not installed and moves exhausted subscriptions last.
    static func orderedQuotas(_ quotas: [Quota], at date: Date) -> [Quota] {
        let installed = quotas.filter(\.isInstalled)
        return installed.filter { $0.group(at: date) != .exhausted } + installed.filter { $0.group(at: date) == .exhausted }
    }

    func render(_ quotas: [Quota], at date: Date) -> NSBitmapImageRep? {
        let quotas = Self.orderedQuotas(quotas, at: date)
        guard !quotas.isEmpty, let mascot else { return nil }
        let view = QuotaImageView(summary: QuotaImageSummary(quotas, at: date), mascot: mascot)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        return bitmap
    }

    func copy(_ quotas: [Quota], at date: Date, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let bitmap = render(quotas, at: date),
              let png = bitmap.representation(using: .png, properties: [:]),
              let tiff = bitmap.representation(using: .tiff, properties: [:]) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png), item.setData(tiff, forType: .tiff) else { return false }
        // Finish rendering before replacing the user's clipboard.
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

extension Quota {
    /// The image's narrow columns use the subscription's short plan label when it has one.
    var compactSubtitle: String {
        let label = shortPlan ?? (plan?.isEmpty == false ? plan! : "—")
        return bucket.map { "\(label) / \($0)" } ?? label
    }
}

/// What the cover says about the rows. Stale and unavailable rows are unknown, never exhausted.
struct QuotaImageSummary {
    enum Mood { case exhausted, low, healthy, unknown }

    let quotas: [Quota]
    let date: Date
    let exhausted: [Quota]
    let low: [Quota]
    let unknown: [Quota]
    let live: [Quota]

    init(_ quotas: [Quota], at date: Date) {
        self.quotas = quotas
        self.date = date
        exhausted = quotas.filter { $0.group(at: date) == .exhausted }
        unknown = quotas.filter { $0.group(at: date) == .unconfirmed }
        live = quotas.filter { $0.group(at: date) == .available }
        // The same band that `quotaColor` draws red in the menu.
        low = live.filter { ($0.remainingPercent ?? 0) <= 20 }
    }

    var mood: Mood {
        if !exhausted.isEmpty { return .exhausted }
        if !low.isEmpty { return .low }
        return live.isEmpty ? .unknown : .healthy
    }

    /// Picks one of a few lines for the situation; the exporter rotates them by day.
    func headline(variant: Int) -> String {
        let single = quotas.count == 1 ? quotas[0].name : nil
        let lines: [String]
        if live.isEmpty && exhausted.isEmpty {
            lines = single.map { ["\($0) went quiet.", "\($0) isn't talking."] }
                ?? ["Radio silence.", "Nobody's answering.", "The numbers ghosted us."]
        } else if live.isEmpty && unknown.isEmpty {
            lines = single.map { ["\($0) is cooked.", "\($0) is fried.", "\($0) has left the chat."] }
                ?? ["Everything is fried.", "Total meltdown.", "Nothing left to vibe with."]
        } else if exhausted.count > 1 {
            lines = ["The vibes have casualties.", "Somebody vibed way too hard.", "Dropping like flies."]
        } else if exhausted.count == 1 {
            lines = ["Somebody vibed too hard.", "Well, that one's toast.", "One down. Still vibing."]
        } else if !low.isEmpty {
            lines = single.map { ["\($0) is on fumes.", "Pace yourself, \($0)."] }
                ?? ["Something's running on fumes.", "Pace yourself. Or don't.", "Low-battery energy."]
        } else if unknown.isEmpty && live.allSatisfy({ $0.remainingPercent == 100 }) {
            lines = ["Fully charged. Suspiciously.", "Not a single token spent.", "Untouched. Who even are you?"]
        } else {
            lines = ["Plenty left. Vibe on.", "Still in the green.", "Room to vibe."]
        }
        return lines[abs(variant) % lines.count]
    }

    var deck: String {
        if quotas.count == 1 {
            let quota = quotas[0]
            switch quota.group(at: date) {
            case .exhausted: return "0% left. Back in \(quota.resetText(at: date, english: true))."
            case .unconfirmed: return "No fresh numbers. Unknown, not dead."
            case .available: return "\(quota.percentageText) left. Resets in \(quota.resetText(at: date, english: true))."
            }
        }
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        func count(_ value: Int) -> String { value < words.count ? words[value] : "\(value)" }
        var sentences: [String] = []
        // Only the first sentence names the noun: "One plan is dead. Two are on fumes."
        func add(_ rows: [Quota], _ singular: String, _ plural: String) {
            guard !rows.isEmpty else { return }
            let noun = sentences.isEmpty ? (rows.count == 1 ? " plan" : " plans") : ""
            sentences.append("\(count(rows.count))\(noun) \(rows.count == 1 ? singular : plural)")
        }
        add(exhausted, "is dead.", "are dead.")
        add(low, "is on fumes.", "are on fumes.")
        if unknown.count == quotas.count {
            return "None of the \(count(quotas.count).lowercased()) plans reported back."
        }
        add(unknown, "didn't report back.", "didn't report back.")
        if !sentences.isEmpty { return sentences.joined(separator: " ") }
        if live.allSatisfy({ $0.remainingPercent == 100 }) { return "\(count(quotas.count)) plans, all at 100%." }
        let lowest = live.min { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }!
        return "\(count(quotas.count)) plans. Lowest: \(lowest.name) at \(lowest.percentageText)."
    }
}

private enum QuotaImageArtwork {
    /// The mascot as a die-cut sticker: a white border grown from its alpha channel.
    static func sticker(contentsOf url: URL) -> NSImage? {
        guard let source = CIImage(contentsOf: url) else { return nil }
        let border = (source.extent.height * 0.034).rounded()
        let canvas = source.extent.insetBy(dx: -border, dy: -border)
        let outline = CIImage(color: .white).cropped(to: canvas).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: source.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: border]),
        ])
        guard let image = CIContext().createCGImage(source.composited(over: outline), from: canvas) else { return nil }
        return NSImage(cgImage: image, size: canvas.size)
    }
}

private enum Palette {
    static let orange = Color(red: 1, green: 0x5B / 255, blue: 0x1A / 255)
    static let yellow = Color(red: 1, green: 0xD2 / 255, blue: 0x1F / 255)
    static let lime = Color(red: 0xC6 / 255, green: 0xF4 / 255, blue: 0x3A / 255)
    static let fog = Color(white: 0.80)
    static let ink = Color(white: 0.04)
    static let panel = Color(white: 0.055)
    static let dim = Color(white: 0.58)
    static let faint = Color(white: 0.36)
    static let track = Color(white: 0.20)

    static func cover(_ mood: QuotaImageSummary.Mood) -> Color {
        switch mood {
        case .exhausted: orange
        case .low: yellow
        case .healthy: lime
        case .unknown: fog
        }
    }
}

private enum Typeface {
    /// Percentages: SF Pro Compressed Black.
    static func figures(_ size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .black, width: .compressed)
    }

    static func helvetica(_ size: CGFloat, _ face: String = "CondensedBlack") -> NSFont {
        NSFont(name: "HelveticaNeue-\(face)", size: size) ?? .systemFont(ofSize: size, weight: .heavy, width: .condensed)
    }

    /// The largest size at which every value fits `width`, so all rows share one size.
    static func figureSize(for values: [String], width: CGFloat, maximum: CGFloat) -> CGFloat {
        let probe = figures(100)
        let widest = values.map { ($0 as NSString).size(withAttributes: [.font: probe]).width }.max() ?? 1
        return min(maximum, floor(width / widest * 97))
    }
}

private struct QuotaImageView: View {
    let summary: QuotaImageSummary
    let mascot: NSImage
    private let fieldWidth: CGFloat = 372

    private var dateLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy · HH:mm"
        return formatter.string(from: summary.date).uppercased()
    }

    var body: some View {
        let field = Palette.cover(summary.mood)
        let day = Calendar.current.ordinality(of: .day, in: .year, for: summary.date) ?? 0
        let headline = Headline(summary.headline(variant: day), width: fieldWidth - 56, height: 290, maximum: 104)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("QUOTA WEEKLY")
                        .font(Font(Typeface.helvetica(17)))
                        .tracking(1.2)
                        .foregroundStyle(field)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Palette.ink)
                    Text(dateLine)
                        .font(Font(Typeface.helvetica(14, "Bold")))
                        .tracking(0.6)
                }
                Rectangle().frame(height: 3).padding(.top, 12)
                headline.padding(.top, 18)
                Text(summary.deck)
                    .font(Font(Typeface.helvetica(21, "Bold")))
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    // Leaves the lower right corner to the mascot.
                    .frame(width: fieldWidth - 190, alignment: .leading)
                    .padding(.top, 14)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.ink)
            .padding([.horizontal, .top], 28)
            .frame(width: fieldWidth, height: 512, alignment: .topLeading)
            .background(field)

            QuotaImageRows(summary: summary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.panel)
        }
        .frame(width: 800, height: 512)
        .overlay(alignment: .bottomLeading) {
            Image(nsImage: mascot)
                .resizable().interpolation(.high).scaledToFit()
                .frame(height: 150)
                .shadow(color: .black.opacity(0.85), radius: 0, x: 5, y: 6)
                .rotationEffect(.degrees(-8))
                .offset(x: fieldWidth - 150, y: -14)
        }
        .clipped()
    }
}

/// A headline set as large as fits the box, with tight leading and a balanced rag.
private struct Headline: View {
    let lines: [String]
    let font: NSFont
    private static let leading: CGFloat = 0.86

    init(_ text: String, width: CGFloat, height: CGFloat, maximum: CGFloat) {
        let words = text.split(separator: " ").map(String.init)
        func measure(_ line: String, _ font: NSFont) -> CGFloat {
            (line as NSString).size(withAttributes: [.font: font]).width
        }
        func wrap(_ font: NSFont, _ width: CGFloat) -> [String] {
            words.reduce(into: []) { lines, word in
                if let last = lines.last, measure(last + " " + word, font) <= width {
                    lines[lines.count - 1] = last + " " + word
                } else {
                    lines.append(word)
                }
            }
        }
        var size = maximum
        while true {
            let font = Typeface.helvetica(size)
            var lines = wrap(font, width)
            // Narrow the measure while the line count holds, but never below the longest word.
            var rag = width
            let longestWord = words.map { measure($0, font) }.max() ?? 0
            while rag - 4 >= longestWord, wrap(font, rag - 4).count == lines.count { rag -= 4 }
            lines = wrap(font, rag)
            let natural = font.ascender - font.descender + font.leading
            let blockHeight = natural + CGFloat(lines.count - 1) * size * Self.leading
            if (lines.count <= 4 && blockHeight <= height && lines.allSatisfy({ measure($0, font) <= width })) || size <= 24 {
                self.lines = lines
                self.font = font
                return
            }
            size -= 2
        }
    }

    var body: some View {
        let natural = font.ascender - font.descender + font.leading
        VStack(alignment: .leading, spacing: font.pointSize * Self.leading - natural) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(Font(font)).fixedSize()
            }
        }
    }
}

private struct QuotaImageRows: View {
    let summary: QuotaImageSummary

    var body: some View {
        let quotas = summary.quotas
        let values = quotas.map { Readout($0, at: summary.date).value }
        if quotas.count == 1 {
            SingleRow(readout: Readout(quotas[0], at: summary.date),
                      figureSize: Typeface.figureSize(for: values, width: 376, maximum: 300))
                .padding(.horizontal, 26)
                .padding(.vertical, 28)
        } else {
            let height = (512 - 36) / CGFloat(quotas.count)
            let scale: CGFloat = quotas.count <= 3 ? 1.3 : 1
            let size = Typeface.figureSize(for: values, width: 210, maximum: min(height * 0.95, 170))
            VStack(spacing: 0) {
                ForEach(quotas) { quota in
                    Row(readout: Readout(quota, at: summary.date), height: height, figureSize: size, scale: scale)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
        }
    }
}

/// How one row reads: exhausted rows say so in words as well as in orange.
private struct Readout {
    let quota: Quota
    let group: Quota.Group
    let value: String
    let tag: String?
    let color: Color
    let reset: String

    init(_ quota: Quota, at date: Date) {
        self.quota = quota
        group = quota.group(at: date)
        switch group {
        case .exhausted: (value, tag, color) = ("0%", "DEAD", Palette.orange)
        case .unconfirmed: (value, tag, color) = ("—", "NO SIGNAL", Palette.faint)
        case .available: (value, tag, color) = (quota.percentageText, nil, .white)
        }
        reset = group == .unconfirmed ? "RESET UNKNOWN" : "RESETS IN " + quota.resetText(at: date, english: true).uppercased()
    }

    var nameColor: Color { group == .available ? .white : Palette.dim }
}

private struct Row: View {
    let readout: Readout
    let height: CGFloat
    let figureSize: CGFloat
    let scale: CGFloat

    var body: some View {
        let figures = Typeface.figures(figureSize)
        let resetFont = Typeface.helvetica(12.5 * scale, "Bold")
        VStack(spacing: 6 * scale) {
            // Both columns drop their descent so the figures stand on the bar.
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3 * scale) {
                    HStack(spacing: 7 * scale) {
                        Text(readout.quota.name.uppercased())
                            .font(Font(Typeface.helvetica(23 * scale)))
                            .tracking(0.4)
                            .foregroundStyle(readout.nameColor)
                        if let tag = readout.tag { Tag(text: tag, filled: readout.group == .exhausted, size: 13 * scale) }
                    }
                    Text(readout.quota.compactSubtitle)
                        .font(Font(Typeface.helvetica(15 * scale, "Medium")))
                        .foregroundStyle(Palette.dim)
                    Text(readout.reset)
                        .font(Font(resetFont))
                        .tracking(0.6)
                        .foregroundStyle(Palette.faint)
                        .padding(.bottom, resetFont.descender)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Text(readout.value)
                    .font(Font(figures))
                    .foregroundStyle(readout.color)
                    .fixedSize()
                    .padding(.bottom, figures.descender)
            }
            Bar(readout: readout, thickness: 3 * scale)
        }
        .padding(.bottom, height * 0.13)
        .frame(height: height, alignment: .bottom)
    }
}

private struct SingleRow: View {
    let readout: Readout
    let figureSize: CGFloat

    var body: some View {
        let figures = Typeface.figures(figureSize)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(readout.quota.name.uppercased())
                    .font(Font(Typeface.helvetica(40)))
                    .foregroundStyle(readout.nameColor)
                if let tag = readout.tag { Tag(text: tag, filled: readout.group == .exhausted, size: 20) }
            }
            Text(readout.quota.compactSubtitle)
                .font(Font(Typeface.helvetica(24, "Medium")))
                .foregroundStyle(Palette.dim)
            Spacer(minLength: 0)
            Text(readout.value)
                .font(Font(figures))
                .foregroundStyle(readout.color)
                .fixedSize()
                .padding(.bottom, figures.descender)
            Bar(readout: readout, thickness: 6).padding(.top, 10)
            Text(readout.reset)
                .font(Font(Typeface.helvetica(18, "Bold")))
                .tracking(0.8)
                .foregroundStyle(Palette.faint)
                .padding(.top, 12)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Tag: View {
    let text: String
    let filled: Bool
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(Font(Typeface.helvetica(size)))
            .tracking(0.8)
            .foregroundStyle(filled ? Palette.ink : Palette.dim)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(filled ? Palette.orange : .clear)
            .overlay { if !filled { Rectangle().strokeBorder(Palette.faint, lineWidth: 1.5) } }
    }
}

/// Remaining quota as a bar; a dashed rule when the value is unknown.
private struct Bar: View {
    let readout: Readout
    let thickness: CGFloat

    var body: some View {
        GeometryReader { proxy in
            if readout.group == .unconfirmed {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: thickness / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: thickness / 2))
                }
                .stroke(Palette.faint, style: StrokeStyle(lineWidth: thickness, dash: [3, 4]))
            } else {
                let remaining = readout.group == .exhausted ? 0 : readout.quota.remainingPercent ?? 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.track)
                    Rectangle().fill(remaining <= 20 ? Palette.orange : .white)
                        .frame(width: proxy.size.width * remaining / 100)
                }
            }
        }
        .frame(height: thickness)
    }
}
