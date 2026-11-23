import Foundation

/// Single source of truth for application identity and version metadata.
public enum AppMetadata {
    public static let clientName = "ai_meter"
    public static let displayName = "AI Meter"
    public static let fallbackVersion = "0.3.0"

    public static var version: String {
        if let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !bundled.isEmpty {
            return bundled
        }
        return fallbackVersion
    }
}
