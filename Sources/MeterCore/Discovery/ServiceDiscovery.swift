import Foundation

/// Outcome of probing the local Mac for a supported AI tool.
public enum DetectionStatus: Equatable, Sendable {
    case detected(source: String)
    case notFound

    public var isDetected: Bool {
        if case .detected = self { return true }
        return false
    }

    public var source: String? {
        if case .detected(let source) = self { return source }
        return nil
    }
}

/// Snapshot of a registered service's descriptor and local detection status.
public struct DetectedService: Identifiable, Equatable, Sendable {
    public let descriptor: ServiceDescriptor
    public let status: DetectionStatus

    public var id: ServiceID { descriptor.id }
    public var isDetected: Bool { status.isDetected }

    public init(descriptor: ServiceDescriptor, status: DetectionStatus) {
        self.descriptor = descriptor
        self.status = status
    }
}

/// Registry holding all supported providers in canonical order and running local discovery.
@MainActor public final class ServiceRegistry {
    public let providers: [any UsageProvider]
    private let providersByID: [ServiceID: any UsageProvider]

    public init(providers: [any UsageProvider]) {
        self.providers = providers
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
    }

    public static func defaultRegistry() -> ServiceRegistry {
        ServiceRegistry(providers: [
            CodexProvider(),
            AntigravityProvider(),
            CopilotProvider(),
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
