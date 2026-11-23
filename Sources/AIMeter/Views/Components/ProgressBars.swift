import SwiftUI
import MeterCore

struct QuotaProgressBar: View {
    let percent: Int
    let tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.65), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(2, proxy.size.width * CGFloat(max(0, min(100, percent))) / 100))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct MiniQuotaProgressBar: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(2, proxy.size.width * CGFloat(max(0, min(100, percent))) / 100))
            }
        }
        .accessibilityHidden(true)
    }
}

struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct PlanPill: View {
    let plan: String
    let accent: Color

    var body: some View {
        let isFree = plan.caseInsensitiveCompare("Free") == .orderedSame
        Text(plan)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(isFree ? Color.secondary : accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(isFree ? Color.primary.opacity(0.08) : accent.opacity(0.14))
            )
            .lineLimit(1)
            .accessibilityLabel("Plan: \(plan)")
    }
}

struct UsageBadgesRow: View {
    let badges: [UsageBadge]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges) { badge in
                HStack(spacing: 4) {
                    Image(systemName: badge.symbol).font(.system(size: 8.5, weight: .semibold))
                    Text(badge.text).font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Spacer(minLength: 0)
        }
    }
}
