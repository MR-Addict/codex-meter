import Foundation

/// Registry holding all supported providers in canonical order and running local discovery.
@MainActor public final class ServiceRegistry {
    public let providers: [any UsageProvider]
    private let providersByID: [ServiceID: any UsageProvider]

    public init(providers: [any UsageProvider]) {
        self.providers = providers
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
    }

    public static func defaultRegistry(
        configStore: any ProviderConfigStore = UserDefaultsConfigStore(),
        commandRunner: any CommandRunning = ProcessCommandRunner()
    ) -> ServiceRegistry {
        ServiceRegistry(providers: [
            CodexProvider(configStore: configStore),
            AntigravityProvider(configStore: configStore, runner: commandRunner),
            CopilotProvider(configStore: configStore, runner: commandRunner),
        ])
    }

    public func provider(for id: ServiceID) -> (any UsageProvider)? {
        providersByID[id]
    }

    public func detectAll() -> [DetectedService] {
        providers.map { DetectedService(descriptor: $0.descriptor, status: $0.detect()) }
    }

    public func detectedServices() -> [DetectedService] {
        detectAll().filter(\.isDetected)
    }

    public func shutdownAll() {
        providers.forEach { $0.shutdown() }
    }
}
