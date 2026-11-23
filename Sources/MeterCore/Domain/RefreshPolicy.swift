import Foundation

/// Completion-based cadence; retries always take precedence over visibility.
public enum RefreshPolicy {
    public static let idleInterval: TimeInterval = 60
    public static let openInterval: TimeInterval = 20

    public static func delay(open: Bool, lastSuccess: Date?, retryAt: Date?, now: Date) -> TimeInterval {
        if let retryAt { return max(0, retryAt.timeIntervalSince(now)) }
        guard let lastSuccess else { return 0 }
        return max(0, lastSuccess.addingTimeInterval(open ? openInterval : idleInterval).timeIntervalSince(now))
    }

    public static func retryDelay(error: Error, failures: Int) -> TimeInterval {
        if let providerError = error as? ProviderError {
            switch providerError.category {
            case .setup: return 60
            case .auth, .update: return 120
            case .connection, .parse: break
            }
        }
        return min(60, 5 * pow(2, Double(min(4, max(0, failures - 1)))))
    }
}

public enum PanelDismissalPolicy {
    public static func outsideClick(isShown: Bool, isPresentingPanel: Bool = false) -> Bool {
        isShown && !isPresentingPanel
    }

    public static func escape(isShown: Bool, isPanelWindow: Bool) -> Bool {
        isShown && isPanelWindow
    }
}
