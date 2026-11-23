import Foundation

/// Configuration keys stored in `UserDefaults` for a provider.
public struct ProviderConfigKeys: Equatable, Sendable {
    public let executablePathKey: String
    public let statusFilePathKey: String?

    public init(executablePathKey: String, statusFilePathKey: String? = nil) {
        self.executablePathKey = executablePathKey
        self.statusFilePathKey = statusFilePathKey
    }
}

/// Pluggable AI service provider contract.
@MainActor public protocol UsageProvider: AnyObject {
    var descriptor: ServiceDescriptor { get }
    var configKeys: ProviderConfigKeys { get }
    func detect() -> DetectionStatus
    func fetchUsage() async throws -> UsageSnapshot
    func shutdown()
    func resetClient()
}
