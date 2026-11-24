import Foundation

/// Parsed Google Antigravity quota payload from `agy --print /usage --output-format json`
/// (`command.data.groups`) or an `agy` `statusLine` JSON snapshot.
public struct AntigravityUsage: Equatable, Sendable {
    public struct ModelQuota: Equatable, Sendable {
        public let id: String
        public let title: String
        public let tag: String?
        public let remainingPercent: Int?
        public let resetsAt: Date?
        let window: QuotaWindow
        let exhausted: Bool
        public let isDisabled: Bool

        public init(
            id: String,
            title: String,
            tag: String? = nil,
            remainingPercent: Int?,
            resetsAt: Date? = nil,
            isDisabled: Bool = false,
            windowName: String? = nil,
            exhausted: Bool? = nil
        ) {
            let token = windowName ?? tag ?? AntigravityUsage.normalizeBucketKey(id).1 ?? title
            switch token.lowercased() {
            case "5h", "5-hour", "five_hour", "five hour": self.window = .fiveHour
            case "weekly", "week", "7d": self.window = .weekly
            default: self.window = .other
            }
            self.exhausted = exhausted ?? (remainingPercent == 0)
            self.id = id
            self.title = title
            self.tag = tag
            self.remainingPercent = remainingPercent.map { max(0, min(100, $0)) }
            self.resetsAt = resetsAt
            self.isDisabled = isDisabled
        }
    }

    public struct ModelGroup: Equatable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let buckets: [ModelQuota]

