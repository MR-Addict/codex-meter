import Foundation

/// Declared by each service alongside its descriptor.
public enum HeadlinePolicy: Hashable, Sendable {
    case windows(preferredGroup: String)
    case allowances(finite: [String], fallback: String)

    func select(_ candidates: [HeadlineCandidate]) -> HeadlineCandidate? {
        let eligible = candidates.filter { !$0.item.isDisabled && ($0.item.remainingPercent != nil || $0.unlimited) }
        switch self {
        case .windows(let preferredGroup):
            guard let first = eligible.first(where: { $0.groupKey == preferredGroup }) ?? eligible.first else {
                return nil
            }
            let group = eligible.filter { $0.sectionID == first.sectionID }
            return group.first { $0.window == .weekly && $0.exhausted }
                ?? group.first { $0.window == .fiveHour }
                ?? group.first { $0.window == .weekly }
                ?? first
        case .allowances(let finite, let fallback):
            for key in finite {
                if let match = eligible.first(where: { $0.allowance == key && !$0.unlimited }) {
                    return match
                }
            }
            return eligible.first { $0.allowance == fallback }
        }
    }
}

enum QuotaWindow {
    case fiveHour, weekly, other
}

struct HeadlineCandidate {
    let item: QuotaItem
    let sectionID: String
    var groupKey: String?
    var groupTitle: String?
    var window: QuotaWindow = .other
    var exhausted = false
    var allowance: String?
    var unlimited = false

    var metric: HeadlineMetric {
        HeadlineMetric(
            title: [groupTitle, item.title].compactMap { $0 }.joined(separator: " · "),
            remainingPercent: unlimited ? 100 : item.remainingPercent,
            valueDisplay: item.valueDisplay,
            nearestResetAt: item.resetPolicy.date,
            subtitle: item.resetPolicy == .unavailable ? item.resetPolicy.formattedText() : nil,
            sectionID: sectionID,
            itemID: item.id
        )
    }
}
