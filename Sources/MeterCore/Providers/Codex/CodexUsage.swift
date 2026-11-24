import Foundation

/// Raw JSON payload decoded from Codex CLI `account/rateLimits/read`.
public struct CodexUsage: Decodable, Sendable {
    public let rateLimits: CodexBucket?
    public let rateLimitsByLimitId: [String: CodexBucket]?
    public let rateLimitResetCredits: CodexResetCredits?
    public let ordinaryUsageAllowed: Bool?
    public let rateLimitReachedType: String?
    public let fallbackPlanType: String?

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
        case rateLimitResetCredits
        case ordinaryUsageAllowed
        case rateLimitReachedType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rateLimits = try container.decodeIfPresent(CodexBucket.self, forKey: .rateLimits)
        self.rateLimitsByLimitId = try container.decodeIfPresent([String: CodexBucket].self, forKey: .rateLimitsByLimitId)
        self.rateLimitResetCredits = try container.decodeIfPresent(CodexResetCredits.self, forKey: .rateLimitResetCredits)
        self.ordinaryUsageAllowed = try container.decodeIfPresent(Bool.self, forKey: .ordinaryUsageAllowed)
        self.rateLimitReachedType = try container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
        self.fallbackPlanType = nil
    }

    private init(
        rateLimits: CodexBucket?,
        rateLimitsByLimitId: [String: CodexBucket]?,
        rateLimitResetCredits: CodexResetCredits?,
        ordinaryUsageAllowed: Bool?,
        rateLimitReachedType: String?,
        fallbackPlanType: String?
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitResetCredits = rateLimitResetCredits
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.rateLimitReachedType = rateLimitReachedType
        self.fallbackPlanType = fallbackPlanType
    }

    private var coreEntry: (key: String?, bucket: CodexBucket)? {
        if let codexBucket = rateLimitsByLimitId?["codex"] {
            return ("codex", codexBucket)
        }
        if let rateLimits {
            return (nil, rateLimits)
        }
        // Fallback for plans (e.g. Free or model-specific tiers) where limits are keyed
        // under a non-"codex" limit ID without a top-level `rateLimits` object.
        if let byId = rateLimitsByLimitId {
            let sorted = byId.sorted { $0.key < $1.key }
            if let firstWithWindows = sorted.first(where: { !$0.value.windows.isEmpty }) {
                return (firstWithWindows.key, firstWithWindows.value)
            }
            if let first = sorted.first {
                return (first.key, first.value)
            }
        }
        return nil
    }

    public var core: CodexBucket? { coreEntry?.bucket }
    public var remaining: Int? { selectedHeadline?.item.remainingPercent }

    public var rawPlanType: String? {
        core?.planType
            ?? rateLimits?.planType
            ?? rateLimitsByLimitId?.values.compactMap(\.planType).first
            ?? fallbackPlanType
    }

    public var planName: String? {
        Self.normalizePlanName(rawPlanType)
    }

    public var additionalBuckets: [(String, CodexBucket)] {
        let excludedKey = coreEntry?.key ?? "codex"
        return (rateLimitsByLimitId ?? [:])
            .filter { $0.key != excludedKey }
            .sorted { $0.key < $1.key }
    }

    /// The soonest reset across every allowance currently reported.
    public var nearestReset: CodexWindow? {
        let windows = (core?.windows ?? []) + additionalBuckets.flatMap { $0.1.windows }
        return windows.compactMap { window -> (CodexWindow, Double)? in
            guard let reset = window.resetsAt else { return nil }
            return (window, reset)
        }.min { $0.1 < $1.1 }?.0
    }

    public func resetSummary(now: Date = Date()) -> String? {
        selectedHeadline?.metric.detailText(now: now)
    }

    public static func decode(_ data: Data, fallbackPlanType: String? = nil) throws -> CodexUsage {
        let decoded: CodexUsage
        do {
            decoded = try JSONDecoder().decode(CodexUsage.self, from: data)
        } catch {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.codex.name)
        }
        guard decoded.rateLimits != nil || decoded.rateLimitsByLimitId != nil else {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.codex.name)
        }
        guard let fallbackPlanType, !fallbackPlanType.isEmpty else {
            return decoded
        }
        return CodexUsage(
            rateLimits: decoded.rateLimits,
            rateLimitsByLimitId: decoded.rateLimitsByLimitId,
            rateLimitResetCredits: decoded.rateLimitResetCredits,
            ordinaryUsageAllowed: decoded.ordinaryUsageAllowed,
            rateLimitReachedType: decoded.rateLimitReachedType,
            fallbackPlanType: fallbackPlanType
        )
    }

    public static func normalizePlanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "free":
            return "Free"
        case "go":
            return "Go"
        case "plus":
            return "Plus"
        case "prolite", "pro_lite", "pro-lite":
            return "Pro Lite"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        case "edu", "education":
            return "Edu"
        default:
            return JSONParsing.humanizeIdentifier(trimmed)
        }
    }

    private var coreCandidates: [HeadlineCandidate] {
        [("primary", core?.primary), ("secondary", core?.secondary)].compactMap { slot, value in
            guard let window = value else { return nil }
            let kind: QuotaWindow = switch window.windowDurationMins {
            case 300: .fiveHour
            case 10080: .weekly
            default: .other
            }
            let item = QuotaItem(
                id: "codex-core-\(slot)",
                title: window.label,
                remainingPercent: window.remaining,
                resetPolicy: window.resetsAt.map { .at(Date(timeIntervalSince1970: $0)) } ?? .unavailable
            )
            return HeadlineCandidate(item: item, sectionID: "codex-core", groupKey: "codex-core",
                                     window: kind, exhausted: window.usedPercent.map { $0 >= 100 } ?? false)
        }
    }

    private var selectedHeadline: HeadlineCandidate? {
        ServiceDescriptor.codex.headlinePolicy.select(coreCandidates)
    }

    public func toSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        let candidates = coreCandidates
        let headline = ServiceDescriptor.codex.headlinePolicy.select(candidates)?.metric ?? .unavailable
        var sections: [QuotaSection] = []
        if core != nil {
            let items = candidates.map(\.item)
            let emptyText: String? = items.isEmpty
                ? (ordinaryUsageAllowed == false ? "Codex not included in current plan" : "Allowance unavailable")
                : nil
            sections.append(
                QuotaSection(
                    id: "codex-core",
                    title: nil,
                    items: items,
                    emptyMessage: emptyText,
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        } else {
            sections.append(
                QuotaSection(
                    id: "codex-core-empty",
                    title: nil,
                    items: [],
                    emptyMessage: ordinaryUsageAllowed == false
                        ? "Codex not included in current plan"
                        : "No Codex allowance reported",
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        }

        for (key, bucket) in additionalBuckets {
            let items = bucket.windows.enumerated().map { winIndex, window in
                QuotaItem(
                    id: "codex-extra-\(key)-\(winIndex)",
                    title: window.label,
                    remainingPercent: window.remaining,
                    resetPolicy: window.resetsAt.map { .at(Date(timeIntervalSince1970: $0)) } ?? .unavailable
                )
            }
            sections.append(
                QuotaSection(
                    id: "codex-bucket-\(key)",
                    title: bucket.limitName ?? key,
                    items: items,
                    footnote: bucket.credits.map { "Credits \($0.display)" },
                    emptyMessage: items.isEmpty ? "Allowance unavailable" : nil,
                    isCollapsible: true,
                    isExpandedByDefault: false
                )
            )
        }

        var badges: [UsageBadge] = []
        if let credits = core?.credits {
            badges.append(UsageBadge(id: "codex-credits", symbol: "creditcard", text: "Credits \(credits.display)"))
        }
        if let resets = rateLimitResetCredits?.availableCount {
            badges.append(
                UsageBadge(
                    id: "codex-resets",
                    symbol: "arrow.counterclockwise",
                    text: "\(resets) reset\(resets == 1 ? "" : "s")"
                )
            )
        }

        return UsageSnapshot(
            serviceID: .codex,
            fetchedAt: fetchedAt,
            accountSubtitle: nil,
            planName: planName,
            headline: headline,
            sections: sections,
            collapsibleSectionTitle: "Other allowances",
            badges: badges
        )
    }
}

public struct CodexBucket: Decodable, Sendable {
    public let limitName: String?
    public let planType: String?
    public let primary: CodexWindow?
    public let secondary: CodexWindow?
    public let credits: CodexCredits?
    public var windows: [CodexWindow] { [primary, secondary].compactMap { $0 } }
}

public struct CodexWindow: Decodable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public var remaining: Int? { usedPercent.map { JSONParsing.clampedPercent(100 - $0) } }

    public var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Allowance" }
        if minutes == 10080 { return "Weekly" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    public func resetText(now: Date = Date()) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        return ResetFormatter.format(resetsAt: Date(timeIntervalSince1970: resetsAt), now: now)
    }
}

public struct CodexCredits: Decodable, Sendable {
    public let balance: String?
    public let unlimited: Bool?
    public var display: String { unlimited == true ? "Unlimited" : balance ?? "Unavailable" }
}

public struct CodexResetCredits: Decodable, Sendable {
    public let availableCount: Int?
}
