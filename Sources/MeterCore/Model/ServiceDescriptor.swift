import Foundation

/// Stable identifier for a supported AI tool / usage provider.
public struct ServiceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let codex = ServiceID("codex")
    public static let antigravity = ServiceID("antigravity")
}

/// Visual icon identity rendered in the menu bar and popover header.
public enum ServiceIconKind: String, Equatable, Hashable, Sendable {
    case codex
    case antigravity
    case generic
}

/// Static metadata describing a supported AI service.
public struct ServiceDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: ServiceID
    public let name: String
    public let shortName: String
    public let defaultSubtitle: String
    public let iconKind: ServiceIconKind
    public let docsURL: URL
    public let loginCommand: String?
    public let executableName: String
    public let requirementLabel: String
    public let supportsStatusFile: Bool

    public init(
        id: ServiceID,
        name: String,
        shortName: String,
        defaultSubtitle: String,
        iconKind: ServiceIconKind,
        docsURL: URL,
        loginCommand: String?,
        executableName: String,
        requirementLabel: String,
        supportsStatusFile: Bool = false
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.defaultSubtitle = defaultSubtitle
        self.iconKind = iconKind
        self.docsURL = docsURL
        self.loginCommand = loginCommand
        self.executableName = executableName
        self.requirementLabel = requirementLabel
        self.supportsStatusFile = supportsStatusFile
    }

    public static let codex = ServiceDescriptor(
        id: .codex,
        name: "Codex",
        shortName: "Codex",
        defaultSubtitle: "ChatGPT allowance",
        iconKind: .codex,
        docsURL: URL(string: "https://developers.openai.com/codex/cli")!,
        loginCommand: "codex login",
        executableName: "codex",
        requirementLabel: "Codex CLI",
        supportsStatusFile: false
    )

    public static let antigravity = ServiceDescriptor(
        id: .antigravity,
        name: "Antigravity",
        shortName: "Antigravity",
        defaultSubtitle: "Google AI quota",
        iconKind: .antigravity,
        docsURL: URL(string: "https://antigravity.google/docs/cli/reference")!,
        loginCommand: "agy",
        executableName: "agy",
        requirementLabel: "Antigravity CLI (agy)",
        supportsStatusFile: true
    )
}
