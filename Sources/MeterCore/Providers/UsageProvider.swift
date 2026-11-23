import Foundation

/// Optional supplemental file configuration exposed in Settings (e.g., Antigravity's statusLine JSON).
public struct SupplementalFileConfig: Equatable, Sendable {
    public let defaultsKey: String
    public let buttonTitle: String
    public let clearButtonTitle: String
    public let panelTitle: String
    public let defaultRelativeDirectory: String?
    public let unreadableErrorMessage: String

    public init(
        defaultsKey: String,
        buttonTitle: String,
        clearButtonTitle: String,
        panelTitle: String,
        defaultRelativeDirectory: String? = nil,
        unreadableErrorMessage: String
    ) {
        self.defaultsKey = defaultsKey
        self.buttonTitle = buttonTitle
        self.clearButtonTitle = clearButtonTitle
        self.panelTitle = panelTitle
        self.defaultRelativeDirectory = defaultRelativeDirectory
        self.unreadableErrorMessage = unreadableErrorMessage
    }
}

/// Declarative configuration schema for a provider.
public struct ProviderConfigSpec: Equatable, Sendable {
    public let executablePathKey: String
    public let supplementalFile: SupplementalFileConfig?

    public init(executablePathKey: String, supplementalFile: SupplementalFileConfig? = nil) {
        self.executablePathKey = executablePathKey
        self.supplementalFile = supplementalFile
    }
}

/// Pluggable AI service provider contract.
@MainActor public protocol UsageProvider: AnyObject {
    var descriptor: ServiceDescriptor { get }
    var configSpec: ProviderConfigSpec { get }
    func detect() -> DetectionStatus
    func fetchUsage() async throws -> UsageSnapshot
    func shutdown()
    func resetClient()
}
