import Foundation
import Testing
import MeterCore
@testable import AIMeter

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
        let pendingID = pending.removeValue(forKey: method)
        let id = try #require(pendingID)
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
        data.append(10)
        onData?(data)
    }
    func complete(usedPercent: Double = 25) async throws {
        try await waitUntil { self.pending["initialize"] != nil }
        try reply("initialize", [:])
        try await waitUntil { self.pending["account/read"] != nil }
        try reply("account/read", ["account": ["type": "chatgpt"]])
        try await waitUntil { self.pending["account/rateLimits/read"] != nil }
        try reply("account/rateLimits/read", ["rateLimits": ["primary": ["usedPercent": usedPercent]]])
    }
}

@MainActor private final class ControlledProvider: UsageProvider {
    let descriptor: ServiceDescriptor
    let configKeys: ProviderConfigKeys
    var detected: Bool
    var fetchCount = 0
    var shutdownCount = 0
    var pendingContinuations: [CheckedContinuation<UsageSnapshot, Error>] = []
    var immediateResult: Result<UsageSnapshot, Error>?

    init(descriptor: ServiceDescriptor, detected: Bool = true) {
        self.descriptor = descriptor
        self.configKeys = ProviderConfigKeys(executablePathKey: "\(descriptor.id.rawValue)Path")
        self.detected = detected
    }

    func detect() -> DetectionStatus {
        detected ? .detected(source: "/mock/\(descriptor.executableName)") : .notFound
    }

    func fetchUsage() async throws -> UsageSnapshot {
        fetchCount += 1
        if let immediateResult {
            return try immediateResult.get()
        }
        return try await withCheckedThrowingContinuation { cont in
            pendingContinuations.append(cont)
        }
    }

    func resolveNext(remaining: Int) {
        guard !pendingContinuations.isEmpty else { return }
        let cont = pendingContinuations.removeFirst()
        let snapshot = UsageSnapshot(
            serviceID: descriptor.id,
            headline: HeadlineMetric(title: "Remaining", remainingPercent: remaining),
            sections: []
        )
        cont.resume(returning: snapshot)
    }

    func failNext(_ error: Error) {
        guard !pendingContinuations.isEmpty else { return }
        let cont = pendingContinuations.removeFirst()
        cont.resume(throwing: error)
    }

