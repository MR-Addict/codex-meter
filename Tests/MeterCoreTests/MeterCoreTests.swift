import Testing
import Foundation
@testable import MeterCore

final class CodexUsageTests {
    func parse(_ json: String) throws -> CodexUsage { try CodexUsage.decode(Data(json.utf8)) }

    @Test func testCoreSelectionAdditionalBucketsAndSnapshotMapping() throws {
        let value = try parse(#"{"rateLimits":{"primary":{"usedPercent":5}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":22.1,"windowDurationMins":300,"resetsAt":5000},"secondary":{"usedPercent":61,"windowDurationMins":10080,"resetsAt":9000},"credits":{"balance":"12"}},"other":{"limitName":"Code Review","primary":{"usedPercent":99}}},"rateLimitResetCredits":{"availableCount":2},"unknown":"ignored"}"#)
        #expect(value.remaining == 39)
        #expect(value.core?.primary?.label == "5-hour")
        #expect(value.core?.secondary?.label == "Weekly")
        #expect(value.additionalBuckets.map(\.0) == ["other"])

        let snapshot = value.toSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(snapshot.serviceID == .codex)
        #expect(snapshot.headline?.remainingPercent == 39)
        #expect(snapshot.headline?.nearestResetAt == Date(timeIntervalSince1970: 5000))
        #expect(snapshot.sections.count == 2)
        #expect(snapshot.sections[0].items.map(\.title) == ["5-hour", "Weekly"])
        #expect(!snapshot.sections[0].isCollapsible)
        #expect(snapshot.sections[1].title == "Code Review")
        #expect(snapshot.sections[1].isCollapsible)
        #expect(!snapshot.sections[1].isExpandedByDefault)
        #expect(snapshot.sections[1].summaryPercent == 1)
        #expect(snapshot.badges.map(\.text) == ["Credits 12", "2 resets"])
    }

    @Test func testLegacyOptionalAndClamp() throws {
        #expect(try parse(#"{"rateLimits":{"primary":{"usedPercent":-10}}}"#).remaining == 100)
        #expect(try parse(#"{"rateLimits":{"secondary":{"usedPercent":150}}}"#).remaining == 0)
        let empty = try parse(#"{"rateLimits":{}}"#)
        #expect(empty.remaining == nil)
        #expect(empty.core?.credits == nil)
        #expect(empty.rateLimitResetCredits == nil)
    }

    @Test func testCreditsDoNotInferZero() throws {
        let value = try parse(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":null}},"rateLimitResetCredits":{"availableCount":0}}"#)
        #expect(value.core?.credits?.display == "Unavailable")
        #expect(value.rateLimitResetCredits?.availableCount == 0)
        #expect(try parse(#"{"rateLimits":{"credits":{"unlimited":true}}}"#).core?.credits?.display == "Unlimited")
    }

    @Test func testResetFormatting() throws {
        let window = try #require(parse(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":90,"resetsAt":5000}}}"#).core?.primary)
        #expect(window.label == "90-minute")
        #expect(window.resetText(now: Date(timeIntervalSince1970: 0)) == "Resets in 1h 24m")
        #expect(window.resetText(now: Date(timeIntervalSince1970: 6000)) == "Reset due · refresh to check")
        #expect(ResetFormatter.compactFormat(resetsAt: Date(timeIntervalSince1970: 5000), now: Date(timeIntervalSince1970: 0)) == "1h 24m")
        #expect(ResetFormatter.compactFormat(resetsAt: Date(timeIntervalSince1970: 5000), now: Date(timeIntervalSince1970: 6000)) == "Due")
        #expect(try parse(#"{"rateLimits":{"primary":{"usedPercent":0}}}"#).core?.primary?.resetText() == "Reset time unavailable")
    }

    @Test func testNearestResetAcrossWindows() throws {
        let value = try parse(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":5000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":3000}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":50,"resetsAt":900}}}}"#)
        #expect(value.nearestReset?.resetsAt == 900)
        #expect(value.resetSummary(now: Date(timeIntervalSince1970: 0)) == "Resets in 15m")
        #expect(try parse(#"{"rateLimits":{"primary":{"usedPercent":10}}}"#).nearestReset == nil)
    }

    @Test func testMalformed() {
        for json in ["oops", "{}", #"{"rateLimits":{"primary":{"usedPercent":"bad"}}}"#] {
            do { _ = try parse(json); Issue.record("Expected malformed response error") } catch {}
        }
    }

    @Test @MainActor func testStateRetainsLastSnapshotAndBlocksOverlap() throws {
        let state = ServiceState(descriptor: .codex)
        #expect(state.title == "Codex —")
        #expect(state.begin())
        #expect(!state.begin())
        let date = Date(timeIntervalSince1970: 100)
        let snapshot = try parse(#"{"rateLimits":{"primary":{"usedPercent":58}}}"#).toSnapshot(fetchedAt: date)
        state.succeed(snapshot, now: date)
        #expect(state.title == "Codex 42%")
        #expect(state.begin())
        state.fail(ProviderError.serviceUnavailable(serviceName: "Codex"))
        #expect(state.title == "Codex 42% ⚠︎")
        #expect(state.lastSuccess == date)
        #expect(state.snapshot != nil)
        state.succeed(try parse(#"{"rateLimits":{}}"#).toSnapshot())
        #expect(state.error == nil)
    }

    @Test func testPlanTypeNormalizationAndFreePlanEdgeCases() throws {
        // Real-world prolite single-window payload
        let prolite = try parse(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1796007500},"secondary":null,"planType":"prolite"}}"#)
        #expect(prolite.planName == "Pro Lite")
        #expect(prolite.toSnapshot().planName == "Pro Lite")
        #expect(prolite.remaining == 99)

        // All standard & unknown plan types
        #expect(CodexUsage.normalizePlanName("free") == "Free")
        #expect(CodexUsage.normalizePlanName("go") == "Go")
        #expect(CodexUsage.normalizePlanName("plus") == "Plus")
        #expect(CodexUsage.normalizePlanName("pro") == "Pro")
        #expect(CodexUsage.normalizePlanName("team") == "Team")
        #expect(CodexUsage.normalizePlanName("business") == "Business")
        #expect(CodexUsage.normalizePlanName("enterprise") == "Enterprise")
        #expect(CodexUsage.normalizePlanName("custom_tier") == "Custom Tier")

        // Free plan fallback when `rateLimits` is omitted and limits live under a non-"codex" bucket
        let freeScoped = try parse(#"{"rateLimitsByLimitId":{"codex_free":{"planType":"free","primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":9000}}}}"#)
        #expect(freeScoped.planName == "Free")
        #expect(freeScoped.remaining == 60)
        #expect(freeScoped.additionalBuckets.isEmpty)
        let freeSnapshot = freeScoped.toSnapshot()
        #expect(freeSnapshot.planName == "Free")
        #expect(freeSnapshot.headline?.remainingPercent == 60)
        #expect(freeSnapshot.sections.count == 1)
        #expect(freeSnapshot.sections[0].items.map(\.title) == ["Weekly"])

        // Free plan with ordinaryUsageAllowed == false and no windows
        let freeDisallowed = try CodexUsage.decode(
            Data(#"{"ordinaryUsageAllowed":false,"rateLimits":{}}"#.utf8),
            fallbackPlanType: "free"
        )
        let disallowedSnapshot = freeDisallowed.toSnapshot()
        #expect(disallowedSnapshot.planName == "Free")
        #expect(disallowedSnapshot.sections[0].emptyMessage == "Codex not included in current plan")
    }
}

@MainActor final class FakeTransport: RPCTransport {
    var onData: ((Data) -> Void)?
    var onExit: (() -> Void)?
    var methods: [String] = []
    var stopped = false
    var response: ((String, Int) -> [String: Any]?)?
    func start() throws {}
    func stop() { stopped = true }
    func write(_ data: Data) throws {
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let method = message["method"] as! String
        methods.append(method)
        guard let id = message["id"] as? Int else { return }
        let reply: [String: Any]?
        if let response {
            reply = response(method, id)
        } else {
            let result: [String: Any]
            switch method {
            case "account/read": result = ["account": ["type": "chatgpt"]]
            case "account/rateLimits/read": result = ["rateLimits": ["primary": ["usedPercent": 25]]]
            default: result = [:]
            }
            reply = ["id": id, "result": result]
        }
        guard let reply else { return }
        // Notifications and unmatched responses must not complete a request.
        onData?(Data("{\"method\":\"unrelated\"}\n{\"id\":9999,\"result\":{}}\n".utf8))
        var encoded = try JSONSerialization.data(withJSONObject: reply)
        encoded.append(10)
        let midpoint = encoded.count / 2
        onData?(Data(encoded.prefix(midpoint)))
        onData?(Data(encoded.dropFirst(midpoint)))
    }
}

final class RPCTests {
    @Test @MainActor func testHandshakeMatchingFragmentationAndReuse() async throws {
        let pipe = FakeTransport()
        let client = RPCClient { pipe }
        let first = try await client.readCodexUsage()
        #expect(first.remaining == 75)
        _ = try await client.readCodexUsage()
        #expect(pipe.methods == ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read", "account/rateLimits/read"])
        client.shutdown()
        #expect(pipe.stopped)
    }

    @Test @MainActor func testAccountPlanTypeFallbackAndPlanRestrictionError() async throws {
        let pipe = FakeTransport()
        pipe.response = { method, id in
            switch method {
            case "initialize": return ["id": id, "result": [:]]
            case "account/read": return ["id": id, "result": ["account": ["type": "chatgpt", "planType": "free"]]]
            case "account/rateLimits/read": return ["id": id, "result": ["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 10080]]]]
            default: return ["id": id, "result": [:]]
            }
        }
        let client = RPCClient { pipe }
        let usage = try await client.readCodexUsage()
        #expect(usage.planName == "Free")
        #expect(usage.remaining == 80)
        client.shutdown()

        let restrictedPipe = FakeTransport()
        restrictedPipe.response = { method, id in
            switch method {
            case "initialize": return ["id": id, "result": [:]]
            case "account/read": return ["id": id, "result": ["account": ["type": "chatgpt", "planType": "free"]]]
            case "account/rateLimits/read": return ["id": id, "error": ["code": -32000, "message": "Upgrade your plan to use Codex"]]
            default: return ["id": id, "result": [:]]
            }
        }
        let restrictedClient = RPCClient { restrictedPipe }
        do {
            _ = try await restrictedClient.readCodexUsage()
            Issue.record("Expected plan restriction error")
        } catch let error as ProviderError {
            #expect(error.message.contains("current ChatGPT plan"))
        }
        restrictedClient.shutdown()
    }

    @Test @MainActor func testExitRecovery() async throws {
        var pipes: [FakeTransport] = []
        let client = RPCClient {
            let pipe = FakeTransport()
            if pipes.isEmpty {
                pipe.response = { [weak pipe] _, _ in pipe?.onExit?(); return nil }
            }
            pipes.append(pipe)
            return pipe
        }
        let value = try await client.readCodexUsage()
        #expect(value.remaining == 75)
        #expect(pipes.count == 2)
        #expect(pipes[0].stopped)
        client.shutdown()
    }

    @Test @MainActor func testTimeoutRetriesAreBounded() async {
        var pipes: [FakeTransport] = []
        let client = RPCClient(timeout: 0.01) {
            let pipe = FakeTransport()
            pipe.response = { _, _ in nil }
            pipes.append(pipe)
            return pipe
        }
        do {
            _ = try await client.readCodexUsage()
            Issue.record("Expected timeout")
        } catch {
            #expect((error as? ProviderError)?.category == .connection)
        }
        #expect(pipes.count == 3)
        let allStopped = pipes.allSatisfy(\.stopped)
        #expect(allStopped)
    }

    @Test @MainActor func testMissingLoginAndUnsupportedMethod() async {
        for expected in [ErrorCategory.auth, .update] {
            let pipe = FakeTransport()
            pipe.response = { method, id in
                if method == "initialize" { return ["id": id, "result": [:]] }
                if expected == .update { return ["id": id, "error": ["code": -32601]] }
                return ["id": id, "result": ["account": NSNull()]]
            }
            let client = RPCClient { pipe }
            do {
                _ = try await client.readCodexUsage()
                Issue.record("Expected failure")
            } catch {
                #expect((error as? ProviderError)?.category == expected)
            }
            client.shutdown()
        }
    }

    @Test @MainActor func testShutdownReleasesPendingRequest() async {
        let pipe = FakeTransport()
        pipe.response = { _, _ in nil }
        let client = RPCClient(timeout: 1) { pipe }
        let task = Task { try await client.readCodexUsage() }
        await Task.yield()
        task.cancel()
        client.shutdown()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
        #expect(pipe.stopped)
    }

    @Test @MainActor func testMalformedWireResponse() async {
        let pipe = FakeTransport()
        pipe.response = { [weak pipe] _, _ in
            pipe?.onData?(Data("not-json\n".utf8))
            return nil
        }
        let client = RPCClient { pipe }
        do {
            _ = try await client.readCodexUsage()
            Issue.record("Expected malformed response")
        } catch {
            #expect((error as? ProviderError)?.category == .parse)
        }
        #expect(pipe.stopped)
    }

    @Test @MainActor func testMissingExecutable() async {
        let client = RPCClient {
            throw ProviderError.missingExecutable(serviceName: "Codex", executableName: "codex")
        }
        do {
            _ = try await client.readCodexUsage()
            Issue.record("Expected missing executable")
        } catch {
            #expect((error as? ProviderError)?.category == .setup)
        }
        #expect(ExecutableLocator.locate(name: "codex", custom: "/nonexistent/ai-meter-test") == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_METER_LIVE_TEST"] == "1"))
    @MainActor func testLiveUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_METER_LIVE_TEST"] == "1" else { return }
        let executable = try #require(ExecutableLocator.locate(name: "codex"))
        let client = RPCClient { ProcessTransport(executable: executable) }
        defer { client.shutdown() }
        let usage = try await client.readCodexUsage()
        #expect(usage.core != nil)
        // Deliberately do not print account data or balances.
    }
}
