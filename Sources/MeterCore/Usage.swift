import Foundation
import Combine

public struct Usage: Decodable {
    public let rateLimits: Bucket?
    public let rateLimitsByLimitId: [String: Bucket]?
    public let rateLimitResetCredits: ResetCredits?
    public var core: Bucket? { rateLimitsByLimitId?["codex"] ?? rateLimits }
    public var remaining: Int? { core?.windows.map(\.remaining).min() }
    public var additionalBuckets: [(String, Bucket)] {
        (rateLimitsByLimitId ?? [:]).filter { $0.key != "codex" }.sorted { $0.key < $1.key }
    }
    /// The soonest reset across every allowance currently reported.
    public var nearestReset: Window? {
        let windows = (core?.windows ?? []) + additionalBuckets.flatMap { $0.1.windows }
        return windows.compactMap { window -> (Window, Double)? in
            guard let reset = window.resetsAt else { return nil }
            return (window, reset)
        }.min { $0.1 < $1.1 }?.0
    }
    public func resetSummary(now: Date = Date()) -> String? {
        nearestReset?.resetText(now: now)
    }
    public static func decode(_ data: Data) throws -> Usage {
        let result = try JSONDecoder().decode(Usage.self, from: data)
        guard result.rateLimits != nil || result.rateLimitsByLimitId != nil else { throw MeterError.malformed }
        return result
    }
}
public struct Bucket: Decodable {
    public let limitName: String?
    public let primary: Window?
    public let secondary: Window?
    public let credits: Credits?
    public var windows: [Window] { [primary, secondary].compactMap { $0 } }
}
public struct Window: Decodable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?
    public var remaining: Int { Int(floor(max(0, min(100, 100 - usedPercent)))) }
    public var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Allowance" }
        if minutes == 10080 { return "Weekly" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
    public func resetText(now: Date = Date()) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = resetsAt - now.timeIntervalSince1970
        guard seconds > 0 else { return "Reset due · refresh to check" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}
public struct Credits: Decodable {
    public let balance: String?
    public let unlimited: Bool?
    public var display: String { unlimited == true ? "Unlimited" : balance ?? "Unavailable" }
}
public struct ResetCredits: Decodable { public let availableCount: Int? }

public enum MeterError: Error, LocalizedError {
    case missingCLI, login, unsupported, timeout, disconnected, malformed, service, launch
    public var errorDescription: String? {
        switch self {
        case .missingCLI: return "Install Codex CLI, or choose its executable below."
        case .login: return "Sign in using ‘codex login’ in Terminal, then refresh. A ChatGPT login is required."
        case .unsupported: return "Update Codex CLI: this version does not support the required account interface."
        case .timeout: return "Codex did not respond within 20 seconds. Check your connection and refresh."
        case .disconnected: return "The Codex connection closed. Refresh to reconnect."
        case .malformed: return "Codex returned an unreadable usage response. Try updating Codex CLI."
        case .service: return "Usage could not be fetched. Check your connection and Codex login, then refresh."
        case .launch: return "Codex CLI could not start. Check the selected executable, then try again."
        }
    }
}
public enum CLILocator {
    public static func locate(custom: String? = nil) -> String? {
        let candidates = custom.map { [$0] } ?? (["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" })
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@MainActor public final class UsageState: ObservableObject {
    @Published public private(set) var usage: Usage?
    @Published public private(set) var lastSuccess: Date?
    @Published public private(set) var error: String?
    @Published public private(set) var failure: MeterError?
    @Published public private(set) var refreshing = false
    public init() {}
    public var title: String {
        let value = usage?.remaining.map { "\($0)%" } ?? "—"
        return "Codex \(value)\(error != nil && usage != nil ? " ⚠︎" : "")"
    }
    public func begin() -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        return true
    }
    public func succeed(_ value: Usage, now: Date = Date()) {
        usage = value; lastSuccess = now; error = nil; failure = nil; refreshing = false
    }
    public func fail(_ failure: Error) {
        self.failure = failure as? MeterError
        error = failure.localizedDescription
        refreshing = false
    }
}
