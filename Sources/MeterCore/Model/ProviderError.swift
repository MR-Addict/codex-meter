import Foundation

/// High-level failure categories that drive retry backoff and header subtitles.
public enum ErrorCategory: String, Equatable, Sendable {
    case setup
    case auth
    case update
    case connection
    case parse

    public var headerSubtitle: String {
        switch self {
        case .setup: return "Setup needed"
        case .auth: return "Sign-in needed"
        case .update: return "Update needed"
        case .connection, .parse: return "Connection issue"
        }
    }
}

/// Actionable recovery affordance shown in the popover error state.
public enum ProviderRecoveryKind: Equatable, Sendable {
    case locateExecutable
    case copyLoginCommand(String)
    case retryOnly
}

/// Provider-agnostic error surfaced to the coordinator and UI.
public struct ProviderError: Error, LocalizedError, Equatable, Sendable {
    public let category: ErrorCategory
    public let title: String
    public let message: String
    public let symbol: String
    public let recovery: ProviderRecoveryKind

    public init(
        category: ErrorCategory,
        title: String,
        message: String,
        symbol: String,
        recovery: ProviderRecoveryKind
    ) {
        self.category = category
        self.title = title
        self.message = message
        self.symbol = symbol
        self.recovery = recovery
    }

    public var errorDescription: String? { message }

    public static func missingExecutable(serviceName: String, executableName: String) -> ProviderError {
        ProviderError(
            category: .setup,
            title: "\(serviceName) CLI not found",
            message: "Install \(serviceName) CLI (`\(executableName)`), or choose its executable below.",
            symbol: "terminal",
            recovery: .locateExecutable
        )
    }

    public static func launchFailed(serviceName: String) -> ProviderError {
        ProviderError(
            category: .setup,
            title: "\(serviceName) CLI could not start",
            message: "\(serviceName) CLI could not start. Check the selected executable, then try again.",
            symbol: "exclamationmark.circle",
            recovery: .locateExecutable
        )
    }

    public static func authRequired(serviceName: String, command: String?, detail: String? = nil) -> ProviderError {
        let defaultMessage: String
        if let command {
            defaultMessage = "Sign in using ‘\(command)’ in Terminal, then refresh."
        } else {
            defaultMessage = "Sign in to \(serviceName), then refresh."
        }
        return ProviderError(
            category: .auth,
            title: "Sign in required",
            message: detail ?? defaultMessage,
            symbol: "person.crop.circle.badge.exclamationmark",
            recovery: command.map { .copyLoginCommand($0) } ?? .retryOnly
        )
    }

    public static func unsupported(serviceName: String, detail: String? = nil) -> ProviderError {
        ProviderError(
            category: .update,
            title: "\(serviceName) update needed",
            message: detail ?? "Update \(serviceName) CLI: this version does not support the required usage interface.",
            symbol: "arrow.down.circle",
            recovery: .retryOnly
        )
    }

    public static func timeout(serviceName: String) -> ProviderError {
        ProviderError(
            category: .connection,
            title: "Can't reach \(serviceName)",
            message: "\(serviceName) did not respond within 20 seconds. Check your connection and refresh.",
            symbol: "wifi.exclamationmark",
            recovery: .retryOnly
        )
    }

    public static func disconnected(serviceName: String) -> ProviderError {
        ProviderError(
            category: .connection,
            title: "Can't reach \(serviceName)",
            message: "The \(serviceName) connection closed. Refresh to reconnect.",
            symbol: "wifi.exclamationmark",
            recovery: .retryOnly
        )
    }

    public static func malformed(serviceName: String) -> ProviderError {
        ProviderError(
            category: .parse,
            title: "Unexpected response",
            message: "\(serviceName) returned an unreadable usage response. Try updating \(serviceName) CLI.",
            symbol: "questionmark.circle",
            recovery: .retryOnly
        )
    }

    public static func serviceUnavailable(serviceName: String, detail: String? = nil) -> ProviderError {
        ProviderError(
            category: .connection,
            title: "Usage unavailable",
            message: detail ?? "Usage could not be fetched. Check your connection and \(serviceName) login, then refresh.",
            symbol: "wifi.exclamationmark",
            recovery: .retryOnly
        )
    }
}
