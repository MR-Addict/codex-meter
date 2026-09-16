import Testing
import Foundation
@testable import MeterCore

final class UsageTests {
    func parse(_ json: String) throws -> Usage { try Usage.decode(Data(json.utf8)) }
    @Test func testCoreSelectionAndAdditionalBuckets() throws {
        let value = try parse(#"{"rateLimits":{"primary":{"usedPercent":5}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":22.1,"windowDurationMins":300},"secondary":{"usedPercent":61,"windowDurationMins":10080}},"other":{"primary":{"usedPercent":99}}},"unknown":"ignored"}"#)
        expectEqual(value.remaining, 39)
        expectEqual(value.core?.primary?.label, "5-hour")
        expectEqual(value.core?.secondary?.label, "Weekly")
        expectEqual(value.additionalBuckets.map(\.0), ["other"])
    }
    @Test func testLegacyOptionalAndClamp() throws {
        expectEqual(try parse(#"{"rateLimits":{"primary":{"usedPercent":-10}}}"#).remaining, 100)
        expectEqual(try parse(#"{"rateLimits":{"secondary":{"usedPercent":150}}}"#).remaining, 0)
        let empty = try parse(#"{"rateLimits":{}}"#)
        expectNil(empty.remaining)
        expectNil(empty.core?.credits)
        expectNil(empty.rateLimitResetCredits)
    }
    @Test func testCreditsDoNotInferZero() throws {
        let value = try parse(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":null}},"rateLimitResetCredits":{"availableCount":0}}"#)
        expectEqual(value.core?.credits?.display, "Unavailable")
        expectEqual(value.rateLimitResetCredits?.availableCount, 0)
        expectEqual(try parse(#"{"rateLimits":{"credits":{"unlimited":true}}}"#).core?.credits?.display, "Unlimited")
    }
    @Test func testResetFormatting() throws {
        let window = try #require(parse(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":90,"resetsAt":5000}}}"#).core?.primary)
        expectEqual(window.label, "90-minute")
        expectEqual(window.resetText(now: Date(timeIntervalSince1970: 0)), "Resets in 1h 24m")
        expectEqual(window.resetText(now: Date(timeIntervalSince1970: 6000)), "Reset due · refresh to check")
        expectEqual(try parse(#"{"rateLimits":{"primary":{"usedPercent":0}}}"#).core?.primary?.resetText(), "Reset time unavailable")
    }
    @Test func testMalformed() {
        for json in ["oops", "{}", #"{"rateLimits":{"primary":{"usedPercent":"bad"}}}"#] {
            do { _ = try parse(json); Issue.record("Expected malformed response error") } catch {}
        }
    }
    @Test @MainActor func testStateRetainsLastSnapshotAndBlocksOverlap() throws {
        let state = UsageState()
        expectEqual(state.title, "Codex —")
        expectTrue(state.begin()); expectFalse(state.begin())
        let date = Date(timeIntervalSince1970: 100)
        state.succeed(try parse(#"{"rateLimits":{"primary":{"usedPercent":58}}}"#), now: date)
        expectEqual(state.title, "Codex 42%")
        expectTrue(state.begin())
        state.fail(MeterError.service)
        expectEqual(state.title, "Codex 42% ⚠︎")
        expectEqual(state.lastSuccess, date)
        expectNotNil(state.usage)
        state.succeed(try parse(#"{"rateLimits":{}}"#))
        expectNil(state.error)
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
        if let response { reply = response(method, id) }
        else {
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
        let first = try await client.readUsage()
        expectEqual(first.remaining, 75)
        _ = try await client.readUsage()
        expectEqual(pipe.methods, ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read", "account/rateLimits/read"])
        client.shutdown()
        expectTrue(pipe.stopped)
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
        let value = try await client.readUsage()
        expectEqual(value.remaining, 75)
        expectEqual(pipes.count, 2)
        expectTrue(pipes[0].stopped)
        client.shutdown()
    }
    @Test @MainActor func testTimeoutRetriesAreBounded() async {
        var pipes: [FakeTransport] = []
        let client = RPCClient(timeout: 0.01) {
            let pipe = FakeTransport(); pipe.response = { _, _ in nil }; pipes.append(pipe); return pipe
        }
        do { _ = try await client.readUsage(); Issue.record("Expected timeout") }
        catch { expectEqual(error as? MeterError, .timeout) }
        expectEqual(pipes.count, 3)
        expectTrue(pipes.allSatisfy(\.stopped))
    }
    @Test @MainActor func testMissingLoginAndUnsupportedMethod() async {
        for expected in [MeterError.login, .unsupported] {
            let pipe = FakeTransport()
            pipe.response = { method, id in
                if method == "initialize" { return ["id": id, "result": [:]] }
                if expected == .unsupported { return ["id": id, "error": ["code": -32601]] }
                return ["id": id, "result": ["account": NSNull()]]
            }
            let client = RPCClient { pipe }
            do { _ = try await client.readUsage(); Issue.record("Expected failure") }
            catch { expectEqual(error as? MeterError, expected) }
            client.shutdown()
        }
    }
    @Test @MainActor func testShutdownReleasesPendingRequest() async {
        let pipe = FakeTransport()
        pipe.response = { _, _ in nil }
        let client = RPCClient(timeout: 1) { pipe }
        let task = Task { try await client.readUsage() }
        await Task.yield()
        task.cancel()
        client.shutdown()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
        expectTrue(pipe.stopped)
    }
    @Test @MainActor func testMalformedWireResponse() async {
        let pipe = FakeTransport()
        pipe.response = { [weak pipe] _, _ in
            pipe?.onData?(Data("not-json\n".utf8))
            return nil
        }
        let client = RPCClient { pipe }
        do { _ = try await client.readUsage(); Issue.record("Expected malformed response") }
        catch { expectEqual(error as? MeterError, .malformed) }
        expectTrue(pipe.stopped)
    }
    @Test @MainActor func testMissingExecutable() async {
        let client = RPCClient { throw MeterError.missingCLI }
        do { _ = try await client.readUsage(); Issue.record("Expected missing CLI") }
        catch { expectEqual(error as? MeterError, .missingCLI) }
        expectNil(CLILocator.locate(custom: "/nonexistent/codex-meter-test"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_METER_LIVE_TEST"] == "1"))
    @MainActor func testLiveUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_METER_LIVE_TEST"] == "1" else {
            return
        }
        let executable = try #require(CLILocator.locate())
        let client = RPCClient { ProcessTransport(executable: executable) }
        defer { client.shutdown() }
        let usage = try await client.readUsage()
        expectNotNil(usage.core)
        // Deliberately do not print account data or balances.
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func expectNotNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value != nil, sourceLocation: sourceLocation)
}
