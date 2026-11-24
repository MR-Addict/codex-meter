import Foundation

/// Parsed GitHub Copilot usage payload from `gh api /copilot_internal/user`.
///
/// Supports both the request-based `quota_snapshots` / `limited_user_quotas` formats
/// and the token-based `ai_credits` billing schema.
public struct CopilotUsage: Equatable, Sendable {
    public struct QuotaBucket: Equatable, Sendable {
        public let id: String
        public let title: String
        public let entitlement: Double?
        public let remaining: Double?
        public let remainingPercent: Int?
        public let unlimited: Bool
        public let overagePermitted: Bool
        public let overageCount: Double?
        public let resetsAt: Date?

        public init(
            id: String,
            title: String,
            entitlement: Double? = nil,
            remaining: Double? = nil,
            remainingPercent: Int? = nil,
            unlimited: Bool = false,
            overagePermitted: Bool = false,
            overageCount: Double? = nil,
            resetsAt: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.entitlement = entitlement
            self.remaining = remaining
            self.remainingPercent = remainingPercent.map { max(0, min(100, $0)) }
            self.unlimited = unlimited
            self.overagePermitted = overagePermitted
            self.overageCount = overageCount
            self.resetsAt = resetsAt
        }

        /// Compact remaining/entitlement label shown in the row tag pill (e.g. `"246 / 300"`).
        public var countTag: String? {
            guard !unlimited, let entitlement, entitlement > 0, let remaining else { return nil }
            let clampedRemaining = max(0, remaining)
            return "\(CopilotUsage.formatNumber(clampedRemaining)) / \(CopilotUsage.formatNumber(entitlement))"
        }
    }

    public let planLabel: String?
    public let resetsAt: Date?
    public let buckets: [QuotaBucket]

    public init(planLabel: String? = nil, resetsAt: Date? = nil, buckets: [QuotaBucket]) {
        self.planLabel = planLabel
        self.resetsAt = resetsAt
        self.buckets = buckets
    }

    public var finiteBuckets: [QuotaBucket] {
        buckets.filter { !$0.unlimited }
    }

    public var unlimitedBuckets: [QuotaBucket] {
        buckets.filter(\.unlimited)
    }

    private var headlineCandidates: [HeadlineCandidate] {
        buckets.map { bucket in
            let reset = bucket.resetsAt ?? resetsAt
            let item = QuotaItem(
                id: "copilot-\(bucket.id)",
                title: bucket.title,
                tag: bucket.countTag,
                remainingPercent: bucket.unlimited ? nil : bucket.remainingPercent,
                valueDisplay: bucket.unlimited ? "Unlimited" : nil,
                resetPolicy: bucket.unlimited ? .none : (reset.map { .at($0) } ?? .none)
            )
            return HeadlineCandidate(item: item, sectionID: bucket.unlimited ? "copilot-included" : "copilot-monthly",
                                     allowance: bucket.id, unlimited: bucket.unlimited)
        }
    }

    public var headlineBucket: QuotaBucket? {
        let selected = ServiceDescriptor.copilot.headlinePolicy.select(headlineCandidates)
        return buckets.first { $0.id == selected?.allowance }
    }

    public var nearestResetAt: Date? {
        let bucketResets = finiteBuckets.compactMap(\.resetsAt)
        if let earliest = bucketResets.min() {
            return earliest
        }
        return resetsAt
    }

