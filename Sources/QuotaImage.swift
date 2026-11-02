import AppKit
import SwiftUI

@MainActor
enum QuotaImageExporter {
    static func orderedQuotas(_ quotas: [Quota], at date: Date) -> [Quota] {
        quotas.filter { $0.group(at: date) != 1 } + quotas.filter { $0.group(at: date) == 1 }
    }

    static func render(_ quotas: [Quota], at date: Date) -> NSBitmapImageRep? {
        guard !quotas.isEmpty else { return nil }
        let view = QuotaImageView(quotas: orderedQuotas(quotas, at: date), date: date)
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

private struct QuotaImageView: View {
    let quotas: [Quota]
    let date: Date
    private let rule = Color(red: 0.81, green: 0.82, blue: 0.84)

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        let rowCount = (quotas.count + 1) / 2
        VStack(spacing: 0) {
            Text("AI 订阅额度")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Color(white: 0.05))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .frame(height: 202)
            rule.frame(height: 0.75)
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    if row > 0 { rule.frame(height: 0.75) }
                    HStack(spacing: 48) {
                        QuotaImageCell(quota: quotas[row * 2], date: date)
                        if row * 2 + 1 < quotas.count {
                            QuotaImageCell(quota: quotas[row * 2 + 1], date: date)
                        } else {
                            Color.clear.frame(width: 304)
                        }
                    }
                    .frame(height: row == rowCount - 1 ? 124 : 123.25)
                }
            }
            .overlay {
                rule.frame(width: 0.75).padding(.vertical, 14)
            }
            rule.frame(height: 0.75)
            Text(timestamp)
                .font(.system(size: 16))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.47))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: 64.5)
        }
        .padding(.horizontal, 32)
        .frame(width: 720)
        .background(Color.white)
    }
}

private struct QuotaImageCell: View {
    let quota: Quota
    let date: Date

    private var plan: String {
        if quota.provider == "antigravity", quota.plan == "Google AI Pro" { return "AI Pro" }
        return quota.plan?.isEmpty == false ? quota.plan! : "—"
    }

    var body: some View {
        let group = quota.group(at: date)
        let primary = Color(white: group == 0 ? 0.05 : 0.51)
        let secondary = Color(white: group == 0 ? 0.36 : 0.51)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(quota.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(primary)
                    .minimumScaleFactor(0.9)
                Text(plan)
                    .font(.system(size: 18))
                    .foregroundStyle(secondary)
                if let bucket = quota.bucket {
                    Text(bucket)
                        .font(.system(size: 18))
                        .foregroundStyle(secondary)
                }
            }
            .lineLimit(1)
            .frame(width: 128, alignment: .leading)
            QuotaRing(quota: quota, group: group, size: 58, lineWidth: 8, hidesUnconfirmed: true)
                .frame(width: 66)
            VStack(alignment: .trailing, spacing: 4) {
                Text(group == 2 ? "—" : quota.percentageText)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(primary)
                    .minimumScaleFactor(0.65)
                Text(group == 2 ? "—" : quota.resetText(at: date))
                    .font(.system(size: 16))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .minimumScaleFactor(0.8)
            }
            .lineLimit(1)
            .frame(width: 86, alignment: .trailing)
        }
        .frame(width: 304)
    }
}
