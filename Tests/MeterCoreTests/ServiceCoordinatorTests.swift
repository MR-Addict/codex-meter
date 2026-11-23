import Foundation
import Testing
@testable import MeterCore

struct ServiceCoordinatorTests {
    @Test @MainActor func zeroServicesDetectedAndRescanAutoSelects() async throws {
        let codex = ControlledTestProvider(descriptor: .codex, detected: false)
        let agy = ControlledTestProvider(descriptor: .antigravity, detected: false)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let coordinator = ServiceCoordinator(
            registry: ServiceRegistry(providers: [codex, agy]),
            configStore: InMemoryConfigStore(),
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { coordinator.stop() }

        #expect(coordinator.detectedServices.isEmpty)
        #expect(coordinator.activeServiceID == nil)
        coordinator.refresh()
        #expect(codex.fetchCount == 0)
        #expect(agy.fetchCount == 0)
        #expect(scheduled.isEmpty)

        agy.detected = true
        coordinator.rescanServices()
        #expect(coordinator.detectedServices.map(\.id) == [.antigravity])
        #expect(coordinator.activeServiceID == .antigravity)
        try await waitUntil { agy.fetchCount == 1 }
        agy.resolveNext(remaining: 88)
        try await waitUntil { coordinator.activeState?.refreshing == false }
        #expect(coordinator.activeState?.snapshot?.remainingPercent == 88)
    }

    @Test @MainActor func switchingServicesShutsDownPreviousIsolatesStaleResultsAndRetainsCache() async throws {
        let codex = ControlledTestProvider(descriptor: .codex, detected: true)
        let agy = ControlledTestProvider(descriptor: .antigravity, detected: true)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let store = InMemoryConfigStore()
        let coordinator = ServiceCoordinator(
            registry: ServiceRegistry(providers: [codex, agy]),
            configStore: store,
            startAutomatically: false,
            scheduler: { scheduled.append(($0, $1)) }
        )
        defer { coordinator.stop() }

        coordinator.refresh()
        try await waitUntil { codex.fetchCount == 1 }
        codex.resolveNext(remaining: 91)
        try await waitUntil { coordinator.state(for: .codex)?.refreshing == false }

        coordinator.refresh(force: true)
        try await waitUntil { codex.fetchCount == 2 }
        coordinator.selectService(.antigravity)

        #expect(coordinator.activeServiceID == .antigravity)
        #expect(store.string(forKey: ServiceCoordinator.activeServiceDefaultsKey) == "antigravity")
        #expect(codex.shutdownCount == 1)
        #expect(coordinator.state(for: .codex)?.refreshing == false)
        #expect(coordinator.state(for: .codex)?.snapshot?.remainingPercent == 91)

        try await waitUntil { agy.fetchCount == 1 }
        agy.resolveNext(remaining: 74)
        try await waitUntil { coordinator.state(for: .antigravity)?.refreshing == false }
        #expect(coordinator.activeState?.snapshot?.remainingPercent == 74)
        #expect(scheduled.last?.0 == 60)
    }

    @Test @MainActor func togglingServicesPersistsStateSwitchesActiveAndHandlesAllDisabled() async throws {
        let codex = ControlledTestProvider(descriptor: .codex, detected: true)
        let agy = ControlledTestProvider(descriptor: .antigravity, detected: true)
        let copilot = ControlledTestProvider(descriptor: .copilot, detected: true)
        let store = InMemoryConfigStore()
        let coordinator = ServiceCoordinator(
            registry: ServiceRegistry(providers: [codex, agy, copilot]),
            configStore: store,
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { coordinator.stop() }

        coordinator.setServiceEnabled(.codex, enabled: false)
        #expect(!coordinator.isServiceEnabled(.codex))
        #expect(codex.shutdownCount == 1)
        #expect(coordinator.activeServiceID == .antigravity)
        #expect(store.stringArray(forKey: ServiceCoordinator.disabledServicesDefaultsKey) == ["codex"])

        coordinator.selectService(.codex)
        #expect(coordinator.activeServiceID == .antigravity)

        coordinator.setServiceEnabled(.antigravity, enabled: false)
        coordinator.setServiceEnabled(.copilot, enabled: false)
        #expect(coordinator.activeServiceID == nil)
        #expect(coordinator.enabledServices.isEmpty)
        #expect(coordinator.detectedServices.count == 3)

        coordinator.setServiceEnabled(.copilot, enabled: true)
        #expect(coordinator.activeServiceID == .copilot)
        try await waitUntil { copilot.fetchCount >= 2 }

        let reloaded = ServiceCoordinator(
            registry: ServiceRegistry(providers: [
                ControlledTestProvider(descriptor: .codex, detected: true),
                ControlledTestProvider(descriptor: .antigravity, detected: true),
                ControlledTestProvider(descriptor: .copilot, detected: true),
            ]),
            configStore: store,
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { reloaded.stop() }
        #expect(!reloaded.isServiceEnabled(.codex))
        #expect(!reloaded.isServiceEnabled(.antigravity))
        #expect(reloaded.isServiceEnabled(.copilot))
        #expect(reloaded.activeServiceID == .copilot)
    }

    @Test @MainActor func sharedConfigStoreSynchronizesCustomExecutableBetweenCoordinatorAndProvider() {
        let store = InMemoryConfigStore()
        let codex = CodexProvider(configStore: store)
        let coordinator = ServiceCoordinator(
            registry: ServiceRegistry(providers: [codex]),
            configStore: store,
            startAutomatically: false,
            scheduler: { _, _ in }
        )
        defer { coordinator.stop() }

        // Point Codex to `/bin/sh` (always executable on macOS) via the coordinator's shared store.
        coordinator.setCustomExecutablePath("/bin/sh", for: .codex)
        #expect(coordinator.hasCustomExecutable(for: .codex))
        #expect(codex.detect() == .detected(source: "/bin/sh"))
        #expect(coordinator.detectionStatus(for: .codex) == .detected(source: "/bin/sh"))

        // Pointing to a nonexistent path clears detection immediately.
        coordinator.setCustomExecutablePath("/nonexistent/codex-bin", for: .codex)
        #expect(codex.detect() == .notFound)
        #expect(coordinator.detectionStatus(for: .codex) == .notFound)

        coordinator.setCustomExecutablePath(nil, for: .codex)
        #expect(!coordinator.hasCustomExecutable(for: .codex))
    }
}
