import Foundation
import ServiceManagement

/// High-level status of the Launch at Login setting.
enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
}

/// Manages a per-user `launchd` LaunchAgent plist (`~/Library/LaunchAgents/<bundleID>.plist`)
/// so locally built / ad-hoc signed builds reliably launch at login across rebuilds.
final class LaunchAtLoginAgent {
    private let label: String
    private let launchAgentsDirectory: URL
    private let appBundlePath: () -> String
    private let fileManager: FileManager
    private let legacyCleanup: () -> Void

    init(
        label: String = Bundle.main.bundleIdentifier ?? "local.ai-meter.app",
        launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        appBundlePath: @escaping () -> String = { Bundle.main.bundlePath },
        fileManager: FileManager = .default,
        legacyCleanup: @escaping () -> Void = {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try? SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.label = label
        self.launchAgentsDirectory = launchAgentsDirectory
        self.appBundlePath = appBundlePath
        self.fileManager = fileManager
        self.legacyCleanup = legacyCleanup
    }

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    func status() -> LoginItemStatus {
        fileManager.fileExists(atPath: plistURL.path) ? .enabled : .disabled
    }

    func setEnabled(_ enabled: Bool) throws -> LoginItemStatus {
        legacyCleanup()
        if enabled {
            try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            let target = appBundlePath()
            let programArguments: [String] = target.hasSuffix(".app")
                ? ["/usr/bin/open", "-a", target]
                : [target]
            let payload: [String: Any] = [
                "Label": label,
                "ProgramArguments": programArguments,
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            return .enabled
        } else {
            if fileManager.fileExists(atPath: plistURL.path) {
                try fileManager.removeItem(at: plistURL)
            }
            return .disabled
        }
    }
}
