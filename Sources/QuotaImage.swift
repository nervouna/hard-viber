import AppKit
import CoreText
import SwiftUI

@MainActor
enum QuotaImageExporter {
    /// Drops tools that are not installed and moves exhausted subscriptions last.
    static func orderedQuotas(_ quotas: [Quota], at date: Date) -> [Quota] {
        let installed = quotas.filter(\.isInstalled)
        return installed.filter { $0.group(at: date) != 1 } + installed.filter { $0.group(at: date) == 1 }
    }

    static func render(_ quotas: [Quota], at date: Date) -> NSBitmapImageRep? {
        let quotas = orderedQuotas(quotas, at: date)
        guard !quotas.isEmpty, let artwork = QuotaImageArtwork.shared else { return nil }
        let view = QuotaImageView(quotas: quotas, date: date, artwork: artwork)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        return bitmap
    }

    static func copy(_ quotas: [Quota], at date: Date, to pasteboard: NSPasteboard = .general) -> Bool {
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

private struct QuotaImageArtwork {
    let paper: NSImage
    let mascot: NSImage
    let title: NSImage
    let titleInkHeight: CGFloat

    static let shared: QuotaImageArtwork? = {
        #if TESTING
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/UsageImage")
        #else
        guard let directory = Bundle.main.resourceURL else { return nil }
        #endif
        guard let paper = NSImage(contentsOf: directory.appendingPathComponent("SharePaper.png")),
              let mascot = NSImage(contentsOf: directory.appendingPathComponent("ShareMascot.png")) else { return nil }

        // Crop to the real glyph bounds so the illustration can match ink height,
        // independently of the font's ascender and line-spacing metrics.
        let font = NSFont(name: "BradleyHandITCTT-Bold", size: 68) ?? NSFont.systemFont(ofSize: 68)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Oops, I vibed again.",
            attributes: [.font: font, .foregroundColor: NSColor.black]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let size = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 2)
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                      bitsPerComponent: 8, bytesPerRow: Int(size.width * 2) * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.textPosition = CGPoint(x: 1 - bounds.minX, y: 1 - bounds.minY)
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return nil }
        return QuotaImageArtwork(paper: paper, mascot: mascot,
                                 title: NSImage(cgImage: cgImage, size: size), titleInkHeight: bounds.height)
    }()
}

private struct QuotaImageView: View {
    let quotas: [Quota]
    let date: Date
    let artwork: QuotaImageArtwork
    private let columnWidth: CGFloat = 736 / 3

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        let rowCount = (quotas.count + 2) / 3
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(nsImage: artwork.title)
                Spacer(minLength: 24)
                Image(nsImage: artwork.mascot)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(height: artwork.titleInkHeight * 1.1)
                    // The smoke is light; align the body rather than its full bounds.
                    .offset(y: -12)
            }
            .padding(.horizontal, 8)
            .frame(height: 140)
            .overlay(alignment: .bottom) { SketchRule().frame(height: 2) }

            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<3) { column in
                            let index = row * 3 + column
                            Group {
                                if index < quotas.count {
                                    QuotaImageCell(quota: quotas[index], date: date)
                                } else { Color.clear }
                            }
                            .padding(.leading, column == 0 ? 8 : 20)
                            .padding(.trailing, 12)
                            .frame(width: columnWidth, height: 162)
                        }
                    }
                    .overlay(alignment: .bottom) { SketchRule().frame(height: 2) }
                }
            }
            .overlay(alignment: .topLeading) {
                // A column rule runs only through the rows that have a cell on both sides.
                ForEach(1..<3) { column in
                    let rows = (quotas.count - column + 2) / 3
                    if rows > 0 {
                        SketchRule(vertical: true)
                            .frame(width: 2, height: CGFloat(rows) * 162 - 20)
                            .offset(x: CGFloat(column) * columnWidth - 1, y: 10)
                    }
                }
            }

            Text(timestamp)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.43))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: 48)
        }
        .padding(.horizontal, 32)
        .frame(width: 800)
        .background { Image(nsImage: artwork.paper).resizable().scaledToFill() }
        .clipped()
    }
}

private struct QuotaImageCell: View {
    let quota: Quota
    let date: Date

    var body: some View {
        let group = quota.group(at: date)
        let primary = Color(white: group == 0 ? 0.04 : 0.61)
        let secondary = Color(white: group == 0 ? 0.39 : 0.61)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(quota.name)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(primary)
                Text(quota.compactSubtitle)
                    .font(.system(size: 16.5, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)

            HStack(spacing: 12) {
                SketchQuotaRing(quota: quota, group: group)
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 0) {
                    Text(group == 2 ? "—" : quota.percentageText)
                        .font(.system(size: 45, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(primary)
                        .minimumScaleFactor(0.62)
                    Text(group == 2 ? "—" : quota.resetText(at: date, english: true))
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 12)
    }
}

private struct SketchRule: View {
    var vertical = false

    var body: some View {
        Canvas { context, size in
            let length = vertical ? size.height : size.width
            var path = Path()
            for step in 0...Int(ceil(length / 2)) {
                let distance = min(length, CGFloat(step) * 2)
                let wobble = 1 + 0.18 * sin(distance * 1.7) + 0.12 * sin(distance * 0.37)
                let point = vertical ? CGPoint(x: wobble, y: distance) : CGPoint(x: distance, y: wobble)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Color(white: 0.47).opacity(0.7)), lineWidth: 0.7)
        }
    }
}

private struct SketchQuotaRing: View {
    let quota: Quota
    let group: Int

    var body: some View {
        Canvas { context, size in
            let width: CGFloat = 7.5
            let radius = (min(size.width, size.height) - width) / 2 - 1
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func arc(from start: Double, to end: Double) -> Path {
                var path = Path()
                let steps = max(1, Int(ceil((end - start) * 128)))
                for step in 0...steps {
                    let angle = (start + (end - start) * Double(step) / Double(steps)) * 2 * .pi - .pi / 2
                    let r = radius + 0.55 * sin(angle * 7) + 0.23 * sin(angle * 19) + 0.11 * sin(angle * 43)
                    let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                if start == 0, end == 1 { path.closeSubpath() }
                return path
            }
            let color = quotaColor(for: group, remaining: quota.remainingPercent)
            let track = arc(from: 0, to: 1)
            let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            context.stroke(track, with: .color(color.opacity(0.19)), style: stroke)
            if group == 0, let remaining = quota.remainingPercent, remaining > 0 {
                let fraction = min(1, remaining / 100)
                let cap = width / (4 * .pi * radius)
                let start = fraction == 1 ? 0 : min(cap, fraction / 2)
                let end = fraction == 1 ? 1 : max(start + 0.00001, fraction - cap)
                context.stroke(arc(from: start, to: end), with: .color(color), style: stroke)
            }
            // Fixed paper flecks give the live chart a crayon texture without
            // changing its measured arc or making repeated exports flicker.
            context.clip(to: track.strokedPath(stroke))
            var seed: UInt64 = 4287
            func random() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double((seed >> 32) & 0xffff) / 65535
            }
            for _ in 0..<1900 {
                let x = random() * size.width, y = random() * size.height
                let diameter = 0.2 + random() * 0.65
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                             with: .color(Color(white: 0.97).opacity(0.6)))
            }
        }
    }
}
