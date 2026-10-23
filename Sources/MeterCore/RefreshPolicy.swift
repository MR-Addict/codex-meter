import Foundation

/// Completion-based cadence; retries always take precedence over visibility.
public enum RefreshPolicy {
    public static func delay(open: Bool, lastSuccess: Date?, retryAt: Date?, now: Date) -> TimeInterval {
        if let retryAt { return max(0, retryAt.timeIntervalSince(now)) }
        guard let lastSuccess else { return 0 }
        return max(0, lastSuccess.addingTimeInterval(open ? 20 : 60).timeIntervalSince(now))
    }
    public static func retryDelay(error: Error, failures: Int) -> TimeInterval {
        switch error as? MeterError {
        case .missingCLI: return 60
        case .login, .unsupported: return 120
        default: return min(60, 5 * pow(2, Double(min(4, max(0, failures - 1)))))
        }
    }
}

public enum PanelDismissalPolicy {
    public static func outsideClick(isShown: Bool, enabled: Bool) -> Bool { isShown && enabled }
    public static func escape(isShown: Bool, isPanelWindow: Bool) -> Bool { isShown && isPanelWindow }
}