    func shutdown() {
        shutdownCount += 1
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    func resetClient() {
        shutdown()
    }
}

private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "ai-meter-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

struct MeterModelTests {
    @Test @MainActor func overlapCloseAndObsoleteTimer() async throws {
        let pipe = ControlledTransport()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let provider = CodexProvider(
            locateExecutable: { "/opt/homebrew/bin/codex" },
            makeClient: { RPCClient { pipe } }
        )
        let model = MeterModel(
            registry: ServiceRegistry(providers: [provider]),
            defaults: makeIsolatedDefaults(),
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { model.stop() }

        #expect(model.activeServiceID == .codex)
        model.refresh()
        model.popoverDidShow()
        model.popoverDidClose()
        #expect(scheduled.isEmpty) // no competing timer while loading

        try await pipe.complete()
        try await waitUntil { model.activeState?.refreshing == false }
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
        #expect(model.activeState?.refreshing == false)
    }

    @Test @MainActor func wakeReplacesPendingClientAndCoalescesNotifications() async throws {
        var pipes: [ControlledTransport] = []
        let provider = CodexProvider(
            locateExecutable: { "/opt/homebrew/bin/codex" },
            makeClient: {
                RPCClient {
                    let pipe = ControlledTransport()
                    pipes.append(pipe)
                    return pipe
                }
            }
        )
        let model = MeterModel(
            registry: ServiceRegistry(providers: [provider]),
            defaults: makeIsolatedDefaults(),
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { model.stop() }

        model.refresh()
        try await waitUntil { !pipes.isEmpty }
        model.resumeEnvironment()
        model.resumeEnvironment()
        try await waitUntil { pipes.count >= 2 }
        #expect(pipes[0].stopped)
        try await pipes[1].complete()
        try await waitUntil { model.activeState?.refreshing == false }
        #expect(pipes.count == 2)
        #expect(model.activeState?.snapshot?.remainingPercent == 75)
        #expect(model.activeState?.error == nil)
    }

    @Test @MainActor func failedRetryIsNotLostOnClose() async throws {
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let provider = CodexProvider(
            locateExecutable: { "/opt/homebrew/bin/codex" },
            makeClient: {
                RPCClient {
                    throw ProviderError.authRequired(serviceName: "Codex", command: "codex login")
                }
            }
        )
        let model = MeterModel(
            registry: ServiceRegistry(providers: [provider]),
            defaults: makeIsolatedDefaults(),
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { model.stop() }

        model.refresh()
        try await waitUntil { model.activeState?.refreshing == false }
        #expect(scheduled.last?.0 == 120)
        let retryAt = model.activeState?.retryAt
        #expect(retryAt != nil)
        model.popoverDidClose()
        #expect(model.activeState?.retryAt == retryAt)
        #expect((scheduled.last?.0 ?? 0) > 119)

        model.stop()
        scheduled.last?.1()
        #expect(model.activeState?.refreshing == false)
        #expect(model.activeState?.retryAt == nil)
    }

    @Test @MainActor func zeroServicesDetectedAndRescanAutoSelects() async throws {
        let codex = ControlledProvider(descriptor: .codex, detected: false)
        let agy = ControlledProvider(descriptor: .antigravity, detected: false)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let model = MeterModel(
            registry: ServiceRegistry(providers: [codex, agy]),
            defaults: makeIsolatedDefaults(),
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { model.stop() }

        #expect(model.detectedServices.isEmpty)
        #expect(model.activeServiceID == nil)
        model.refresh()
        #expect(codex.fetchCount == 0)
        #expect(agy.fetchCount == 0)
        #expect(scheduled.isEmpty)

        // User installs Antigravity CLI and rescans
        agy.detected = true
        model.rescanServices()
        #expect(model.detectedServices.map(\.id) == [.antigravity])
        #expect(model.activeServiceID == .antigravity)
        try await waitUntil { agy.fetchCount == 1 }
        agy.resolveNext(remaining: 88)
        try await waitUntil { model.activeState?.refreshing == false }
        #expect(model.activeState?.snapshot?.remainingPercent == 88)
    }

    @Test @MainActor func switchingServicesShutsDownPreviousIsolatesStaleResultsAndRetainsCache() async throws {
        let codex = ControlledProvider(descriptor: .codex, detected: true)
        let agy = ControlledProvider(descriptor: .antigravity, detected: true)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let defaults = makeIsolatedDefaults()
        let model = MeterModel(
            registry: ServiceRegistry(providers: [codex, agy]),
            defaults: defaults,
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { model.stop() }

        #expect(model.detectedServices.count == 2)
        #expect(model.activeServiceID == .codex)

        // Complete initial Codex fetch
        model.refresh()
        try await waitUntil { codex.fetchCount == 1 }
        codex.resolveNext(remaining: 91)
        try await waitUntil { model.state(for: .codex)?.refreshing == false }
        #expect(model.state(for: .codex)?.snapshot?.remainingPercent == 91)

        // Start another Codex fetch, then switch to Antigravity mid-flight
        model.refresh(force: true)
        try await waitUntil { codex.fetchCount == 2 }
        model.selectService(.antigravity)

        #expect(model.activeServiceID == .antigravity)
        #expect(defaults.string(forKey: "activeServiceID") == "antigravity")
        #expect(codex.shutdownCount == 1)
        #expect(model.state(for: .codex)?.refreshing == false)
        // Codex's cached snapshot is preserved while inactive
        #expect(model.state(for: .codex)?.snapshot?.remainingPercent == 91)

        // Antigravity immediately starts refreshing
        try await waitUntil { agy.fetchCount == 1 }
        agy.resolveNext(remaining: 74)
        try await waitUntil { model.state(for: .antigravity)?.refreshing == false }
        #expect(model.activeState?.snapshot?.remainingPercent == 74)
        #expect(scheduled.last?.0 == 60)
    }

    @Test @MainActor func threeServicesCoexistAndSwitchToCopilot() async throws {
        let codex = ControlledProvider(descriptor: .codex, detected: true)
        let agy = ControlledProvider(descriptor: .antigravity, detected: true)
        let copilot = ControlledProvider(descriptor: .copilot, detected: true)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let defaults = makeIsolatedDefaults()
        let model = MeterModel(
            registry: ServiceRegistry(providers: [codex, agy, copilot]),
            defaults: defaults,
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { model.stop() }

        #expect(model.detectedServices.map(\.id) == [.codex, .antigravity, .copilot])
        #expect(model.activeServiceID == .codex)

        model.selectService(.copilot)
        #expect(model.activeServiceID == .copilot)
        #expect(defaults.string(forKey: "activeServiceID") == "copilot")
        try await waitUntil { copilot.fetchCount == 1 }
        copilot.resolveNext(remaining: 82)
        try await waitUntil { model.state(for: .copilot)?.refreshing == false }
        #expect(model.activeState?.title == "Copilot 82%")
        #expect(scheduled.last?.0 == 60)
    }

    @Test @MainActor func togglingServicesPersistsStateSwitchesActiveAndHandlesAllDisabled() async throws {
        let codex = ControlledProvider(descriptor: .codex, detected: true)
        let agy = ControlledProvider(descriptor: .antigravity, detected: true)
        let copilot = ControlledProvider(descriptor: .copilot, detected: true)
        let defaults = makeIsolatedDefaults()
        let model = MeterModel(
            registry: ServiceRegistry(providers: [codex, agy, copilot]),
            defaults: defaults,
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { model.stop() }

        #expect(model.enabledServices.map(\.id) == [.codex, .antigravity, .copilot])
        #expect(model.activeServiceID == .codex)

        // Disable active service (codex) -> shuts it down and switches to antigravity
        model.setServiceEnabled(.codex, enabled: false)
        #expect(!model.isServiceEnabled(.codex))
        #expect(codex.shutdownCount == 1)
        #expect(model.enabledServices.map(\.id) == [.antigravity, .copilot])
        #expect(model.activeServiceID == .antigravity)
        #expect(defaults.stringArray(forKey: "disabledServiceIDs") == ["codex"])

        // Disabled service cannot be selected
        model.selectService(.codex)
        #expect(model.activeServiceID == .antigravity)

        // Disable remaining services -> activeServiceID becomes nil while detectedServices stays intact
        model.setServiceEnabled(.antigravity, enabled: false)
        #expect(model.activeServiceID == .copilot)
        model.setServiceEnabled(.copilot, enabled: false)
        #expect(model.activeServiceID == nil)
        #expect(model.enabledServices.isEmpty)
        #expect(model.detectedServices.count == 3)

        // Re-enabling one service when none are active activates and refreshes it immediately
        model.setServiceEnabled(.copilot, enabled: true)
        #expect(model.activeServiceID == .copilot)
        try await waitUntil { copilot.fetchCount >= 2 }

        // A fresh MeterModel with the same defaults restores disabled services
        let reloaded = MeterModel(
            registry: ServiceRegistry(providers: [
                ControlledProvider(descriptor: .codex, detected: true),
                ControlledProvider(descriptor: .antigravity, detected: true),
                ControlledProvider(descriptor: .copilot, detected: true),
            ]),
            defaults: defaults,
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { reloaded.stop() }
        #expect(!reloaded.isServiceEnabled(.codex))
        #expect(!reloaded.isServiceEnabled(.antigravity))
        #expect(reloaded.isServiceEnabled(.copilot))
        #expect(reloaded.enabledServices.map(\.id) == [.copilot])
        #expect(reloaded.activeServiceID == .copilot)
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
