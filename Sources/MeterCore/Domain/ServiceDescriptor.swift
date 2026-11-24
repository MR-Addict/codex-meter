import Foundation

/// Stable identifier for a supported AI tool / usage provider.
///
/// Concrete service identifiers are declared via extensions inside each provider module
/// (e.g., `ServiceID.codex`, `ServiceID.antigravity`, `ServiceID.copilot`).
public struct ServiceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Static, UI-agnostic metadata describing a supported AI service.
///
/// Concrete descriptors are defined alongside their respective providers so adding a new
/// service does not require editing core domain types.
public struct ServiceDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: ServiceID
    public let name: String
    public let shortName: String
    public let defaultSubtitle: String
    public let docsURL: URL
    public let loginCommand: String?
    public let executableName: String
    public let headlinePolicy: HeadlinePolicy
    public let requirementLabel: String

    public init(
        id: ServiceID,
        name: String,
        shortName: String,
        defaultSubtitle: String,
        docsURL: URL,
        loginCommand: String?,
        executableName: String,
        headlinePolicy: HeadlinePolicy,
        requirementLabel: String
    ) {
        self.headlinePolicy = headlinePolicy
        self.id = id
        self.name = name
        self.shortName = shortName
        self.defaultSubtitle = defaultSubtitle
        self.docsURL = docsURL
        self.loginCommand = loginCommand
        self.executableName = executableName
        self.requirementLabel = requirementLabel
    }
}
