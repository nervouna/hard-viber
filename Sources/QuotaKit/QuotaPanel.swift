import SwiftUI

func quotaColor(for group: Quota.Group, remaining: Double?) -> Color {
    guard group == .available, let remaining, remaining > 0 else { return .secondary }
    if remaining > 50 { return Color(red: 0.23, green: 0.53, blue: 0.43) }
    if remaining > 20 { return Color(red: 0.62, green: 0.42, blue: 0.10) }
    return Color(red: 0.78, green: 0.36, blue: 0.29)
}

struct QuotaRing: View {
    let quota: Quota
    let group: Quota.Group
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var hidesUnconfirmed = false
    var refreshing = false

    var body: some View {
        // A separate branch, so the pulse stops with the refresh instead of at an arbitrary phase.
        if refreshing {
            ring.phaseAnimator([1, 0.3]) { ring, opacity in ring.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.7) }
        } else {
            ring
        }
    }

    @ViewBuilder private var ring: some View {
        let color = quotaColor(for: group, remaining: quota.remainingPercent)
        ZStack {
            Circle().stroke(color.opacity(group == .unconfirmed ? 0.15 : 0.2), lineWidth: lineWidth)
            if let value = quota.remainingPercent, value > 0, !(hidesUnconfirmed && group == .unconfirmed) {
                let fraction = min(1, value / 100)
                // Round caps must not fill the final gap of a nearly full ring.
                let cap = lineWidth / (2 * .pi * size)
                let start = fraction == 1 ? 0 : min(cap, fraction / 2)
                let end = fraction == 1 ? 1 : max(start + 0.00001, fraction - cap)
                Circle()
                    .trim(from: start, to: end)
                    .stroke(color.opacity(group == .unconfirmed ? 0.4 : 1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct QuotaRow: View {
    let quota: Quota
    let now: Date
    var refreshing = false

    var body: some View {
        // While its refresh runs, a value past its freshness window keeps its place and color; the
        // ring pulses until the refresh confirms it or the row turns grey.
        let group = quota.group(at: now, refreshing: refreshing)
        HStack(spacing: 8) {
            QuotaRing(quota: quota, group: group, refreshing: refreshing)
            VStack(alignment: .leading, spacing: 1) {
                Text(quota.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(group == .available ? .primary : .secondary)
                Text(quota.subtitle)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(quota.percentageText)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(group == .available ? .primary : .secondary)
                    .minimumScaleFactor(0.85)
                Text(quota.resetText(at: now))
                    .font(.system(size: 10.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .contentShape(Rectangle())
        .help(quota.error ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quota.accessibilityText(at: now, refreshing: refreshing))
    }
}

struct QuotaPanel: View {
    @ObservedObject var store: UsageStore
    let onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let quotas = store.installedQuotas
            let refreshing = store.refreshing
            let groups = Dictionary(grouping: quotas) { $0.group(at: timeline.date, refreshing: refreshing.contains($0.provider)) }
                .sorted { $0.key < $1.key }.map(\.value)
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, quotas in
                    if index > 0 {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    ForEach(quotas) { quota in
                        QuotaRow(quota: quota, now: timeline.date, refreshing: refreshing.contains(quota.provider))
                    }
                }
                if quotas.isEmpty {
                    Text("未检测到已安装的服务")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .padding(.vertical, 5)
            .frame(width: 336)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .accessibilityAction(named: Text("复制用量图片"), onCopy)
    }
}
