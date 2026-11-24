import Foundation
import Testing
@testable import MeterCore

struct HeadlinePolicyTests {
    let origin = Date(timeIntervalSince1970: 0)

    @MainActor
    private func check(_ snapshot: UsageSnapshot, service: ServiceDescriptor, title: String,
                       value: String, reset: String?) throws {
        let headline = try #require(snapshot.headline)
        let section = try #require(snapshot.sections.first { $0.id == headline.sectionID })
        let item = try #require(section.items.first { $0.id == headline.itemID })
        #expect(!section.isCollapsible)
        #expect(item.valueDisplay == value)
        #expect(headline.valueDisplay == value)
        #expect(headline.title == title)
        #expect(headline.detailText(now: origin) == reset)
        #expect(snapshot.resetSummary(now: origin) == reset)
        let state = ServiceState(descriptor: service)
        state.succeed(snapshot)
        #expect(state.menuBarValue == value)
        #expect(state.quotaDescription == "\(title) · \(value)")
    }

    @Test @MainActor func weeklyOnlyCodex() throws {
        let data = Data(#"{"rateLimits":{"primary":{"windowDurationMins":10080,"usedPercent":3,"resetsAt":500400}}}"#.utf8)
        try check(CodexUsage.decode(data).toSnapshot(), service: .codex, title: "Weekly",
                  value: "97%", reset: "Resets in 5d 19h")
    }

    @Test @MainActor func codexWeeklyOverrideRequiresActualExhaustion() throws {
        for (used, expected) in [(99.9, "5-hour"), (100.0, "Weekly")] {
            let json = """
            {"rateLimits":{"primary":{"usedPercent":\(used),"windowDurationMins":10080,"resetsAt":3600},
                           "secondary":{"usedPercent":20,"windowDurationMins":300}}}
            """
            let snapshot = try CodexUsage.decode(Data(json.utf8)).toSnapshot()
            try check(snapshot, service: .codex, title: expected, value: used == 100 ? "0%" : "80%",
                      reset: used == 100 ? "Resets in 1h 0m" : "Reset time unavailable")
        }
    }

    @Test @MainActor func missingCodexReadingFallsBackWithinCore() throws {
        let json = #"{"rateLimits":{"primary":{"windowDurationMins":300},"secondary":{"usedPercent":41,"windowDurationMins":90}}}"#
        try check(CodexUsage.decode(Data(json.utf8)).toSnapshot(), service: .codex,
                  title: "90-minute", value: "59%", reset: "Reset time unavailable")
    }

    @Test @MainActor func geminiPoolUsesItsOwnWindowsAndReset() throws {
        for (fraction, exhausted) in [(0.76, false), (0.001, false), (0, true)] {
            let json = """
            {"groups":[{"name":"Claude and GPT models","buckets":[{"window":"weekly","remaining_fraction":0}]},
                       {"name":"Gemini Models","buckets":[
                         {"window":"weekly","remaining_fraction":\(fraction),"reset_in_seconds":583200},
                         {"window":"5h","remaining_fraction":1,"reset_in_seconds":16500}]}]}
            """
            let snapshot = try AntigravityUsage.decode(Data(json.utf8), now: origin).toSnapshot()
            try check(snapshot, service: .antigravity, title: exhausted ? "Gemini · Weekly" : "Gemini · 5-hour",
                      value: exhausted ? "0%" : "100%", reset: exhausted ? "Resets in 6d 18h" : "Resets in 4h 35m")
            #expect(snapshot.sections.first?.title == "Gemini Models")
        }
    }

    @Test @MainActor func disabledAndMissingGeminiReadingsAllowFallbackToFirstActiveGroup() throws {
        let json = """
        {"groups":[{"name":"Gemini Models","buckets":[{"window":"5h","remaining_fraction":1,"disabled":true},
                      {"window":"weekly","remaining_fraction":null,"reset_in_seconds":16500}]},
                   {"name":"Claude and GPT models","buckets":[{"window":"5h","remaining_fraction":0.9}]},
                   {"name":"Another pool","buckets":[{"window":"weekly","remaining_fraction":0}]}]}
        """
        let snapshot = try AntigravityUsage.decode(Data(json.utf8), now: origin).toSnapshot()
        try check(snapshot, service: .antigravity, title: "Claude & GPT · 5-hour", value: "90%", reset: nil)
    }

    @Test @MainActor func copilotChatAndCompletionResetAreIndependent() throws {
        let json = """
        {"quota_snapshots":{"chat":{"entitlement":200,"remaining":199},
                            "completions":{"entitlement":2000,"remaining":338,"resetsAt":3000}}}
        """
        let snapshot = try CopilotUsage.decode(Data(json.utf8)).toSnapshot()
        try check(snapshot, service: .copilot, title: "Chat", value: "99%", reset: nil)
        #expect(snapshot.sections[0].items.last?.valueDisplay == "16%")
    }

    @Test @MainActor func unlimitedChatBeatsFiniteCompletions() throws {
        let json = #"{"quota_snapshots":{"chat":{"unlimited":true},"completions":{"percent_remaining":5}}}"#
        let snapshot = try CopilotUsage.decode(Data(json.utf8)).toSnapshot()
        try check(snapshot, service: .copilot, title: "Chat", value: "Unlimited", reset: nil)
    }

    @Test @MainActor func completionsAloneRemainDetailOnly() throws {
        let json = #"{"quota_snapshots":{"completions":{"percent_remaining":16,"resetsAt":3000}}}"#
        let snapshot = try CopilotUsage.decode(Data(json.utf8)).toSnapshot()
        let state = ServiceState(descriptor: .copilot)
        state.succeed(snapshot)
        #expect(state.menuBarValue == "—")
        #expect(state.quotaDescription == "Primary quota · Unavailable")
        #expect(snapshot.headline?.itemID == nil)
        #expect(snapshot.resetSummary() == nil)
        #expect(snapshot.sections[0].items[0].valueDisplay == "16%")
    }
}
