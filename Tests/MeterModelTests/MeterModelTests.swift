import Foundation
import Testing
import MeterCore
@testable import CodexMeter

@MainActor private final class ControlledTransport: RPCTransport {
    var onData: ((Data) -> Void)?
    var onExit: (() -> Void)?
    var methods: [String] = []
    var pending: [String: Int] = [:]
    var stopped = false
    func start() throws {}
    func stop() { stopped = true }
    func write(_ data: Data) throws {
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let method = message["method"] as! String
        methods.append(method)
        if let id = message["id"] as? Int { pending[method] = id }
    }
    func reply(_ method: String, _ result: [String: Any]) throws {
        let id = try #require(pending.removeValue(forKey: method))
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
        data.append(10)
        onData?(data)
    }
    func complete() async throws {
        try await waitUntil { !(pending["initialize"] == nil) }
        try reply("initialize", [:])
        try await waitUntil { !(pending["account/read"] == nil) }
        try reply("account/read", ["account": ["type": "chatgpt"]])
        try await waitUntil { !(pending["account/rateLimits/read"] == nil) }
        try reply("account/rateLimits/read", ["rateLimits": ["primary": ["usedPercent": 25]]])
    }
}

struct MeterModelTests {
    @Test @MainActor func overlapCloseAndObsoleteTimer() async throws {
        let pipe = ControlledTransport()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let model = MeterModel(startAutomatically: false, makeClient: { RPCClient { pipe } },
                               scheduler: { scheduled.append(($0, $1)) })
        defer { model.stop() }
        model.refresh()
        model.popoverDidShow()
        model.popoverDidClose()
        #expect(scheduled.isEmpty) // no competing timer while loading
        try await pipe.complete()
        try await waitUntil { !(model.state.refreshing) }
        #expect(scheduled.last?.0 == 60)
        let oldFire = try #require(scheduled.last?.1)
        model.popoverDidShow() // rapid reopen coalesces, switches to 20s cadence
        #expect((scheduled.last?.0 ?? 100) <= 20)
        let count = pipe.methods.count
        oldFire()
        await Task.yield()
        #expect(pipe.methods.count == count)
        model.stop()
        scheduled.last?.1()
        #expect(!model.state.refreshing)
    }
    @Test @MainActor func wakeReplacesPendingClientAndCoalescesNotifications() async throws {
        var pipes: [ControlledTransport] = []
        let model = MeterModel(startAutomatically: false, makeClient: {
            RPCClient { let pipe = ControlledTransport(); pipes.append(pipe); return pipe }
        }, scheduler: { _, _ in })
        defer { model.stop() }
        model.refresh()
        try await waitUntil { !(pipes.isEmpty) }
        model.resumeEnvironment()
        model.resumeEnvironment()
        try await waitUntil { !(pipes.count < 2) }
        #expect(pipes[0].stopped)
        try await pipes[1].complete()
        try await waitUntil { !(model.state.refreshing) }
        #expect(pipes.count == 2)
        #expect(model.state.usage?.remaining == 75)
        #expect(model.state.error == nil)
    }
    @Test @MainActor func failedRetryIsNotLostOnClose() async throws {
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let model = MeterModel(startAutomatically: false,
            makeClient: { RPCClient { throw MeterError.login } },
            scheduler: { scheduled.append(($0, $1)) })
        defer { model.stop() }
        model.refresh()
        try await waitUntil { !(model.state.refreshing) }
        #expect(scheduled.last?.0 == 120)
        let retryAt = model.retryAt
        model.popoverDidClose()
        #expect(model.retryAt == retryAt)
        #expect((scheduled.last?.0 ?? 0) > 119)
        model.stop()
        scheduled.last?.1()
        #expect(!model.state.refreshing)
        #expect(model.retryAt == nil)
    }
}

private struct WaitTimeout: Error {}
@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw WaitTimeout()
}