    /// Concise subscription tier label (`"Free"`, `"Pro"`, `"Pro+"`, `"Business"`, `"Enterprise"`, etc.).
    public var planName: String? {
        guard let planLabel else { return nil }
        let trimmed = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("copilot ") {
            let suffix = String(trimmed.dropFirst("copilot ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? trimmed : suffix
        }
        return trimmed
    }

    public func toSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        let finite = finiteBuckets
        let unlimited = unlimitedBuckets
        let candidates = headlineCandidates
        let selected = ServiceDescriptor.copilot.headlinePolicy.select(candidates)
        let headline = selected?.metric ?? .unavailable

        var sections: [QuotaSection] = []
        if !finite.isEmpty {
            let items = candidates.filter { !$0.unlimited }.map(\.item)
            sections.append(
                QuotaSection(
                    id: "copilot-monthly",
                    title: "Monthly allowance",
                    items: items,
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        }
        let showIncluded = !unlimited.isEmpty && (finite.isEmpty || selected?.unlimited == true)
        if showIncluded {
            let items = candidates.filter(\.unlimited).map(\.item)
            sections.append(
                QuotaSection(
                    id: "copilot-included",
                    title: "Included features",
                    items: items,
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        } else if sections.isEmpty {
            sections.append(
                QuotaSection(
                    id: "copilot-empty",
                    title: "Monthly allowance",
                    items: [],
                    emptyMessage: "No quota limits reported",
                    isCollapsible: false,
                    isExpandedByDefault: true
                )
            )
        }

        var badges: [UsageBadge] = []
        if !showIncluded && !unlimited.isEmpty {
            let names = unlimited.map(\.title)
            let summary = names.count <= 2
                ? names.joined(separator: " & ")
                : "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
            badges.append(
                UsageBadge(
                    id: "copilot-unlimited",
                    symbol: "infinity",
                    text: "Unlimited \(summary)"
                )
            )
        }

        let totalOverage = finite.compactMap(\.overageCount).filter { $0 > 0 }.reduce(0, +)
        if totalOverage > 0 {
            badges.append(
                UsageBadge(
                    id: "copilot-overage",
                    symbol: "plus.circle",
                    text: "Overage \(Self.formatNumber(totalOverage))"
                )
            )
        } else if let primary = buckets.first(where: { $0.id == selected?.allowance }), primary.overagePermitted, (primary.remainingPercent ?? 100) <= 20 {
            badges.append(
                UsageBadge(
                    id: "copilot-overage-enabled",
                    symbol: "creditcard",
                    text: "Overage enabled"
                )
            )
        }

        return UsageSnapshot(
            serviceID: .copilot,
            fetchedAt: fetchedAt,
            accountSubtitle: planLabel,
            planName: planName,
            headline: headline,
            sections: sections,
            collapsibleSectionTitle: "Included features",
            badges: badges
        )
    }

    // MARK: - Decoding

    /// Decodes `/copilot_internal/user` JSON payloads across Pro/Pro+/Business/Enterprise/Free
    /// and both legacy request-based and AI Credits billing schemas.
    public static func decode(_ data: Data, now: Date = Date()) throws -> CopilotUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.copilot.name)
        }

        let planLabel = parsePlanLabel(from: root)
        let topResetDate = parseResetDate(
            from: root,
            keys: ["quota_reset_date_utc", "quota_reset_date", "limited_user_reset_date", "reset_date_utc", "reset_date"]
        )

        var buckets: [QuotaBucket] = []
        var seenIDs = Set<String>()
        var hasRecognizedStructure = false

        // 1. Standard `quota_snapshots` / `quotaSnapshots` dictionary
        if let snapshots = (root["quota_snapshots"] as? [String: Any]) ?? (root["quotaSnapshots"] as? [String: Any]) {
            hasRecognizedStructure = true
            let sortedKeys = JSONParsing.sortedKeys(
                snapshots.keys,
                preferredOrder: ["ai_credits", "premium_interactions", "chat", "completions"],
                caseInsensitive: true
            )
            for key in sortedKeys {
                guard let entry = snapshots[key] as? [String: Any] else { continue }
                let normalizedKey = normalizeBucketID(key)
                if let bucket = parseSnapshotBucket(id: normalizedKey, dict: entry, defaultReset: topResetDate),
                   seenIDs.insert(bucket.id).inserted {
                    buckets.append(bucket)
                }
            }
        }

        // 2. Top-level `ai_credits` / `aiCredits` object (new token-based billing schema)
        if !seenIDs.contains("ai_credits"),
           let creditsDict = (root["ai_credits"] as? [String: Any]) ?? (root["aiCredits"] as? [String: Any]) {
            hasRecognizedStructure = true
            if let bucket = parseSnapshotBucket(id: "ai_credits", dict: creditsDict, defaultReset: topResetDate),
               seenIDs.insert(bucket.id).inserted {
                buckets.insert(bucket, at: 0)
            }
        }

        // 3. Legacy Copilot Free `limited_user_quotas` + `monthly_quotas`
        if let limitedQuotas = root["limited_user_quotas"] as? [String: Any] {
            hasRecognizedStructure = true
            let monthlyQuotas = (root["monthly_quotas"] as? [String: Any]) ?? [:]
            let sortedKeys = JSONParsing.sortedKeys(
                limitedQuotas.keys,
                preferredOrder: ["premium_interactions", "chat", "completions"],
                caseInsensitive: true
            )
            for key in sortedKeys {
                let normalizedKey = normalizeBucketID(key)
                guard !seenIDs.contains(normalizedKey),
                      let remaining = JSONParsing.doubleValue(limitedQuotas[key]) else { continue }
                let entitlement = JSONParsing.doubleValue(monthlyQuotas[key])
                let percent: Int?
                if let entitlement, entitlement > 0 {
                    percent = JSONParsing.clampedPercent((remaining / entitlement) * 100.0)
                } else {
                    percent = nil
                }
                let bucket = QuotaBucket(
                    id: normalizedKey,
                    title: displayTitle(for: normalizedKey),
                    entitlement: entitlement,
                    remaining: remaining,
                    remainingPercent: percent,
                    unlimited: false,
                    resetsAt: topResetDate
                )
                seenIDs.insert(bucket.id)
                buckets.append(bucket)
            }
        }

        // A valid `/copilot_internal/user` response at minimum carries quota containers or `copilot_plan`.
        if !hasRecognizedStructure && planLabel == nil {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.copilot.name)
        }

        return CopilotUsage(planLabel: planLabel, resetsAt: topResetDate, buckets: buckets)
    }

    // MARK: - Parsing Helpers

    private static func parseSnapshotBucket(
        id: String,
        dict: [String: Any],
        defaultReset: Date?
    ) -> QuotaBucket? {
        let unlimited = (dict["unlimited"] as? Bool) ?? (dict["isUnlimited"] as? Bool) ?? false
        let hasQuota = dict["has_quota"] as? Bool
        let overagePermitted = (dict["overage_permitted"] as? Bool) ?? (dict["overagePermitted"] as? Bool) ?? false
        let overageCount = JSONParsing.doubleValue(dict["overage_count"] ?? dict["overageCount"])
        let entitlement = JSONParsing.doubleValue(dict["entitlement"] ?? dict["entitlementRequests"] ?? dict["limit"])
        let used = JSONParsing.doubleValue(dict["used"] ?? dict["usedRequests"] ?? dict["used_requests"])
        var remaining = JSONParsing.doubleValue(dict["remaining"] ?? dict["quota_remaining"] ?? dict["remainingRequests"])
        if remaining == nil, let entitlement, let used {
            remaining = max(0, entitlement - used)
        }

        // Skip buckets explicitly marked as ungranted on the user's plan (e.g., `premium_interactions`
        // with `has_quota: false, entitlement: 0` on Copilot Free).
        if hasQuota == false { return nil }
        if !unlimited {
            if let entitlement, entitlement <= 0, (overageCount ?? 0) <= 0, hasQuota != true {
                return nil
            }
        }

        let bucketReset = parseResetDate(
            from: dict,
            keys: ["reset_date_utc", "reset_date", "resetDate", "resets_at", "resetsAt", "reset_time", "resetTime"]
        ) ?? defaultReset

        if unlimited {
            return QuotaBucket(
                id: id,
                title: displayTitle(for: id),
                entitlement: entitlement,
                remaining: remaining,
                remainingPercent: 100,
                unlimited: true,
                overagePermitted: overagePermitted,
                overageCount: overageCount,
                resetsAt: bucketReset
            )
        }

        let percent = parseRemainingPercent(from: dict, entitlement: entitlement, remaining: remaining, used: used)
        guard percent != nil || remaining != nil || entitlement != nil else {
            return nil
        }

        return QuotaBucket(
            id: id,
            title: displayTitle(for: id),
            entitlement: entitlement,
            remaining: remaining,
            remainingPercent: percent,
            unlimited: false,
            overagePermitted: overagePermitted,
            overageCount: overageCount,
            resetsAt: bucketReset
        )
    }

    private static func parseRemainingPercent(
        from dict: [String: Any],
        entitlement: Double?,
        remaining: Double?,
        used: Double?
    ) -> Int? {
        if let pct = JSONParsing.doubleValue(dict["percent_remaining"] ?? dict["remainingPercentage"] ?? dict["remaining_percent"]) {
            return JSONParsing.clampedPercent(pct)
        }
        if let fraction = JSONParsing.doubleValue(dict["remaining_fraction"] ?? dict["remainingFraction"]) {
            return JSONParsing.percentFromFraction(fraction)
        }
        if let usedPct = JSONParsing.doubleValue(dict["used_percent"] ?? dict["usedPercent"] ?? dict["percent_used"]) {
            return JSONParsing.clampedPercent(100.0 - usedPct)
        }
        if let entitlement, entitlement > 0 {
            if let remaining {
                return JSONParsing.clampedPercent((remaining / entitlement) * 100.0)
            }
            if let used {
                return JSONParsing.clampedPercent(((entitlement - used) / entitlement) * 100.0)
            }
        }
        return nil
    }

    private static func parsePlanLabel(from dict: [String: Any]) -> String? {
        if let sku = (dict["access_type_sku"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !sku.isEmpty {
            if sku.contains("free_limited") || sku == "free" || sku == "copilot_free" {
                return "Copilot Free"
            }
            if sku.contains("educational") || sku.contains("student") {
                return "Copilot Student"
            }
        }

        let rawPlan = (dict["copilot_plan"] as? String)
            ?? (dict["plan"] as? String)
            ?? (dict["access_type_sku"] as? String)
        guard let rawPlan else { return nil }
        let trimmed = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "free", "individual_free", "copilot_free", "free_limited_copilot":
            return "Copilot Free"
        case "individual", "pro", "copilot_pro", "monthly_subscriber", "yearly_subscriber":
            return "Copilot Pro"
        case "individual_pro", "pro_plus", "pro+", "copilot_pro_plus":
            return "Copilot Pro+"
        case "business", "copilot_business":
            return "Copilot Business"
        case "enterprise", "copilot_enterprise":
            return "Copilot Enterprise"
        case "edu", "student", "free_educational_quota":
            return "Copilot Student"
        default:
            let cleaned = JSONParsing.humanizeIdentifier(trimmed)
            return cleaned.lowercased().hasPrefix("copilot") ? cleaned : "Copilot \(cleaned)"
        }
    }

    private static func parseResetDate(from dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let epoch = JSONParsing.doubleValue(raw), epoch > 0 {
                return Date(timeIntervalSince1970: epoch)
            }
            if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let iso = JSONParsing.parseISO8601(trimmed) {
                    return iso
                }
                if let dateOnly = JSONParsing.parseUTCDateOnly(trimmed) {
                    return dateOnly
                }
            }
        }
        return nil
    }

    private static func normalizeBucketID(_ raw: String) -> String {
        switch raw.lowercased() {
        case "aicredits", "ai-credits", "ai_credits":
            return "ai_credits"
        case "premiuminteractions", "premium-interactions", "premium_interactions", "premium_requests":
            return "premium_interactions"
        default:
            return raw.lowercased()
        }
    }

    private static func displayTitle(for id: String) -> String {
        switch id.lowercased() {
        case "ai_credits":
            return "AI credits"
        case "premium_interactions":
            return "Premium requests"
        case "chat":
            return "Chat"
        case "completions":
            return "Completions"
        default:
            return JSONParsing.humanizeIdentifier(id)
        }
    }

    static func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", value)
    }
}
