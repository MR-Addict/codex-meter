import Foundation

/// Shared JSON decoding, scalar extraction, date parsing, and formatting helpers across providers.
public enum JSONParsing {
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Parses a JSON object directly, or falls back to stripping ANSI codes and extracting
    /// the outermost `{ ... }` payload when CLI output includes log preamble/epilogue.
    public static func extractJSONObject(from data: Data) -> [String: Any]? {
        if let direct = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return direct
        }
        let cleaned = stripANSI(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return nil
    }

    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{001B}") else { return text }
        return text.replacingOccurrences(
            of: #"\u001B\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )
    }

    public static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Safely extracts a numeric `Double`, rejecting JSON booleans bridged as `NSNumber`.
    public static func doubleValue(_ raw: Any?) -> Double? {
        if let raw, !isBoolean(raw), let num = raw as? NSNumber {
            return num.doubleValue
        }
        if let str = raw as? String {
            return Double(str)
        }
        return nil
    }

    /// Clamps a percentage in `[0, 100]` using floor rounding for conservative remaining-quota display.
    public static func clampedPercent(_ value: Double) -> Int {
        Int(floor(max(0, min(100, value))))
    }

    /// Converts either a `[0, 1]` fraction or a `[0, 100]` percentage into a clamped integer percent.
    public static func percentFromFraction(_ fraction: Double) -> Int {
        let scaled = fraction <= 1.0 && fraction >= 0.0 ? fraction * 100.0 : fraction
        return clampedPercent(scaled)
    }

    /// Parses RFC 3339 / ISO 8601 timestamps with or without fractional seconds.
    public static func parseISO8601(_ string: String) -> Date? {
        if let date = try? isoFractional.parse(string) {
            return date
        }
        return try? isoStandard.parse(string)
    }

    /// Parses date-only UTC strings (`yyyy-MM-dd`) as midnight UTC.
    public static func parseUTCDateOnly(_ string: String) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }

    /// Sorts dictionary keys putting `preferredOrder` entries first and remaining keys alphabetically.
    public static func sortedKeys<S: Sequence>(
        _ keys: S,
        preferredOrder: [String],
        caseInsensitive: Bool = false
    ) -> [String] where S.Element == String {
        let normalizedOrder = caseInsensitive ? preferredOrder.map { $0.lowercased() } : preferredOrder
        return keys.sorted { lhs, rhs in
            let leftKey = caseInsensitive ? lhs.lowercased() : lhs
            let rightKey = caseInsensitive ? rhs.lowercased() : rhs
            let leftIdx = normalizedOrder.firstIndex(of: leftKey) ?? Int.max
            let rightIdx = normalizedOrder.firstIndex(of: rightKey) ?? Int.max
            if leftIdx != rightIdx { return leftIdx < rightIdx }
            return lhs < rhs
        }
    }

    public static func humanizeIdentifier(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
