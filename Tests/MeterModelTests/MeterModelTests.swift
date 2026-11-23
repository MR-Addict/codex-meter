import Foundation
import ServiceManagement
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
    let configSpec: ProviderConfigSpec
    var detected: Bool
    var fetchCount = 0
    var shutdownCount = 0
    var pendingContinuations: [CheckedContinuation<UsageSnapshot, Error>] = []
    var immediateResult: Result<UsageSnapshot, Error>?

    init(
        descriptor: ServiceDescriptor,
        detected: Bool = true,
        supplementalFile: SupplementalFileConfig? = nil
    ) {
        self.descriptor = descriptor
        self.configSpec = ProviderConfigSpec(
            executablePathKey: "\(descriptor.id.rawValue)Path",
            supplementalFile: supplementalFile
        )
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

@MainActor private final class MockPlatformActions: PlatformActions {
    var chosenFileURL: URL?
    var executablePaths: Set<String> = []
    var readablePaths: Set<String> = []
    var copiedTexts: [String] = []
    var loginStatus: SMAppService.Status = .notRegistered
    var lastFilePanelTitle: String?
    var terminated = false

    func chooseFile(title: String, initialDirectory: URL?) -> URL? {
        lastFilePanelTitle = title
        return chosenFileURL
    }

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }

    func isReadableFile(atPath path: String) -> Bool {
        readablePaths.contains(path)
    }

    func copyToClipboard(_ text: String) {
        copiedTexts.append(text)
    }

    func loginItemStatus() -> SMAppService.Status {
        loginStatus
    }

    func setLoginItemEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        loginStatus = enabled ? .enabled : .notRegistered
        return loginStatus
    }

    func observeSystemEvents(
        onWake: @escaping @MainActor () -> Void,
        onAppActive: @escaping @MainActor () -> Void,
        onTerminate: @escaping @MainActor () -> Void
    ) -> [NSObjectProtocol] {
        []
    }

    func removeSystemObservers(_ observers: [NSObjectProtocol]) {}

    func terminateApp() {
        terminated = true
    }
}

struct MeterModelTests {
    @Test @MainActor func overlapCloseAndObsoleteTimer() async throws {
        let pipe = ControlledTransport()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let provider = CodexProvider(
            locateExecutable: { "/opt/homebrew/bin/codex" },
            makeClient: { CodexRPCClient { pipe } }
        )
        let model = MeterModel(
            registry: ServiceRegistry(providers: [provider]),
            configStore: InMemoryConfigStore(),
            platform: MockPlatformActions(),
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
                CodexRPCClient {
                    let pipe = ControlledTransport()
                    pipes.append(pipe)
                    return pipe
                }
            }
        )
        let model = MeterModel(
            registry: ServiceRegistry(providers: [provider]),
            configStore: InMemoryConfigStore(),
            platform: MockPlatformActions(),
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
                CodexRPCClient {
                    throw ProviderError.authRequired(serviceName: "Codex", command: "codex login")
                }
            }
        )
        let model = MeterModel(
            registry: ServiceRegistry(providers: [provider]),
            configStore: InMemoryConfigStore(),
            platform: MockPlatformActions(),
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

    @Test @MainActor func threeServicesCoexistAndSwitchToCopilot() async throws {
        let codex = ControlledProvider(descriptor: .codex, detected: true)
        let agy = ControlledProvider(descriptor: .antigravity, detected: true)
        let copilot = ControlledProvider(descriptor: .copilot, detected: true)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let store = InMemoryConfigStore()
        let model = MeterModel(
            registry: ServiceRegistry(providers: [codex, agy, copilot]),
            configStore: store,
            platform: MockPlatformActions(),
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { model.stop() }

        #expect(model.detectedServices.map(\.id) == [.codex, .antigravity, .copilot])
        #expect(model.activeServiceID == .codex)

        model.selectService(.copilot)
        #expect(model.activeServiceID == .copilot)
        #expect(store.string(forKey: ServiceCoordinator.activeServiceDefaultsKey) == "copilot")
        try await waitUntil { copilot.fetchCount == 1 }
        copilot.resolveNext(remaining: 82)
        try await waitUntil { model.state(for: .copilot)?.refreshing == false }
        #expect(model.activeState?.title == "Copilot 82%")
        #expect(scheduled.last?.0 == 60)
    }

    @Test @MainActor func platformActionsHandleExecutableValidationClipboardAndSectionDefaults() {
        let codex = ControlledProvider(descriptor: .codex, detected: true)
        let store = InMemoryConfigStore()
        let platform = MockPlatformActions()
        let model = MeterModel(
            registry: ServiceRegistry(providers: [codex]),
            configStore: store,
            platform: platform,
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { model.stop() }

        // Choosing a non-executable sets preferenceError and does not persist.
        platform.chosenFileURL = URL(fileURLWithPath: "/tmp/not-exec")
        model.chooseExecutable(for: .codex)
        #expect(model.preferenceError != nil)
        #expect(!model.hasCustomExecutable(for: .codex))

        // Choosing a valid executable clears error and persists into shared config store.
        platform.executablePaths.insert("/usr/local/bin/codex")
        platform.chosenFileURL = URL(fileURLWithPath: "/usr/local/bin/codex")
        model.chooseExecutable(for: .codex)
        #expect(model.preferenceError == nil)
        #expect(model.hasCustomExecutable(for: .codex))
        #expect(store.string(forKey: "codexPath") == "/usr/local/bin/codex")

        // Clipboard helper copies via PlatformActions.
        model.copyLoginCommand("codex login")
        #expect(platform.copiedTexts == ["codex login"])
        #expect(model.copiedLoginCommand == "codex login")

        // Section expansion respects `isExpandedByDefault`.
        let collapsedSection = QuotaSection(id: "sec-collapsed", items: [], isCollapsible: true, isExpandedByDefault: false)
        let expandedSection = QuotaSection(id: "sec-expanded", items: [], isCollapsible: true, isExpandedByDefault: true)
        #expect(!model.isSectionExpanded(collapsedSection))
        #expect(model.isSectionExpanded(expandedSection))
        model.toggleSection("sec-collapsed")
        model.toggleSection("sec-expanded")
        #expect(model.isSectionExpanded(collapsedSection))
        #expect(!model.isSectionExpanded(expandedSection))

        // Login item & quit delegate cleanly.
        model.setLogin(true)
        #expect(model.loginEnabled)
        model.quit()
        #expect(platform.terminated)
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
