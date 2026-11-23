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
        public let isDisabled: Bool

        public init(
            id: String,
            title: String,
            tag: String? = nil,
            remainingPercent: Int?,
            resetsAt: Date? = nil,
            isDisabled: Bool = false
        ) {
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
        self.groups = [ModelGroup(id: "antigravity-models", name: "Model limits", buckets: models)]
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

    public func toSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        let active = activeModels
        let lowest = lowestRemaining
        let subtitleFallback: String? = nearestResetAt == nil && !active.isEmpty
            ? "\(active.count) model limit\(active.count == 1 ? "" : "s") tracked"
            : nil

        let headline = HeadlineMetric(
            title: "Lowest quota",
            remainingPercent: lowest,
            nearestResetAt: nearestResetAt,
            subtitle: subtitleFallback
        )

        // Put the most-constrained (lowest remaining %) model group first as primary;
        // tie-break by original group order so Gemini Models stays primary on ties.
        let orderedGroups: [ModelGroup]
        if groups.count > 1 {
            let primaryIndex = groups.enumerated().min { lhs, rhs in
                let leftMin = lhs.element.buckets.filter { !$0.isDisabled }.compactMap(\.remainingPercent).min() ?? Int.max
                let rightMin = rhs.element.buckets.filter { !$0.isDisabled }.compactMap(\.remainingPercent).min() ?? Int.max
                if leftMin != rightMin { return leftMin < rightMin }
                return lhs.offset < rhs.offset
            }?.offset ?? 0

            var reordered = [groups[primaryIndex]]
            for (idx, group) in groups.enumerated() where idx != primaryIndex {
                reordered.append(group)
            }
            orderedGroups = reordered
        } else {
            orderedGroups = groups
        }

        let sections: [QuotaSection] = orderedGroups.enumerated().map { index, group in
            let isSecondary = orderedGroups.count > 1 && index > 0
            let items = group.buckets.map { bucket in
                QuotaItem(
                    id: "agy-\(group.id)-\(bucket.id)",
                    title: bucket.title,
                    tag: bucket.tag,
                    remainingPercent: bucket.remainingPercent,
                    resetPolicy: bucket.resetsAt.map { .at($0) } ?? .none,
                    isDisabled: bucket.isDisabled
                )
            }
            return QuotaSection(
                id: "agy-group-\(group.id)",
                title: Self.displayGroupName(group.name),
                detailText: Self.displayGroupDetail(group.description),
                layout: .compact,
                items: items,
                emptyMessage: items.isEmpty ? "No model limits reported" : nil,
                isCollapsible: isSecondary,
                isExpandedByDefault: !isSecondary
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
            headline: headline,
            sections: sections,
            badges: badges
        )
    }

    /// Decodes documented `agy` JSON formats:
    /// 1. `agy --print /usage --output-format json` (`command.data.groups`)
    /// 2. `statusLine` JSON (`quota` map)
    /// 3. Per-model arrays (`models` / `model_limits` / `buckets` / `clientModelConfigs`)
    public static func decode(_ data: Data, now: Date = Date()) throws -> AntigravityUsage {
        let rootObject = try parseJSONObject(from: data)
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

    private static func parseJSONObject(from data: Data) throws -> [String: Any] {
        if let direct = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return direct
        }
        // Handle CLI output that contains ANSI sequences or leading/trailing log lines around a JSON object.
        let cleaned = stripANSI(String(decoding: data, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedData = cleaned.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] {
            return parsed
        }
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}"),
           firstBrace < lastBrace {
            let slice = String(cleaned[firstBrace...lastBrace])
            if let sliceData = slice.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: sliceData) as? [String: Any] {
                return parsed
            }
        }
        throw ProviderError.malformed(serviceName: ServiceDescriptor.antigravity.name)
    }

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

            let parsedBuckets: [(order: Int, quota: ModelQuota)] = rawBuckets.enumerated().compactMap { bIndex, entry in
                let bucketID = (entry["id"] as? String) ?? "\(id)-\(bIndex)"
                let rawWindow = (entry["window"] as? String)?.lowercased()
                let rawName = (entry["name"] as? String) ?? (entry["display_name"] as? String)
                let disabled = (entry["disabled"] as? Bool) ?? false
                let remaining = parseRemainingPercent(from: entry)
                let resetsAt = parseResetDate(from: entry, now: now)

                guard remaining != nil || disabled else { return nil }

                let (title, order) = normalizeWindowTitle(window: rawWindow, fallbackName: rawName ?? bucketID)
                let quota = ModelQuota(
                    id: bucketID,
                    title: title,
                    tag: nil,
                    remainingPercent: remaining,
                    resetsAt: resetsAt,
                    isDisabled: disabled
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
        let preferredOrder = ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
        let sortedKeys = map.keys.sorted { lhs, rhs in
            let leftIdx = preferredOrder.firstIndex(of: lhs) ?? Int.max
            let rightIdx = preferredOrder.firstIndex(of: rhs) ?? Int.max
            if leftIdx != rightIdx { return leftIdx < rightIdx }
            return lhs < rhs
        }

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
                remainingPercent: remaining,
                resetsAt: resetsAt,
                isDisabled: disabled
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
                remainingPercent: remaining,
                resetsAt: resetsAt,
                isDisabled: disabled
            )
        }
    }

    private static func parseRemainingPercent(from dict: [String: Any]) -> Int? {
        if let fraction = doubleValue(dict["remaining_fraction"] ?? dict["remainingFraction"]) {
            let scaled = fraction <= 1.0 && fraction >= 0.0 ? fraction * 100.0 : fraction
            return Int(floor(max(0, min(100, scaled))))
        }
        if let remaining = doubleValue(dict["remaining_percent"] ?? dict["remainingPercent"]) {
            return Int(floor(max(0, min(100, remaining))))
        }
        if let used = doubleValue(dict["used_percent"] ?? dict["usedPercent"]) {
            return Int(floor(max(0, min(100, 100.0 - used))))
        }
        return nil
    }

    private static func parseResetDate(from dict: [String: Any], now: Date) -> Date? {
        let rawTime = dict["reset_time"] ?? dict["resetTime"] ?? dict["resets_at"] ?? dict["resetsAt"]
        if let epoch = doubleValue(rawTime), epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        if let iso = rawTime as? String, !iso.isEmpty {
            if let parsed = parseISO8601(iso) { return parsed }
        }
        if let seconds = doubleValue(dict["reset_in_seconds"] ?? dict["resetInSeconds"]), seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func extractPlanLabel(from dict: [String: Any]) -> String? {
        for key in ["plan_name", "planName", "plan", "tier"] {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
            if let nested = dict[key] as? [String: Any] {
                if let name = (nested["display_name"] as? String) ?? (nested["name"] as? String), !name.isEmpty {
                    return name
                }
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
                if !isBoolean(value), let number = value as? NSNumber {
                    return number.stringValue
                }
                if let text = value as? String, !text.isEmpty {
                    return text
                }
                if let nested = value as? [String: Any] {
                    if let unlimited = nested["unlimited"] as? Bool, unlimited { return "Unlimited" }
                    if let remaining = nested["remaining"] as? NSNumber, !isBoolean(remaining) {
                        return remaining.stringValue
                    }
                    if let balance = nested["balance"] as? String, !balance.isEmpty { return balance }
                }
            }
        }
        if let planStatus = dict["planStatus"] as? [String: Any],
           let credits = planStatus["availablePromptCredits"] as? NSNumber,
           !isBoolean(credits) {
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
            return (key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized, nil)
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let raw, !isBoolean(raw), let num = raw as? NSNumber { return num.doubleValue }
        if let str = raw as? String { return Double(str) }
        return nil
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

    private static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{001B}") else { return text }
        return text.replacingOccurrences(
            of: #"\u001B\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )
    }
}