        public init(id: String, name: String, description: String? = nil, buckets: [ModelQuota]) {
            self.id = id
            self.name = name
            self.description = description
            self.buckets = buckets
        }
    }

    public let planLabel: String?
    public let aiCredits: String?
    public let groups: [ModelGroup]

    public init(planLabel: String? = nil, aiCredits: String? = nil, groups: [ModelGroup]) {
        self.planLabel = planLabel
        self.aiCredits = aiCredits
        self.groups = groups
    }

    public init(planLabel: String? = nil, aiCredits: String? = nil, models: [ModelQuota]) {
        self.planLabel = planLabel
        self.aiCredits = aiCredits
        // Flat responses encode the pool in the bucket key (e.g. gemini-weekly).
        // Keep unwindowed legacy model lists in their original order.
        var order: [String] = []
        var pools: [String: [ModelQuota]] = [:]
        for model in models {
            let (_, suffix) = Self.normalizeBucketKey(model.id)
            let id: String
            if suffix != nil {
                id = model.id.split(separator: "-").dropLast().joined(separator: "-")
            } else if model.window != .other {
                id = model.id
            } else {
                id = "antigravity-models"
            }
            if pools[id] == nil { order.append(id) }
            pools[id, default: []].append(model)
        }
        if models.isEmpty {
            self.groups = [ModelGroup(id: "antigravity-models", name: "Model limits", buckets: [])]
            return
        }
        self.groups = order.compactMap { id in
            guard let buckets = pools[id], let first = buckets.first else { return nil }
            let name = id == "antigravity-models" ? "Model limits" : first.title
            return ModelGroup(id: id, name: name, buckets: buckets)
        }
    }

    public var models: [ModelQuota] {
        groups.flatMap(\.buckets)
    }

    public var activeModels: [ModelQuota] {
        models.filter { !$0.isDisabled }
    }

    public var lowestRemaining: Int? {
        activeModels.compactMap(\.remainingPercent).min()
    }

    public var nearestResetAt: Date? {
        activeModels.compactMap(\.resetsAt).min()
    }

    /// Concise subscription tier label (`"Free"`, `"Pro"`, `"Ultra"`, etc.).
    /// Prefers explicit plan metadata when provided by `agy` / `statusLine` JSON;
    /// otherwise uses high-confidence structural signals from `/usage` groups.
    public var planName: String? {
        if let explicit = Self.normalizePlanName(planLabel) {
            return explicit
        }

        // High-confidence Pro signal: dedicated paid Pro Argon quota description.
        if groups.contains(where: { ($0.description ?? "").lowercased().contains("for paid pro plans") }) {
            return "Pro"
        }

        // High-confidence Free signal: active window-based buckets exist, all are weekly-only (no 5-hour window).
        let active = activeModels
        if !active.isEmpty {
            let hasWeekly = active.contains { $0.window == .weekly }
            let hasFiveHour = active.contains { $0.window == .fiveHour }
            if hasWeekly && !hasFiveHour {
                return "Free"
            }
        }

        return nil
    }

    public static func normalizePlanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        switch lower {
        case "free", "google ai free", "ai free", "individual", "individual free":
            return "Free"
        case "pro", "google ai pro", "ai pro":
            return "Pro"
        case "ultra", "google ai ultra", "ai ultra":
            return "Ultra"
        case "enterprise", "google ai enterprise":
            return "Enterprise"
        case "business", "google ai business":
            return "Business"
        default:
            if lower.hasPrefix("google ai ") {
                let suffix = String(trimmed.dropFirst("google ai ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return suffix.isEmpty ? trimmed : suffix
            }
            return trimmed
        }
    }

    public func toSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        let grouped = groups.map { group in
            let sectionID = "agy-group-\(group.id)"
            let isGemini = [group.id, group.name].contains {
                ["gemini", "gemini-models", "gemini models"].contains($0.lowercased())
            } || group.buckets.contains { ["gemini-5h", "gemini-weekly"].contains($0.id.lowercased()) }
            let name = isGemini ? "Gemini" : Self.displayGroupName(group.name)
            let candidates = group.buckets.map { bucket in
                let title: String
                switch bucket.window {
                case .fiveHour: title = "5-hour"
                case .weekly: title = "Weekly"
                case .other:
                    title = bucket.title == group.name ? (bucket.tag ?? bucket.title) : bucket.title
                }
                let item = QuotaItem(
                    id: "agy-\(group.id)-\(bucket.id)",
                    title: title,
                    tag: bucket.window == .other && bucket.tag != title ? bucket.tag : nil,
                    remainingPercent: bucket.remainingPercent,
                    resetPolicy: bucket.resetsAt.map { .at($0) } ?? .none,
                    isDisabled: bucket.isDisabled
                )
                return HeadlineCandidate(item: item, sectionID: sectionID, groupKey: isGemini ? "gemini" : group.id,
                                         groupTitle: name, window: bucket.window, exhausted: bucket.exhausted)
            }
            return (group: group, id: sectionID, candidates: candidates)
        }
        let selected = ServiceDescriptor.antigravity.headlinePolicy.select(grouped.flatMap(\.candidates))
        var ordered = grouped
        if let index = ordered.firstIndex(where: { $0.id == selected?.sectionID }) {
            let primary = ordered.remove(at: index)
            ordered.insert(primary, at: 0)
        }
        let sections = ordered.enumerated().map { index, entry in
            QuotaSection(
                id: entry.id,
                title: Self.displayGroupName(entry.group.name),
                detailText: Self.displayGroupDetail(entry.group.description),
                items: entry.candidates.map(\.item),
                emptyMessage: entry.candidates.isEmpty ? "No model limits reported" : nil,
                isCollapsible: index > 0,
                isExpandedByDefault: index == 0
            )
        }

        var badges: [UsageBadge] = []
        if let aiCredits, !aiCredits.isEmpty {
            badges.append(UsageBadge(id: "agy-credits", symbol: "sparkles", text: "AI Credits \(aiCredits)"))
        }

        return UsageSnapshot(
            serviceID: .antigravity,
            fetchedAt: fetchedAt,
            accountSubtitle: planLabel,
            planName: planName,
            headline: selected?.metric ?? HeadlineMetric.unavailable,
            sections: sections,
            collapsibleSectionTitle: "Other models",
            badges: badges
        )
    }

    /// Decodes documented `agy` JSON formats:
    /// 1. `agy --print /usage --output-format json` (`command.data.groups`)
    /// 2. `statusLine` JSON (`quota` map)
    /// 3. Per-model arrays (`models` / `model_limits` / `buckets` / `clientModelConfigs`)
    public static func decode(_ data: Data, now: Date = Date()) throws -> AntigravityUsage {
        guard let rootObject = JSONParsing.extractJSONObject(from: data) else {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.antigravity.name)
        }
        let payload = unwrapEnvelope(rootObject)

        let planLabel = extractPlanLabel(from: payload) ?? extractPlanLabel(from: rootObject)
        let aiCredits = extractCredits(from: payload) ?? extractCredits(from: rootObject)

        // 1. Hierarchical model groups (`agy --print /usage --output-format json` -> `command.data.groups`)
        if let rawGroups = payload["groups"] as? [[String: Any]] {
            let parsedGroups = parseGroups(rawGroups, now: now)
            return AntigravityUsage(planLabel: planLabel, aiCredits: aiCredits, groups: parsedGroups)
        }

        var models: [ModelQuota] = []
        var foundRecognizedContainer = false

        // 2. Named quota buckets dictionary (documented `agy` statusLine schema)
        if let quotaDict = payload["quota"] as? [String: Any] {
            foundRecognizedContainer = true
            models.append(contentsOf: parseQuotaMap(quotaDict, now: now))
        } else if let quotaArray = payload["quota"] as? [[String: Any]] {
            foundRecognizedContainer = true
            models.append(contentsOf: parseModelList(quotaArray, now: now))
        }

        // 3. Per-model / bucket arrays (`models`, `model_limits`, `modelLimits`, `buckets`, `clientModelConfigs`)
        let listKeys = ["models", "model_limits", "modelLimits", "buckets", "clientModelConfigs"]
        for key in listKeys {
            if let list = payload[key] as? [[String: Any]] {
                foundRecognizedContainer = true
                models.append(contentsOf: parseModelList(list, now: now))
            }
        }

        // 4. Nested `cascadeModelConfigData.clientModelConfigs` if present
        if let cascade = payload["cascadeModelConfigData"] as? [String: Any],
           let list = cascade["clientModelConfigs"] as? [[String: Any]] {
            foundRecognizedContainer = true
            models.append(contentsOf: parseModelList(list, now: now))
        }

        guard foundRecognizedContainer else {
            throw ProviderError.malformed(serviceName: ServiceDescriptor.antigravity.name)
        }

        var seen = Set<String>()
        let uniqueModels = models.filter { seen.insert($0.id).inserted }
        return AntigravityUsage(planLabel: planLabel, aiCredits: aiCredits, models: uniqueModels)
    }

    // MARK: - Parsing helpers

    private static func hasQuotaContainer(_ object: [String: Any]) -> Bool {
        object["groups"] != nil
            || object["quota"] != nil
            || object["models"] != nil
            || object["model_limits"] != nil
            || object["modelLimits"] != nil
            || object["buckets"] != nil
            || object["clientModelConfigs"] != nil
            || object["cascadeModelConfigData"] != nil
    }

    private static func unwrapEnvelope(_ object: [String: Any]) -> [String: Any] {
        if hasQuotaContainer(object) {
            return object
        }

        // Prioritize `command` -> `data` (`agy --print /usage --output-format json`)
        // before generic `usage` (which is a token counter object in print-mode envelopes).
        let envelopeKeys = ["command", "data", "result", "userStatus", "payload", "usage"]
        for key in envelopeKeys {
            if let nested = object[key] as? [String: Any] {
                let candidate = unwrapEnvelope(nested)
                if hasQuotaContainer(candidate) {
                    return candidate
                }
            }
            if let nestedText = object[key] as? String,
               let nestedData = nestedText.data(using: .utf8),
               let nestedObject = try? JSONSerialization.jsonObject(with: nestedData) as? [String: Any] {
                let candidate = unwrapEnvelope(nestedObject)
                if hasQuotaContainer(candidate) {
                    return candidate
                }
            }
        }
        return object
    }

    private static func parseGroups(_ rawGroups: [[String: Any]], now: Date) -> [ModelGroup] {
        rawGroups.enumerated().compactMap { index, group in
            let name = (group["name"] as? String)
                ?? (group["display_name"] as? String)
                ?? (group["id"] as? String)
                ?? "Group \(index + 1)"
            let id = (group["id"] as? String)
                ?? name.lowercased().replacingOccurrences(of: " ", with: "-")
            let description = group["description"] as? String
            let rawBuckets = (group["buckets"] as? [[String: Any]]) ?? []

            let parsedBuckets: [(order: Int, quota: ModelQuota)] = rawBuckets.enumerated().map { bIndex, entry in
                let bucketID = (entry["id"] as? String) ?? "\(id)-\(bIndex)"
                let rawWindow = (entry["window"] as? String)?.lowercased()
                let rawName = (entry["name"] as? String) ?? (entry["display_name"] as? String)
                let disabled = (entry["disabled"] as? Bool) ?? false
                var remaining = parseRemainingPercent(from: entry)
                let resetsAt = parseResetDate(from: entry, now: now)
                // Proto3 JSON can omit `remaining_fraction: 0.0` when exhausted;
                // preserve the bucket as 0% when a reset timestamp is reported.
                if remaining == nil && !disabled && resetsAt != nil && !hasBalanceField(entry) {
                    remaining = 0
                }

                let (title, order) = normalizeWindowTitle(window: rawWindow, fallbackName: rawName ?? bucketID)
                let quota = ModelQuota(
                    id: bucketID,
                    title: title,
                    tag: nil,
                    remainingPercent: remaining.map(JSONParsing.clampedPercent),
                    resetsAt: resetsAt,
                    isDisabled: disabled,
                    windowName: rawWindow,
                    exhausted: remaining.map { $0 <= 0 }
                )
                return (order, quota)
            }

            let sortedBuckets = parsedBuckets
                .sorted { lhs, rhs in
                    if lhs.order != rhs.order { return lhs.order < rhs.order }
                    return lhs.quota.id < rhs.quota.id
                }
                .map(\.quota)

            return ModelGroup(id: id, name: name, description: description, buckets: sortedBuckets)
        }
    }

    private static func normalizeWindowTitle(window: String?, fallbackName: String) -> (String, Int) {
        switch window {
        case "5h", "5-hour", "five_hour":
            return ("5-hour", 0)
        case "daily", "24h", "1d":
            return ("Daily", 1)
        case "weekly", "7d", "week":
            return ("Weekly", 2)
        case "monthly", "30d", "month":
            return ("Monthly", 3)
        default:
            let cleaned = fallbackName
                .replacingOccurrences(of: " Limit Remaining", with: "")
                .replacingOccurrences(of: " Remaining", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned.isEmpty ? fallbackName : cleaned, 10)
        }
    }

    private static func parseQuotaMap(_ map: [String: Any], now: Date) -> [ModelQuota] {
        let sortedKeys = JSONParsing.sortedKeys(
            map.keys,
            preferredOrder: ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
        )

        return sortedKeys.compactMap { key -> ModelQuota? in
            guard let entry = map[key] as? [String: Any] else { return nil }
            let (title, tag) = normalizeBucketKey(key)
            let disabled = (entry["disabled"] as? Bool) ?? false
            let remaining = parseRemainingPercent(from: entry)
            let resetsAt = parseResetDate(from: entry, now: now)
            return ModelQuota(
                id: key,
                title: (entry["display_name"] as? String) ?? (entry["label"] as? String) ?? title,
                tag: (entry["window"] as? String) ?? tag,
                remainingPercent: remaining.map(JSONParsing.clampedPercent),
                resetsAt: resetsAt,
                isDisabled: disabled,
                exhausted: remaining.map { $0 <= 0 }
            )
        }
    }

    private static func parseModelList(_ list: [[String: Any]], now: Date) -> [ModelQuota] {
        list.enumerated().compactMap { index, entry -> ModelQuota? in
            let quotaObj = (entry["quotaInfo"] as? [String: Any])
                ?? (entry["quota_info"] as? [String: Any])
                ?? (entry["quota"] as? [String: Any])
                ?? entry

            let rawID = (entry["id"] as? String)
                ?? (entry["modelId"] as? String)
                ?? (entry["model_id"] as? String)
                ?? (entry["label"] as? String)
                ?? (entry["name"] as? String)
                ?? "model-\(index)"

            let title = (entry["display_name"] as? String)
                ?? (entry["displayName"] as? String)
                ?? (entry["label"] as? String)
                ?? (entry["name"] as? String)
                ?? normalizeBucketKey(rawID).0

            let tag = (entry["window"] as? String)
                ?? (entry["pool"] as? String)
                ?? (entry["tier"] as? String)
                ?? normalizeBucketKey(rawID).1

            let disabled = (entry["disabled"] as? Bool) ?? (quotaObj["disabled"] as? Bool) ?? false
            let remaining = parseRemainingPercent(from: quotaObj) ?? parseRemainingPercent(from: entry)
            let resetsAt = parseResetDate(from: quotaObj, now: now) ?? parseResetDate(from: entry, now: now)

            guard remaining != nil || disabled else { return nil }

            return ModelQuota(
                id: rawID,
                title: title,
                tag: tag,
                remainingPercent: remaining.map(JSONParsing.clampedPercent),
                resetsAt: resetsAt,
                isDisabled: disabled,
                exhausted: remaining.map { $0 <= 0 }
            )
        }
    }

    private static func hasBalanceField(_ entry: [String: Any]) -> Bool {
        ["remaining_fraction", "remainingFraction", "remaining_percent", "remainingPercent", "used_percent", "usedPercent"]
            .contains { entry[$0] != nil }
    }

    private static func parseRemainingPercent(from dict: [String: Any]) -> Double? {
        if let fraction = JSONParsing.doubleValue(dict["remaining_fraction"] ?? dict["remainingFraction"]) {
            return (0...1).contains(fraction) ? fraction * 100 : fraction
        }
        if let remaining = JSONParsing.doubleValue(dict["remaining_percent"] ?? dict["remainingPercent"]) {
            return remaining
        }
        if let used = JSONParsing.doubleValue(dict["used_percent"] ?? dict["usedPercent"]) {
            return 100 - used
        }
        return nil
    }

    private static func parseResetDate(from dict: [String: Any], now: Date) -> Date? {
        let rawTime = dict["reset_time"] ?? dict["resetTime"] ?? dict["resets_at"] ?? dict["resetsAt"]
        if let epoch = JSONParsing.doubleValue(rawTime), epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        if let iso = rawTime as? String, !iso.isEmpty, let parsed = JSONParsing.parseISO8601(iso) {
            return parsed
        }
        if let seconds = JSONParsing.doubleValue(dict["reset_in_seconds"] ?? dict["resetInSeconds"]), seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    private static func extractPlanLabel(from dict: [String: Any]) -> String? {
        for key in ["plan_name", "planName", "plan", "tier"] {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
            if let nested = dict[key] as? [String: Any],
               let name = (nested["display_name"] as? String) ?? (nested["name"] as? String),
               !name.isEmpty {
                return name
            }
        }
        if let planStatus = dict["planStatus"] as? [String: Any],
           let planInfo = planStatus["planInfo"] as? [String: Any],
           let name = (planInfo["planName"] as? String) ?? (planInfo["teamsTier"] as? String),
           !name.isEmpty {
            return name
        }
        return nil
    }

    private static func extractCredits(from dict: [String: Any]) -> String? {
        for key in ["ai_credits", "aiCredits", "availablePromptCredits", "credits"] {
            if let value = dict[key] {
                if !JSONParsing.isBoolean(value), let number = value as? NSNumber {
                    return number.stringValue
                }
                if let text = value as? String, !text.isEmpty {
                    return text
                }
                if let nested = value as? [String: Any] {
                    if let unlimited = nested["unlimited"] as? Bool, unlimited { return "Unlimited" }
                    if let remaining = nested["remaining"] as? NSNumber, !JSONParsing.isBoolean(remaining) {
                        return remaining.stringValue
                    }
                    if let balance = nested["balance"] as? String, !balance.isEmpty { return balance }
                }
            }
        }
        if let planStatus = dict["planStatus"] as? [String: Any],
           let credits = planStatus["availablePromptCredits"] as? NSNumber,
           !JSONParsing.isBoolean(credits) {
            return credits.stringValue
        }
        return nil
    }

    private static func normalizeBucketKey(_ key: String) -> (String, String?) {
        switch key.lowercased() {
        case "gemini-5h": return ("Gemini", "5-hour")
        case "gemini-weekly": return ("Gemini", "Weekly")
        case "3p-5h": return ("Claude / GPT", "5-hour")
        case "3p-weekly": return ("Claude / GPT", "Weekly")
        default:
            let parts = key.split(separator: "-").map(String.init)
            if parts.count >= 2 {
                let last = parts.last!.lowercased()
                let tag: String? = switch last {
                case "5h": "5-hour"
                case "weekly", "7d": "Weekly"
                case "daily", "24h": "Daily"
                default: nil
                }
                if let tag {
                    let base = parts.dropLast().joined(separator: " ").capitalized
                    return (base, tag)
                }
            }
            return (JSONParsing.humanizeIdentifier(key), nil)
        }
    }

    private static func displayGroupName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "claude and gpt models":
            return "Claude & GPT"
        default:
            return trimmed
        }
    }

    private static func displayGroupDetail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = "Models within this group:"
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            let models = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return models.isEmpty ? nil : models
        }
        return nil
    }
}
