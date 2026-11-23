import SwiftUI
import MeterCore

struct UsageContentView: View {
    @ObservedObject var model: MeterModel
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        let primarySections = snapshot.sections.filter { !$0.isCollapsible }
        let collapsibleSections = snapshot.sections.filter(\.isCollapsible)

        VStack(spacing: 9) {
            if let headline = snapshot.headline {
                compactHero(headline)
            }

            ForEach(primarySections) { section in
                primarySectionView(section)
            }

            if !collapsibleSections.isEmpty {
                collapsibleGroupsCard(
                    title: snapshot.collapsibleSectionTitle ?? "Other allowances",
                    sections: collapsibleSections
                )
            }

            if !snapshot.badges.isEmpty {
                UsageBadgesRow(badges: snapshot.badges)
            }
        }
    }

    private func compactHero(_ headline: HeadlineMetric) -> some View {
        let remaining = headline.remainingPercent
        let tint = MeterTheme.quotaColor(for: remaining ?? 100)
        return HStack(spacing: 11) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.001, CGFloat(remaining ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(headline.valueDisplay)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining == nil ? Color.secondary : tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let detail = headline.detailText(now: now) {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(MeterTheme.cardBackground)
    }

    @ViewBuilder
    private func primarySectionView(_ section: QuotaSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = section.title {
                MeterTheme.sectionHeaderLabel(title)
            }

            if section.items.isEmpty {
                if let emptyMessage = section.emptyMessage {
                    emptyCard(emptyMessage)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        compactQuotaRow(item)
                        if index < section.items.count - 1 {
                            MeterTheme.hairlineDivider.padding(.horizontal, 11)
                        }
                    }
                    if let detail = section.detailText {
                        MeterTheme.hairlineDivider.padding(.horizontal, 11)
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                    }
                }
                .background(MeterTheme.cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsibleGroupsCard(title: String, sections: [QuotaSection]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MeterTheme.sectionHeaderLabel(title)

            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    collapsibleSectionRow(section)
                    if index < sections.count - 1 {
                        MeterTheme.hairlineDivider.padding(.horizontal, 11)
                    }
                }
            }
            .background(MeterTheme.cardBackground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsibleSectionRow(_ section: QuotaSection) -> some View {
        let isExpanded = model.isSectionExpanded(section)
        let summary = section.summaryPercent
        let tint = MeterTheme.quotaColor(for: summary ?? 100)

        return VStack(spacing: 0) {
            Button {
                model.toggleSection(section.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)

                    Text(section.title ?? "Group")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if !isExpanded, let summary {
                        MiniQuotaProgressBar(percent: summary, tint: tint)
                            .frame(width: 42, height: 4)
                    }

                    Text(summary.map { "\($0)%" } ?? "—")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(summary == nil ? Color.secondary : tint)
                        .frame(minWidth: 32, alignment: .trailing)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let detail = section.detailText {
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 6)
                    }

                    if section.items.isEmpty {
                        if let empty = section.emptyMessage {
                            Text(empty)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 11)
                                .padding(.bottom, 8)
                        }
                    } else {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, item in
                            compactQuotaRow(item, indented: true)
                            if idx < section.items.count - 1 {
                                MeterTheme.hairlineDivider.padding(.leading, 24).padding(.trailing, 11)
                            }
                        }
                    }

                    if let footnote = section.footnote {
                        Text(footnote)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 7)
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private func compactQuotaRow(_ item: QuotaItem, indented: Bool = false) -> some View {
        let tint = item.isDisabled ? Color.secondary : MeterTheme.quotaColor(for: item.remainingPercent ?? 100)
        let compactReset = item.resetPolicy.compactText(now: now)
        let fullReset = item.resetPolicy.formattedText(now: now)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if let tag = item.tag {
                    TagPill(text: tag)
                }
                if let compactReset {
                    Text("· \(compactReset)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if item.resetPolicy == .unavailable {
                    Text("· No reset time")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.valueDisplay)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.remainingPercent == nil || item.isDisabled ? Color.secondary : tint)
            }
            if let percent = item.remainingPercent {
                QuotaProgressBar(percent: percent, tint: tint, height: 4)
            }
        }
        .opacity(item.isDisabled ? 0.55 : 1)
        .padding(.leading, indented ? 24 : 11)
        .padding(.trailing, 11)
        .padding(.vertical, 7.5)
        .help(fullReset ?? "\(item.title): \(item.valueDisplay)")
        .accessibilityValue(
            fullReset.map { "\(item.valueDisplay) remaining. \($0)" } ?? "\(item.valueDisplay)"
        )
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(MeterTheme.cardBackground)
    }
}
