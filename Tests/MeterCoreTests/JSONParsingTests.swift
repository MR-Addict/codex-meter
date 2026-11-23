import Foundation
import Testing
@testable import MeterCore

struct JSONParsingTests {
    @Test func extractsJSONObjectAcrossDirectANSIAndPreambleInputs() throws {
        let direct = try #require(JSONParsing.extractJSONObject(from: Data(#"{"a":1}"#.utf8)))
        #expect((direct["a"] as? Int) == 1)

        let ansiWrapped = "\u{001B}[32mInfo:\u{001B}[0m loading...\n{\"ok\":true,\"value\":42}\ndone\n"
        let extracted = try #require(JSONParsing.extractJSONObject(from: Data(ansiWrapped.utf8)))
        #expect((extracted["value"] as? Int) == 42)

        #expect(JSONParsing.extractJSONObject(from: Data("plain text".utf8)) == nil)
    }

    @Test func rejectsBooleansInDoubleValueExtraction() {
        #expect(JSONParsing.isBoolean(NSNumber(value: true)))
        #expect(!JSONParsing.isBoolean(NSNumber(value: 1)))
        #expect(JSONParsing.doubleValue(NSNumber(value: true)) == nil)
        #expect(JSONParsing.doubleValue(NSNumber(value: 12.5)) == 12.5)
        #expect(JSONParsing.doubleValue("42.25") == 42.25)
        #expect(JSONParsing.doubleValue("nope") == nil)
    }

    @Test func parsesISO8601AndUTCDateOnly() throws {
        let withMillis = try #require(JSONParsing.parseISO8601("2026-10-06T22:28:10.500Z"))
        let withoutMillis = try #require(JSONParsing.parseISO8601("2026-10-06T22:28:10Z"))
        #expect(abs(withMillis.timeIntervalSince(withoutMillis) - 0.5) < 0.001)

        let dateOnly = try #require(JSONParsing.parseUTCDateOnly("2026-12-01"))
        let expected = try #require(JSONParsing.parseISO8601("2026-12-01T00:00:00Z"))
        #expect(dateOnly == expected)
        #expect(JSONParsing.parseUTCDateOnly("invalid") == nil)
    }

    @Test func clampsPercentagesAndSortsPreferredKeys() {
        #expect(JSONParsing.clampedPercent(-5) == 0)
        #expect(JSONParsing.clampedPercent(99.9) == 99)
        #expect(JSONParsing.clampedPercent(120) == 100)
        #expect(JSONParsing.percentFromFraction(0.725) == 72)
        #expect(JSONParsing.percentFromFraction(84.2) == 84)

        let sorted = JSONParsing.sortedKeys(
            ["z", "chat", "a", "Premium_Interactions"],
            preferredOrder: ["premium_interactions", "chat"],
            caseInsensitive: true
        )
        #expect(sorted == ["Premium_Interactions", "chat", "a", "z"])
        #expect(JSONParsing.humanizeIdentifier("custom_plan-tier") == "Custom Plan Tier")
    }
}
