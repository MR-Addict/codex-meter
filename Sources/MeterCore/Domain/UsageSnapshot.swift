import Foundation

/// How a quota item should render its reset countdown.
public enum ResetDisplayPolicy: Equatable, Sendable {
    /// Display a live countdown toward the given reset date.
    case at(Date)
    /// The tool normally reports resets, so a missing reset timestamp should be shown explicitly.
    case unavailable
    /// The tool or item does not have reset semantics; omit the reset row completely.
    case none

    public var date: Date? {
        if case .at(let date) = self { return date }
        return nil
    }

    public func formattedText(now: Date = Date()) -> String? {
        switch self {
        case .at(let date):
            return ResetFormatter.format(resetsAt: date, now: now)
        case .unavailable:
            return "Reset time unavailable"
        case .none:
            return nil
        }
    }

    public func compactText(now: Date = Date()) -> String? {
        switch self {
        case .at(let date):
            return ResetFormatter.compactFormat(resetsAt: date, now: now)
        case .unavailable, .none:
            return nil
        }
    }
}

/// Shared reset countdown formatting across all providers.
public enum ResetFormatter {
    public static func format(resetsAt: Date, now: Date = Date()) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset due · refresh to check" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 {
            return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h"
        }
        if minutes >= 60 {
            return "Resets in \(minutes / 60)h \(minutes % 60)m"
        }
        return "Resets in \(minutes)m"
    }

    /// Short inline countdown for tight quota rows (e.g. `"4h 22m"`, `"6d 23h"`, `"Due"`).
    public static func compactFormat(resetsAt: Date, now: Date = Date()) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Due" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 {
            return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
        }
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

/// Primary headline metric powering the menu bar readout and popover hero ring.
public struct HeadlineMetric: Equatable, Sendable {
    public let title: String
    public let remainingPercent: Int?
    public let valueDisplay: String
    public let nearestResetAt: Date?
    public let sectionID: String?
    public let itemID: String?
    static let unavailable = HeadlineMetric(title: "Primary quota", remainingPercent: nil)

    public let subtitle: String?

    public init(
        title: String,
        remainingPercent: Int?,
        valueDisplay: String? = nil,
        nearestResetAt: Date? = nil,
        subtitle: String? = nil,
        sectionID: String? = nil,
        itemID: String? = nil
    ) {
        let clamped = remainingPercent.map { max(0, min(100, $0)) }
        self.title = title
        self.remainingPercent = clamped
        self.valueDisplay = valueDisplay ?? clamped.map { "\($0)%" } ?? "Unavailable"
        self.nearestResetAt = nearestResetAt
        self.sectionID = sectionID
        self.itemID = itemID
        self.subtitle = subtitle
    }

    public func detailText(now: Date = Date()) -> String? {
        if let nearestResetAt {
            return ResetFormatter.format(resetsAt: nearestResetAt, now: now)
        }
        return subtitle
    }
}

/// A single quota item (time window, model limit, or feature bucket).
public struct QuotaItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tag: String?
    public let remainingPercent: Int?
    public let valueDisplay: String
    public let resetPolicy: ResetDisplayPolicy
    public let isDisabled: Bool

    public init(
        id: String,
        title: String,
        tag: String? = nil,
        remainingPercent: Int?,
        valueDisplay: String? = nil,
        resetPolicy: ResetDisplayPolicy = .none,
        isDisabled: Bool = false
    ) {
        let clamped = remainingPercent.map { max(0, min(100, $0)) }
        self.id = id
        self.title = title
        self.tag = tag
        self.remainingPercent = clamped
        self.valueDisplay = valueDisplay ?? (isDisabled ? "Inactive" : (clamped.map { "\($0)%" } ?? "Unavailable"))
        self.resetPolicy = resetPolicy
        self.isDisabled = isDisabled
    }
}

/// A logical group of quota items (e.g., primary allowances, model limits, or additional buckets).
public struct QuotaSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let detailText: String?
    public let items: [QuotaItem]
    public let footnote: String?
    public let emptyMessage: String?
    public let isCollapsible: Bool
    public let isExpandedByDefault: Bool

    public init(
        id: String,
        title: String? = nil,
        detailText: String? = nil,
        items: [QuotaItem],
        footnote: String? = nil,
        emptyMessage: String? = nil,
        isCollapsible: Bool = false,
        isExpandedByDefault: Bool = true
    ) {
        self.id = id
        self.title = title
        self.detailText = detailText
        self.items = items
        self.footnote = footnote
        self.emptyMessage = emptyMessage
        self.isCollapsible = isCollapsible
        self.isExpandedByDefault = isExpandedByDefault
    }

    /// Lowest active remaining percentage in this section (used for collapsed 1-line summaries).
    public var summaryPercent: Int? {
        items
            .filter { !$0.isDisabled }
            .compactMap(\.remainingPercent)
            .min()
    }
}

/// Small metadata chip rendered below quota sections (credits, reset credits, overage, etc.).
public struct UsageBadge: Identifiable, Equatable, Sendable {
    public let id: String
    public let symbol: String
    public let text: String

    public init(id: String, symbol: String, text: String) {
        self.id = id
        self.symbol = symbol
        self.text = text
    }
}

/// Normalized, provider-agnostic point-in-time usage snapshot.
public struct UsageSnapshot: Equatable, Sendable {
    public let serviceID: ServiceID
    public let fetchedAt: Date
    public let accountSubtitle: String?
    public let planName: String?
    public let headline: HeadlineMetric?
    public let sections: [QuotaSection]
    public let collapsibleSectionTitle: String?
    public let badges: [UsageBadge]

    public init(
        serviceID: ServiceID,
        fetchedAt: Date = Date(),
        accountSubtitle: String? = nil,
        planName: String? = nil,
        headline: HeadlineMetric?,
        sections: [QuotaSection],
        collapsibleSectionTitle: String? = nil,
        badges: [UsageBadge] = []
    ) {
        self.serviceID = serviceID
        self.fetchedAt = fetchedAt
        self.accountSubtitle = accountSubtitle
        self.planName = planName
        self.headline = headline
        self.sections = sections
        self.collapsibleSectionTitle = collapsibleSectionTitle
        self.badges = badges
    }

    public var remainingPercent: Int? { headline?.remainingPercent }

    public var nearestResetAt: Date? { headline?.nearestResetAt }

    public func resetSummary(now: Date = Date()) -> String? {
        headline?.detailText(now: now)
    }
}
