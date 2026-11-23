import Foundation

/// Raw JSON payload decoded from Codex CLI `account/rateLimits/read`.
public struct CodexUsage: Decodable, Sendable {
    public let rateLimits: CodexBucket?
    public let rateLimitsByLimitId: [String: CodexBucket]?
    public let rateLimitResetCredits: CodexResetCredits?

    public var core: CodexBucket? { rateLimitsByLimitId?["codex"] ?? rateLimits }
    public var remaining: Int? { core?.windows.map(\.remaining).min() }

    public var additionalBuckets: [(String, CodexBucket)] {
        (rateLimitsByLimitId ?? [:]).filter { $0.key != "codex" }.sorted { $0.key < $1.key }
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
        nearestReset?.resetText(now: now)
    }

    public static func decode(_ data: Data) throws -> CodexUsage {
        let result: CodexUsage
        do {
            result = try JSONDecoder().decode(CodexUsage.self, from: data)
        } catch {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.codex.name)
        }
        guard result.rateLimits != nil || result.rateLimitsByLimitId != nil else {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.codex.name)
        }
        return result
    }

    /// Converts Codex's wire format into the generic `UsageSnapshot`.
    public func toSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        let nearestDate = nearestReset?.resetsAt.map { Date(timeIntervalSince1970: $0) }
        let headline = HeadlineMetric(
            title: "Overall remaining",
            remainingPercent: remaining,
            nearestResetAt: nearestDate
        )

        var sections: [QuotaSection] = []
        if let core {
            let items = core.windows.enumerated().map { index, window in
                QuotaItem(
                    id: "codex-core-\(index)-\(window.label)",
                    title: window.label,
                    remainingPercent: window.remaining,
                    resetPolicy: window.resetsAt.map { .at(Date(timeIntervalSince1970: $0)) } ?? .unavailable
                )
            }
            sections.append(
                QuotaSection(
                    id: "codex-core",
                    title: nil,
                    layout: .compact,
                    items: items,
                    emptyMessage: items.isEmpty ? "Allowance unavailable" : nil,
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        } else {
            sections.append(
                QuotaSection(
                    id: "codex-core-empty",
                    title: nil,
                    layout: .compact,
                    items: [],
                    emptyMessage: "No Codex allowance reported",
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        }

        for entry in additionalBuckets {
            let (key, bucket) = entry
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
                    layout: .compact,
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
            headline: headline,
            sections: sections,
            badges: badges
        )
    }
}

public struct CodexBucket: Decodable, Sendable {
    public let limitName: String?
    public let primary: CodexWindow?
    public let secondary: CodexWindow?
    public let credits: CodexCredits?
    public var windows: [CodexWindow] { [primary, secondary].compactMap { $0 } }
}

public struct CodexWindow: Decodable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public var remaining: Int { Int(floor(max(0, min(100, 100 - usedPercent)))) }

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
